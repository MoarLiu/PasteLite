import AppKit
import Foundation

@MainActor
enum AccessibilityService {
    private static let promptOptionKey = "AXTrustedCheckOptionPrompt"

    static func isTrusted(prompt: Bool = false) -> Bool {
        let options = [promptOptionKey: prompt] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    @discardableResult
    static func promptIfNeeded() -> Bool {
        guard !isTrusted(prompt: false) else { return true }
        _ = isTrusted(prompt: true)
        return false
    }
}
