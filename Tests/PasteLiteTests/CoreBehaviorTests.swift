import AppKit
import Carbon
@testable import PasteLite
import Testing

@Test
func urlDetectorRequiresSchemeAndHost() {
    #expect(URLDetector.isLikelyURL("https://example.com/path"))
    #expect(URLDetector.isLikelyURL("  https://example.com  "))
    #expect(!URLDetector.isLikelyURL("example.com/path"))
    #expect(!URLDetector.isLikelyURL("not a url"))
}

@Test
func colorDetectorParsesHexColors() throws {
    let color = try #require(ColorDetector.color(from: "#336699")?.usingColorSpace(.sRGB))

    #expect(abs(color.redComponent - CGFloat(0x33) / 255) < 0.001)
    #expect(abs(color.greenComponent - CGFloat(0x66) / 255) < 0.001)
    #expect(abs(color.blueComponent - CGFloat(0x99) / 255) < 0.001)
    #expect(ColorDetector.color(from: "336699") == nil)
    #expect(ColorDetector.color(from: "#12345") == nil)
}

@Test
func updateCheckerComparesSemanticVersions() {
    #expect(UpdateChecker.compareVersions("0.1.1", "0.1.0") == .orderedDescending)
    #expect(UpdateChecker.compareVersions("v1.0.0", "1.0") == .orderedSame)
    #expect(UpdateChecker.compareVersions("1.0.0", "1.0.1") == .orderedAscending)
}

@Test
func updateCheckerReportsMissingFeed() async throws {
    let result = try await UpdateChecker(endpoint: nil, currentVersion: "0.1.0").check()
    #expect(result == .notConfigured)
}

@Test
func appInfoUsesGitHubReleaseFeedByDefault() {
    #expect(AppInfo.updateCheckURL == AppInfo.defaultUpdateCheckURL)
}

@MainActor
@Test
func hotkeySettingsPersistSelectedChoice() throws {
    let suiteName = "PasteLiteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HotkeySettingsStore(defaults: defaults)
    #expect(store.selectedChoiceID == HotkeySettingsStore.defaultChoiceID)

    store.selectChoice(id: "disabled")
    #expect(store.selectedShortcuts.isEmpty)

    let reloadedStore = HotkeySettingsStore(defaults: defaults)
    #expect(reloadedStore.selectedChoiceID == "disabled")
}

@MainActor
@Test
func hotkeySettingsPersistCustomShortcut() throws {
    let suiteName = "PasteLiteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HotkeySettingsStore(defaults: defaults)
    store.recordShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey | optionKey),
        title: "Control-Option-A"
    )

    #expect(store.selectedChoiceID == HotkeySettingsStore.customChoiceID)
    #expect(store.selectedShortcuts.first?.title == "Control-Option-A")

    let reloadedStore = HotkeySettingsStore(defaults: defaults)
    #expect(reloadedStore.selectedChoiceID == HotkeySettingsStore.customChoiceID)
    #expect(reloadedStore.selectedShortcuts.first?.keyCode == UInt32(kVK_ANSI_A))
    #expect(reloadedStore.selectedShortcuts.first?.modifiers == UInt32(controlKey | optionKey))
}

@MainActor
@Test
func hotkeySettingsRejectInvalidCustomShortcut() throws {
    let suiteName = "PasteLiteTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    let store = HotkeySettingsStore(defaults: defaults)
    store.beginRecording()
    store.recordShortcut(
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(shiftKey),
        title: "Shift-A"
    )

    #expect(store.customShortcut == nil)
    #expect(store.isRecording)
    #expect(store.validationMessage != nil)
}

@Test
func hotkeyShortcutDisplaysSymbolTitle() {
    #expect(HotkeyShortcut.defaults[0].displayTitle == "⇧⌘V")

    let shortcut = HotkeyShortcut(
        id: "control-option-a",
        keyCode: UInt32(kVK_ANSI_A),
        modifiers: UInt32(controlKey | optionKey),
        title: "Control-Option-A"
    )

    #expect(shortcut.displayTitle == "⌃⌥A")
}

