import AppKit
import Combine
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let appState = AppState()
    private let hotkeySettings = HotkeySettingsStore.shared
    private var statusItem: NSStatusItem?
    private var hotkeyStatusMenuItem: NSMenuItem?
    private var updateMenuItem: NSMenuItem?
    private var panelController: HistoryPanelController?
    private var clipboardMonitor: ClipboardMonitor?
    private var hotkeyManager: HotkeyManager?
    private var hotkeySettingsCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        if let appIcon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = appIcon
        }

        let historyStore = SQLiteHistoryStore()
        let pasteService = PasteService(historyStore: historyStore)
        let panelController = HistoryPanelController(
            appState: appState,
            historyStore: historyStore,
            pasteService: pasteService
        )

        self.panelController = panelController
        self.clipboardMonitor = ClipboardMonitor(historyStore: historyStore) { [weak appState = self.appState] message in
            appState?.showStatus(message)
        }
        self.hotkeyManager = HotkeyManager { [weak panelController] in
            panelController?.toggle()
        }

        configureStatusItem()
        observeHotkeySettings()
        clipboardMonitor?.start()
        registerCurrentHotkey()
    }

    func applicationWillTerminate(_ notification: Notification) {
        clipboardMonitor?.stop()
        hotkeyManager?.unregister()
        hotkeySettingsCancellable?.cancel()
    }

    private func configureStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "PasteLite")

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(
                title: "Show Clipboard History",
                action: #selector(togglePanelFromStatusItem),
                keyEquivalent: ""
            )
        )

        let hotkeyStatusMenuItem = NSMenuItem(title: "Hotkey: Registering...", action: nil, keyEquivalent: "")
        hotkeyStatusMenuItem.isEnabled = false
        menu.addItem(hotkeyStatusMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        let updateMenuItem = NSMenuItem(title: "Check for Updates...", action: #selector(checkForUpdates), keyEquivalent: "")
        menu.addItem(updateMenuItem)
        let versionMenuItem = NSMenuItem(title: AppInfo.displayVersion, action: nil, keyEquivalent: "")
        versionMenuItem.isEnabled = false
        menu.addItem(versionMenuItem)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit PasteLite", action: #selector(quit), keyEquivalent: "q"))

        menu.items.forEach { $0.target = self }
        item.menu = menu

        self.hotkeyStatusMenuItem = hotkeyStatusMenuItem
        self.updateMenuItem = updateMenuItem
        statusItem = item
    }

    @objc private func togglePanelFromStatusItem() {
        panelController?.toggle(anchor: statusItem?.button)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    @objc private func openSettings() {
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func checkForUpdates() {
        updateMenuItem?.isEnabled = false
        updateMenuItem?.title = "Checking for Updates..."

        Task {
            let result: Result<UpdateCheckResult, Error>
            do {
                result = .success(try await UpdateChecker().check())
            } catch {
                result = .failure(error)
            }

            await MainActor.run {
                self.updateMenuItem?.isEnabled = true
                self.updateMenuItem?.title = "Check for Updates..."
                self.presentUpdateResult(result)
            }
        }
    }

    private func updateHotkeyStatus(_ status: HotkeyRegistrationStatus?) {
        let message = status?.message ?? "Hotkey unavailable"
        hotkeySettings.updateRegistrationStatus(status)
        hotkeyStatusMenuItem?.title = message
        statusItem?.button?.toolTip = message
    }

    private func observeHotkeySettings() {
        hotkeySettingsCancellable = hotkeySettings.$settingsVersion
            .dropFirst()
            .sink { [weak self] _ in
                Task { @MainActor in
                    self?.registerCurrentHotkey()
                }
            }
    }

    private func registerCurrentHotkey() {
        updateHotkeyStatus(hotkeyManager?.register(shortcuts: hotkeySettings.selectedShortcuts))
    }

    private func presentUpdateResult(_ result: Result<UpdateCheckResult, Error>) {
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.alertStyle = .informational

        switch result {
        case let .success(updateResult):
            configure(alert, for: updateResult)
        case let .failure(error):
            alert.messageText = "Could Not Check for Updates"
            alert.informativeText = error.localizedDescription
            alert.addButton(withTitle: "OK")
        }

        let response = alert.runModal()
        if response == .alertFirstButtonReturn,
           case let .success(.updateAvailable(_, _, releaseURL?)) = result {
            NSWorkspace.shared.open(releaseURL)
        }
    }

    private func configure(_ alert: NSAlert, for result: UpdateCheckResult) {
        switch result {
        case .notConfigured:
            alert.messageText = "Update Checking Is Not Configured"
            alert.informativeText = "This build does not include an update feed URL."
            alert.addButton(withTitle: "OK")
        case let .upToDate(currentVersion):
            alert.messageText = "PasteLite Is Up to Date"
            alert.informativeText = "You are running PasteLite \(currentVersion)."
            alert.addButton(withTitle: "OK")
        case let .updateAvailable(currentVersion, latestVersion, releaseURL):
            alert.messageText = "A PasteLite Update Is Available"
            alert.informativeText = "Installed: \(currentVersion)\nLatest: \(latestVersion)"
            if releaseURL != nil {
                alert.addButton(withTitle: "Open Release")
                alert.addButton(withTitle: "Cancel")
            } else {
                alert.addButton(withTitle: "OK")
            }
        }
    }
}
