import AppKit
import SwiftUI

enum AppTheme: String, CaseIterable, Identifiable {
    case auto, light, dark
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var appearance: NSAppearance? {
        switch self {
        case .auto: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

enum PanelPosition: String, CaseIterable { case center, nearTop }
enum SelectionAction: String, CaseIterable { case paste, copy }
enum SensitivePolicy: String, CaseIterable { case masked, skip }
enum UpdateChannel: String, CaseIterable { case stable, beta }
enum SettingsPage: String, CaseIterable, Identifiable {
    case general, storage, privacy, updates
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
    var symbol: String {
        switch self {
        case .general: return "slider.horizontal.3"
        case .storage: return "internaldrive"
        case .privacy: return "checkmark.shield"
        case .updates: return "arrow.triangle.2.circlepath"
        }
    }
}

@MainActor
final class AppPreferences: ObservableObject {
    static let shared = AppPreferences(defaults:
        ProcessInfo.processInfo.environment["PASTELITE_PREFERENCES_SUITE"].flatMap(UserDefaults.init(suiteName:)) ?? .standard)
    private let defaults: UserDefaults
    @Published var theme: AppTheme { didSet { save(theme.rawValue, "theme"); NSApp.appearance = theme.appearance } }
    @Published var accent: PL.Accent { didSet { save(accent.rawValue, "accent") } }
    @Published var position: PanelPosition { didSet { save(position.rawValue, "position") } }
    @Published var showPreview: Bool { didSet { save(showPreview, "showPreview") } }
    @Published var selectionAction: SelectionAction { didSet { save(selectionAction.rawValue, "selectionAction") } }
    @Published var plainText: Bool { didSet { save(plainText, "plainText") } }
    @Published var historyLimit: Int { didSet { save(historyLimit, "historyLimit") } }
    @Published var recordingPaused: Bool { didSet { save(recordingPaused, "recordingPaused") } }
    @Published var sensitivePolicy: SensitivePolicy { didSet { save(sensitivePolicy.rawValue, "sensitivePolicy") } }
    @Published var clearOnQuit: Bool { didSet { save(clearOnQuit, "clearOnQuit") } }
    @Published var excludedApps: [String] { didSet { save(excludedApps, "excludedApps") } }
    @Published var fetchLinkPreviews: Bool { didSet { save(fetchLinkPreviews, "fetchLinkPreviews") } }
    @Published var automaticUpdates: Bool { didSet { save(automaticUpdates, "automaticUpdates") } }
    @Published var automaticDownloads: Bool { didSet { save(automaticDownloads, "automaticDownloads") } }
    @Published var updateChannel: UpdateChannel { didSet { save(updateChannel.rawValue, "updateChannel") } }
    @Published var updateEndpoint: String { didSet { save(updateEndpoint, "updateEndpoint") } }
    @Published var settingsPage: SettingsPage = .general

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func value(_ key: String) -> String { defaults.string(forKey: "design.\(key)") ?? "" }
        theme = AppTheme(rawValue: value("theme")) ?? .auto
        accent = PL.Accent(rawValue: value("accent")) ?? .blue
        position = PanelPosition(rawValue: value("position")) ?? .center
        showPreview = defaults.object(forKey: "design.showPreview") as? Bool ?? true
        selectionAction = SelectionAction(rawValue: value("selectionAction")) ?? .paste
        plainText = defaults.bool(forKey: "design.plainText")
        historyLimit = max(50, defaults.object(forKey: "design.historyLimit") as? Int ?? 500)
        recordingPaused = defaults.bool(forKey: "design.recordingPaused")
        sensitivePolicy = SensitivePolicy(rawValue: value("sensitivePolicy")) ?? .masked
        clearOnQuit = defaults.bool(forKey: "design.clearOnQuit")
        excludedApps = defaults.stringArray(forKey: "design.excludedApps") ?? []
        fetchLinkPreviews = defaults.bool(forKey: "design.fetchLinkPreviews")
        automaticUpdates = defaults.object(forKey: "design.automaticUpdates") as? Bool ?? true
        automaticDownloads = defaults.bool(forKey: "design.automaticDownloads")
        updateChannel = UpdateChannel(rawValue: value("updateChannel")) ?? .stable
        updateEndpoint = value("updateEndpoint")
    }

    private func save(_ value: Any, _ key: String) { defaults.set(value, forKey: "design.\(key)") }
}
