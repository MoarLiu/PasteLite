import AppKit
import Foundation

enum LibraryItemType: String, Codable, Sendable {
    case snapshot, snippet
}

struct LibraryGroup: Identifiable, Hashable, Sendable {
    let id: UUID
    var name: String
    var createdAt: Date
    var updatedAt: Date
}

enum LibraryGroupSelection: Hashable, Sendable {
    case all, ungrouped, group(UUID)

    var groupID: UUID? {
        if case let .group(id) = self { return id }
        return nil
    }

    var storedValue: String {
        switch self {
        case .all: return "all"
        case .ungrouped: return "ungrouped"
        case let .group(id): return id.uuidString
        }
    }

    init(storedValue: String) {
        if storedValue == "ungrouped" { self = .ungrouped }
        else if let id = UUID(uuidString: storedValue) { self = .group(id) }
        else { self = .all }
    }
}

struct LibraryItem: Identifiable, Hashable, Sendable {
    let id: UUID
    var groupID: UUID?
    var name: String
    var type: LibraryItemType
    var content: ClipboardItem
    var sourceHistoryID: UUID?
    var sourceContentHash: String?
    var savedAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var revision: Int

    var displayItem: ClipboardItem {
        var result = content
        result.title = name
        result.origin = .library
        result.contentRevision = revision
        result.copiedAt = savedAt
        result.isPinned = true
        return result
    }

    var metadataOnly: LibraryItem {
        var result = self
        result.content = content.metadataOnly
        return result
    }
}

struct LibraryDraft: Identifiable, Equatable, Sendable {
    let id = UUID()
    var editingID: UUID?
    var expectedRevision: Int?
    var type: LibraryItemType
    var name: String
    var groupID: UUID?
    var body: String
    var kind: ClipboardKind
    var source: ClipboardItem?
    var generation: Int

    var isSnippet: Bool { type == .snippet }
}

struct LibraryGroupDraft: Identifiable {
    let id = UUID()
    var group: LibraryGroup?
}

enum LibraryValidation {
    static let snippetByteLimit = 1024 * 1024
    static let representationByteLimit = 20 * 1024 * 1024
    static let itemByteLimit = 64 * 1024 * 1024

    static func defaultName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .components(separatedBy: .newlines).first ?? ""
        return name.isEmpty ? "Untitled" : String(name.prefix(120))
    }

    static func name(_ value: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 120, !result.contains("\n"), !result.contains("\r") else {
            throw LibraryError.invalid("Choose a name with 1–120 characters on one line.")
        }
        return result
    }

    static func groupName(_ value: String, existing: [LibraryGroup], excluding id: UUID? = nil) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty, result.count <= 40, !result.contains("\n"), !result.contains("\r") else {
            throw LibraryError.invalid("Choose a group name with 1–40 characters on one line.")
        }
        let reserved = ["All Saved", "All Favorites", "Ungrouped", "全部收藏", "未分组"]
        guard !reserved.contains(where: { $0.caseInsensitiveCompare(result) == .orderedSame }),
              !existing.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(result) == .orderedSame }) else {
            throw LibraryError.invalid("A group with this name already exists.")
        }
        return result
    }

    static func snippet(_ body: String, kind: ClipboardKind) throws {
        guard [.text, .code].contains(kind) else { throw LibraryError.invalid("Choose Text or Code for this snippet.") }
        guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LibraryError.invalid("Enter some text for this snippet.")
        }
        guard body.utf8.count <= snippetByteLimit else { throw LibraryError.invalid("A snippet can contain up to 1 MiB of text.") }
    }

    static func snapshot(_ item: ClipboardItem) throws {
        guard item.kind != .concealed, !item.isExpired,
              !item.assets.contains(where: { $0.pasteboardType == .concealed }) else {
            throw LibraryError.invalid("Concealed content cannot be saved permanently.")
        }
        guard item.hasLoadedAssets, !item.assets.isEmpty else { throw HistoryItemLoadError.unavailable }
        guard item.assets.allSatisfy({ $0.data.count <= representationByteLimit }),
              item.assetByteCount <= itemByteLimit else {
            throw LibraryError.invalid("This content exceeds the saved-item size limit.")
        }
    }
}

enum LibraryError: LocalizedError {
    case invalid(String), unavailable, changed, cleared

    var errorDescription: String? {
        switch self {
        case let .invalid(message): return message
        case .unavailable: return "Saved items require local storage. Restore storage access and retry."
        case .changed: return "This saved item changed. Reopen it before saving or copying."
        case .cleared: return "The library was cleared. Reopen the editor to create a new item."
        }
    }
}
