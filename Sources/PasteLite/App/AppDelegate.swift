import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let hotkeySettings = HotkeySettingsStore.shared
    private let preferences = AppPreferences.shared
    private var statusItem: NSStatusItem?
    private var popover: NSPopover?
    private var menuTarget: NSRunningApplication?
    private var panelController: HistoryPanelController?
    private var clipboardMonitor: ClipboardMonitor?
    private var hotkeyManager: HotkeyManager?
    private var hotkeyRegistrationController: HotkeyRegistrationController?
    private var observers = Set<AnyCancellable>()
    private var maintenanceTimer: Timer?
    private var updateTimer: Timer?
    private var isTerminating = false
    private var isReadyToTerminate = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        NSApp.appearance = preferences.theme.appearance
        if let appIcon = NSImage(named: "AppIcon") { NSApp.applicationIconImage = appIcon }
        let historyStore = AppServices.shared.historyStore
        let pasteService = PasteService(historyStore: historyStore)
        let controller = HistoryPanelController(appState: appState, historyStore: historyStore, pasteService: pasteService)
        panelController = controller
        clipboardMonitor = ClipboardMonitor(historyStore: historyStore, onError: { [weak appState] message in
            appState?.showStatus(message)
        }, preferences: preferences)
        hotkeyManager = HotkeyManager { [weak controller, weak hotkeySettings] in
            guard hotkeySettings?.isRecording == false else { return }
            controller?.toggle()
        }
        configureStatusItem(historyStore: historyStore)
        FolderSyncService.shared.start(store: historyStore)
        preferences.$localMCPEnabled.removeDuplicates().sink { enabled in
            if enabled { LocalMCPServer.shared.start(store: historyStore) }
            else { LocalMCPServer.shared.stop() }
        }.store(in: &observers)
        if let hotkeyManager {
            hotkeyRegistrationController = HotkeyRegistrationController(settings: hotkeySettings, registrar: hotkeyManager) { [weak self] status in
                self?.hotkeySettings.updateRegistrationStatus(status)
                self?.statusItem?.button?.toolTip = status.message
            }
        }
        preferences.$recordingPaused.dropFirst().sink { [weak self] _ in
            historyStore.invalidateCaptures()
            DispatchQueue.main.async { self?.updateStatusIcon() }
        }.store(in: &observers)
        preferences.$historyLimit.removeDuplicates().dropFirst().sink { limit in
            Task { await historyStore.updateLimit(limit) }
        }.store(in: &observers)
        preferences.$sensitivePolicy.dropFirst().sink { _ in historyStore.invalidateCaptures() }.store(in: &observers)
        preferences.$excludedApps.dropFirst().sink { _ in historyStore.invalidateCaptures() }.store(in: &observers)
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            Task { @MainActor in await historyStore.expireSensitive() }
        }
        updateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in
                if AppPreferences.shared.automaticUpdates { await UpdateModel.shared.check(trigger: .automatic) }
            }
        }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-preview"),
           ProcessInfo.processInfo.environment["PASTELITE_DATA_DIRECTORY"] != nil {
            preferences.automaticUpdates = false
            Task {
                await PreviewFixtures.seed(historyStore)
                if ProcessInfo.processInfo.arguments.contains("--review-quit") {
                    preferences.clearOnQuit = true
                    NSApp.terminate(nil)
                    NSApp.terminate(nil)
                } else { controller.toggle() }
            }
            return
        }
        #endif
        clipboardMonitor?.start()
        if ProcessInfo.processInfo.arguments.contains("--show-history") { controller.toggle() }
        Task {
            if preferences.automaticUpdates { await UpdateModel.shared.check(trigger: .automatic) }
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if isReadyToTerminate { return .terminateNow }
        guard !isTerminating else { return .terminateCancel }
        if panelController?.hasOpenEditor == true {
            panelController?.finishEditorBeforeQuit { sender.terminate(nil) }
            return .terminateCancel
        }
        guard preferences.clearOnQuit else { return .terminateNow }
        isTerminating = true
        FolderSyncService.shared.stop()
        clipboardMonitor?.stop()
        Task {
            let result = await AppServices.shared.historyStore.clearIncludingPinned()
            if result.isSuccess {
                self.preferences.syncFolder = ""
                self.isReadyToTerminate = true
                DispatchQueue.main.async { sender.terminate(nil) }
            }
            else {
                ReleaseInstaller.cancelPendingInstall()
                isTerminating = false
                clipboardMonitor?.start()
                FolderSyncService.shared.start(store: AppServices.shared.historyStore)
                let alert = NSAlert()
                alert.messageText = "Could Not Clear History"
                alert.informativeText = "PasteLite is still open so you can retry clearing your clipboard history."
                alert.runModal()
            }
        }
        // NSApplication's terminateLater nested loop can block the Swift main actor
        // when termination originated in an async action. Return to the run loop,
        // then issue the final termination only after storage finishes.
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        LocalMCPServer.shared.stop()
        FolderSyncService.shared.stop()
        clipboardMonitor?.stop()
        hotkeyRegistrationController?.stop()
        maintenanceTimer?.invalidate()
        updateTimer?.invalidate()
    }

    private func configureStatusItem(historyStore: SQLiteHistoryStore) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        updateStatusIcon()
        item.button?.target = self
        item.button?.action = #selector(toggleMenu)
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: MenuBarView(
            historyStore: historyStore,
            onHistory: { [weak self] in
                guard let self else { return }
                self.popover?.close()
                self.panelController?.toggle(anchor: self.statusItem?.button, target: self.menuTarget)
            },
            onPaste: { [weak self] item in
                guard let self else { return }
                self.popover?.close()
                self.panelController?.pasteFromMenu(item, target: self.menuTarget)
            },
            onSettings: { [weak self] in self?.openSettings() },
            onUpdates: { [weak self] in self?.openSettings(page: .updates); Task { await UpdateModel.shared.check() } },
            onQuit: { NSApp.terminate(nil) }
        ))
        self.popover = popover
    }

    private func updateStatusIcon() {
        let name = preferences.recordingPaused ? "MenuBarIconPausedTemplate" : "MenuBarIconTemplate"
        let image = NSImage(named: name) ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteLite")
        image?.isTemplate = true
        image?.size = NSSize(width: 18, height: 18)
        statusItem?.button?.image = image
        statusItem?.button?.appearsDisabled = preferences.recordingPaused
        statusItem?.button?.setAccessibilityLabel(preferences.recordingPaused ? "PasteLite, recording paused" : "PasteLite")
    }

    @objc private func toggleMenu() {
        guard let button = statusItem?.button, let popover else { return }
        if popover.isShown { popover.close() }
        else {
            menuTarget = NSWorkspace.shared.frontmostApplication
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
    }

    private func openSettings(page: SettingsPage = .general) {
        popover?.close()
        preferences.settingsPage = page
        // Menu and Command-comma use the same SwiftUI Settings scene.
        if #available(macOS 14, *) {
            SettingsActionRouter.open?()
        } else {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}
