import AppKit
import SwiftUI

@MainActor
final class HistoryPanelController: NSWindowController {
    private let appState: AppState
    private let historyStore: SQLiteHistoryStore
    private let pasteService: PasteService
    private var previousApp: NSRunningApplication?
    private var isOrderingOut = false
    private(set) var clipboardActionTask: Task<Void, Never>?
    private var clipboardActionID: UUID?

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
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 510),
            styleMask: [.nonactivatingPanel, .titled, .fullSizeContentView, .resizable],
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
                    self?.paste(item)
                },
                onRemove: { [weak self] item in
                    self?.remove(item)
                },
                onClear: { [weak self] in
                    self?.confirmAndClearHistory()
                },
                onDismiss: { [weak self] in
                    self?.close()
                }
            )
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func toggle(anchor: NSView? = nil) {
        if window?.isVisible == true {
            close()
        } else {
            show(anchor: anchor)
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

    private func show(anchor: NSView?) {
        cancelClipboardAction()
        let frontmostApp = NSWorkspace.shared.frontmostApplication
        previousApp = frontmostApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier ? nil : frontmostApp
        appState.pasteTargetName = previousApp?.localizedName
        appState.prepareForPresentation()
        position(anchor: anchor)
        window?.orderFrontRegardless()
        window?.makeKey()
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

    private func copyToClipboard(_ item: ClipboardItem, dismissOnSuccess: Bool = false) {
        let id = beginClipboardAction()
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.copyToClipboard(item)
            guard self.finishClipboardAction(id: id) else { return }
            self.appState.apply(result, successMessage: "Copied to clipboard.")
            if result.isSuccess, dismissOnSuccess { self.hidePanel() }
        }
    }

    private func paste(_ item: ClipboardItem) {
        let id = beginClipboardAction()
        let target = previousApp
        clipboardActionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.pasteService.paste(item, into: target) { [weak self] in
                self?.hidePanel()
            }
            guard self.finishClipboardAction(id: id) else { return }
            if !result.isSuccess {
                self.appState.apply(result, successMessage: "")
                self.window?.orderFrontRegardless()
                self.window?.makeKey()
            }
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
        alert.informativeText = "This removes every saved clipboard item from local history."
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
        panel.animationBehavior = .utilityWindow
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.onResignKey = { [weak self] in
            guard let self, self.window?.isVisible == true,
                  self.window?.attachedSheet == nil else { return }
            self.close()
        }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.appState.moveSelection(delta: delta, in: self.currentItems)
        }
        panel.onReturnAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.copyToClipboard(item, dismissOnSuccess: true)
        }
        panel.onCopyAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.copyToClipboard(item)
        }
        panel.onDeleteAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            self.remove(item)
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
            y: visibleFrame.maxY - panelSize.height - 88
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
    func apply(_ result: PasteServiceResult, successMessage: String) {
        switch result {
        case .success:
            guard !successMessage.isEmpty else { return }
            showStatus(successMessage)
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

        switch event.keyCode {
        case 53:
            onCancel?()
        case 51, 117:
            if !isEditingText && modifiers.isEmpty {
                onDeleteAction?()
            } else {
                super.sendEvent(event)
            }
        case 126:
            if modifiers.isEmpty { onMoveSelection?(-1) } else { super.sendEvent(event) }
        case 125:
            if modifiers.isEmpty { onMoveSelection?(1) } else { super.sendEvent(event) }
        case 36, 76:
            if modifiers == .option {
                onCopyAction?()
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
