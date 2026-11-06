import AppKit
import SwiftUI
import Combine

@MainActor
final class HistoryPanelController: NSWindowController {
    private let appState: AppState
    private let historyStore: SQLiteHistoryStore
    private let pasteService: PasteService
    private var previousApp: NSRunningApplication?
    private var isOrderingOut = false
    private(set) var clipboardActionTask: Task<Void, Never>?
    private var clipboardActionID: UUID?
    private let preferences = AppPreferences.shared
    private var preferenceObserver: AnyCancellable?
    private var actionsObserver: AnyCancellable?
    private var storeObserver: AnyCancellable?
    private var observedLibraryGeneration = 0
    private var observedCaptureGeneration = 0
    private var resultObserver: AnyCancellable?
    private var targetTerminationObserver: AnyCancellable?

    private var currentItems: [ClipboardItem] {
        appState.visibleItems
    }

    private var currentSelection: ClipboardItem? {
        appState.selectedItem(in: currentItems)
    }

    init(appState: AppState, historyStore: SQLiteHistoryStore, pasteService: PasteService) {
        self.appState = appState
        self.historyStore = historyStore
        self.pasteService = pasteService

        let panel = HistoryPanel(
            contentRect: NSRect(x: 0, y: 0, width: 880, height: 560),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )

        super.init(window: panel)
        configure(panel)
        panel.contentView = NSHostingView(
            rootView: HistoryPanelView(
                appState: appState,
                historyStore: historyStore,
                onCopy: { [weak self] item in
                    self?.copyToClipboard(item)
                },
                onPaste: { [weak self] item in
                    self?.performPrimaryAction(item)
                },
                onRemove: { [weak self] item in
                    self?.remove(item)
                },
                onClear: { [weak self] in
                    self?.confirmAndClearHistory()
                },
                onDismiss: { [weak self] in
                    self?.close()
                },
                onPin: { [weak self] item in self?.togglePin(item) },
                onUndo: { [weak self] in self?.undoDelete() },
                onCopyText: { [weak self] text in
                    guard let self else { return }
                    self.appState.apply(self.pasteService.copyString(text))
                },
                onNewSnippet: { [weak self] in self?.newSnippet() },
                onCreateSnippet: { [weak self] item in self?.prepareEditor(item, type: .snippet) },
                onEditSaved: { [weak self] item in self?.editSaved(item) },
                onDeleteGroup: { [weak self] group in self?.deleteGroup(group) },
                onMoveSaved: { [weak self] item, group in
                    guard let self else { return }
                    Task { self.report(await self.historyStore.moveLibraryItem(item, groupID: group)) }
                },
                onClearLibrary: { [weak self] in self?.confirmAndClearLibrary() },
                onOpenLink: { [weak self] url in self?.close(); NSWorkspace.shared.open(url) },
                onExport: { [weak self] in self?.exportBackup() },
                onImport: { [weak self] in self?.importBackup() },
                onMerge: { [weak self] in self?.copyMergedSelection() },
                onStackNext: { [weak self] in self?.pasteStackNext() },
                onStackCancel: { [weak self] in self?.cancelClipboardAction() },
                onScript: { [weak self] item in self?.chooseScript(for: item) },
                onTextToolUse: { [weak self] text in self?.useTextToolOutput(text) }
            )
        )
        preferenceObserver = preferences.$showPreview.removeDuplicates().sink { [weak self] preview in
            DispatchQueue.main.async { self?.resizePanel(preview: preview) }
        }
        actionsObserver = Publishers.CombineLatest(appState.$actionsPresented, appState.$stackPresented)
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }.dropFirst().sink { [weak self] presented in
            guard !presented.0, !presented.1 else { return }
            DispatchQueue.main.async {
                guard let self, let window = self.window, window.isVisible,
                      !window.isKeyWindow, window.attachedSheet == nil else { return }
                self.close()
            }
        }
        storeObserver = historyStore.$snapshotRevision.sink { [weak self] _ in
            DispatchQueue.main.async {
                guard let self else { return }
                if self.observedLibraryGeneration != self.historyStore.libraryGeneration ||
                    self.observedCaptureGeneration != self.historyStore.captureGeneration {
                    self.cancelClipboardAction()
                    self.observedLibraryGeneration = self.historyStore.libraryGeneration
                    self.observedCaptureGeneration = self.historyStore.captureGeneration
                    let historyIDs = Set(self.historyStore.items.map(\.id))
                    let savedIDs = Set(self.historyStore.libraryItems.map(\.id))
                    self.appState.stack.removeAll { $0.origin == .history ? !historyIDs.contains($0.id) : !savedIDs.contains($0.id) }
                    if self.appState.stack.isEmpty { self.appState.resetStackTarget() }
                }
            }
        }
        refreshResults()
        targetTerminationObserver = NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didTerminateApplicationNotification)
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self, self.previousApp?.isTerminated == true else { return }
                    self.previousApp = nil
                    self.appState.pasteTargetName = nil
                }
            }
        resultObserver = appState.$isUpdatingResults.removeDuplicates().sink { [weak self] updating in
            guard !updating else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.appState.recordVisibleResults(window: self.window)
            }
        }
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle(anchor: NSView? = nil, target: NSRunningApplication? = nil) {
        if window?.isVisible == true {
            close()
        } else {
            show(anchor: anchor, target: target)
        }
    }

    override func close() {
        guard !isOrderingOut else { return }
        if appState.editorDraft != nil { appState.requestEditorDismissal(); return }
        if appState.textToolDraft != nil { appState.textToolDraft = nil; return }
        if appState.groupDraft != nil { return }
        cancelClipboardAction()
        hidePanel()
    }

    private func hidePanel() {
        guard !isOrderingOut else { return }
        isOrderingOut = true
        appState.stackPresented = false
        window?.orderOut(nil)
        isOrderingOut = false
    }

    private func show(anchor: NSView?, target: NSRunningApplication?) {
        if PerformanceRecorder.enabled { appState.presentationStartedAt = ProcessInfo.processInfo.systemUptime }
        cancelClipboardAction()
        let frontmostApp = target ?? NSWorkspace.shared.frontmostApplication
        previousApp = frontmostApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmostApp
        appState.pasteTargetName = previousApp?.localizedName
        appState.prepareForPresentation()
        position(anchor: anchor)
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    func pasteFromMenu(_ item: ClipboardItem, target: NSRunningApplication?) {
        previousApp = target
        appState.pasteTargetName = target?.localizedName
        performPrimaryAction(item)
    }

    private func resizePanel(preview: Bool) {
        guard let window else { return }
        let old = window.frame
        let width: CGFloat = preview ? 880 : 520
        window.setFrame(NSRect(x: old.midX - width / 2, y: old.minY, width: width, height: 560), display: true)
    }

    private func cancelClipboardAction() {
        clipboardActionTask?.cancel()
        clipboardActionTask = nil
        clipboardActionID = nil
        appState.isPerformingClipboardAction = false
        appState.stackBusy = false
    }

    private func beginClipboardAction() -> UUID {
        cancelClipboardAction()
        let id = UUID()
        clipboardActionID = id
        appState.isPerformingClipboardAction = true
        return id
    }

    private func finishClipboardAction(id: UUID) -> Bool {
        guard clipboardActionID == id, !Task.isCancelled else { return false }
        clipboardActionTask = nil
        clipboardActionID = nil
        appState.isPerformingClipboardAction = false
        return true
    }

    private func copyToClipboard(_ item: ClipboardItem, dismissOnSuccess: Bool = false, plainText: Bool = false) {
        if appState.isSelecting { copyMergedSelection(); return }
        if prepareTemplate(item, paste: false, plainText: plainText) { return }
        let id = beginClipboardAction()
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.copyToClipboard(item, plainText: plainText)
            guard self.finishClipboardAction(id: id) else { return }
            if result.isSuccess { await self.historyStore.recordUse(item) }
            self.appState.apply(result)
            if result.isSuccess, dismissOnSuccess {
                self.hidePanel()
            } else if !result.isSuccess, self.window?.isVisible != true {
                self.window?.orderFrontRegardless()
                self.window?.makeKey()
            }
        }
    }

    private func performPrimaryAction(_ item: ClipboardItem, alternate: Bool = false) {
        if appState.isSelecting { copyMergedSelection(); return }
        if previousApp?.isTerminated == true { previousApp = nil; appState.pasteTargetName = nil }
        let plain = alternate ? !preferences.plainText : preferences.plainText
        if prepareTemplate(item, paste: preferences.selectionAction == .paste && AccessibilityService.isTrusted() && previousApp != nil, plainText: plain) { return }
        if preferences.selectionAction == .copy || !AccessibilityService.isTrusted() || previousApp == nil {
            copyToClipboard(item, dismissOnSuccess: true, plainText: plain)
        } else { paste(item, plainText: plain) }
    }

    private func prepareTemplate(_ item: ClipboardItem, paste: Bool, plainText: Bool, fromStack: Bool = false) -> Bool {
        guard item.origin == .library, historyStore.libraryItems.first(where: { $0.id == item.id })?.type == .snippet,
              !TextTemplate(text: item.previewText).variables.isEmpty else { return false }
        guard TextTemplate(text: item.previewText).variables.count <= 64 else { appState.showStatus("A template supports up to 64 variables."); return true }
        appState.textToolDraft = TextToolDraft(item: item, text: item.previewText, paste: paste, plainText: plainText, generation: historyStore.actionGeneration, fromStack: fromStack)
        return true
    }

    private func chooseScript(for item: ClipboardItem) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.shellScript]; panel.allowsMultipleSelection = false
        panel.message = "Choose a shell script that reads UTF-8 stdin and returns UTF-8 stdout. You can review and run it in the next step."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let script = panel.url, let self else { return }
            Task { @MainActor in
                do {
                    let loaded = try await self.historyStore.resolve(item)
                    guard loaded.kind != .concealed, let text = ClipboardTextRepresentation.string(in: loaded.assets) else { throw LibraryError.invalid("This content has no editable text.") }
                    self.appState.textToolDraft = TextToolDraft(item: item, text: text, script: script, paste: false, plainText: true, generation: self.historyStore.actionGeneration)
                } catch { self.appState.showStatus(error.localizedDescription, clearAfter: 6) }
            }
        }
    }

    private func useTextToolOutput(_ text: String) {
        guard let draft = appState.textToolDraft else { return }
        let request = beginClipboardAction()
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard draft.generation == self.historyStore.actionGeneration else { throw LibraryError.cleared }
                _ = try await self.historyStore.resolve(draft.item)
                try Task.checkCancellation()
                guard draft.generation == self.historyStore.actionGeneration else { throw LibraryError.cleared }
                self.appState.textToolDraft = nil
                let prepared = TextToolOutput.item(text)
                let result: PasteServiceResult
                if draft.paste {
                    result = await self.pasteService.paste(prepared, into: self.previousApp, plainText: draft.plainText, validating: [draft.item]) { [weak self] in self?.hidePanel() }
                } else { result = await self.pasteService.copyToClipboard(prepared, validating: [draft.item]) }
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.apply(result)
                if result.isSuccess {
                    if draft.fromStack, self.appState.stack.first?.id == draft.item.id { self.appState.stack.removeFirst() }
                    await self.historyStore.recordUse(draft.item)
                } else { self.window?.orderFrontRegardless(); self.window?.makeKey() }
            } catch {
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.showStatus(error.localizedDescription, clearAfter: 6)
            }
        }
    }

    private func paste(_ item: ClipboardItem, plainText: Bool) {
        let id = beginClipboardAction()
        let target = previousApp
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.paste(item, into: target, plainText: plainText) { [weak self] in
                self?.hidePanel()
            }
            guard self.finishClipboardAction(id: id) else { return }
            if result.isSuccess {
                await self.historyStore.recordUse(item)
                self.appState.clearStatus()
            } else {
                self.appState.apply(result)
                self.window?.orderFrontRegardless()
                self.window?.makeKey()
            }
        }
    }

    private func togglePin(_ item: ClipboardItem) {
        guard item.kind != .concealed else { appState.showStatus("Concealed content cannot be saved permanently."); return }
        if item.origin == .history, historyStore.savedSnapshot(for: item) == nil {
            prepareEditor(item, type: .snapshot)
            return
        }
        Task { [weak self] in
            guard let self else { return }
            let id = item.origin == .library ? item.id : self.historyStore.savedSnapshot(for: item)?.id
            if let id { self.report(await self.historyStore.removeLibraryItem(id: id)) }
        }
    }

    private func undoDelete() {
        Task { [weak self] in
            guard let self else { return }
            switch await self.historyStore.undoDelete() {
            case .success:
                self.appState.clearStatus()
            case let .failure(message):
                // Keep deletedItem so the user can retry undo after the storage issue resolves.
                self.appState.showStatus(message, clearAfter: 6)
            }
        }
    }

    private func remove(_ item: ClipboardItem) {
        cancelClipboardAction()
        Task { [weak self] in
            guard let self else { return }
            let result = item.origin == .library ? await self.historyStore.removeLibraryItem(id: item.id) : await self.historyStore.remove(id: item.id)
            switch result {
            case .success:
                // Undo is the success feedback; don't leave a stale error beside it.
                self.appState.clearStatus()
            case let .failure(message):
                self.appState.showStatus(message)
            }
        }
    }

    private func clearHistory() {
        cancelClipboardAction()
        Task { [weak self] in
            guard let self else { return }
            switch await self.historyStore.clear() {
            case .success:
                self.appState.showStatus("Clipboard history cleared.")
            case let .failure(message):
                self.appState.showStatus(message)
            }
        }
    }

    private func confirmAndClearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear Clipboard History?"
        appState.actionsPresented = false
        alert.informativeText = "Delete \(historyStore.items.filter { !$0.isPinned }.count) items from local history? Saved items and protected legacy pins will be kept. This cannot be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")

        if let window {
            alert.beginSheetModal(for: window) { [weak self] response in
                Task { @MainActor in
                    guard response == .alertFirstButtonReturn else { return }
                    self?.clearHistory()
                }
            }
            return
        }

        if alert.runModal() == .alertFirstButtonReturn {
            clearHistory()
        }
    }

    private func refreshResults() {
        appState.refreshResults(history: historyStore.items, library: historyStore.libraryItems, groups: historyStore.libraryGroups)
    }

    private func report(_ result: HistoryStoreMutationResult) {
        if case let .failure(message) = result { appState.showStatus(message, clearAfter: 6) }
        else { appState.clearStatus() }
    }

    private func newSnippet() {
        guard historyStore.isLibraryAvailable else { appState.showStatus(LibraryError.unavailable.localizedDescription); return }
        appState.beginEditing(LibraryDraft(type: .snippet, name: "Untitled Snippet", groupID: appState.selectedGroup.groupID,
                                          body: "", kind: .text, generation: historyStore.libraryGeneration))
    }

    private func copyMergedSelection() {
        let selected = appState.selectedItems
        let separator = appState.mergeSeparator
        let clipboardVersion = pasteService.clipboardChangeCount
        guard !selected.isEmpty else { appState.showStatus("Select items to merge."); return }
        let request = beginClipboardAction()
        let generation = historyStore.actionGeneration
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                var loaded: [ClipboardItem] = []
                for item in selected { loaded.append(try await self.historyStore.resolve(item)); try Task.checkCancellation() }
                guard generation == self.historyStore.actionGeneration else { throw LibraryError.cleared }
                let merged = try await Task.detached(priority: .userInitiated) { try MergedCopy.item(from: loaded, separator: separator) }.value
                try Task.checkCancellation()
                guard generation == self.historyStore.actionGeneration else { throw LibraryError.cleared }
                let result = await self.pasteService.copyToClipboard(merged, validating: selected, expectedChangeCount: clipboardVersion)
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.apply(result)
                if result.isSuccess { for item in selected { await self.historyStore.recordUse(item) } }
            } catch {
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.showStatus(error.localizedDescription, clearAfter: 6)
            }
        }
    }

    func pasteStackNext() {
        guard !appState.stackBusy, appState.editorDraft == nil, appState.groupDraft == nil,
              let item = appState.stack.first else { return }
        guard let target = previousApp, !target.isTerminated,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            appState.showStatus("Open the panel from the app you want to paste into."); return
        }
        if let pid = appState.stackTargetPID, pid != target.processIdentifier {
            appState.showStatus("The stack target changed. Choose Use Current Target to continue.", clearAfter: 6); return
        }
        appState.stackTargetPID = target.processIdentifier
        appState.stackTargetName = target.localizedName
        if prepareTemplate(item, paste: true, plainText: preferences.plainText, fromStack: true) {
            appState.stackPresented = false
            return
        }
        let request = beginClipboardAction()
        appState.stackBusy = true
        let plain = preferences.plainText
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.paste(item, into: target, plainText: plain) { [weak self] in self?.hidePanel() }
            guard self.finishClipboardAction(id: request) else { return }
            self.appState.stackBusy = false
            self.appState.apply(result)
            if result.isSuccess {
                self.appState.stack.removeFirst()
                await self.historyStore.recordUse(item)
            } else {
                self.window?.orderFrontRegardless(); self.window?.makeKey()
            }
        }
    }

    private func exportBackup() {
        cancelClipboardAction()
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "PasteLite-Library-Backup.json"
        panel.allowedContentTypes = [.json]
        panel.message = "Includes saved text, groups, original formats and images. File entries remain references."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do { try await self.historyStore.exportLibrary(to: url); self.appState.showStatus("Library backup saved.") }
                catch { self.appState.showStatus(error.localizedDescription, clearAfter: 8) }
            }
        }
    }

    private func importBackup() {
        cancelClipboardAction()
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Merge a PasteLite backup. Existing items, names and edits are kept; duplicates are skipped. File references require the original paths."
        guard let window else { return }
        panel.beginSheetModal(for: window) { [weak self] response in
            guard response == .OK, let url = panel.url, let self else { return }
            Task {
                do {
                    let result = try await self.historyStore.importLibrary(from: url)
                    self.appState.mode = .library
                    self.appState.selectedGroup = .all
                    self.appState.searchText = ""; self.appState.selectedFilter = .all; self.appState.selectedSource = nil
                    self.appState.showStatus("Imported \(result.added) items; skipped \(result.skipped) existing items.", clearAfter: 6)
                } catch { self.appState.showStatus(error.localizedDescription, clearAfter: 8) }
            }
        }
    }

    private func editSaved(_ item: LibraryItem) {
        appState.beginEditing(LibraryDraft(editingID: item.id, expectedRevision: item.revision, type: item.type,
                                          name: item.name, groupID: item.groupID, body: item.content.previewText,
                                          kind: item.content.kind, generation: historyStore.libraryGeneration))
    }

    private func prepareEditor(_ item: ClipboardItem, type: LibraryItemType) {
        guard historyStore.isLibraryAvailable else { appState.showStatus(LibraryError.unavailable.localizedDescription); return }
        guard appState.editorDraft == nil, appState.groupDraft == nil else { return }
        let request = beginClipboardAction()
        let generation = historyStore.libraryGeneration
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            do {
                let loaded = try await self.historyStore.resolve(item)
                try LibraryValidation.snapshot(loaded)
                let body: String
                if type == .snippet {
                    guard [.text, .code].contains(loaded.kind), let text = ClipboardTextRepresentation.string(in: loaded.assets) else {
                        throw LibraryError.invalid("This item does not contain editable text.")
                    }
                    try LibraryValidation.snippet(text, kind: loaded.kind)
                    body = text
                } else { body = "" }
                guard generation == self.historyStore.libraryGeneration else { throw LibraryError.cleared }
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.beginEditing(LibraryDraft(type: type, name: LibraryValidation.defaultName(item.title),
                                                       groupID: self.appState.selectedGroup.groupID, body: body,
                                                       kind: loaded.kind, source: loaded, generation: generation))
            } catch {
                guard self.finishClipboardAction(id: request) else { return }
                self.appState.showStatus(error.localizedDescription, clearAfter: 6)
            }
        }
    }

    private func deleteGroup(_ group: LibraryGroup) {
        let count = historyStore.libraryItems.filter { $0.groupID == group.id }.count
        confirm(title: "Delete “\(group.name)” ?", message: "\(count) saved items will move to Ungrouped. Their content will be kept.", button: "Delete Group") { [weak self] in
            guard let self else { return }
            Task { self.report(await self.historyStore.deleteGroup(group)) }
        }
    }

    private func confirmAndClearLibrary() {
        confirm(title: "Clear Saved Library?", message: "Delete \(historyStore.libraryItems.count) saved items and all custom groups? Clipboard history will be kept. This cannot be undone.", button: "Clear Saved Library") { [weak self] in
            guard let self else { return }
            self.cancelClipboardAction()
            Task { self.report(await self.historyStore.clearLibrary()) }
        }
    }

    private func confirm(title: String, message: String, button: String, action: @escaping @MainActor () -> Void) {
        appState.actionsPresented = false
        let alert = NSAlert()
        alert.messageText = title; alert.informativeText = message; alert.alertStyle = .warning
        alert.addButton(withTitle: button); alert.addButton(withTitle: "Cancel")
        if let window {
            alert.beginSheetModal(for: window) { response in
                Task { @MainActor in if response == .alertFirstButtonReturn { action() } }
            }
        }
    }

    var hasOpenEditor: Bool { appState.editorDraft != nil || appState.textToolDraft != nil }
    func finishEditorBeforeQuit(_ action: @escaping @MainActor () -> Void) {
        if appState.textToolDraft != nil { appState.textToolDraft = nil; action() }
        else { appState.requestEditorDismissal(afterDismiss: action) }
    }

    private func configure(_ panel: HistoryPanel) {
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary, .transient]
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.isOpaque = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.animationBehavior = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? .none : .utilityWindow
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.onResignKey = { [weak self] in
            guard let self, self.window?.isVisible == true,
                  self.window?.attachedSheet == nil, !self.appState.actionsPresented, !self.appState.stackPresented else { return }
            self.close()
        }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.appState.stackPresented { self.appState.stackPresented = false }
            else if self.appState.actionsPresented { self.appState.actionsPresented = false }
            else if !self.appState.searchText.isEmpty { self.appState.searchText = "" }
            else { self.close() }
        }
        panel.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.appState.moveSelection(delta: delta, in: self.currentItems)
        }
        panel.onReturnAction = { [weak self] in
            guard let self, !self.appState.isUpdatingResults, let item = self.currentSelection else { return }
            self.performPrimaryAction(item)
        }
        panel.onCopyAction = { [weak self] in
            guard let self, !self.appState.isUpdatingResults, let item = self.currentSelection else { return }
            self.copyToClipboard(item)
        }
        panel.onDeleteAction = { [weak self] in
            guard let self, self.appState.searchText.isEmpty, let item = self.currentSelection else { return }
            self.remove(item)
        }
        panel.canDeleteSelection = { [weak self] in self?.appState.searchText.isEmpty == true }
        panel.canUndoDeletion = { [weak self] in self?.historyStore.hasUndoDeletion == true }
        panel.onAlternateReturnAction = { [weak self] in
            guard let self, !self.appState.isUpdatingResults, let item = self.currentSelection else { return }
            self.performPrimaryAction(item, alternate: true)
        }
        panel.onActions = { [weak self] in self?.appState.actionsPresented.toggle() }
        panel.onPin = { [weak self] in if let self, let item = self.currentSelection { self.togglePin(item) } }
        panel.onUndo = { [weak self] in self?.undoDelete() }
        panel.onNumber = { [weak self] index in
            guard let self, !self.appState.isUpdatingResults, self.currentItems.indices.contains(index) else { return }
            self.performPrimaryAction(self.currentItems[index])
        }
        panel.onJump = { [weak self] last in
            guard let self else { return }
            self.appState.selectedItemID = last ? self.currentItems.last?.id : self.currentItems.first?.id
            self.appState.moveSelection(delta: 0, in: self.currentItems)
        }
        panel.onCycleFilter = { [weak self] reverse in
            guard let self else { return }
            let filters = HistoryFilter.allCases
            let index = filters.firstIndex(of: self.appState.selectedFilter) ?? 0
            self.appState.selectedFilter = filters[(index + (reverse ? filters.count - 1 : 1)) % filters.count]
        }
        panel.onSwitchMode = { [weak self] in self?.appState.switchMode() }
        panel.onNewSnippet = { [weak self] in if self?.appState.mode == .library { self?.newSnippet() } }
        panel.onEditSnippet = { [weak self] in
            guard let self, self.appState.mode == .library, let id = self.currentSelection?.id,
                  let item = self.historyStore.libraryItems.first(where: { $0.id == id && $0.type == .snippet }) else { return }
            self.editSaved(item)
        }
    }

    private func position(anchor: NSView?) {
        guard let window else { return }
        let screen = screen(for: anchor) ?? screenUnderMouse() ?? NSScreen.main
        let visibleFrame = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let size = window.frame.size
        let preferredOrigin = preferredOrigin(anchor: anchor, visibleFrame: visibleFrame, panelSize: size)
        let origin = NSPoint(
            x: clamp(preferredOrigin.x, lower: visibleFrame.minX + 24, upper: visibleFrame.maxX - size.width - 24),
            y: clamp(preferredOrigin.y, lower: visibleFrame.minY + 24, upper: visibleFrame.maxY - size.height - 24)
        )
        window.setFrameOrigin(origin)
    }

    private func preferredOrigin(anchor: NSView?, visibleFrame: NSRect, panelSize: NSSize) -> NSPoint {
        if let anchor,
           let anchorWindow = anchor.window {
            let localFrame = anchor.convert(anchor.bounds, to: nil)
            let screenFrame = anchorWindow.convertToScreen(localFrame)
            return NSPoint(
                x: screenFrame.midX - panelSize.width / 2,
                y: screenFrame.minY - panelSize.height - 12
            )
        }

        return NSPoint(
            x: visibleFrame.midX - panelSize.width / 2,
            y: preferences.position == .center ? visibleFrame.midY - panelSize.height / 2 : visibleFrame.maxY - panelSize.height - 88
        )
    }

    private func screen(for anchor: NSView?) -> NSScreen? {
        guard let anchor,
              let anchorWindow = anchor.window else {
            return nil
        }

        let localFrame = anchor.convert(anchor.bounds, to: nil)
        let screenFrame = anchorWindow.convertToScreen(localFrame)
        return NSScreen.screens.first { $0.frame.intersects(screenFrame) }
    }

    private func screenUnderMouse() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouseLocation, $0.frame, false) }
    }

    private func clamp(_ value: CGFloat, lower: CGFloat, upper: CGFloat) -> CGFloat {
        guard lower <= upper else { return lower }
        return min(max(value, lower), upper)
    }
}

