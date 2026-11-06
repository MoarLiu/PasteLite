import AppKit
import SwiftUI
import Testing
@testable import PasteLite

#if DEBUG
@Suite(.serialized)
@MainActor
struct DesignSnapshotTests {
    @Test func exportNativeDesignPreviews() async throws {
        guard let output = ProcessInfo.processInfo.environment["PASTELITE_PREVIEW_OUTPUT"] else { return }
        #expect(ProcessInfo.processInfo.environment["PASTELITE_DATA_DIRECTORY"] != nil)
        #expect(ProcessInfo.processInfo.environment["PASTELITE_PREFERENCES_SUITE"] != nil)
        let outputURL = URL(fileURLWithPath: output)
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let sourceRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let icon = NSImage(contentsOf: sourceRoot.appendingPathComponent("Resources/AppIcon.icns"))
        icon?.setName("AppIcon")
        let store = AppServices.shared.historyStore
        await PreviewFixtures.seed(store)
        let state = AppState()
        state.pasteTargetName = "TextEdit"
        let prefs = AppPreferences.shared
        let oldTheme = prefs.theme, oldPreview = prefs.showPreview, oldPage = prefs.settingsPage
        defer { prefs.theme = oldTheme; prefs.showPreview = oldPreview; prefs.settingsPage = oldPage; _ = icon }
        let panel = HistoryPanelView(appState: state, historyStore: store, onCopy: { _ in }, onPaste: { _ in },
            onRemove: { _ in }, onClear: {}, onDismiss: {})
        for theme in [AppTheme.light, .dark] {
            prefs.theme = theme
            prefs.showPreview = true
            state.selectedFilter = .all
            state.searchText = ""
            state.normalizeSelection(in: state.filteredItems(in: store.items))
            try await render(panel, name: "history-\(theme.rawValue)", size: NSSize(width: 880, height: 560), output: outputURL)
            state.mode = .library
            state.refreshResults(history: store.items, library: store.libraryItems, groups: store.libraryGroups)
            try await resultsReady(state)
            try await render(panel, name: "library-\(theme.rawValue)", size: NSSize(width: 880, height: 560), output: outputURL)
            prefs.showPreview = false
            try await render(panel, name: "library-compact-\(theme.rawValue)", size: NSSize(width: 520, height: 560), output: outputURL)
            prefs.showPreview = true
            let editor = LibraryDraft(type: .snippet, name: "需求整理", body: "请整理以下需求：\n\n1. 用户场景\n2. 功能范围\n3. 验收标准", kind: .text, generation: store.libraryGeneration)
            let editorState = AppState()
            editorState.beginEditing(editor)
            try await render(SnippetEditorView(appState: editorState, store: store, initial: editor),
                             name: "snippet-editor-\(theme.rawValue)", size: NSSize(width: 480, height: 460), output: outputURL)
            state.mode = .history
            try await resultsReady(state)
            for page in SettingsPage.allCases {
                prefs.settingsPage = page
                try await render(SettingsView(), name: "settings-\(page.rawValue)-\(theme.rawValue)", size: NSSize(width: 600, height: 680), output: outputURL)
            }
            try await render(MenuBarView(historyStore: store, onHistory: {}, onPaste: { _ in }, onSettings: {}, onUpdates: {}, onQuit: {}),
                name: "menu-\(theme.rawValue)", size: NSSize(width: 312, height: 426), output: outputURL)
        }
        prefs.theme = .light
        for kind in [ClipboardKind.text, .color, .image, .file, .link, .code, .concealed] {
            state.selectedItemID = store.items.first(where: { $0.kind == kind })?.id
            try await render(panel, name: "preview-\(kind.rawValue)", size: NSSize(width: 880, height: 560), output: outputURL)
        }
        prefs.showPreview = false
        try await render(panel, name: "history-compact", size: NSSize(width: 520, height: 560), output: outputURL)
        prefs.showPreview = true
        state.searchText = "no-match-for-this-query"
        try await render(panel, name: "search-empty", size: NSSize(width: 880, height: 560), output: outputURL)
        state.searchText = "clipboard"
        try await render(panel, name: "search-results", size: NSSize(width: 880, height: 560), output: outputURL)
    }

    private func render<V: View>(_ view: V, name: String, size: NSSize, output: URL) async throws {
        let host = NSHostingView(rootView: view.environment(\.controlActiveState, .key))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        defer { window.orderOut(nil); window.contentView = nil }
        host.frame = NSRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        try await Task.sleep(nanoseconds: 150_000_000)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        #expect(data.count > 4096)
        try data.write(to: output.appendingPathComponent(name + ".png"))
    }
}
#endif
