import AppKit
import Foundation

enum ClipboardKind: String, CaseIterable, Codable, Identifiable, Sendable {
    case text
    case link
    case color
    case image
    case file
    case code
    case concealed

    var id: String { rawValue }

    var title: String {
        switch self {
        case .text: "Text"
        case .link: "Link"
        case .color: "Color"
        case .image: "Image"
        case .file: "File"
        case .code: "Code"
        case .concealed: "Concealed"
        }
    }
}

enum HistoryFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case pinned
    case text
    case image
    case link
    case file
    case color

    var id: String { rawValue }

    static var contentFilters: [HistoryFilter] { allCases.filter { $0 != .pinned } }

    var title: String {
        switch self {
        case .all: "All"
        case .pinned: "Pinned"
        case .text: "Text"
        case .image: "Images"
        case .file: "Files"
        case .link: "Links"
        case .color: "Colors"
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
    var expiresAt: Date?
    var contentHash: String
    var previewText: String
    var assets: [ClipboardAsset]
    var hasLoadedAssets: Bool
    var isPinned: Bool = false
    var useCount: Int = 0
    var storedByteCount: Int = 0
    var origin: ClipboardOrigin = .history
    var contentRevision: Int = 0
    var recognizedText = ""
    var hasRecognizedText = false

    init(
        id: UUID = UUID(),
        title: String,
        kind: ClipboardKind,
        sourceAppName: String? = nil,
        sourceBundleIdentifier: String? = nil,
        copiedAt: Date = Date(),
        expiresAt: Date? = nil,
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
        self.expiresAt = expiresAt ?? (kind == .concealed ? copiedAt.addingTimeInterval(86400) : nil)
        self.contentHash = contentHash
        self.previewText = previewText
        self.assets = assets
        self.hasLoadedAssets = hasLoadedAssets
    }

    var assetByteCount: Int { hasLoadedAssets ? assets.reduce(0) { $0 + $1.data.count } : storedByteCount }
    var sourceKey: String { sourceBundleIdentifier ?? sourceAppName ?? "unknown" }
    var isExpired: Bool {
        guard kind == .concealed else { return false }
        return (expiresAt ?? copiedAt.addingTimeInterval(86400)) <= Date()
    }

    var metadataOnly: ClipboardItem {
        var item = self
        item.storedByteCount = assetByteCount
        item.assets = []
        item.hasLoadedAssets = false
        return item
    }
}

enum ClipboardOrigin: String, Codable, Sendable {
    case history, library
}

extension ClipboardKind {
    var symbol: String {
        switch self {
        case .text: return "text.alignleft"
        case .link: return "link"
        case .color: return "paintpalette"
        case .image: return "photo"
        case .file: return "folder.fill"
        case .code: return "chevron.left.forwardslash.chevron.right"
        case .concealed: return "lock.fill"
        }
    }
}