private extension AppState {
    func apply(_ result: PasteServiceResult) {
        switch result {
        case .success:
            clearStatus()
        case let .failure(message):
            showStatus(message)
        }
    }
}

final class HistoryPanel: NSPanel {
    var onResignKey: (() -> Void)?
    var onCancel: (() -> Void)?
    var onMoveSelection: ((Int) -> Void)?
    var onReturnAction: (() -> Void)?
    var onCopyAction: (() -> Void)?
    var onDeleteAction: (() -> Void)?
    var onAlternateReturnAction: (() -> Void)?
    var onActions: (() -> Void)?
    var onPin: (() -> Void)?
    var onUndo: (() -> Void)?
    var onNumber: ((Int) -> Void)?
    var onJump: ((Bool) -> Void)?
    var onCycleFilter: ((Bool) -> Void)?
    var onSwitchMode: (() -> Void)?
    var onNewSnippet: (() -> Void)?
    var onEditSnippet: (() -> Void)?
    var canDeleteSelection: (() -> Bool)?
    var canUndoDeletion: (() -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func resignKey() {
        super.resignKey()
        onResignKey?()
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }

    override func sendEvent(_ event: NSEvent) {
        guard event.type == .keyDown, attachedSheet == nil else {
            super.sendEvent(event)
            return
        }

        // The field editor must receive composition events before history shortcuts.
        let textInput = firstResponder as? NSTextInputClient
        if textInput?.hasMarkedText() == true {
            super.sendEvent(event)
            return
        }
        let isEditingText = firstResponder is NSTextView || firstResponder is NSTextField
        let hasSelectedText: Bool
        if let textView = firstResponder as? NSTextView {
            hasSelectedText = textView.selectedRange().length > 0
        } else if let textField = firstResponder as? NSTextField {
            hasSelectedText = (textField.currentEditor()?.selectedRange.length ?? 0) > 0
        } else {
            hasSelectedText = false
        }
        let isActionControlFocused = firstResponder is NSButton || firstResponder is NSSegmentedControl
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c":
                if hasSelectedText { super.sendEvent(event) } else { onCopyAction?() }
                return
            case "k": onActions?(); return
            case "n": if onNewSnippet != nil { onNewSnippet?(); return }
            case "e": if onEditSnippet != nil { onEditSnippet?(); return }
            case "z":
                if !isEditingText, canUndoDeletion?() == true { onUndo?(); return }
            case let value?:
                if let number = Int(value), (1...9).contains(number) { onNumber?(number - 1); return }
            default: break
            }
        }
        if modifiers == [.command, .shift], event.charactersIgnoringModifiers?.lowercased() == "p" {
            onPin?(); return
        }

        switch event.keyCode {
        case 53:
            onCancel?()
        case 51, 117:
            if modifiers == .command && canDeleteSelection?() == false {
                super.sendEvent(event)
            } else if modifiers == .command || !isEditingText && modifiers.isEmpty {
                onDeleteAction?()
            } else {
                super.sendEvent(event)
            }
        case 126:
            if modifiers == .command { onJump?(false) }
            else if modifiers.isEmpty { onMoveSelection?(-1) } else { super.sendEvent(event) }
        case 125:
            if modifiers == .command { onJump?(true) }
            else if modifiers.isEmpty { onMoveSelection?(1) } else { super.sendEvent(event) }
        case 48:
            if modifiers == .control || modifiers == [.control, .shift] { onSwitchMode?() }
            else { super.sendEvent(event) }
        case 36, 76:
            if modifiers == .option {
                if let onAlternateReturnAction { onAlternateReturnAction() } else { onCopyAction?() }
            } else if modifiers.isEmpty {
                if isActionControlFocused { super.sendEvent(event) } else { onReturnAction?() }
            } else {
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
}
