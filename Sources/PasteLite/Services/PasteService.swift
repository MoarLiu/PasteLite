import AppKit
import Foundation

enum PasteServiceResult: Equatable {
    case success
    case failure(String)

    var isSuccess: Bool {
        if case .success = self {
            return true
        }
        return false
    }
}

@MainActor
final class PasteService {
    private weak var historyStore: (any HistoryStore)?
    private let pasteboard: NSPasteboard
    private let environment: any PasteEnvironment

    init(historyStore: any HistoryStore, pasteboard: NSPasteboard = .general, environment: (any PasteEnvironment)? = nil) {
        self.environment = environment ?? SystemPasteEnvironment()
        self.historyStore = historyStore
        self.pasteboard = pasteboard
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem, plainText: Bool = false) async -> PasteServiceResult {
        let changeCount = pasteboard.changeCount
        let generation = historyStore?.actionGeneration
        do {
            let loaded = try await resolve(item)
            let prepared = try await prepare(loaded, plainText: plainText)
            try Task.checkCancellation()
            guard pasteboard.changeCount == changeCount, historyStore?.actionGeneration == generation else {
                return .failure("The clipboard changed while loading this item. Please copy it again.")
            }
            return write(prepared)
        } catch is CancellationError {
            return .failure("Copy cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    @discardableResult
    func paste(_ item: ClipboardItem, into previousApp: NSRunningApplication?,
               plainText: Bool = false, beforeActivation: @MainActor () -> Void = {}) async -> PasteServiceResult {
        guard let target = previousApp, !environment.isTerminated(target),
              target.processIdentifier != environment.ownProcessIdentifier else {
            return .failure("The target app is unavailable. Open history from the app you want to paste into.")
        }
        guard environment.requestAccessibility() else {
            return .failure("Paste requires Accessibility permission. Enable it in System Settings, then try again.")
        }

        let startingPID = environment.frontmostProcessIdentifier
        let originalChangeCount = pasteboard.changeCount
        let generation = historyStore?.actionGeneration
        do {
            let loaded = try await resolve(item)
            let prepared = try await prepare(loaded, plainText: plainText)
            try Task.checkCancellation()
            guard !environment.isTerminated(target),
                  environment.frontmostProcessIdentifier == startingPID,
                  pasteboard.changeCount == originalChangeCount,
                  historyStore?.actionGeneration == generation else {
                return .failure("The active app or clipboard changed. Paste was cancelled.")
            }
            let result = write(prepared)
            guard result.isSuccess else { return result }
            let writtenChangeCount = pasteboard.changeCount
            beforeActivation()
            try Task.checkCancellation()

            let activated = environment.activate(target)
            guard activated else { return .failure("Could not activate the target app. The item was copied to the clipboard.") }

            let deadline = environment.uptime + 1
            var activeObservations = 0
            while environment.uptime < deadline {
                try await environment.waitForActivation()
                try Task.checkCancellation()
                guard !environment.isTerminated(target), environment.isAccessibilityTrusted,
                      pasteboard.changeCount == writtenChangeCount,
                      historyStore?.actionGeneration == generation else {
                    return .failure("The target app, permission, or clipboard changed. Paste was cancelled.")
                }
                let activePID = environment.frontmostProcessIdentifier
                if activePID == target.processIdentifier, environment.isActive(target) {
                    activeObservations += 1
                    if activeObservations >= 2 {
                        guard environment.sendPaste(to: target) else {
                            return .failure("Could not send Paste to the target app. The item is on the clipboard.")
                        }
                        return .success
                    }
                } else {
                    activeObservations = 0
                    if let activePID, activePID != startingPID,
                       activePID != environment.ownProcessIdentifier {
                        return .failure("The active app changed. Paste was cancelled.")
                    }
                }
            }
            return .failure("The target app did not become active. The item was copied to the clipboard.")
        } catch is CancellationError {
            return .failure("Paste cancelled.")
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    func copyString(_ string: String) -> PasteServiceResult {
        write(ClipboardItem(title: string, kind: .text, contentHash: "",
                            previewText: string, assets: [.init(index: 0, pasteboardType: .string, data: Data(string.utf8))]))
    }

    private func prepare(_ item: ClipboardItem, plainText: Bool) async throws -> ClipboardItem {
        guard !item.isExpired else { throw HistoryItemLoadError.unavailable }
        if item.origin == .library, item.kind == .file {
            let paths = item.assets.filter { $0.pasteboardType == .fileURL }
                .compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.path }
            guard !paths.isEmpty, paths.allSatisfy({ FileManager.default.fileExists(atPath: $0) }) else {
                throw LibraryError.invalid("A saved file is unavailable. It may have been moved or deleted.")
            }
        }
        guard plainText else { return item }
        let conversion = Task.detached(priority: .userInitiated) { Self.plainTextItem(item) }
        let prepared = await withTaskCancellationHandler { await conversion.value } onCancel: { conversion.cancel() }
        try Task.checkCancellation()
        guard !prepared.isExpired else { throw HistoryItemLoadError.unavailable }
        return prepared
    }

    nonisolated private static func plainTextItem(_ item: ClipboardItem) -> ClipboardItem {
        let text = ClipboardTextRepresentation.string(in: item.assets)
            ?? ([.color, .file].contains(item.kind) ? item.previewText : nil)
        guard let text else { return item }
        var result = item
        result.assets = [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))]
        return result
    }

    private func resolve(_ item: ClipboardItem) async throws -> ClipboardItem {
        try Task.checkCancellation()
        guard !item.isExpired else { throw HistoryItemLoadError.unavailable }
        if item.hasLoadedAssets, item.origin == .history { return item }
        guard let historyStore else { throw HistoryItemLoadError.unavailable }
        return try await historyStore.resolve(item)
    }

    private func write(_ item: ClipboardItem) -> PasteServiceResult {
        let originalChangeCount = pasteboard.changeCount
        let preparedItems = preparePasteboardItems(for: item)
        guard preparedItems.result.isSuccess else { return preparedItems.result }
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)
        guard pasteboard.changeCount == originalChangeCount else {
            return .failure("The clipboard changed while preparing this item. Please try again.")
        }

        pasteboard.clearContents()
        guard pasteboard.writeObjects(preparedItems.items) else {
            snapshot?.restore(to: pasteboard)
            PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
            return .failure("Could not write clipboard item.")
        }

        guard pasteboard.setString("1", forType: .pasteLiteSelfMarker) else {
            snapshot?.restore(to: pasteboard)
            PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
            return .failure("Could not mark clipboard write.")
        }

        PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
        return .success
    }

    private func preparePasteboardItems(for item: ClipboardItem) -> (items: [NSPasteboardItem], result: PasteServiceResult) {
        guard !item.assets.isEmpty else {
            return ([], .failure("Clipboard item has no data to copy."))
        }

        var groupedItems: [Int: NSPasteboardItem] = [:]
        for asset in item.assets {
            let pasteboardItem = groupedItems[asset.index] ?? NSPasteboardItem()
            guard pasteboardItem.setData(asset.data, forType: asset.pasteboardType),
                  pasteboardItem.setPasteLiteSelfMarker() else {
                return ([], .failure("Could not prepare clipboard item."))
            }
            groupedItems[asset.index] = pasteboardItem
        }
        if item.kind == .concealed {
            for pasteboardItem in groupedItems.values {
                guard pasteboardItem.setString("1", forType: .concealed) else {
                    return ([], .failure("Could not preserve concealed content protection."))
                }
            }
        }

        let items = groupedItems.keys.sorted().compactMap { groupedItems[$0] }
        guard !items.isEmpty else {
            return ([], .failure("Clipboard item has no writable data."))
        }

        return (items, .success)
    }

}

struct PasteboardSnapshot {
    private static let restorableTypes = Set(NSPasteboard.PasteboardType.pasteLiteReadableTypes)
    private static let maxTypeByteCount = 20 * 1024 * 1024
    private static let maxSnapshotByteCount = 64 * 1024 * 1024

