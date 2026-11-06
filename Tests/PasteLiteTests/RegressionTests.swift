import AppKit
import ImageIO
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct RegressionTests {
    @Test
    func developmentVersionIs032() {
        #expect(AppInfo.fallbackVersion == "0.3.2")
        #expect(AppInfo.fallbackBuild == "32")
    }

    @Test
    func deleteEditsSearchInsteadOfRemovingHistory() throws {
        let (panel, editor) = try editingPanel()
        var deletions = 0
        panel.onDeleteAction = { deletions += 1 }
        panel.sendEvent(try keyEvent(51, characters: "\u{7f}", panel: panel))
        #expect(deletions == 0)
        #expect(editor.string == "searc")
    }

    @Test
    func deleteStillRemovesHistoryOutsideTextEditor() throws {
        let panel = makePanel()
        var deletions = 0
        panel.onDeleteAction = { deletions += 1 }
        panel.sendEvent(try keyEvent(51, characters: "\u{7f}", panel: panel))
        #expect(deletions == 1)
    }

    @Test(arguments: [UInt16(36), 51, 53, 125, 126])
    func compositionDoesNotDispatchHistoryShortcuts(keyCode: UInt16) throws {
        let (panel, editor) = try editingPanel()
        var historyActions = 0
        panel.onReturnAction = { historyActions += 1 }
        panel.onDeleteAction = { historyActions += 1 }
        panel.onCancel = { historyActions += 1 }
        panel.onMoveSelection = { _ in historyActions += 1 }
        editor.setMarkedText("zhong", selectedRange: NSRange(location: 5, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        panel.sendEvent(try keyEvent(keyCode, characters: keyCode == 36 ? "\r" : "", panel: panel))
        #expect(historyActions == 0)
    }

    @Test
    func tabUsesNativeFocusNavigationInsteadOfCyclingFilters() throws {
        let (panel, _) = try editingPanel()
        var filterCycles = 0
        panel.onCycleFilter = { _ in filterCycles += 1 }
        panel.sendEvent(try keyEvent(48, characters: "\t", panel: panel))
        #expect(filterCycles == 0)
    }

    @Test
    func commandCWithSelectedTextUsesNativeEventHandling() throws {
        let panel = makePanel()
        let textView = CopyTrackingTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 80))
        textView.string = "selected text"
        textView.setSelectedRange(NSRange(location: 0, length: 8))
        panel.contentView?.addSubview(textView)
        #expect(panel.makeFirstResponder(textView))
        var historyCopies = 0
        panel.onCopyAction = { historyCopies += 1 }

        panel.sendEvent(try keyEvent(8, characters: "c", panel: panel, modifierFlags: .command))
        #expect(historyCopies == 0)
        #expect(textView.keyDownCount == 1)
    }

    @Test
    func returnActivatesFocusedButtonInsteadOfHistoryAction() throws {
        let panel = makePanel()
        let button = ReturnTrackingButton(frame: NSRect(x: 0, y: 0, width: 120, height: 30))
        button.keyEquivalent = "\r"
        panel.contentView?.addSubview(button)
        #expect(panel.makeFirstResponder(button))
        var historyActions = 0
        panel.onReturnAction = { historyActions += 1 }

        panel.sendEvent(try keyEvent(36, characters: "\r", panel: panel))
        #expect(historyActions == 0)
        #expect(button.clickCount == 1)
    }

    @Test
    func returnInSearchStillDispatchesHistoryAction() throws {
        let (panel, _) = try editingPanel()
        var historyActions = 0
        panel.onReturnAction = { historyActions += 1 }
        panel.sendEvent(try keyEvent(36, characters: "\r", panel: panel))
        #expect(historyActions == 1)
    }

    @Test
    func failedUndoRetainsPayloadAndCanRetryAfterStorageRecovers() async throws {
        try await withFixture { store, board, url in
            let original = item("Undo retry payload")
            #expect(await store.add(original) == .success)
            let state = AppState()
            state.normalizeSelection(in: store.items)
            state.showStatus("Earlier failure")
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: board))
            defer { controller.close() }
            let panel = try #require(controller.window as? HistoryPanel)
            @MainActor func waitUntil(_ condition: () -> Bool) async throws {
                for _ in 0..<100 {
                    if condition() { return }
                    try await Task.sleep(nanoseconds: 10_000_000)
                }
                try #require(condition())
            }

            panel.onDeleteAction?()
            try await waitUntil { store.deletedItem != nil && state.statusMessage == nil }
            #expect(store.items.isEmpty)

            let database = try SQLiteDatabase(url: url)
            try database.execute("""
                CREATE TRIGGER reject_restore BEFORE INSERT ON history_items
                BEGIN SELECT RAISE(ABORT, 'test restore failure'); END;
                """)
            panel.onUndo?()
            try await waitUntil { state.statusMessage != nil }
            #expect(store.deletedItem?.id == original.id)
            #expect(store.deletedItem?.assets.map(\.data) == original.assets.map(\.data))

            try database.execute("DROP TRIGGER reject_restore;")
            panel.onUndo?()
            try await waitUntil {
                store.deletedItem == nil && store.items.contains(where: { $0.id == original.id }) &&
                    state.statusMessage == nil
            }
            let restored = try #require(store.items.first)
            #expect(try await store.resolve(restored).assets.map(\.data) == original.assets.map(\.data))
        }
    }

    @Test
    func repeatedStatusSurvivesCancelledOldTimer() async throws {
        let state = AppState()
        defer { state.clearStatus() }
        state.showStatus("Copied", clearAfter: 60)
        await Task.yield()
        state.showStatus("Copied", clearAfter: 60)
        try await Task.sleep(nanoseconds: 20_000_000)
        #expect(state.statusMessage == "Copied")
    }

    @Test
    func metadataLoadsWithoutOriginalAttachments() async throws {
        try await withFixture { store, _, databaseURL in
            let original = item("before\u{0}after 🐈 中文")
            #expect(await store.add(original) == .success)
            let reloaded = SQLiteHistoryStore(databaseURL: databaseURL)
            await reloaded.loadRecentItems()
            let summary = try #require(reloaded.items.first)
            #expect(summary.assets.isEmpty)
            #expect(!summary.hasLoadedAssets)
            #expect(summary.title == original.title)
            #expect(summary.previewText == original.previewText)
            let loaded = try await reloaded.resolve(summary)
            #expect(loaded.hasLoadedAssets)
            #expect(loaded.assets.first?.data == original.assets.first?.data)
        }
    }

    @Test(arguments: [false, true])
    func nativeColorIsCapturedAndCopiedWithItsOriginalData(useLegacyWriter: Bool) async throws {
        try await withFixture { store, pasteboard, _ in
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: pasteboard)
            pasteboard.clearContents()
            let originalColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
            if useLegacyWriter {
                pasteboard.declareTypes([.legacyColor], owner: nil)
                originalColor.write(to: pasteboard)
            } else {
                #expect(pasteboard.writeObjects([originalColor]))
            }
            let colorType = try #require(pasteboard.availableType(from: NSPasteboard.PasteboardType.pasteLiteColorTypes))
            let originalData = try #require(pasteboard.data(forType: colorType))
            await monitor.checkForChanges()
            let summary = try #require(store.items.first)
            #expect(summary.kind == .color)
            #expect(summary.previewText == "#336699")
            let service = PasteService(historyStore: store, pasteboard: pasteboard)
            #expect(await service.copyToClipboard(summary) == .success)
            #expect(pasteboard.data(forType: colorType) == originalData)
            let color = try #require(NSColor(from: pasteboard)?.usingColorSpace(.sRGB))
            #expect(abs(color.redComponent - 0.2) < 0.001)
            #expect(abs(color.greenComponent - 0.4) < 0.001)
            #expect(abs(color.blueComponent - 0.6) < 0.001)
            monitor.stop()
        }
    }

    @Test(arguments: [NSPasteboard.PasteboardType.concealed, .transient, .autoGenerated])
    func ignoredClipboardContentsStayOutOfHistory(type: NSPasteboard.PasteboardType) async throws {
        try await withFixture { store, pasteboard, _ in
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: pasteboard)
            pasteboard.clearContents()
            #expect(pasteboard.setString("secret", forType: .string))
            #expect(pasteboard.setString("1", forType: type))
            await monitor.checkForChanges()
            #expect(store.items.isEmpty)
            monitor.stop()
        }
    }

    @Test
    func selfCopyIsNotRecaptured() async throws {
        try await withFixture { store, pasteboard, _ in
            let original = item("same content")
            #expect(await store.add(original) == .success)
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: pasteboard)
            let service = PasteService(historyStore: store, pasteboard: pasteboard)
            #expect(await service.copyToClipboard(original) == .success)
            await monitor.checkForChanges()
            #expect(store.items.map(\.id) == [original.id])
            monitor.stop()
        }
    }

    enum HistoryCopyAction: CaseIterable {
        case copy, primary, alternate
    }

    @Test(arguments: HistoryCopyAction.allCases)
    func copyingOlderHistoryRefreshesItsTimeAndOrder(action: HistoryCopyAction) async throws {
        try await withFixture { store, pasteboard, databaseURL in
            var older = item("older history")
            older.copiedAt = Date().addingTimeInterval(-172_800)
            var newer = item("newer history")
            newer.copiedAt = Date().addingTimeInterval(-60)
            #expect(await store.add(older) == .success)
            #expect(await store.add(newer) == .success)
            #expect(store.items.map(\.id) == [newer.id, older.id])

            let state = AppState()
            state.selectedItemID = older.id
            defer { state.clearStatus() }
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: pasteboard))
            let panel = try #require(controller.window as? HistoryPanel)
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: pasteboard)
            defer { monitor.stop(); controller.close() }
            let startedAt = Date()
            switch action {
            case .copy: panel.onCopyAction?()
            case .primary: panel.onReturnAction?()
            case .alternate: panel.onAlternateReturnAction?()
            }
            await controller.clipboardActionTask?.value
            await monitor.checkForChanges()

            #expect(pasteboard.string(forType: .string) == older.previewText)
            #expect(store.items.map(\.id) == [older.id, newer.id])
            let refreshed = try #require(store.items.first)
            #expect(refreshed.copiedAt >= startedAt)
            #expect(refreshed.copiedAt <= Date())
            #expect(refreshed.useCount == 1)
            #expect(state.selectedItemID == older.id)
            #expect(try await store.resolve(refreshed).assets.map(\.data) == older.assets.map(\.data))

            let reloaded = SQLiteHistoryStore(databaseURL: databaseURL)
            await reloaded.loadRecentItems()
            #expect(reloaded.items.map(\.id) == [older.id, newer.id])
            #expect(reloaded.items.first?.copiedAt == refreshed.copiedAt)
            #expect(reloaded.items.first?.useCount == 1)
        }
    }

    @Test
    func failedHistoryCopyKeepsItsTimeAndOrder() async throws {
        try await withFixture { store, pasteboard, databaseURL in
            var older = item("unavailable history")
            older.copiedAt = Date().addingTimeInterval(-120)
            let newer = item("available history")
            #expect(await store.add(older) == .success)
            #expect(await store.add(newer) == .success)
            let database = try SQLiteDatabase(url: databaseURL)
            let deletion = try database.prepare("DELETE FROM history_assets WHERE history_id = ?;")
            try deletion.bind(older.id.uuidString, at: 1)
            try deletion.run()
            let before = store.items
            let state = AppState()
            state.selectedItemID = older.id
            defer { state.clearStatus() }
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: pasteboard))
            defer { controller.close() }
            let panel = try #require(controller.window as? HistoryPanel)
            panel.onCopyAction?()
            await controller.clipboardActionTask?.value
            #expect(state.statusMessage == "This clipboard item is no longer available.")
            #expect(store.items == before)
        }
    }

    @Test(arguments: [false, true])
    func recordingUseRefreshesTimeWithinPinnedSections(memoryOnly: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteHistoryStore(databaseURL: memoryOnly ? directory : directory.appendingPathComponent("History.sqlite3"))
        await store.loadRecentItems()
        var older = item("older")
        older.copiedAt = Date().addingTimeInterval(-120)
        var newer = item("newer")
        newer.copiedAt = Date().addingTimeInterval(-60)
        var pinned = item("pinned")
        pinned.copiedAt = Date().addingTimeInterval(-180)
        for value in [older, newer, pinned] { #expect(await store.add(value) == .success) }
        #expect(await store.togglePin(pinned) == .success)
        let startedAt = Date()
        await store.recordUse(older)
        #expect(store.items.map(\.id) == [pinned.id, older.id, newer.id])
        #expect(store.items.first?.isPinned == true)
        #expect(store.items[1].copiedAt >= startedAt)
        #expect(store.items[1].useCount == 1)
        #expect(try await store.resolve(store.items[1]).assets.map(\.data) == older.assets.map(\.data))
        await store.recordUse(pinned)
        #expect(store.items.map(\.id) == [pinned.id, older.id, newer.id])
        #expect(store.items.first?.isPinned == true)
        #expect(store.items.first?.copiedAt ?? .distantPast >= startedAt)
    }

    @Test
    func selfWriteTrackingIsScopedToThePasteboard() {
        let first = makePasteboard()
        let second = makePasteboard()
        defer { first.releaseGlobally(); second.releaseGlobally() }
        PasteLitePasteboardWriteGuard.markSelfWrite(on: first)
        #expect(!PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: first.changeCount, on: second))
        #expect(PasteLitePasteboardWriteGuard.consumeIfSelfWrite(changeCount: first.changeCount, on: first))
    }

    @Test
    func captureFailureReachesTheUserFacingState() async throws {
        try await withFixture { store, pasteboard, databaseURL in
            let database = try SQLiteDatabase(url: databaseURL)
            try database.execute("""
                CREATE TRIGGER block_capture BEFORE INSERT ON history_items
                BEGIN SELECT RAISE(ABORT, 'blocked'); END;
                """)
            var reportedError: String?
            let monitor = ClipboardMonitor(historyStore: store, pasteboard: pasteboard, onError: { reportedError = $0 })
            pasteboard.clearContents()
            #expect(pasteboard.setString("capture failure", forType: .string))
            await monitor.checkForChanges()
            #expect(store.items.isEmpty)
            #expect(reportedError == "Could not save this clipboard item to history.")
            #expect(store.errorMessage == reportedError)
            monitor.stop()
        }
    }

    @Test
    func memoryFallbackIsVisibleAndCanResolveItsItems() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteHistoryStore(databaseURL: directory)
        await store.loadRecentItems()
        #expect(store.storageWarning != nil)
        let original = item("memory only")
        #expect(await store.add(original) == .success)
        let summary = try #require(store.items.first)
        #expect(summary.assets.isEmpty)
        let loaded = try await store.resolve(summary)
        #expect(loaded.assets.first?.data == original.assets.first?.data)
        let reloaded = SQLiteHistoryStore(databaseURL: directory)
        await reloaded.loadRecentItems()
        #expect(reloaded.items.isEmpty)
        #expect(reloaded.storageWarning != nil)
    }

    @Test
    func memoryFallbackEvictsOldestAttachmentsAtItsByteBudget() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SQLiteHistoryStore(databaseURL: directory)
        await store.loadRecentItems()
        for index in 0..<4 {
            let original = ClipboardItem(title: "Image \(index)", kind: .image, contentHash: "image-\(index)", previewText: "",
                assets: [ClipboardAsset(index: 0, pasteboardType: .png, data: Data(repeating: UInt8(index), count: 20 * 1024 * 1024))])
            #expect(await store.add(original) == .success)
        }
        #expect(store.items.map(\.title) == ["Image 3", "Image 2", "Image 1"])
    }

    @Test
    func imagesAreDownsampledCachedAndDiscardedAfterClear() async throws {
        try await withFixture { store, _, _ in
            let original = ClipboardItem(title: "Large image", kind: .image, contentHash: "large-image", previewText: "",
                assets: [ClipboardAsset(index: 0, pasteboardType: .png, data: try png(width: 2400, height: 1200))])
            #expect(await store.add(original) == .success)
            let summary = try #require(store.items.first)
            #expect(summary.assets.isEmpty)
            let image = try #require(await store.image(for: summary, maxPixelSize: 64))
            #expect(image.size.width == 64)
            #expect(image.size.height == 32)
            let cached = await store.image(for: summary, maxPixelSize: 64)
            #expect(cached === image)
            #expect(await store.clear() == .success)
            #expect(await store.image(for: summary, maxPixelSize: 64) == nil)
        }
    }

    @Test
    func removedItemsCannotResolveOriginalData() async throws {
        try await withFixture { store, _, _ in
            #expect(await store.add(item("remove")) == .success)
            let summary = try #require(store.items.first)
            #expect(await store.remove(id: summary.id) == .success)
            do {
                _ = try await store.resolve(summary)
                Issue.record("Removed data was still available")
            } catch {
                #expect(error is HistoryItemLoadError)
            }
        }
    }

    @Test
    func copyPreservesMultiplePasteboardItems() async throws {
        try await withFixture { store, pasteboard, _ in
            let assets = ["file:///tmp/first.txt", "file:///tmp/second.txt"].enumerated().map {
                ClipboardAsset(index: $0.offset, pasteboardType: .fileURL, data: Data($0.element.utf8))
            }
            let original = ClipboardItem(title: "2 Files", kind: .file, contentHash: "two-files", previewText: "two files", assets: assets)
            #expect(await store.add(original) == .success)
            let summary = try #require(store.items.first)
            let service = PasteService(historyStore: store, pasteboard: pasteboard)
            #expect(await service.copyToClipboard(summary) == .success)
            #expect(pasteboard.pasteboardItems?.count == 2)
            #expect(pasteboard.pasteboardItems?[0].data(forType: .fileURL) == assets[0].data)
            #expect(pasteboard.pasteboardItems?[1].data(forType: .fileURL) == assets[1].data)
        }
    }

    @Test
    func copyDoesNotOverwriteAClipboardChangedDuringLoad() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        let store = ResolvingStore(resolved: item("old history"))
        store.onResolve = {
            pasteboard.clearContents()
            _ = pasteboard.setString("new clipboard", forType: .string)
        }
        let service = PasteService(historyStore: store, pasteboard: pasteboard)
        let result = await service.copyToClipboard(store.resolved.metadataOnly)
        #expect(!result.isSuccess)
        #expect(pasteboard.string(forType: .string) == "new clipboard")
    }

    @Test
    func cancelledCopyDoesNotWriteAfterLoading() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        _ = pasteboard.setString("original", forType: .string)
        let store = ResolvingStore(resolved: item("history"))
        let service = PasteService(historyStore: store, pasteboard: pasteboard)
        var task: Task<PasteServiceResult, Never>?
        store.onResolve = { task?.cancel() }
        task = Task { await service.copyToClipboard(store.resolved.metadataOnly) }
        let result = await task?.value
        #expect(result == .failure("Copy cancelled."))
        #expect(pasteboard.string(forType: .string) == "original")
        store.onResolve = nil
    }

    @Test
    func closingPanelCancelsPendingCopy() async throws {
        try await withFixture { store, pasteboard, _ in
            #expect(await store.add(item("pending")) == .success)
            pasteboard.clearContents()
            #expect(pasteboard.setString("original", forType: .string))
            let state = AppState()
            let controller = HistoryPanelController(appState: state, historyStore: store,
                pasteService: PasteService(historyStore: store, pasteboard: pasteboard))
            let panel = try #require(controller.window as? HistoryPanel)
            panel.onReturnAction?()
            let task = controller.clipboardActionTask
            controller.close()
            await task?.value
            #expect(!state.isPerformingClipboardAction)
            #expect(pasteboard.string(forType: .string) == "original")
        }
    }

    @Test
    func pasteRejectsMissingOrOwnApplicationBeforeWriting() async {
        let pasteboard = makePasteboard()
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        _ = pasteboard.setString("original", forType: .string)
        let store = ResolvingStore(resolved: item("history"))
        let service = PasteService(historyStore: store, pasteboard: pasteboard)
        let missing = await service.paste(store.resolved, into: nil)
        let ownApp = await service.paste(store.resolved, into: NSRunningApplication.current)
        #expect(!missing.isSuccess)
        #expect(!ownApp.isSuccess)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test
    func concurrentHistoryMutationsConvergeWithDatabase() async throws {
        try await withFixture { store, _, databaseURL in
            await withTaskGroup(of: HistoryStoreMutationResult.self) { group in
                for index in 0..<12 {
                    let original = item("Concurrent \(index)")
                    group.addTask { await store.add(original) }
                }
                for await result in group { #expect(result == .success) }
            }
            let reloaded = SQLiteHistoryStore(databaseURL: databaseURL)
            await reloaded.loadRecentItems()
            #expect(store.items.count == 12)
            #expect(store.items.map(\.id) == reloaded.items.map(\.id))
        }
    }
}

@MainActor
private func withFixture(_ body: @MainActor (SQLiteHistoryStore, NSPasteboard, URL) async throws -> Void) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteRegression-\(UUID().uuidString)")
    let databaseURL = directory.appendingPathComponent("History.sqlite3")
    let pasteboard = makePasteboard()
    defer {
        pasteboard.releaseGlobally()
        try? FileManager.default.removeItem(at: directory)
    }
    let store = SQLiteHistoryStore(databaseURL: databaseURL)
    await store.loadRecentItems()
    #expect(store.storageWarning == nil)
    try await body(store, pasteboard, databaseURL)
}

