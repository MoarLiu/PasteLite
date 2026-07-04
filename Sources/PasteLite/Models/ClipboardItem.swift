import AppKit
import Foundation

enum ClipboardKind: String, CaseIterable, Codable, Identifiable {
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

struct ClipboardAsset: Identifiable, Hashable {
    let id = UUID()
    var index: Int
    var pasteboardType: NSPasteboard.PasteboardType
    var data: Data
}

struct ClipboardItem: Identifiable, Hashable {
    let id: UUID
    var title: String
    var kind: ClipboardKind
    var sourceAppName: String?
    var sourceBundleIdentifier: String?
    var copiedAt: Date
    var contentHash: String
    var previewText: String
    var assets: [ClipboardAsset]

    init(
        id: UUID = UUID(),
        title: String,
        kind: ClipboardKind,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        copiedAt: Date = Date(),
        contentHash: String,
        previewText: String,
        assets: [ClipboardAsset]
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
    }
}
