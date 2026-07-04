import AppKit
import Carbon
import SwiftUI

struct HotkeyRecorderView: View {
    @ObservedObject var hotkeySettings: HotkeySettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .center, spacing: 16) {
                Text("Global hotkey")
                    .foregroundStyle(.secondary)
                    .frame(width: 120, alignment: .leading)

                VStack(alignment: .trailing, spacing: 7) {
                    recorderButton
                        .frame(width: 230, height: 44)

                    HStack(spacing: 10) {
                        Button("Reset") {
                            hotkeySettings.cancelRecording()
                            hotkeySettings.selectChoice(id: HotkeySettingsStore.defaultChoiceID)
                        }
                        .disabled(hotkeySettings.selectedChoiceID == HotkeySettingsStore.defaultChoiceID)

                        Button("Disable") {
                            hotkeySettings.cancelRecording()
                            hotkeySettings.selectChoice(id: HotkeySettingsStore.disabledChoiceID)
                        }
                        .disabled(hotkeySettings.selectedChoiceID == HotkeySettingsStore.disabledChoiceID)
                    }
                    .font(.caption)
                }
            }

            Text(helpMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
    }

    private var recorderButton: some View {
        Button {
            hotkeySettings.beginRecording()
        } label: {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(recorderBorderColor, lineWidth: 1)

                HStack(spacing: 10) {
                    Text(displayTitle)
                        .font(.system(size: 17, weight: .semibold, design: .rounded))
                        .lineLimit(1)

                    Spacer(minLength: 8)

                    Text(stateTitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 13)
            }
        }
        .buttonStyle(.plain)
        .background(recordingBridge)
    }

    @ViewBuilder
    private var recordingBridge: some View {
        if hotkeySettings.isRecording {
            HotkeyCaptureView(
                onCapture: { capturedShortcut in
                    hotkeySettings.recordShortcut(
                        keyCode: capturedShortcut.keyCode,
                        modifiers: capturedShortcut.modifiers,
                        title: capturedShortcut.title
                    )
                },
                onCancel: {
                    hotkeySettings.cancelRecording()
                }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
    }

    private var displayTitle: String {
        if hotkeySettings.isRecording {
            return "Press shortcut..."
        }

        if hotkeySettings.selectedChoiceID == HotkeySettingsStore.disabledChoiceID {
            return "Disabled"
        }

        return hotkeySettings.selectedShortcuts.first?.displayTitle ?? "Not set"
    }

    private var stateTitle: String {
        if hotkeySettings.isRecording {
            return "Recording"
        }

        switch hotkeySettings.selectedChoiceID {
        case HotkeySettingsStore.defaultChoiceID:
            return "Automatic"
        case HotkeySettingsStore.customChoiceID:
            return "Custom"
        case HotkeySettingsStore.disabledChoiceID:
            return "Off"
        default:
            return "Preset"
        }
    }

    private var recorderBorderColor: Color {
        hotkeySettings.isRecording ? Color.accentColor.opacity(0.7) : Color.accentColor.opacity(0.35)
    }

    private var helpMessage: String {
        hotkeySettings.validationMessage
            ?? "Click the shortcut field, then press a shortcut containing Command, Control, or Option. Esc cancels."
    }
}

private struct CapturedHotkey {
    var keyCode: UInt32
    var modifiers: UInt32
    var title: String
}

private struct HotkeyCaptureView: NSViewRepresentable {
    let onCapture: (CapturedHotkey) -> Void
    let onCancel: () -> Void

    func makeNSView(context: Context) -> HotkeyCaptureNSView {
        let view = HotkeyCaptureNSView()
        view.onCapture = onCapture
        view.onCancel = onCancel
        return view
    }

    func updateNSView(_ nsView: HotkeyCaptureNSView, context: Context) {
        nsView.onCapture = onCapture
        nsView.onCancel = onCancel

        DispatchQueue.main.async {
            nsView.window?.makeFirstResponder(nsView)
        }
    }
}

private final class HotkeyCaptureNSView: NSView {
    var onCapture: ((CapturedHotkey) -> Void)?
    var onCancel: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        DispatchQueue.main.async {
            self.window?.makeFirstResponder(self)
        }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == UInt16(kVK_Escape) {
            onCancel?()
            return
        }

        guard let capturedHotkey = CapturedHotkey(event: event) else {
            NSSound.beep()
            return
        }

        onCapture?(capturedHotkey)
    }
}