@MainActor
private func makePasteboard() -> NSPasteboard {
    NSPasteboard(name: NSPasteboard.Name("PasteLiteRegression.\(UUID().uuidString)"))
}

private func item(_ content: String) -> ClipboardItem {
    let assets = [ClipboardAsset(index: 0, pasteboardType: .string, data: Data(content.utf8))]
    return ClipboardItem(title: content, kind: .text, contentHash: ClipboardContentHasher.hash(assets: assets),
                         previewText: content, assets: assets)
}

@MainActor
private func makePanel() -> HistoryPanel {
    _ = NSApplication.shared
    return HistoryPanel(contentRect: NSRect(x: 0, y: 0, width: 400, height: 200),
                        styleMask: .borderless, backing: .buffered, defer: false)
}

@MainActor
private func editingPanel() throws -> (HistoryPanel, NSTextView) {
    let panel = makePanel()
    let field = NSTextField(frame: NSRect(x: 10, y: 10, width: 350, height: 30))
    field.stringValue = "search"
    panel.contentView?.addSubview(field)
    #expect(panel.makeFirstResponder(field))
    let editor = try #require(field.currentEditor() as? NSTextView)
    editor.setSelectedRange(NSRange(location: 6, length: 0))
    return (panel, editor)
}

@MainActor
private func keyEvent(_ keyCode: UInt16, characters: String, panel: HistoryPanel,
                      modifierFlags: NSEvent.ModifierFlags = []) throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifierFlags, timestamp: 0,
        windowNumber: panel.windowNumber, context: nil, characters: characters, charactersIgnoringModifiers: characters,
        isARepeat: false, keyCode: keyCode))
}

