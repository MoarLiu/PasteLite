import AppKit
import SwiftUI

@MainActor
final class HistoryPanelController: NSWindowController {
    private let appState: AppState
    private let historyStore: SQLiteHistoryStore
    private let pasteService: PasteService
    private var previousApp: NSRunningApplication?
    private var isOrderingOut = false

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
                    _ = self?.copyToClipboard(item)
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
        isOrderingOut = true
        window?.orderOut(nil)
        isOrderingOut = false
    }

    private func show(anchor: NSView?) {
        previousApp = NSWorkspace.shared.frontmostApplication
        appState.prepareForPresentation()
        position(anchor: anchor)
        window?.orderFrontRegardless()
        window?.makeKey()
    }

    private func copyToClipboard(_ item: ClipboardItem) -> PasteServiceResult {
        let result = pasteService.copyToClipboard(item)
        appState.apply(result, successMessage: "Copied to clipboard.")
        return result
    }

    private func paste(_ item: ClipboardItem) {
        let result = pasteService.paste(item, into: previousApp)
        guard result.isSuccess else {
            appState.apply(result, successMessage: "")
            return
        }
        close()
    }

    private func remove(_ item: ClipboardItem) {
        historyStore.remove(id: item.id)
        appState.showStatus("Removed from history.")
    }

    private func clearHistory() {
        historyStore.clear()
        appState.showStatus("Clipboard history cleared.")
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
        panel.onResignKey = { [weak self] in self?.close() }
        panel.onCancel = { [weak self] in self?.close() }
        panel.onMoveSelection = { [weak self] delta in
            guard let self else { return }
            self.appState.moveSelection(delta: delta, in: self.currentItems)
        }
        panel.onReturnAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            let result = self.copyToClipboard(item)
            if result.isSuccess {
                self.close()
            }
        }
        panel.onCopyAction = { [weak self] in
            guard let self, let item = self.currentSelection else { return }
            _ = self.copyToClipboard(item)
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
        guard event.type == .keyDown else {
            super.sendEvent(event)
            return
        }

        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        switch event.keyCode {
        case 53:
            onCancel?()
        case 51, 117:
            if modifiers.subtracting([.numericPad, .function]).isEmpty {
                onDeleteAction?()
            } else {
                super.sendEvent(event)
            }
        case 126:
            onMoveSelection?(-1)
        case 125:
            onMoveSelection?(1)
        case 36, 76:
            if modifiers.contains(.option) {
                onCopyAction?()
            } else if modifiers.subtracting([.numericPad]).isEmpty {
                onReturnAction?()
            } else {
                super.sendEvent(event)
            }
        default:
            super.sendEvent(event)
        }
    }
}
