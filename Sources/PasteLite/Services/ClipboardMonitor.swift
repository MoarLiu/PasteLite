import AppKit
import CryptoKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private weak var historyStore: (any HistoryStore)?
    private var timer: Timer?
    private var captureTask: Task<Void, Never>?
    private let onError: (String) -> Void
    private var lastChangeCount: Int
    private let pasteboard: NSPasteboard
    private let pollInterval: TimeInterval = 0.5
    private let maxAssetByteCount = 20 * 1024 * 1024
    private let maxItemByteCount = 64 * 1024 * 1024

    private let supportedTypes = Set(NSPasteboard.PasteboardType.pasteLiteReadableTypes)

    init(historyStore: any HistoryStore, pasteboard: NSPasteboard = .general,
         onError: @escaping (String) -> Void = { _ in }) {
        self.onError = onError
        self.historyStore = historyStore
        self.pasteboard = pasteboard
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
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
    }

    func checkForChanges() async {
        guard captureTask == nil else { return }
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        if PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: currentChangeCount, on: pasteboard) {
            return
        }

        let rootTypes = Set(pasteboard.types ?? [])
        guard !rootTypes.isDisjoint(with: supportedTypes),
              !pasteboard.pasteLiteHasIgnoredTypes else {
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceName = sourceApp?.localizedName
        let sourceIdentifier = sourceApp?.bundleIdentifier
        let copiedAt = Date()
        let itemAssets = collectAssets()
        let nativeColorHex: String?
        if itemAssets.contains(where: { NSPasteboard.PasteboardType.pasteLiteColorTypes.contains($0.pasteboardType) }),
           let color = NSColor(from: pasteboard) {
            nativeColorHex = ColorDetector.hexString(from: color)
        } else {
            nativeColorHex = nil
        }
        // A provider may replace the clipboard while its promised data is read.
        guard pasteboard.changeCount == currentChangeCount, !itemAssets.isEmpty else { return }

        captureTask = Task { [weak self] in
            let processing = Task.detached(priority: .utility) {
                ClipboardItemFactory.make(assets: itemAssets, nativeColorHex: nativeColorHex,
                                          sourceAppName: sourceName, sourceBundleIdentifier: sourceIdentifier,
                                          copiedAt: copiedAt)
            }
            let item = await withTaskCancellationHandler {
                await processing.value
            } onCancel: {
                processing.cancel()
            }
            guard let self else { return }
            defer { self.captureTask = nil }
            guard !Task.isCancelled, let item, let historyStore = self.historyStore else { return }
            let result = await historyStore.add(item)
            if case let .failure(message) = result, !Task.isCancelled {
                self.onError(message)
            }
        }
        await captureTask?.value
    }

    private func collectAssets() -> [ClipboardAsset] {
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
                appendAsset(
                    ClipboardAsset(index: itemIndex, pasteboardType: type, data: data),
                    to: &assets,
                    totalByteCount: &totalByteCount
                )
            }
        }

        if assets.isEmpty {
            for type in supportedTypes.sorted(by: { $0.rawValue < $1.rawValue }) {
                guard let data = pasteboard.data(forType: type) else { continue }
                appendAsset(
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
    ) {
        guard asset.data.count <= maxAssetByteCount,
              totalByteCount + asset.data.count <= maxItemByteCount else {
            return
        }

        totalByteCount += asset.data.count
        assets.append(asset)
    }

}

enum ClipboardItemFactory {
    static func make(assets: [ClipboardAsset], nativeColorHex: String?, sourceAppName: String?,
                     sourceBundleIdentifier: String?, copiedAt: Date) -> ClipboardItem? {
        guard !Task.isCancelled, !assets.isEmpty else { return nil }
        let textAsset = assets.first(where: { $0.pasteboardType == .string })
            ?? assets.first(where: { $0.pasteboardType == .URL })
        let text = textAsset.flatMap { String(data: $0.data, encoding: .utf8) } ?? ""
        let kind: ClipboardKind
        let preview: String
        let title: String
        if assets.contains(where: { $0.pasteboardType == .fileURL }) {
            kind = .file
            let files = assets.filter { $0.pasteboardType == .fileURL }
            preview = files.compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.path }.joined(separator: "\n")
            title = files.count == 1 ? "File" : "\(files.count) Files"
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
