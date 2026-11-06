import AppKit
import CryptoKit
import Foundation

struct ClipboardCapture: Sendable {
    var assets: [ClipboardAsset]
    var nativeColorHex: String?
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var copiedAt: Date

    func makeItem() -> ClipboardItem? {
        ClipboardItemFactory.make(assets: assets, nativeColorHex: nativeColorHex,
                                  sourceAppName: sourceAppName, sourceBundleIdentifier: sourceBundleIdentifier,
                                  copiedAt: copiedAt)
    }
}

enum ClipboardCaptureError: LocalizedError {
    case representationTooLarge
    case itemTooLarge

    var errorDescription: String? {
        switch self {
        case .representationTooLarge:
            return "Clipboard item was not saved because part of its content exceeds the 20 MiB limit."
        case .itemTooLarge:
            return "Clipboard item was not saved because its total size exceeds the 64 MiB limit."
        }
    }
}

@MainActor
final class ClipboardMonitor {
    typealias CaptureProcessor = @Sendable (ClipboardCapture) async -> ClipboardItem?

    private weak var historyStore: (any HistoryStore)?
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private let onError: (String) -> Void
    private let processCapture: CaptureProcessor
    private var lastChangeCount: Int
    private let pasteboard: NSPasteboard
    private let preferences: AppPreferences?
    private let sourceApplication: () -> (String?, String?)
    private var lastSourceApplicationName: String?
    private var lastSourceBundleIdentifier: String?
    private var sourceApplicationDidChange = false
    private var sourceActivationObserver: NSObjectProtocol?
    private let pollInterval: TimeInterval = 0.5
    private let maxAssetByteCount = 20 * 1024 * 1024
    private let maxItemByteCount = 64 * 1024 * 1024

    private let supportedTypes = Set(NSPasteboard.PasteboardType.pasteLiteReadableTypes)

    init(historyStore: any HistoryStore, pasteboard: NSPasteboard = .general,
         processCapture: @escaping CaptureProcessor = { $0.makeItem() },
         onError: @escaping (String) -> Void = { _ in }, preferences: AppPreferences? = nil,
         sourceApplication: @escaping () -> (String?, String?) = {
             let app = NSWorkspace.shared.frontmostApplication
             return (app?.localizedName, app?.bundleIdentifier)
         }) {
        self.onError = onError
        self.processCapture = processCapture
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.preferences = preferences
        self.sourceApplication = sourceApplication
        self.lastChangeCount = pasteboard.changeCount
        let initialSource = sourceApplication()
        self.lastSourceApplicationName = initialSource.0
        self.lastSourceBundleIdentifier = initialSource.1
    }

    func start() {
        guard timer == nil else { return }
        if sourceActivationObserver == nil {
            sourceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // The observer runs on the main queue. Mark the switch before
                // the next poll, rather than deferring it to another task.
                MainActor.assumeIsolated { self?.sourceApplicationDidChange = true }
            }
        }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.checkForChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        captureTask?.cancel()
        if let sourceActivationObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(sourceActivationObserver)
        }
        sourceActivationObserver = nil
    }

    func checkForChanges() async {
        guard captureTask == nil, let historyStore else { return }
        let source = sourceApplication()
        let sourceChanged = sourceApplicationDidChange ||
            source.1 != lastSourceBundleIdentifier ||
            (source.1 == nil && source.0 != lastSourceApplicationName)
        sourceApplicationDidChange = false
        lastSourceApplicationName = source.0
        lastSourceBundleIdentifier = source.1

        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount
        guard preferences?.recordingPaused != true else { return }

        if PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: currentChangeCount, on: pasteboard) {
            return
        }
        // A pasteboard change observed during an app switch cannot be attributed safely.
        // Drop it rather than risk recording content copied from an excluded application.
        guard !sourceChanged else { return }

        let rootTypes = Set(pasteboard.types ?? [])
        let allTypes = rootTypes.union(pasteboard.pasteboardItems?.flatMap(\.types) ?? [])
        let concealed = allTypes.contains(.concealed)
        let ignored = NSPasteboard.PasteboardType.pasteLiteIgnoredTypes.subtracting(
            preferences?.sensitivePolicy == .masked ? [.concealed] : []
        )
        guard !rootTypes.isDisjoint(with: supportedTypes), allTypes.isDisjoint(with: ignored) else {
            return
        }

        let (sourceName, sourceIdentifier) = source
        guard !((sourceIdentifier.map { preferences?.excludedApps.contains($0) == true }) ?? false) else { return }
        let copiedAt = Date()
        let generation = historyStore.captureGeneration
        let itemAssets: [ClipboardAsset]
        do {
            itemAssets = try collectAssets()
        } catch {
            guard pasteboard.changeCount == currentChangeCount else { return }
            historyStore.reportCaptureError(error.localizedDescription)
            onError(error.localizedDescription)
            return
        }
        let nativeColorHex: String?
        if itemAssets.contains(where: { NSPasteboard.PasteboardType.pasteLiteColorTypes.contains($0.pasteboardType) }),
           let color = NSColor(from: pasteboard) {
            nativeColorHex = ColorDetector.hexString(from: color)
        } else {
            nativeColorHex = nil
        }
        // A provider may replace the clipboard while its promised data is read.
        guard pasteboard.changeCount == currentChangeCount, !itemAssets.isEmpty else { return }

        let capture = ClipboardCapture(assets: itemAssets, nativeColorHex: nativeColorHex,
                                       sourceAppName: sourceName, sourceBundleIdentifier: sourceIdentifier,
                                       copiedAt: copiedAt)
        let processor = processCapture
        captureTask = Task { [weak self] in
            let processing = Task.detached(priority: .utility) {
                await processor(capture)
            }
            let item = await withTaskCancellationHandler {
                await processing.value
            } onCancel: {
                processing.cancel()
            }
            guard let self else { return }
            defer { self.captureTask = nil }
            guard !Task.isCancelled, var item, let historyStore = self.historyStore,
                  self.preferences?.recordingPaused != true,
                  !(sourceIdentifier.map { self.preferences?.excludedApps.contains($0) == true } ?? false),
                  !concealed || self.preferences?.sensitivePolicy == .masked else { return }
            if concealed {
                item.kind = .concealed
                item.expiresAt = item.copiedAt.addingTimeInterval(86400)
                item.title = "Concealed content"
                item.previewText = ""
            }
            let result = await historyStore.addCaptured(item, generation: generation)
            if case let .failure(message) = result, !Task.isCancelled,
               historyStore.captureGeneration == generation {
                self.onError(message)
            }
        }
        await captureTask?.value
    }

    private func collectAssets() throws -> [ClipboardAsset] {
        var assets: [ClipboardAsset] = []
        var totalByteCount = 0
        let items = pasteboard.pasteboardItems ?? []

        for (itemIndex, pasteboardItem) in items.enumerated() {
            let types = Set(pasteboardItem.types)
                .intersection(supportedTypes)
                .filter { !$0.isPasteLiteIgnored }
                .sorted { $0.rawValue < $1.rawValue }

            for type in types {
                guard let data = pasteboardItem.data(forType: type) else { continue }
                try appendAsset(
                    ClipboardAsset(index: itemIndex, pasteboardType: type, data: data),
                    to: &assets,
                    totalByteCount: &totalByteCount
                )
            }
        }

        if assets.isEmpty {
            for type in supportedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = pasteboard.data(forType: type) else { continue }
                try appendAsset(
                    ClipboardAsset(index: 0, pasteboardType: type, data: data),
                    to: &assets,
                    totalByteCount: &totalByteCount
                )
            }
        }

        return assets.sorted {
            if $0.index == $1.index {
                return $0.pasteboardType.rawValue < $1.pasteboardType.rawValue
            }
            return $0.index < $1.index
        }
    }

    private func appendAsset(
        _ asset: ClipboardAsset,
        to assets: inout [ClipboardAsset],
        totalByteCount: inout Int
    ) throws {
        guard asset.data.count <= maxAssetByteCount else { throw ClipboardCaptureError.representationTooLarge }
        guard totalByteCount + asset.data.count <= maxItemByteCount else { throw ClipboardCaptureError.itemTooLarge }

        totalByteCount += asset.data.count
        assets.append(asset)
    }

}