    var items: [NSPasteboardItem]

    static func capture(from pasteboard: NSPasteboard) -> PasteboardSnapshot? {
        var totalByteCount = 0
        let items = pasteboard.pasteboardItems?.compactMap { item in
            copyItem(item, totalByteCount: &totalByteCount)
        } ?? []

        guard !items.isEmpty else {
            let rootItems = copyRootTypes(from: pasteboard, totalByteCount: &totalByteCount)
            return rootItems.isEmpty ? nil : PasteboardSnapshot(items: rootItems)
        }
        return PasteboardSnapshot(items: items)
    }

    func restore(to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        _ = pasteboard.writeObjects(items)
    }

    private static func copyItem(_ item: NSPasteboardItem, totalByteCount: inout Int) -> NSPasteboardItem? {
        let copiedItem = NSPasteboardItem()
        var copiedTypeCount = 0
        for type in item.types {
            guard shouldRestore(type),
                  let data = item.data(forType: type),
                  canAdd(data, totalByteCount: &totalByteCount),
                  copiedItem.setData(data, forType: type) else {
                continue
            }
            copiedTypeCount += 1
        }
        return copiedTypeCount > 0 ? copiedItem : nil
    }

    private static func copyRootTypes(from pasteboard: NSPasteboard, totalByteCount: inout Int) -> [NSPasteboardItem] {
        let copiedItem = NSPasteboardItem()
        var copiedTypeCount = 0
        for type in pasteboard.types ?? [] {
            guard shouldRestore(type),
                  let data = pasteboard.data(forType: type),
                  canAdd(data, totalByteCount: &totalByteCount),
                  copiedItem.setData(data, forType: type) else {
                continue
            }
            copiedTypeCount += 1
        }
        return copiedTypeCount > 0 ? [copiedItem] : []
    }

    private static func shouldRestore(_ type: NSPasteboard.PasteboardType) -> Bool {
        restorableTypes.contains(type) || [.concealed, .transient, .autoGenerated].contains(type)
    }

    private static func canAdd(_ data: Data, totalByteCount: inout Int) -> Bool {
        guard data.count <= maxTypeByteCount,
              totalByteCount + data.count <= maxSnapshotByteCount else {
            return false
        }

        totalByteCount += data.count
        return true
    }
}
