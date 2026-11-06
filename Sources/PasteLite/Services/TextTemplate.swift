import Foundation

struct TextTemplate: Sendable {
    let text: String
    var variables: [String] {
        let expression = try! NSRegularExpression(pattern: #"\{\{\s*([\p{L}\p{N}_-]{1,64})\s*\}\}"#)
        let range = NSRange(text.startIndex..., in: text)
        var seen = Set<String>()
        return expression.matches(in: text, range: range).compactMap {
            guard let range = Range($0.range(at: 1), in: text) else { return nil }
            let name = String(text[range])
            return seen.insert(name).inserted ? name : nil
        }
    }

    func expand(values: [String: String]) throws -> String {
        let expression = try! NSRegularExpression(pattern: #"\{\{\s*([\p{L}\p{N}_-]{1,64})\s*\}\}"#)
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var bytes = text.utf8.count
        for match in matches {
            guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: text),
                  let value = values[String(text[keyRange])] else { throw LibraryError.invalid("Fill in every template variable.") }
            let replacementBytes = value.utf8.count
            guard replacementBytes <= LibraryValidation.snippetByteLimit else { throw LibraryError.invalid("Expanded text exceeds 1 MiB.") }
            bytes = bytes - text[range].utf8.count + replacementBytes
            guard bytes <= LibraryValidation.snippetByteLimit else { throw LibraryError.invalid("Expanded text exceeds 1 MiB.") }
        }
        var result = text
        for match in matches.reversed() {
            guard let keyRange = Range(match.range(at: 1), in: text), let range = Range(match.range, in: result),
                  let value = values[String(text[keyRange])] else { throw LibraryError.invalid("Fill in every template variable.") }
            result.replaceSubrange(range, with: value)
        }
        guard result.utf8.count <= LibraryValidation.snippetByteLimit else { throw LibraryError.invalid("Expanded text exceeds 1 MiB.") }
        return result
    }
}

struct TextToolDraft: Identifiable {
    let id = UUID()
    var item: ClipboardItem
    var text: String
    var script: URL?
    var paste: Bool
    var plainText: Bool
    var generation: Int
    var fromStack = false
}

enum TextToolOutput {
    static func item(_ text: String) -> ClipboardItem {
        let assets: [ClipboardAsset] = [.init(index: 0, pasteboardType: .string, data: Data(text.utf8))]
        return ClipboardItem(title: "Prepared text", kind: .text, contentHash: ClipboardContentHasher.hash(assets: assets), previewText: text, assets: assets)
    }
}