enum ClipboardItemFactory {
    static func make(assets: [ClipboardAsset], nativeColorHex: String?, sourceAppName: String?,
                     sourceBundleIdentifier: String?, copiedAt: Date) -> ClipboardItem? {
        guard !Task.isCancelled, !assets.isEmpty else { return nil }
        let text = ClipboardTextRepresentation.string(in: assets) ?? ""
        let kind: ClipboardKind
        let preview: String
        let title: String
        if assets.contains(where: { $0.pasteboardType == .fileURL }) {
            kind = .file
            let files = assets.filter { $0.pasteboardType == .fileURL }
            preview = files.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.path }.joined(separator: "\n")
            let firstName = files.first.flatMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.lastPathComponent } ?? "File"
            title = files.count == 1 ? firstName : "\(firstName) and \(files.count - 1) more"
        } else if assets.contains(where: { NSPasteboard.PasteboardType.pasteLiteImageTypes.contains($0.pasteboardType) }) {
            kind = .image
            preview = text
            title = ClipboardImageProcessor.title(for: assets)
        } else {
            preview = nativeColorHex ?? text
            if nativeColorHex != nil || ColorDetector.color(from: text) != nil {
                kind = .color
            } else if URLDetector.isLikelyURL(text) {
                kind = .link
            } else if CodeDetector.language(for: text) != nil {
                kind = .code
            } else {
                kind = .text
            }
            title = preview.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return nil }
        }
        let contentHash = ClipboardContentHasher.hash(assets: assets)
        guard !Task.isCancelled else { return nil }
        return ClipboardItem(title: title, kind: kind, sourceAppName: sourceAppName,
                             sourceBundleIdentifier: sourceBundleIdentifier, copiedAt: copiedAt,
                             contentHash: contentHash, previewText: preview, assets: assets)
    }
}

enum ClipboardContentHasher {
    static func hash(assets: [ClipboardAsset]) -> String {
        let orderedAssets = assets.sorted {
            if $0.index == $1.index {
                return $0.pasteboardType.rawValue < $1.pasteboardType.rawValue
            }
            return $0.index < $1.index
        }

        var hasher = SHA256()
        for asset in orderedAssets {
            update(UInt64(asset.index), hasher: &hasher)

            let typeData = Data(asset.pasteboardType.rawValue.utf8)
            update(UInt64(typeData.count), hasher: &hasher)
            hasher.update(data: typeData)

            update(UInt64(asset.data.count), hasher: &hasher)
            hasher.update(data: asset.data)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func update(_ value: UInt64, hasher: inout SHA256) {
        var encodedValue = value.bigEndian
        let data = withUnsafeBytes(of: &encodedValue) { Data($0) }
        hasher.update(data: data)
    }
}
