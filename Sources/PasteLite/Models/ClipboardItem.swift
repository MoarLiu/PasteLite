import AppKit
import Foundation

enum ClipboardKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case link
    case color
    case image
    case file

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .color: "Color"
        case .image: "Image"
        case .file: "File"
        }
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable {
    case all
    case text
    case image
    case file
    case link
    case color

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All Types"
        case .text: "Text Only"
        case .image: "Images Only"
        case .file: "Files Only"
        case .link: "Links Only"
        case .color: "Colors Only"
        }
    }
}

struct ClipboardAsset: Identifiable, Hashable, Sendable {
    let id = UUID()
    var index: Int
    var pasteboardType: NSPasteboard.PasteboardType
    var data: Data
}

struct ClipboardItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var title: String
    var kind: ClipboardKind
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var copiedAt: Date
    var contentHash: String
    var previewText: String
    var assets: [ClipboardAsset]
    var hasLoadedAssets: Bool

    init(
        id: UUID = UUID(),
        title: String,
        kind: ClipboardKind,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        copiedAt: Date = Date(),
        contentHash: String,
        previewText: String,
        assets: [ClipboardAsset],
        hasLoadedAssets: Bool = true
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.sourceAppName = sourceAppName
        self.sourceBundleIdentifier = sourceBundleIdentifier
        self.copiedAt = copiedAt
        self.contentHash = contentHash
        self.previewText = previewText
        self.assets = assets
        self.hasLoadedAssets = hasLoadedAssets
    }

    var assetByteCount: Int {
        assets.reduce(0) { $0 + $1.data.count }
    }

    var metadataOnly: ClipboardItem {
        var item = self
        item.assets = []
        item.hasLoadedAssets = false
        return item
    }
}
