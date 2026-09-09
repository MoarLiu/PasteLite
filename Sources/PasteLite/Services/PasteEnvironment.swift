import AppKit

// Keep system interaction injectable so focus, permission, and cancellation paths
// can be exercised without activating another app or posting real keystrokes.
@MainActor
protocol PasteEnvironment {
    var ownProcessIdentifier: pid_t { get }
    var frontmostProcessIdentifier: pid_t? { get }
    var uptime: TimeInterval { get }
    var isAccessibilityTrusted: Bool { get }
    func requestAccessibility() -> Bool
    func isTerminated(_ app: NSRunningApplication) -> Bool
    func isActive(_ app: NSRunningApplication) -> Bool
    func activate(_ app: NSRunningApplication) -> Bool
    func waitForActivation() async throws
    func sendPaste(to app: NSRunningApplication) -> Bool
}

@MainActor
struct SystemPasteEnvironment: PasteEnvironment {
    var ownProcessIdentifier: pid_t { ProcessInfo.processInfo.processIdentifier }
    var frontmostProcessIdentifier: pid_t? { NSWorkspace.shared.frontmostApplication?.processIdentifier }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var isAccessibilityTrusted: Bool { AccessibilityService.isTrusted() }

    func requestAccessibility() -> Bool { AccessibilityService.promptIfNeeded() }
    func isTerminated(_ app: NSRunningApplication) -> Bool { app.isTerminated }
    func isActive(_ app: NSRunningApplication) -> Bool { app.isActive }

    func activate(_ app: NSRunningApplication) -> Bool {
        if #available(macOS 14.0, *) { return app.activate() }
        return app.activate(options: .activateIgnoringOtherApps)
    }

    func waitForActivation() async throws {
        try await Task.sleep(nanoseconds: 20_000_000)
    }

    func sendPaste(to app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.isActive,
              frontmostProcessIdentifier == app.processIdentifier,
              let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.postToPid(app.processIdentifier)
        keyUp.postToPid(app.processIdentifier)
        return true
    }
}
