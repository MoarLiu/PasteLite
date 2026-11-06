import Foundation
import AppKit
import Darwin

/// Portable saved content. File payloads contain paths, never the referenced files.
struct LibraryArchive: Codable, Sendable {
    static let format = "PasteLite.Library"
    static let maximumBytes = 256 * 1024 * 1024
    var format = Self.format
    var version = 1
    var exportedAt = Date()
    var groups: [Group]
    var items: [Entry]

    struct Group: Codable, Sendable {
        var id: UUID
        var name: String
        var createdAt: Date
    }
    struct Asset: Codable, Sendable {
        var index: Int
        var type: String
        var data: Data
    }
    struct Entry: Codable, Sendable {
        var id: UUID
        var groupID: UUID?
        var name: String
        var type: String
        var kind: String
        var originalTitle: String
        var preview: String
        var sourceApp: String?
        var sourceBundle: String?
        var savedAt: Date
        var updatedAt: Date
        var uses: Int
        var assets: [Asset]

        init(_ item: LibraryItem) {
            id = item.id; groupID = item.groupID; name = item.name
            type = item.type.rawValue; kind = item.content.kind.rawValue
            originalTitle = item.content.title; preview = item.content.previewText
            sourceApp = item.content.sourceAppName; sourceBundle = item.content.sourceBundleIdentifier
            savedAt = item.savedAt; updatedAt = item.updatedAt; uses = item.content.useCount
            assets = item.content.assets.map { Asset(index: $0.index, type: $0.pasteboardType.rawValue, data: $0.data) }
        }

        func materialize(groupID: UUID?, id: UUID) throws -> LibraryItem {
            guard let itemType = LibraryItemType(rawValue: type),
                  let itemKind = ClipboardKind(rawValue: kind), uses >= 0,
                  assets.count <= 256, !assets.isEmpty else { throw LibraryError.invalid("The backup contains an invalid saved item.") }
            let validName = try LibraryValidation.name(name)
            let representations = assets.map { ClipboardAsset(index: $0.index, pasteboardType: .init($0.type), data: $0.data) }
            var keys = Set<String>()
            for asset in assets {
                guard (0...10000).contains(asset.index), !asset.type.isEmpty, asset.type.utf8.count <= 1024,
                      keys.insert("\(asset.index):\(asset.type)").inserted else {
                    throw LibraryError.invalid("The backup contains duplicate or invalid clipboard formats.")
                }
            }
            let hash = ClipboardContentHasher.hash(assets: representations)
            var content = ClipboardItem(id: id, title: originalTitle, kind: itemKind,
                                        sourceAppName: sourceApp, sourceBundleIdentifier: sourceBundle,
                                        copiedAt: savedAt, contentHash: hash, previewText: preview, assets: representations)
            try LibraryValidation.snapshot(content)
            if itemType == .snippet {
                try LibraryValidation.snippet(preview, kind: itemKind)
                guard representations.count == 1, representations[0].index == 0,
                      representations[0].pasteboardType == .string,
                      representations[0].data == Data(preview.utf8) else {
                    throw LibraryError.invalid("The backup contains an invalid text snippet.")
                }
            }
            content.useCount = uses
            content.origin = .library
            return LibraryItem(id: id, groupID: groupID, name: validName, type: itemType, content: content,
                               sourceHistoryID: nil, sourceContentHash: itemType == .snapshot ? hash : nil,
                               savedAt: savedAt, updatedAt: updatedAt, lastUsedAt: nil, revision: 1)
        }
    }

    func validatedItems() throws -> [LibraryItem] {
        guard format == Self.format, version == 1, items.count <= 10000, groups.count <= 1000,
              Set(groups.map(\.id)).count == groups.count, Set(items.map(\.id)).count == items.count else {
            throw LibraryError.invalid("This is not a supported PasteLite backup.")
        }
        var knownGroups: [LibraryGroup] = []
        for group in groups {
            let name = try LibraryValidation.groupName(group.name, existing: knownGroups)
            knownGroups.append(.init(id: group.id, name: name, createdAt: group.createdAt, updatedAt: group.createdAt))
        }
        let ids = Set(groups.map(\.id))
        var total = 0
        return try items.map { item in
            guard item.groupID == nil || ids.contains(item.groupID!) else { throw LibraryError.invalid("A backup item references a missing group.") }
            for asset in item.assets {
                guard asset.data.count <= LibraryValidation.representationByteLimit,
                      total <= Self.maximumBytes - asset.data.count else { throw LibraryError.invalid("The backup exceeds the size limit.") }
                total += asset.data.count
            }
            return try item.materialize(groupID: item.groupID, id: item.id)
        }
    }

    static func read(from url: URL) throws -> Self {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= maximumBytes else { throw LibraryError.invalid("A backup must be smaller than 256 MiB.") }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count <= maximumBytes else { throw LibraryError.invalid("The backup exceeds the size limit.") }
        let archive = try JSONDecoder().decode(Self.self, from: data)
        _ = try archive.validatedItems()
        return archive
    }

    func write(to url: URL) throws {
        _ = try validatedItems()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw LibraryError.invalid("The backup exceeds 256 MiB. Export a smaller library.") }
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".pastelite-backup-\(UUID().uuidString)")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}

struct LibraryImportResult: Sendable {
    var added: Int
    var skipped: Int
    var snapshot: HistorySnapshot
}
