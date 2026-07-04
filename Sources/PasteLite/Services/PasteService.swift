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

    init(historyStore: any HistoryStore, pasteboard: NSPasteboard = .general) {
        self.historyStore = historyStore
        self.pasteboard = pasteboard
    }

    @discardableResult
    func copyToClipboard(_ item: ClipboardItem) -> PasteServiceResult {
        write(item)
    }

    @discardableResult
    func paste(_ item: ClipboardItem, into previousApp: NSRunningApplication?) -> PasteServiceResult {
        guard AccessibilityService.promptIfNeeded() else {
            return .failure("Paste requires Accessibility permission. Enable it in System Settings, then try again.")
        }

        let result = write(item)
        guard result.isSuccess else { return result }

        if #available(macOS 14.0, *) {
            previousApp?.activate()
        } else {
            previousApp?.activate(options: .activateIgnoringOtherApps)
        }

        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 120_000_000)
            guard AccessibilityService.isTrusted() else { return }
            Self.simulateCommandV()
        }
        return .success
    }

    private func write(_ item: ClipboardItem) -> PasteServiceResult {
        let preparedItems = preparePasteboardItems(for: item)
        guard preparedItems.result.isSuccess else { return preparedItems.result }
        let snapshot = PasteboardSnapshot.capture(from: pasteboard)

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

        let items = groupedItems.keys.sorted().compactMap { groupedItems[$0] }
        guard !items.isEmpty else {
            return ([], .failure("Clipboard item has no writable data."))
        }

        return (items, .success)
    }

    private static func simulateCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgAnnotatedSessionEventTap)
        keyUp?.post(tap: .cgAnnotatedSessionEventTap)
    }
}

private struct PasteboardSnapshot {
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
        restorableTypes.contains(type) && !type.isPasteLiteIgnored
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
