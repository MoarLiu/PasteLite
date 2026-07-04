import Carbon
import Foundation

struct HotkeyShortcutChoice: Identifiable, Equatable {
    var id: String
    var title: String
    var shortcuts: [HotkeyShortcut]
}

@MainActor
final class HotkeySettingsStore: ObservableObject {
    static let shared = HotkeySettingsStore()

    static let defaultChoiceID = "automatic"
    static let customChoiceID = "custom"
    static let disabledChoiceID = "disabled"
    static let baseChoices: [HotkeyShortcutChoice] = [
        HotkeyShortcutChoice(
            id: "automatic",
            title: "Automatic",
            shortcuts: HotkeyShortcut.defaults
        ),
        HotkeyShortcutChoice(
            id: HotkeyShortcut.defaults[0].id,
            title: HotkeyShortcut.defaults[0].title,
            shortcuts: [HotkeyShortcut.defaults[0]]
        ),
        HotkeyShortcutChoice(
            id: HotkeyShortcut.defaults[1].id,
            title: HotkeyShortcut.defaults[1].title,
            shortcuts: [HotkeyShortcut.defaults[1]]
        ),
        HotkeyShortcutChoice(
            id: HotkeyShortcut.controlOptionV.id,
            title: HotkeyShortcut.controlOptionV.title,
            shortcuts: [HotkeyShortcut.controlOptionV]
        ),
        HotkeyShortcutChoice(
            id: HotkeyShortcut.controlOptionCommandV.id,
            title: HotkeyShortcut.controlOptionCommandV.title,
            shortcuts: [HotkeyShortcut.controlOptionCommandV]
        ),
        HotkeyShortcutChoice(
            id: customChoiceID,
            title: "Custom...",
            shortcuts: []
        ),
        HotkeyShortcutChoice(
            id: disabledChoiceID,
            title: "Disabled",
            shortcuts: []
        )
    ]

    @Published private(set) var selectedChoiceID: String
    @Published private(set) var customShortcut: HotkeyShortcut?
    @Published private(set) var isRecording = false
    @Published private(set) var validationMessage: String?
    @Published private(set) var registrationMessage = "Hotkey: Registering..."
    @Published private(set) var settingsVersion = 0

    private static let selectedChoiceKey = "PasteLite.selectedHotkeyChoice"
    private static let customKeyCodeKey = "PasteLite.customHotkeyKeyCode"
    private static let customModifiersKey = "PasteLite.customHotkeyModifiers"
    private static let customTitleKey = "PasteLite.customHotkeyTitle"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        customShortcut = Self.loadCustomShortcut(from: defaults)
        let storedChoiceID = defaults.string(forKey: Self.selectedChoiceKey)
        if let storedChoiceID,
           Self.baseChoice(id: storedChoiceID) != nil {
            selectedChoiceID = storedChoiceID
        } else {
            selectedChoiceID = Self.defaultChoiceID
        }
    }

    var choices: [HotkeyShortcutChoice] {
        Self.baseChoices.map { choice in
            guard choice.id == Self.customChoiceID,
                  let customShortcut else {
                return choice
            }
            return HotkeyShortcutChoice(
                id: choice.id,
                title: "Custom: \(customShortcut.title)",
                shortcuts: [customShortcut]
            )
        }
    }

    var selectedChoice: HotkeyShortcutChoice {
        choices.first { $0.id == selectedChoiceID } ?? choices[0]
    }

    var selectedShortcuts: [HotkeyShortcut] {
        selectedChoice.shortcuts
    }

    func selectChoice(id: String) {
        guard Self.baseChoice(id: id) != nil else { return }
        selectedChoiceID = id
        defaults.set(id, forKey: Self.selectedChoiceKey)
        validationMessage = nil
        settingsVersion += 1
    }

    func updateRegistrationStatus(_ status: HotkeyRegistrationStatus?) {
        registrationMessage = status?.message ?? "Hotkey unavailable"
    }

    func beginRecording() {
        isRecording = true
        validationMessage = "Press a shortcut containing Command, Control, or Option. Esc cancels."
    }

    func cancelRecording() {
        isRecording = false
        validationMessage = nil
    }

    func recordShortcut(keyCode: UInt32, modifiers: UInt32, title: String) {
        guard Self.isValidShortcut(keyCode: keyCode, modifiers: modifiers) else {
            validationMessage = "Use at least one of Command, Control, or Option with another key."
            isRecording = true
            return
        }

        let shortcut = HotkeyShortcut(
            id: Self.customChoiceID,
            keyCode: keyCode,
            modifiers: modifiers,
            title: title
        )
        customShortcut = shortcut
        selectedChoiceID = Self.customChoiceID
        validationMessage = nil
        isRecording = false
        defaults.set(Self.customChoiceID, forKey: Self.selectedChoiceKey)
        defaults.set(Int(keyCode), forKey: Self.customKeyCodeKey)
        defaults.set(Int(modifiers), forKey: Self.customModifiersKey)
        defaults.set(title, forKey: Self.customTitleKey)
        settingsVersion += 1
    }

    static func baseChoice(id: String) -> HotkeyShortcutChoice? {
        baseChoices.first { $0.id == id }
    }

    static func isValidShortcut(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let requiredModifiers = UInt32(cmdKey | controlKey | optionKey)
        return modifiers & requiredModifiers != 0
    }

    private static func loadCustomShortcut(from defaults: UserDefaults) -> HotkeyShortcut? {
        guard let title = defaults.string(forKey: customTitleKey) else {
            return nil
        }

        let keyCode = defaults.integer(forKey: customKeyCodeKey)
        let modifiers = defaults.integer(forKey: customModifiersKey)
        guard isValidShortcut(keyCode: UInt32(keyCode), modifiers: UInt32(modifiers)) else {
            return nil
        }

        return HotkeyShortcut(
            id: customChoiceID,
            keyCode: UInt32(keyCode),
            modifiers: UInt32(modifiers),
            title: title
        )
    }
}