private func png(width: Int, height: Int) throws -> Data {
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.6, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let data = NSMutableData()
    let destination = try #require(CGImageDestinationCreateWithData(data as CFMutableData, "public.png" as CFString, 1, nil))
    CGImageDestinationAddImage(destination, image, nil)
    #expect(CGImageDestinationFinalize(destination))
    return data as Data
}

@MainActor
private final class CopyTrackingTextView: NSTextView {
    var keyDownCount = 0
    override func keyDown(with event: NSEvent) {
        keyDownCount += 1
        super.keyDown(with: event)
    }
}

@MainActor
private final class ReturnTrackingButton: NSButton {
    var clickCount = 0
    override func performClick(_ sender: Any?) { clickCount += 1 }
}

@MainActor
private final class ResolvingStore: HistoryStore {
    @Published var items: [ClipboardItem] = []
    var resolved: ClipboardItem
    var onResolve: (() -> Void)?

    init(resolved: ClipboardItem) { self.resolved = resolved }
    func loadRecentItems(limit: Int) async {}
    func add(_ item: ClipboardItem) async -> HistoryStoreMutationResult { .success }
    func remove(id: UUID) async -> HistoryStoreMutationResult { .success }
    func clear() async -> HistoryStoreMutationResult { .success }
    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem {
        onResolve?()
        return resolved
    }
}
