import Foundation

enum MergedCopy {
    static func item(from items: [ClipboardItem], separator: String) throws -> ClipboardItem {
        guard !items.isEmpty, items.count <= 100, separator.utf8.count <= 1024 else {
            throw LibraryError.invalid("Choose between 1 and 100 items to merge.")
        }
        var parts: [String] = []
        var byteCount = 0
        for item in items {
            guard item.kind != .concealed, !item.isExpired,
                  !item.assets.contains(where: { $0.pasteboardType == .concealed }),
                  let text = ClipboardTextRepresentation.string(in: item.assets) else {
                throw LibraryError.invalid("“\(item.title)” has no mergeable text. Copy it separately.")
            }
            byteCount += text.utf8.count + (parts.isEmpty ? 0 : separator.utf8.count)
            guard byteCount <= LibraryValidation.itemByteLimit else { throw LibraryError.invalid("Merged text exceeds 64 MiB.") }
            parts.append(text)
        }
        let text = parts.joined(separator: separator)
        let assets: [ClipboardAsset] = [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))]
        return ClipboardItem(title: "Merged text", kind: .text, contentHash: ClipboardContentHasher.hash(assets: assets), previewText: text, assets: assets)
    }
}