@Test
func clipboardContentHashIncludesItemStructure() {
    let first = ClipboardAsset(index: 0, pasteboardType: .string, data: Data("same".utf8))
    let second = ClipboardAsset(index: 1, pasteboardType: .string, data: Data("same".utf8))
    let regroupedSecond = ClipboardAsset(index: 2, pasteboardType: .string, data: Data("same".utf8))

    let originalHash = ClipboardContentHasher.hash(assets: [first, second])
    let reorderedHash = ClipboardContentHasher.hash(assets: [second, first])
    let regroupedHash = ClipboardContentHasher.hash(assets: [first, regroupedSecond])

    #expect(originalHash == reorderedHash)
    #expect(originalHash != regroupedHash)
}

@MainActor
@Test
func historyPanelReturnKeyDispatchesReturnAction() throws {
    let panel = HistoryPanel(
        contentRect: .zero,
        styleMask: .borderless,
        backing: .buffered,
        defer: false
    )
    var returnCount = 0
    var copyCount = 0

    panel.onReturnAction = {
        returnCount += 1
    }
    panel.onCopyAction = {
        copyCount += 1
    }

    let event = try #require(
        NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: UInt16(kVK_Return)
        )
    )

    panel.sendEvent(event)

    #expect(returnCount == 1)
    #expect(copyCount == 0)
}

@MainActor
@Test
func historyPanelReturnActionCopiesAndHidesWindow() throws {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLiteTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let appState = AppState()
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let service = PasteService(historyStore: store, pasteboard: pasteboard)
    let item = makeItem(title: "Return", content: "return copied text", contentHash: "return-copy")
    store.add(item)

    let controller = HistoryPanelController(
        appState: appState,
        historyStore: store,
        pasteService: service
    )
    let panel = try #require(controller.window as? HistoryPanel)

    panel.orderFrontRegardless()
    panel.onReturnAction?()

    #expect(pasteboard.string(forType: .string) == "return copied text")
    #expect(!panel.isVisible)
}

@MainActor
@Test
func copyToClipboardWritesItemWithoutPastePermissionPath() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLiteTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let service = PasteService(historyStore: store, pasteboard: pasteboard)

    let result = service.copyToClipboard(makeItem(title: "Copied", content: "copied text", contentHash: "copied-hash"))

    #expect(result == .success)
    #expect(pasteboard.string(forType: .string) == "copied text")
}

@MainActor
@Test
func sqliteStoreDeduplicatesByContentHash() {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)

    store.add(makeItem(title: "First", content: "same", contentHash: "same-hash"))
    store.add(makeItem(title: "Second", content: "same", contentHash: "same-hash"))

    #expect(store.items.count == 1)
    #expect(store.items.first?.title == "Second")
}

@MainActor
@Test
func sqliteStorePrunesToLimit() {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 2)

    store.add(makeItem(title: "One", content: "1", contentHash: "hash-1"))
    store.add(makeItem(title: "Two", content: "2", contentHash: "hash-2"))
    store.add(makeItem(title: "Three", content: "3", contentHash: "hash-3"))

    #expect(store.items.map(\.title) == ["Three", "Two"])
}

@MainActor
@Test
func sqliteStoreClearRemovesPersistedItems() {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    store.add(makeItem(title: "Saved", content: "saved", contentHash: "saved-hash"))

    store.clear()

    let reloadedStore = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    #expect(reloadedStore.items.isEmpty)
}

@MainActor
@Test
func sqliteStoreRemoveDeletesPersistedItem() throws {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let first = makeItem(title: "First", content: "first", contentHash: "first-hash")
    let second = makeItem(title: "Second", content: "second", contentHash: "second-hash")
    store.add(first)
    store.add(second)

    store.remove(id: first.id)

    #expect(store.items.map(\.title) == ["Second"])

    let reloadedStore = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    #expect(reloadedStore.items.map(\.title) == ["Second"])
}

