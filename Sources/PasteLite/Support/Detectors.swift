import AppKit
import Foundation

enum CodeDetector {
    static func language(for text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("ssh ") || text.hasPrefix("curl ") || text.hasPrefix("#!/") ||
            text.hasPrefix("git ") || text.hasPrefix("npm ") { return "Shell" }
        if text.contains("import SwiftUI") || text.contains("func ") && text.contains("{") ||
            text.contains("let ") && text.contains(" = ") && text.contains("\n") { return "Swift" }
        if text.contains("const ") && text.contains("=") || text.contains("function ") { return "JavaScript" }
        if text.contains("def ") && text.contains(":") || text.contains("import ") && text.contains("\n") { return "Python" }
        if (text.hasPrefix("{") && text.hasSuffix("}")) || (text.hasPrefix("[") && text.hasSuffix("]")) {
            if (try? JSONSerialization.jsonObject(with: Data(text.utf8))) != nil { return "JSON" }
        }
        if text.hasPrefix("SELECT ") || text.hasPrefix("CREATE TABLE ") { return "SQL" }
        if text.hasPrefix("<") && text.contains("</") { return "HTML" }
        return nil
    }
}

enum URLDetector {
    static func isLikelyURL(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        if let url = URL(string: trimmed), url.scheme != nil, url.host != nil {
            return true
        }
        return false
    }
}

enum ColorDetector {
    static func hexString(from color: NSColor) -> String? {
        guard let color = color.usingColorSpace(.sRGB) else { return nil }
        let values = [color.redComponent, color.greenComponent, color.blueComponent, color.alphaComponent]
        guard values.allSatisfy({ $0.isFinite }) else { return nil }
        let bytes = values.map { Int((min(max($0, 0), 1) * 255).rounded()) }
        let components = bytes[3] == 255 ? Array(bytes.prefix(3)) : bytes
        return "#" + components.map { String(format: "%02X", $0) }.joined()
    }

    static func color(from text: String) -> NSColor? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?$"#, options: .regularExpression) != nil else {
            return nil
        }

        let hex = String(trimmed.dropFirst())
        guard let value = UInt64(hex, radix: 16) else { return nil }
        let hasAlpha = hex.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xff) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xff) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xff) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xff) / 255 : 1

        return NSColor(red: red, green: green, blue: blue, alpha: alpha)
    }
}
