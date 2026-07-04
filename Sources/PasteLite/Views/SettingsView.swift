import AppKit
import SwiftUI

@MainActor
struct SettingsView: View {
    @ObservedObject private var hotkeySettings = HotkeySettingsStore.shared

    private var isAccessibilityTrusted: Bool {
        AccessibilityService.isTrusted()
    }

    var body: some View {
        Form {
            Section("General") {
                settingsRow("Version", AppInfo.displayVersion)
                HotkeyRecorderView(hotkeySettings: hotkeySettings)
                settingsRow("Hotkey status", hotkeySettings.registrationMessage)
                settingsRow("History limit", "\(SQLiteHistoryStore.defaultLimit) items")
            }

            Section("Storage") {
                settingsRow("Database", PasteLiteDatabasePaths.historyDatabaseURL.path)
                    .textSelection(.enabled)
            }

            Section("Updates") {
                settingsRow("Update feed", AppInfo.updateCheckURL?.absoluteString ?? "Not configured")
                    .textSelection(.enabled)
            }

            Section("Permissions") {
                HStack(alignment: .firstTextBaseline) {
                    Text("Accessibility")
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 24)
                    if isAccessibilityTrusted {
                        Label("Granted", systemImage: "checkmark.circle")
                            .foregroundStyle(.green)
                    } else {
                        Button {
                            requestAccessibilityAccess()
                        } label: {
                            Label("Request Access", systemImage: "person.crop.circle.badge.checkmark")
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 580, height: 420)
    }

    private func settingsRow(_ title: String, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .foregroundStyle(.secondary)
            Spacer(minLength: 24)
            Text(value)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
        }
    }

    private func requestAccessibilityAccess() {
        if AccessibilityService.promptIfNeeded() {
            return
        }

        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