@MainActor
@Test
func sqliteStoreKeepsMemoryStateWhenInsertFails() throws {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let first = makeItem(title: "First", content: "first", contentHash: "first-hash")
    store.add(first)

    let adminDatabase = try SQLiteDatabase(url: databaseURL)
    try adminDatabase.execute(
        """
        CREATE TRIGGER reject_history_insert
        BEFORE INSERT ON history_items
        BEGIN
            SELECT RAISE(ABORT, 'blocked');
        END;
        """
    )

    let result = store.add(makeItem(title: "Second", content: "second", contentHash: "second-hash"))

    #expect(result == .failure("Could not save this clipboard item to history."))
    #expect(store.items.map(\.title) == ["First"])
}

@MainActor
@Test
func sqliteStoreKeepsMemoryStateWhenDeleteFails() throws {
    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let item = makeItem(title: "Saved", content: "saved", contentHash: "saved-hash")
    store.add(item)

    let adminDatabase = try SQLiteDatabase(url: databaseURL)
    try adminDatabase.execute(
        """
        CREATE TRIGGER reject_history_delete
        BEFORE DELETE ON history_items
        BEGIN
            SELECT RAISE(ABORT, 'blocked');
        END;
        """
    )

    let removeResult = store.remove(id: item.id)
    let clearResult = store.clear()

    #expect(removeResult == .failure("Could not remove this clipboard item from history."))
    #expect(clearResult == .failure("Could not clear clipboard history."))
    #expect(store.items.map(\.title) == ["Saved"])
}

@MainActor
@Test
func selfWriteChangeCountIsConsumedOnce() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLiteTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    #expect(pasteboard.setString("test", forType: .string))

    PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
    let changeCount = pasteboard.changeCount

    #expect(PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: changeCount))
    #expect(!PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: changeCount))
}

@MainActor
@Test
func selfWriteGuardKeepsOnlyLatestChangeCount() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLiteTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }

    pasteboard.clearContents()
    #expect(pasteboard.setString("first", forType: .string))
    PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
    let firstChangeCount = pasteboard.changeCount

    pasteboard.clearContents()
    #expect(pasteboard.setString("second", forType: .string))
    PasteLitePasteboardWriteGuard.markSelfWrite(on: pasteboard)
    let secondChangeCount = pasteboard.changeCount

    #expect(!PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: firstChangeCount))
    #expect(PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: secondChangeCount))
}

@MainActor
@Test
func copyFailureDoesNotClearExistingPasteboardContents() {
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteLiteTests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    #expect(pasteboard.setString("original", forType: .string))

    let (databaseURL, directory) = makeDatabaseURL()
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = SQLiteHistoryStore(databaseURL: databaseURL, limit: 10)
    let service = PasteService(historyStore: store, pasteboard: pasteboard)

    let result = service.copyToClipboard(
        ClipboardItem(
            title: "Empty",
            kind: .text,
            contentHash: "empty",
            previewText: "",
            assets: []
        )
    )

    #expect(result == .failure("Clipboard item has no data to copy."))
    #expect(pasteboard.string(forType: .string) == "original")
}

private func makeDatabaseURL() -> (databaseURL: URL, directory: URL) {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("PasteLiteTests-\(UUID().uuidString)", isDirectory: true)
    return (directory.appendingPathComponent("History.sqlite3"), directory)
}

private func makeItem(title: String, content: String, contentHash: String) -> ClipboardItem {
    ClipboardItem(
        title: title,
        kind: .text,
        contentHash: contentHash,
        previewText: content,
        assets: [
            ClipboardAsset(
                index: 0,
                pasteboardType: .string,
                data: Data(content.utf8)
            )
        ]
    )
}
