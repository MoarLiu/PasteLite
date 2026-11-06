import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var historyStore: SQLiteHistoryStore
    @ObservedObject var preferences = AppPreferences.shared
    @ObservedObject var hotkey = HotkeySettingsStore.shared
    let onHistory: () -> Void
    let onPaste: (ClipboardItem) -> Void
    let onSettings: () -> Void
    let onUpdates: () -> Void
    let onQuit: () -> Void
    private var recentItems: [ClipboardItem] { Array(historyStore.items.sorted { $0.copiedAt > $1.copiedAt }.prefix(5)) }
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                AppIconView(size: 32)
                VStack(alignment: .leading, spacing: 3) {
                    Text("PasteLite").font(.system(size: 13, weight: .semibold))
                    HStack(spacing: 4) {
                        Circle().fill(preferences.recordingPaused ? Color.orange : .green).frame(width: 5, height: 5)
                        Text(preferences.recordingPaused ? "Recording paused" : "Recording · \(historyStore.items.count) items")
                    }.font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("Record clipboard", isOn: Binding(get: { !preferences.recordingPaused }, set: { preferences.recordingPaused = !$0 }))
                    .labelsHidden().toggleStyle(.switch).controlSize(.small)
            }.padding(12)
            Divider().padding(.horizontal, 8)
            menuButton("Open Clipboard History", symbol: "doc.on.clipboard", shortcut: hotkey.activeShortcut?.displayTitle ?? "No shortcut", action: onHistory)
                .font(.system(size: 13, weight: .medium))
            Divider().padding(.horizontal, 8)
            HStack { Text("RECENT ITEMS").font(.system(size: 10, weight: .semibold)).foregroundStyle(.tertiary); Spacer() }
                .padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 3)
            if historyStore.items.isEmpty {
                Text("Copy something to start your history.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            ForEach(Array(recentItems.enumerated()), id: \.element.id) { index, item in
                Button { onPaste(item) } label: {
                    HStack(spacing: 9) {
                        Image(systemName: item.kind.symbol).foregroundColor(item.kind == .concealed ? .orange : .secondary).frame(width: 18)
                        Text(item.kind == .concealed ? "Concealed content" : item.title).lineLimit(1)
                        Spacer(minLength: 4)
                        Text("⌘\(index + 1)").foregroundStyle(.tertiary).font(.system(size: 11))
                    }.font(.system(size: 12)).padding(.horizontal, 12).frame(height: 30).contentShape(Rectangle())
                }.buttonStyle(MenuItemStyle()).keyboardShortcut(KeyEquivalent(Character(String(index + 1))), modifiers: .command)
            }
            Divider().padding(.horizontal, 8).padding(.vertical, 5)
            menuButton("Settings…", symbol: "gearshape", shortcut: "⌘ ,", action: onSettings)
                .keyboardShortcut(",", modifiers: .command)
            menuButton("Check for Updates…", symbol: "arrow.triangle.2.circlepath", shortcut: AppInfo.version, action: onUpdates)
            Divider().padding(.horizontal, 8).padding(.vertical, 5)
            menuButton("Quit PasteLite", symbol: "power", shortcut: "⌘ Q", action: onQuit)
                .keyboardShortcut("q", modifiers: .command)
        }
        .padding(5).frame(width: 312)
        .background(VisualEffect(material: .menu))
        .accentColor(preferences.accent.color)
    }
    private func menuButton(_ title: String, symbol: String, shortcut: String? = nil, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol).frame(width: 18).foregroundStyle(.secondary)
                Text(title)
                Spacer(minLength: 3)
                if let shortcut { Text(shortcut).font(.system(size: 10.5)).foregroundStyle(.secondary) }
            }.padding(.horizontal, 11).frame(height: 30).contentShape(Rectangle())
        }.buttonStyle(MenuItemStyle()).font(.system(size: 12))
    }
}
private struct MenuItemStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        MenuItemBody(configuration: configuration)
    }
    private struct MenuItemBody: View {
        let configuration: Configuration
        @State private var hovered = false
        var body: some View {
            configuration.label.background(Color.accentColor.opacity(configuration.isPressed ? 0.2 : hovered ? 0.1 : 0), in: RoundedRectangle(cornerRadius: 6))
                .onHover { hovered = $0 }
        }
    }
}
