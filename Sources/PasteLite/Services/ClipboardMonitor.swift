import AppKit
import CryptoKit
import Foundation

@MainActor
final class ClipboardMonitor {
    private weak var historyStore: (any HistoryStore)?
    private var timer: Timer?
    private var lastChangeCount: Int
    private let pasteboard = NSPasteboard.general
    private let pollInterval: TimeInterval = 0.5
    private let maxAssetByteCount = 20 * 1024 * 1024
    private let maxItemByteCount = 64 * 1024 * 1024

    private let supportedTypes = Set(NSPasteboard.PasteboardType.pasteLiteReadableTypes)

    init(historyStore: any HistoryStore) {
        self.historyStore = historyStore
        self.lastChangeCount = pasteboard.changeCount
    }

    func start() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForChanges()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func checkForChanges() {
        let currentChangeCount = pasteboard.changeCount
        guard currentChangeCount != lastChangeCount else { return }
        lastChangeCount = currentChangeCount

        if PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: currentChangeCount) {
            return
        }

        let rootTypes = Set(pasteboard.types ?? [])
        guard !rootTypes.isDisjoint(with: supportedTypes),
              !pasteboard.pasteLiteHasIgnoredTypes else {
            return
        }

        let sourceApp = NSWorkspace.shared.frontmostApplication
        let itemAssets = collectAssets()
        guard !itemAssets.isEmpty else { return }

        let kind = detectKind(assets: itemAssets)
        let previewText = previewText(for: itemAssets, kind: kind)
        guard !previewText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || kind == .image || kind == .file else {
            return
        }

        let item = ClipboardItem(
            title: title(for: previewText, kind: kind, assets: itemAssets),
            kind: kind,
            sourceAppName: sourceApp?.localizedName,
            sourceBundleIdentifier: sourceApp?.bundleIdentifier,
            contentHash: ClipboardContentHasher.hash(assets: itemAssets),
            previewText: previewText,
            assets: itemAssets
        )

        historyStore?.add(item)
    }

    private func collectAssets() -> [ClipboardAsset] {
        var assets: [ClipboardAsset] = []
        var totalByteCount = 0
        let items = pasteboard.pasteboardItems ?? []

        for (itemIndex, pasteboardItem) in items.enumerated() {
            let types = Set(pasteboardItem.types)
                .intersection(supportedTypes)
                .filter { !$0.isPasteLiteIgnored }

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
            for type in supportedTypes {
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

    private func detectKind(assets: [ClipboardAsset]) -> ClipboardKind {
        if assets.contains(where: { $0.pasteboardType == .fileURL }) { return .file }
        if assets.contains(where: { NSPasteboard.PasteboardType.pasteLiteImageTypes.contains($0.pasteboardType) }) { return .image }
        let text = string(from: assets)
        if ColorDetector.color(from: text) != nil { return .color }
        if URLDetector.isLikelyURL(text) { return .link }
        return .text
    }

    private func previewText(for assets: [ClipboardAsset], kind: ClipboardKind) -> String {
        if kind == .file {
            return assets
                .filter { $0.pasteboardType == .fileURL }
                .compactMap { URL(dataRepresentation: $0.data, relativeTo: nil)?.path }
                .joined(separator: "\n")
        }
        return string(from: assets)
    }

    private func title(for previewText: String, kind: ClipboardKind, assets: [ClipboardAsset]) -> String {
        switch kind {
        case .image:
            if let imageAsset = assets.first(where: { NSPasteboard.PasteboardType.pasteLiteImageTypes.contains($0.pasteboardType) }),
               let image = NSImage(data: imageAsset.data) {
                return "Image (\(Int(image.size.width)) x \(Int(image.size.height)))"
            }
            return "Image"
        case .file:
            let count = assets.filter { $0.pasteboardType == .fileURL }.count
            return count == 1 ? "File" : "\(count) Files"
        case .color, .link, .text:
            return previewText.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private func string(from assets: [ClipboardAsset]) -> String {
        guard let data = assets.first(where: { $0.pasteboardType == .string || $0.pasteboardType == .URL })?.data else {
            return ""
        }
        return String(data: data, encoding: .utf8) ?? ""
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
