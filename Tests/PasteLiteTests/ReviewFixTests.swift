import AppKit
import Carbon
import SwiftUI
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct ReviewFixTests {
    @Test(arguments: [false, true])
    func clearingHistoryDiscardsPendingCapture(memoryOnly: Bool) async throws {
        try await withReviewFixture(memoryOnly: memoryOnly) { store, board, databaseURL in
            let gate = CaptureGate()
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: board,
                processCapture: { await gate.process($0) })
            defer { monitor.stop() }
            board.clearContents()
            #expect(board.setString("before clear", forType: .string))
            let capture = Task { await monitor.checkForChanges() }
            await gate.waitUntilStarted()

            #expect(await store.clear() == .success)
            await gate.release()
            await capture.value
            #expect(store.items.isEmpty)
            let reloaded = SQLiteHistoryStore(databaseURL: databaseURL)
            await reloaded.loadRecentItems()
            #expect(reloaded.items.isEmpty)

            board.clearContents()
            #expect(board.setString("after clear", forType: .string))
            await monitor.checkForChanges()
            #expect(store.items.map(\.previewText) == ["after clear"])
        }
    }

    @Test(arguments: [false, true])
    func repositoryRejectsCaptureQueuedBeforeClear(memoryOnly: Bool) async throws {
        try await withReviewFixture(memoryOnly: memoryOnly) { _, _, databaseURL in
            let repository = HistoryRepository(databaseURL: databaseURL, limit: 10)
            _ = await repository.loadRecentItems(limit: 10)
            _ = await repository.clear(captureGeneration: 1)
            let stale = await repository.add(reviewItem("stale"), captureGeneration: 0)
            #expect(stale.result == .success)
            #expect(stale.snapshot.items.isEmpty)
            let fresh = await repository.add(reviewItem("fresh"), captureGeneration: 1)
            #expect(fresh.snapshot.items.map(\.previewText) == ["fresh"])
        }
    }

    @Test(arguments: [false, true])
    func oversizedCaptureIsRejectedWithoutSavingPartialContent(aggregateLimit: Bool) async throws {
        try await withReviewFixture { store, board, _ in
            let previous = reviewItem("existing history")
            #expect(await store.add(previous) == .success)
            var reportedErrors: [String] = []
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: board, onError: { reportedErrors.append($0) })
            defer { monitor.stop() }
            let sizes = aggregateLimit ? Array(repeating: 17 * 1024 * 1024, count: 4) : [16, 21 * 1024 * 1024]
            let originals = sizes.enumerated().map { index, size in
                let item = NSPasteboardItem()
                #expect(item.setData(Data(repeating: UInt8(65 + index), count: size), forType: .string))
                return item
            }
            board.clearContents()
            #expect(board.writeObjects(originals))
            let changeCount = board.changeCount
            await monitor.checkForChanges()

            #expect(store.items.map(\.id) == [previous.id])
            #expect(reportedErrors.count == 1)
            #expect(store.captureErrorMessage == reportedErrors.first)
            #expect(store.captureErrorMessage?.contains(aggregateLimit ? "64 MiB" : "20 MiB") == true)
            #expect(board.changeCount == changeCount)
            #expect(board.pasteboardItems?.map { $0.data(forType: .string)?.count ?? 0 } == sizes)

            board.clearContents()
            #expect(board.setString("complete new content", forType: .string))
            await monitor.checkForChanges()
            #expect(store.items.first?.previewText == "complete new content")
            #expect(store.captureErrorMessage == nil)
        }
    }

    @Test
    func recordingSuspendsHotkeyAndRestoresTheCurrentChoice() throws {
        let suiteName = "PasteLiteReviewFixTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HotkeySettingsStore(defaults: defaults)
        let registrar = RecordingRegistrar()
        var statuses: [HotkeyRegistrationStatus] = []
        let controller = HotkeyRegistrationController(settings: settings, registrar: registrar) { statuses.append($0) }
        defer { controller.stop() }
        #expect(registrar.activeShortcuts == settings.selectedShortcuts)

        settings.beginRecording()
        #expect(registrar.activeShortcuts.isEmpty)
        #expect(statuses.last == .recording)
        settings.recordShortcut(keyCode: 0, modifiers: UInt32(shiftKey), title: "Shift-A")
        #expect(settings.isRecording)
        #expect(registrar.activeShortcuts.isEmpty)
        settings.cancelRecording()
        #expect(registrar.activeShortcuts == HotkeyShortcut.defaults)

        settings.beginRecording()
        settings.recordShortcut(keyCode: UInt32(kVK_ANSI_A), modifiers: UInt32(controlKey | optionKey), title: "Control-Option-A")
        #expect(!settings.isRecording)
        #expect(registrar.activeShortcuts == settings.selectedShortcuts)
        #expect(registrar.activeShortcuts.first?.keyCode == UInt32(kVK_ANSI_A))

        settings.selectChoice(id: HotkeySettingsStore.disabledChoiceID)
        settings.beginRecording()
        settings.cancelRecording()
        #expect(registrar.activeShortcuts.isEmpty)
        #expect(statuses.last == .disabled)
        controller.stop()
        let registrationCount = registrar.registrationCount
        settings.selectChoice(id: HotkeySettingsStore.defaultChoiceID)
        #expect(registrar.registrationCount == registrationCount)
    }

    @Test
    func closingRecordingWindowRestoresHotkey() async throws {
        _ = NSApplication.shared
        let suiteName = "PasteLiteReviewFixTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let settings = HotkeySettingsStore(defaults: defaults)
        let registrar = RecordingRegistrar()
        let controller = HotkeyRegistrationController(settings: settings, registrar: registrar) { _ in }
        defer { controller.stop() }
        let window = NSWindow(contentRect: NSRect(x: -10_000, y: -10_000, width: 580, height: 180),
            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: HotkeyRecorderView(hotkeySettings: settings))
        defer { window.close() }
        window.orderFrontRegardless()
        settings.beginRecording()
        #expect(registrar.activeShortcuts.isEmpty)
        try await eventually("shortcut recording view creation") {
            guard let content = window.contentView else { return false }
            content.layoutSubtreeIfNeeded()
            return descendants(content).contains { String(describing: type(of: $0)).hasSuffix("HotkeyCaptureNSView") }
        }
        window.close()
        #expect(!settings.isRecording)
        #expect(registrar.activeShortcuts == settings.selectedShortcuts)
    }

    @Test
    func newDatabaseAndSidecarsArePrivate() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLitePermissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite3")
        let database = try SQLiteDatabase(url: url)
        try database.execute("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('preserved');")
        #expect(try permissions(directory) == 0o700)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            #expect(try permissions(URL(fileURLWithPath: path)) == 0o600)
        }
    }

    @Test
    func existingPermissionsAreRepairedWithoutTruncatingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLitePermissions-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        let url = directory.appendingPathComponent("History.sqlite3")
        let first = try SQLiteDatabase(url: url)
        // Generic database users must not change permissions on an existing shared parent.
        #expect(try permissions(directory) == 0o755)
        try first.execute("CREATE TABLE sample(value TEXT); INSERT INTO sample VALUES ('preserved');")
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
        }
        let reopened = try SQLiteDatabase(url: url, privateDirectory: true)
        #expect(try permissions(directory) == 0o700)
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            #expect(try permissions(URL(fileURLWithPath: path)) == 0o600)
        }
        let statement = try reopened.prepare("SELECT value FROM sample;")
        #expect(try statement.step())
        #expect(statement.columnString(at: 0) == "preserved")
    }

    @Test
    func keyboardSelectionScrollsIntoViewAndResetsOnPresentation() async throws {
        try await withReviewFixture { store, board, _ in
            _ = NSApplication.shared
            for index in 0..<40 { #expect(await store.add(reviewItem("Entry \(index)")) == .success) }
            let state = AppState()
            state.normalizeSelection(in: store.items)
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: board))
            defer { controller.close() }
            let panel = try #require(controller.window as? HistoryPanel)
            panel.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            panel.orderFrontRegardless()
            @MainActor func historyScrollView() -> NSScrollView? {
                guard let content = panel.contentView else { return nil }
                content.layoutSubtreeIfNeeded()
                return descendants(content).compactMap { $0 as? NSScrollView }.first {
                    ($0.documentView?.frame.height ?? 0) > $0.contentView.bounds.height
                }
            }
            try await eventually("history scroll view creation") { historyScrollView() != nil }
            let scroll = try #require(historyScrollView())
            try await eventually("initial scroll position") { scroll.contentView.bounds.minY < 2 }
            let initialOffset = scroll.contentView.bounds.minY
            // Row clicks assign the selection directly; a visible row must stay under the pointer.
            state.selectedItemID = store.items[6].id
            try await Task.sleep(nanoseconds: 60_000_000)
            #expect(abs(scroll.contentView.bounds.minY - initialOffset) < 1)
            for _ in 0..<25 {
                panel.sendEvent(try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                    windowNumber: panel.windowNumber, context: nil, characters: "\u{F701}", charactersIgnoringModifiers: "\u{F701}",
                    isARepeat: false, keyCode: 125)))
            }
            #expect(state.selectedItemID == store.items[31].id)
            try await eventually("keyboard selection scrolling") { scroll.contentView.bounds.minY > 100 }

            state.searchText = "Entry 1"
            try await eventually("filtered selection scrolling") {
                state.selectedItemID == state.filteredItems(in: store.items).first?.id && scroll.contentView.bounds.minY < 2
            }

            state.prepareForPresentation()
            try await eventually("presentation scroll reset") { state.selectedItemID == store.items.first?.id && scroll.contentView.bounds.minY < 2 }
            panel.onReturnAction?()
            await controller.clipboardActionTask?.value
            #expect(board.string(forType: .string) == store.items.first?.previewText)
            #expect(!panel.isVisible)
        }
    }
}

