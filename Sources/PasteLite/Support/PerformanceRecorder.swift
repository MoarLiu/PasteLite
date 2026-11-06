import AppKit
import Foundation

/// Opt-in local diagnostics. Timing ends after AppKit lays out and displays the
/// hosting view; it includes query scheduling and rendering, not just sorting.
@MainActor
enum PerformanceRecorder {
    private static var samples: [[String: String]] = []

    static var enabled: Bool { ProcessInfo.processInfo.environment["PASTELITE_PERFORMANCE_OUTPUT"] != nil }

    static func record(_ kind: String, startedAt: TimeInterval, window: NSWindow?) {
        guard let path = ProcessInfo.processInfo.environment["PASTELITE_PERFORMANCE_OUTPUT"],
              let window, window.isVisible else { return }
        window.contentView?.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let milliseconds = (ProcessInfo.processInfo.systemUptime - startedAt) * 1000
        samples.append(["kind": kind, "milliseconds": String(format: "%.3f", milliseconds)])
        if let data = try? JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys]) {
            let url = URL(fileURLWithPath: path)
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path)
        }
    }
}
