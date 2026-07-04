import AppKit
import Foundation

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