private actor CaptureGate {
    private var continuation: CheckedContinuation<ClipboardItem?, Never>?
    private var started: CheckedContinuation<Void, Never>?
    private var capture: ClipboardCapture?
    private var released = false

    func process(_ capture: ClipboardCapture) async -> ClipboardItem? {
        if released { return capture.makeItem() }
        self.capture = capture
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started?.resume()
            started = nil
        }
    }

    func waitUntilStarted() async {
        if continuation != nil { return }
        await withCheckedContinuation { started = $0 }
    }

    func release() {
        released = true
        continuation?.resume(returning: capture?.makeItem())
        continuation = nil
        capture = nil
    }
}

@MainActor
private final class RecordingRegistrar: HotkeyRegistering {
    var activeShortcuts: [HotkeyShortcut] = []
    var registrationCount = 0

    func register(shortcuts: [HotkeyShortcut]) -> HotkeyRegistrationStatus {
        registrationCount += 1
        activeShortcuts = shortcuts
        return shortcuts.first.map { .registered($0) } ?? .disabled
    }

    func unregister() { activeShortcuts = [] }
}

@MainActor
private func withReviewFixture(memoryOnly: Bool = false,
    _ body: @MainActor (SQLiteHistoryStore, NSPasteboard, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteReviewFix-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = memoryOnly ? directory : directory.appendingPathComponent("History.sqlite3")
    let board = NSPasteboard(name: .init("PasteLiteReviewFix.\(UUID().uuidString)"))
    defer {
        board.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    let store = SQLiteHistoryStore(databaseURL: url)
    await store.loadRecentItems()
    try await body(store, board, url)
}

private func reviewItem(_ text: String) -> ClipboardItem {
    let assets = [ClipboardAsset(index: 0, pasteboardType: .string, data: Data(text.utf8))]
    return ClipboardItem(title: text, kind: .text, contentHash: ClipboardContentHasher.hash(assets: assets), previewText: text, assets: assets)
}

private func permissions(_ url: URL) throws -> Int {
    (try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
}

@MainActor
private func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap { descendants($0) }
}

@MainActor
private func eventually(_ description: String, _ condition: @MainActor () -> Bool) async throws {
    for _ in 0..<150 {
        if condition() { return }
        try await Task.sleep(nanoseconds: 20_000_000)
    }
    try #require(condition(), "Timed out waiting for \(description).")
}
