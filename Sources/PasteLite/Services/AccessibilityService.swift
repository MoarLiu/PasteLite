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

    static func openSettings() {
        _ = promptIfNeeded()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
