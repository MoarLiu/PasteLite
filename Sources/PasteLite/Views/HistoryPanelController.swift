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

    private var currentItems: [ClipboardItem] {
        appState.filteredItems(in: historyStore.items)
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
                }
            )
        )
        preferenceObserver = preferences.$showPreview.removeDuplicates().sink { [weak self] preview in
            DispatchQueue.main.async { self?.resizePanel(preview: preview) }
        }
        actionsObserver = appState.$actionsPresented.removeDuplicates().dropFirst().sink { [weak self] presented in
            guard !presented else { return }
            DispatchQueue.main.async {
                guard let self, let window = self.window, window.isVisible,
                      !window.isKeyWindow, window.attachedSheet == nil else { return }
                self.close()
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
        cancelClipboardAction()
        hidePanel()
    }

    private func hidePanel() {
        guard !isOrderingOut else { return }
        isOrderingOut = true
        window?.orderOut(nil)
        isOrderingOut = false
    }

    private func show(anchor: NSView?, target: NSRunningApplication?) {
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
        let id = beginClipboardAction()
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.copyToClipboard(item, plainText: plainText)
            guard self.finishClipboardAction(id: id) else { return }
            if result.isSuccess { await self.historyStore.recordUse(item) }
            self.appState.apply(result)
            if result.isSuccess, dismissOnSuccess { self.hidePanel() }
        }
    }

    private func performPrimaryAction(_ item: ClipboardItem, alternate: Bool = false) {
        let plain = alternate ? !preferences.plainText : preferences.plainText
        if preferences.selectionAction == .copy || !AccessibilityService.isTrusted() || previousApp == nil {
            copyToClipboard(item, dismissOnSuccess: true, plainText: plain)
        } else { paste(item, plainText: plain) }
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
        Task { [weak self] in
            guard let self else { return }
            if case let .failure(message) = await self.historyStore.togglePin(item) { self.appState.showStatus(message) }
        }
    }

    private func undoDelete() {
        Task { [weak self] in
            guard let self else { return }
            if case let .failure(message) = await self.historyStore.undoDelete() { self.appState.showStatus(message) }
        }
    }

    private func remove(_ item: ClipboardItem) {
        cancelClipboardAction()
        Task { [weak self] in
            guard let self else { return }
            switch await self.historyStore.remove(id: item.id) {
            case .success:
                self.appState.showStatus("Removed from history.")
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
        alert.informativeText = "Delete \(historyStore.items.filter { !$0.isPinned }.count) items from local history? Pinned items will be kept. This cannot be undone."
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
                  self.window?.attachedSheet == nil, !self.appState.actionsPresented else { return }
            self.close()
        }
        panel.onCancel = { [weak self] in
            guard let self else { return }
            if self.appState.actionsPresented { self.appState.actionsPresented = false }
            else if !self.appState.searchText.isEmpty { self.appState.searchText = "" }
            else { self.close() }
        }
        panel.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.appState.moveSelection(delta: delta, in: self.currentItems)
        }
        panel.onReturnAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.performPrimaryAction(item)
        }
        panel.onCopyAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.copyToClipboard(item)
        }
        panel.onDeleteAction = { [weak self] in
            guard let self, self.appState.searchText.isEmpty, let item = self.currentSelection else { return }
            self.remove(item)
        }
        panel.canDeleteSelection = { [weak self] in self?.appState.searchText.isEmpty == true }
        panel.canUndoDeletion = { [weak self] in self?.historyStore.deletedItem != nil }
        panel.onAlternateReturnAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.performPrimaryAction(item, alternate: true)
        }
        panel.onActions = { [weak self] in self?.appState.actionsPresented.toggle() }
        panel.onPin = { [weak self] in if let self, let item = self.currentSelection { self.togglePin(item) } }
        panel.onUndo = { [weak self] in self?.undoDelete() }
        panel.onNumber = { [weak self] index in
            guard let self, self.currentItems.indices.contains(index) else { return }
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
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.capsLock, .numericPad, .function])
        if modifiers == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "c": onCopyAction?(); return
            case "k": onActions?(); return
            case "z":
                if canUndoDeletion?() == true { onUndo?(); return }
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
            if modifiers.isEmpty || modifiers == .shift { onCycleFilter?(modifiers == .shift) }
            else { super.sendEvent(event) }
        case 36, 76:
            if modifiers == .option {
                if let onAlternateReturnAction { onAlternateReturnAction() } else { onCopyAction?() }
            } else if modifiers.isEmpty {
                onReturnAction?()
            } else {
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
}
