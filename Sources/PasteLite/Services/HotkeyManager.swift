import AppKit
import Carbon

struct HotkeyShortcut: Equatable {
    var id: String
    var keyCode: UInt32
    var modifiers: UInt32
    var title: String

    static let defaults = [
        HotkeyShortcut(
            id: "shift-command-v",
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | shiftKey),
            title: "Shift-Command-V"
        ),
        HotkeyShortcut(
            id: "shift-option-command-v",
            keyCode: UInt32(kVK_ANSI_V),
            modifiers: UInt32(cmdKey | optionKey | shiftKey),
            title: "Shift-Option-Command-V"
        )
    ]

    static let controlOptionV = HotkeyShortcut(
        id: "control-option-v",
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey),
        title: "Control-Option-V"
    )

    static let controlOptionCommandV = HotkeyShortcut(
        id: "control-option-command-v",
        keyCode: UInt32(kVK_ANSI_V),
        modifiers: UInt32(controlKey | optionKey | cmdKey),
        title: "Control-Option-Command-V"
    )
}

extension HotkeyShortcut {
    var displayTitle: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return "\(result)\(displayKeyTitle)"
    }

    private var displayKeyTitle: String {
        switch keyTitleComponent {
        case "Return":
            return "↩"
        case "Tab":
            return "⇥"
        case "Delete":
            return "⌫"
        case "Forward Delete":
            return "⌦"
        case "Left Arrow":
            return "←"
        case "Right Arrow":
            return "→"
        case "Up Arrow":
            return "↑"
        case "Down Arrow":
            return "↓"
        default:
            return keyTitleComponent.uppercased()
        }
    }

    private var keyTitleComponent: String {
        let modifierNames = Set(["Control", "Option", "Shift", "Command"])
        let parts = title.split(separator: "-").map(String.init)
        let keyParts = parts.drop(while: { modifierNames.contains($0) })
        return keyParts.joined(separator: "-")
    }
}

struct HotkeyRegistrationFailure: Equatable {
    var shortcut: HotkeyShortcut
    var status: OSStatus
}

enum HotkeyRegistrationStatus: Equatable {
    case disabled
    case registered(HotkeyShortcut)
    case failed([HotkeyRegistrationFailure])
    case eventHandlerFailed(OSStatus)

    var message: String {
        switch self {
        case .disabled:
            return "Hotkey: Disabled"
        case let .registered(shortcut):
            return "Hotkey: \(shortcut.title)"
        case let .failed(failures):
            let details = failures
                .map { "\($0.shortcut.title) (\($0.status))" }
                .joined(separator: ", ")
            return details.isEmpty ? "Hotkey unavailable" : "Hotkey unavailable: \(details)"
        case let .eventHandlerFailed(status):
            return "Hotkey handler failed: \(status)"
        }
    }
}

@MainActor
final class HotkeyManager {
    private static let signature = OSType(0x504C_5445)
    private static var current: HotkeyManager?
    private static var eventHandlerInstalled = false

    private var hotKeyRef: EventHotKeyRef?
    private let callback: () -> Void

    init(callback: @escaping () -> Void) {
        self.callback = callback
        Self.current = self
    }

    @discardableResult
    func register(shortcuts: [HotkeyShortcut] = HotkeyShortcut.defaults) -> HotkeyRegistrationStatus {
        unregister()
        guard !shortcuts.isEmpty else {
            return .disabled
        }

        let handlerStatus = installEventHandlerIfNeeded()
        guard handlerStatus == noErr else {
            return .eventHandlerFailed(handlerStatus)
        }

        var failures: [HotkeyRegistrationFailure] = []
        for (index, shortcut) in shortcuts.enumerated() {
            var registeredRef: EventHotKeyRef?
            let hotKeyID = EventHotKeyID(signature: Self.signature, id: UInt32(index + 1))
            let status = RegisterEventHotKey(
                shortcut.keyCode,
                shortcut.modifiers,
                hotKeyID,
                GetApplicationEventTarget(),
                0,
                &registeredRef
            )

            if status == noErr, let registeredRef {
                hotKeyRef = registeredRef
                return .registered(shortcut)
            }

            failures.append(HotkeyRegistrationFailure(shortcut: shortcut, status: status))
        }

        return .failed(failures)
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }
    }

    private func installEventHandlerIfNeeded() -> OSStatus {
        guard !Self.eventHandlerInstalled else { return noErr }

        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )

        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, _ in
                var hotKeyID = EventHotKeyID()
                GetEventParameter(
                    event,
                    EventParamName(kEventParamDirectObject),
                    EventParamType(typeEventHotKeyID),
                    nil,
                    MemoryLayout<EventHotKeyID>.size,
                    nil,
                    &hotKeyID
                )

                guard hotKeyID.signature == HotkeyManager.signature, hotKeyID.id >= 1 else {
                    return noErr
                }

                Task { @MainActor in
                    HotkeyManager.current?.callback()
                }
                return noErr
            },
            1,
            &eventType,
            nil,
            nil
        )

        if status == noErr {
            Self.eventHandlerInstalled = true
        }
        return status
    }
}