private extension CapturedHotkey {
    init?(event: NSEvent) {
        let modifiers = Self.carbonModifiers(from: event.modifierFlags)
        guard modifiers != 0,
              let keyTitle = Self.keyTitle(for: event) else {
            return nil
        }

        self.keyCode = UInt32(event.keyCode)
        self.modifiers = modifiers
        self.title = Self.title(modifiers: event.modifierFlags, keyTitle: keyTitle)
    }

    private static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var modifiers: UInt32 = 0
        if flags.contains(.command) { modifiers |= UInt32(cmdKey) }
        if flags.contains(.option) { modifiers |= UInt32(optionKey) }
        if flags.contains(.control) { modifiers |= UInt32(controlKey) }
        if flags.contains(.shift) { modifiers |= UInt32(shiftKey) }
        return modifiers
    }

    private static func title(modifiers flags: NSEvent.ModifierFlags, keyTitle: String) -> String {
        var parts: [String] = []
        if flags.contains(.control) { parts.append("Control") }
        if flags.contains(.option) { parts.append("Option") }
        if flags.contains(.shift) { parts.append("Shift") }
        if flags.contains(.command) { parts.append("Command") }
        parts.append(keyTitle)
        return parts.joined(separator: "-")
    }

    private static func keyTitle(for event: NSEvent) -> String? {
        if let specialTitle = specialKeyTitle(for: event.keyCode) {
            return specialTitle
        }

        let characters = event.charactersIgnoringModifiers ?? event.characters ?? ""
        let trimmedCharacters = characters.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCharacters.isEmpty,
              let character = trimmedCharacters.first else {
            return nil
        }

        return String(character).uppercased()
    }

    private static func specialKeyTitle(for keyCode: UInt16) -> String? {
        switch Int(keyCode) {
        case kVK_Space:
            return "Space"
        case kVK_Return:
            return "Return"
        case kVK_Tab:
            return "Tab"
        case kVK_Delete:
            return "Delete"
        case kVK_ForwardDelete:
            return "Forward Delete"
        case kVK_LeftArrow:
            return "Left Arrow"
        case kVK_RightArrow:
            return "Right Arrow"
        case kVK_UpArrow:
            return "Up Arrow"
        case kVK_DownArrow:
            return "Down Arrow"
        case kVK_Home:
            return "Home"
        case kVK_End:
            return "End"
        case kVK_PageUp:
            return "Page Up"
        case kVK_PageDown:
            return "Page Down"
        case kVK_F1:
            return "F1"
        case kVK_F2:
            return "F2"
        case kVK_F3:
            return "F3"
        case kVK_F4:
            return "F4"
        case kVK_F5:
            return "F5"
        case kVK_F6:
            return "F6"
        case kVK_F7:
            return "F7"
        case kVK_F8:
            return "F8"
        case kVK_F9:
            return "F9"
        case kVK_F10:
            return "F10"
        case kVK_F11:
            return "F11"
        case kVK_F12:
            return "F12"
        case kVK_F13:
            return "F13"
        case kVK_F14:
            return "F14"
        case kVK_F15:
            return "F15"
        case kVK_F16:
            return "F16"
        case kVK_F17:
            return "F17"
        case kVK_F18:
            return "F18"
        case kVK_F19:
            return "F19"
        case kVK_F20:
            return "F20"
        default:
            return nil
        }
    }
}
