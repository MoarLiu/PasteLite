import AppKit
import SwiftUI
import Combine

@MainActor
struct SettingsView: View {
    @ObservedObject private var preferences = AppPreferences.shared
    @ObservedObject private var hotkeySettings = HotkeySettingsStore.shared
    @ObservedObject private var historyStore = AppServices.shared.historyStore
    @ObservedObject private var updater = UpdateModel.shared
    @State private var trusted = AccessibilityService.isTrusted()
    @State private var storageBytes: Int64 = 0
    @State private var showClearConfirmation = false
    @State private var showClearLibraryConfirmation = false
    @State private var advanced = false
    @State private var operationMessage: String?
    private let refresh = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(SettingsPage.allCases) { page in
                    Button { preferences.settingsPage = page } label: {
                        VStack(spacing: 7) {
                            Image(systemName: page.symbol).font(.system(size: 22, weight: .regular))
                            Text(page.title).font(.system(size: 12, weight: .medium))
                        }
                        .foregroundColor(preferences.settingsPage == page ? .accentColor : .secondary)
                        .frame(width: 79, height: 65)
                        .background(preferences.settingsPage == page ? Color.primary.opacity(0.07) : .clear,
                                    in: RoundedRectangle(cornerRadius: 10))
                    }.buttonStyle(.plain)
                        .accessibilityAddTraits(preferences.settingsPage == page ? [.isSelected] : [])
                }
            }.padding(.top, 12).padding(.bottom, 14).frame(maxWidth: .infinity)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch preferences.settingsPage {
                    case .general: general
                    case .storage: storage
                    case .privacy: privacy
                    case .updates: updates
                    }
                    if let operationMessage { Text(operationMessage).font(.caption).foregroundStyle(.secondary) }
                }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 600, height: 680)
        .background(Color(nsColor: .windowBackgroundColor))
        .accentColor(preferences.accent.color)
        .onAppear { trusted = AccessibilityService.isTrusted(); refreshStorage() }
        .onReceive(refresh) { _ in trusted = AccessibilityService.isTrusted(); refreshStorage() }
        .onChange(of: preferences.settingsPage) { _ in hotkeySettings.cancelRecording() }
        .alert("Clear Clipboard History?", isPresented: $showClearConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear History", role: .destructive) {
                Task { report(await historyStore.clear()); refreshStorage() }
            }
        } message: { Text("Delete \(historyStore.items.filter { !$0.isPinned }.count) history items? Saved items and protected legacy pins will be kept. This cannot be undone.") }
        .alert("Clear Saved Library?", isPresented: $showClearLibraryConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Clear Saved Library", role: .destructive) { Task { report(await historyStore.clearLibrary()); refreshStorage() } }
        } message: { Text("Delete \(historyStore.libraryItems.count) saved items, snippets, and all custom groups? History will be kept. This cannot be undone.") }
    }

    private var general: some View {
        Group {
            group("Global Shortcut") {
                HotkeyRecorderView(hotkeySettings: hotkeySettings).padding(12)
                Divider()
                HStack(spacing: 6) {
                    Circle().fill(hotkeyStatusColor).frame(width: 6, height: 6)
                    Text(hotkeySettings.registrationMessage).font(.system(size: 11.5)).foregroundStyle(.secondary)
                    Spacer()
                }.padding(12)
            }
            if hotkeySettings.selectedShortcuts.first?.title.contains("Control-Space") == true {
                Label("macOS may use Control-Space to switch input sources. Change it in Keyboard › Keyboard Shortcuts, or choose another shortcut.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11.5)).foregroundColor(.orange)
            }
            group("History Panel") {
                row("Position on screen") {
                    Picker("Position on screen", selection: $preferences.position) {
                        Text("Center").tag(PanelPosition.center)
                        Text("Near Top").tag(PanelPosition.nearTop)
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                }
                Divider()
                row("Show preview pane", detail: "Large preview and details next to the list") {
                    Toggle("Show preview pane", isOn: $preferences.showPreview).labelsHidden().toggleStyle(.switch)
                }
            }
            group("Pasting") {
                row("When you choose an item") {
                    Picker("When you choose an item", selection: $preferences.selectionAction) {
                        Text("Paste into active app").tag(SelectionAction.paste)
                        Text("Copy to clipboard").tag(SelectionAction.copy)
                    }.labelsHidden().frame(width: 205)
                }
                Divider()
                row("Paste as plain text by default", detail: "Hold Option while pasting to do the opposite") {
                    Toggle("Paste as plain text by default", isOn: $preferences.plainText).labelsHidden().toggleStyle(.switch)
                }
            }
            group("Appearance") {
                row("Theme") {
                    Picker("Theme", selection: $preferences.theme) {
                        ForEach(AppTheme.allCases) { Text($0.title).tag($0) }
                    }.pickerStyle(.segmented).labelsHidden().frame(width: 220)
                }
                Divider()
                row("Accent color", detail: preferences.accent.rawValue.capitalized) {
                    HStack(spacing: 7) {
                        ForEach(PL.Accent.allCases) { accent in
                            Button { preferences.accent = accent } label: {
                                Circle().fill(accent.color).frame(width: 22, height: 22)
                                    .overlay(Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundColor(.white).opacity(preferences.accent == accent ? 1 : 0))
                                    .padding(3).overlay(Circle().strokeBorder(preferences.accent == accent ? accent.color : .clear, lineWidth: 2))
                            }.buttonStyle(.plain).help(accent.rawValue.capitalized).accessibilityLabel(accent.rawValue.capitalized)
                                .accessibilityAddTraits(preferences.accent == accent ? [.isSelected] : [])
                        }
                    }
                }
            }
        }
    }
    private var storage: some View {
        Group {
            group("Clipboard Storage") {
                VStack(alignment: .leading, spacing: 16) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(ByteCountFormatter.string(fromByteCount: storageBytes, countStyle: .file)).font(.system(size: 28, weight: .semibold))
                        Spacer()
                        Text("\(historyStore.items.count) history items").foregroundStyle(.secondary)
                    }
                    GeometryReader { geometry in
                        HStack(spacing: 0) {
                            ForEach(ClipboardKind.allCases) { kind in
                                let bytes = historyStore.items.filter { $0.kind == kind }.reduce(0) { $0 + $1.assetByteCount }
                                if bytes > 0 {
                                    Rectangle().fill(typeColor(kind)).frame(width: geometry.size.width * CGFloat(bytes) / CGFloat(max(1, totalAssetBytes)))
                                }
                            }
                        }.clipShape(Capsule())
                    }.frame(height: 9)
                    ForEach(ClipboardKind.allCases) { kind in
                        let items = historyStore.items.filter { $0.kind == kind }
                        if !items.isEmpty {
                            HStack {
                                Circle().fill(typeColor(kind)).frame(width: 7, height: 7)
                                Text(kind.title)
                                Text("\(items.count)").foregroundStyle(.secondary)
                                Spacer()
                                Text(ByteCountFormatter.string(fromByteCount: Int64(items.reduce(0) { $0 + $1.assetByteCount }), countStyle: .file)).foregroundStyle(.secondary)
                            }.font(.system(size: 12))
                        }
                    }
                }.padding(16)
                Divider()
                row("History limit", detail: "Saved items do not count toward this limit") {
                    Picker("History limit", selection: $preferences.historyLimit) {
                        ForEach(Array(Set([100, 250, 500, 1000, 2500, 5000, preferences.historyLimit])).sorted(), id: \.self) { Text("\($0) items").tag($0) }
                    }.labelsHidden().frame(width: 135)
                }
            }
            group("Saved Library") {
                row("Saved items", detail: "\(historyStore.libraryGroups.count) custom groups · Stored independently of history") {
                    Text("\(historyStore.libraryItems.count) items").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                row("Saved content size") {
                    Text(ByteCountFormatter.string(fromByteCount: Int64(historyStore.libraryItems.reduce(0) { $0 + $1.content.assetByteCount }), countStyle: .file))
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Divider()
                row("Clear saved library", detail: "Deletes saved items, snippets, and groups; history is kept") {
                    Button("Clear Saved…", role: .destructive) { showClearLibraryConfirmation = true }
                        .disabled(historyStore.libraryItems.isEmpty && historyStore.libraryGroups.isEmpty)
                }
            }
            group("Database") {
                VStack(alignment: .leading, spacing: 12) {
                    Text(PasteLiteDatabasePaths.historyDatabaseURL.path).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(.secondary).textSelection(.enabled)
                    Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([PasteLiteDatabasePaths.historyDatabaseURL]) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
            group("Manage History") {
                row("Clear clipboard history", detail: "Saved items and protected legacy pins will be kept") {
                    Button("Clear History…", role: .destructive) { showClearConfirmation = true }.disabled(historyStore.items.allSatisfy(\.isPinned))
                }
            }
        }
    }
    private var privacy: some View {
        Group {
            group("Accessibility") {
                HStack(spacing: 12) {
                    Image(systemName: trusted ? "checkmark.shield.fill" : "hand.raised.fill").font(.system(size: 25)).foregroundColor(trusted ? .green : .orange)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(trusted ? "Paste into any app" : "Allow direct pasting").font(.system(size: 13, weight: .semibold))
                        Text(trusted ? "Accessibility permission is granted." : "Permission is needed to paste into the active app. Copying always works.")
                            .font(.system(size: 11.5)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(trusted ? "System Settings…" : "Grant Access…") { AccessibilityService.openSettings() }
                }.padding(16)
            }
            group("Sensitive Content") {
                row("Concealed clipboard content", detail: "Marked by password managers and other apps") {
                    Picker("Concealed clipboard content", selection: $preferences.sensitivePolicy) {
                        Text("Save, hide preview").tag(SensitivePolicy.masked)
                        Text("Do not save").tag(SensitivePolicy.skip)
                    }.labelsHidden().frame(width: 165)
                }
                Divider()
                Text("Saved concealed content stays on this Mac, is hidden in previews and search, and is deleted after 24 hours. Transient content is never saved.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).padding(12)
            }
            group("Excluded Apps") {
                VStack(spacing: 0) {
                    if preferences.excludedApps.isEmpty {
                        Text("Clipboard content from excluded apps will not be recorded.").font(.system(size: 11.5)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading).padding(14)
                    }
                    ForEach(preferences.excludedApps, id: \.self) { identifier in
                        HStack {
                            if let icon = SourceAppIcon.image(for: identifier) { Image(nsImage: icon).resizable().frame(width: 20, height: 20) }
                            Text(appName(identifier)).font(.system(size: 12))
                            Spacer()
                            Button { preferences.excludedApps.removeAll { $0 == identifier } } label: { Image(systemName: "minus.circle") }.buttonStyle(.borderless).help("Remove exclusion")
                        }.padding(12)
                        Divider()
                    }
                    Button { addExcludedApp() } label: { Label("Add Application…", systemImage: "plus") }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            group("Website Previews") {
                row("Load website previews", detail: "Connects to selected links to fetch page information") {
                    Toggle("Load website previews", isOn: $preferences.fetchLinkPreviews).labelsHidden().toggleStyle(.switch)
                }
            }
            group("When PasteLite Quits") {
                row("Clear all data on quit", detail: "Deletes history, saved items, snippets, and groups") {
                    Toggle("Clear history on quit", isOn: $preferences.clearOnQuit).labelsHidden().toggleStyle(.switch)
                }
            }
        }
    }
    private var updates: some View {
        Group {
            VStack(spacing: 10) {
                AppIconView(size: 76)
                Text("PasteLite").font(.system(size: 23, weight: .semibold))
                Text(AppInfo.displayVersion).font(.system(size: 12)).foregroundStyle(.secondary)
                Text(updater.message).font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                Text("Updates download inside PasteLite. Installing an update briefly restarts the app.")
                    .font(.system(size: 11)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                if updater.isChecking || updater.isDownloading { ProgressView().controlSize(.small) }
                HStack {
                    if updater.stagedApp != nil {
                        Button("Install & Relaunch") { updater.install() }.buttonStyle(.borderedProminent)
                    } else {
                        Button("Check for Updates") { Task { await updater.check() } }.disabled(updater.isChecking || updater.isDownloading)
                        if updater.release != nil {
                            Button("Download Update") { Task { await updater.download() } }.disabled(updater.isChecking || updater.isDownloading)
                        }
                    }
                }
                if let last = updater.lastChecked { Text("Last checked \(last.formatted(date: .abbreviated, time: .shortened))").font(.system(size: 11)).foregroundStyle(.tertiary) }
            }.frame(maxWidth: .infinity).padding(.vertical, 10)
            group("Update Preferences") {
                row("Automatically check for updates") { Toggle("Automatically check for updates", isOn: $preferences.automaticUpdates).labelsHidden().toggleStyle(.switch) }
                Divider()
                row("Automatically install updates", detail: "Downloads, verifies, then relaunches PasteLite") { Toggle("Automatically install updates", isOn: $preferences.automaticDownloads).labelsHidden().toggleStyle(.switch).disabled(!preferences.automaticUpdates) }
                Divider()
                row("Update channel") {
                    Picker("Update channel", selection: $preferences.updateChannel) {
                        Text("Stable").tag(UpdateChannel.stable)
                        Text("Beta").tag(UpdateChannel.beta)
                    }.labelsHidden().frame(width: 130)
                }
            }
            DisclosureGroup("Advanced", isExpanded: $advanced) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Update feed URL").font(.system(size: 12, weight: .medium))
                    TextField(AppInfo.defaultUpdateCheckURL?.absoluteString ?? "https://", text: $preferences.updateEndpoint).textFieldStyle(.roundedBorder)
                    Text("Leave empty to use the official release feed. HTTPS is required.").font(.system(size: 11)).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }.font(.system(size: 12))
            HStack {
                Link("View Release Notes on GitHub", destination: updater.release?.html_url ?? URL(string: "https://github.com/MoarLiu/PasteLite/releases")!)
                Spacer()
                Link("Send Feedback", destination: URL(string: "https://github.com/MoarLiu/PasteLite/issues")!)
            }.font(.system(size: 12))
        }
    }
    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary).padding(.leading, 4)
            VStack(spacing: 0, content: content).frame(maxWidth: .infinity)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.65), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
        }
    }
    private func row<Control: View>(_ title: String, detail: String? = nil, @ViewBuilder control: () -> Control) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 13))
                if let detail { Text(detail).font(.system(size: 11.5)).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 10)
            control().controlSize(.small)
        }.padding(.horizontal, 12).padding(.vertical, 12).frame(minHeight: 44)
    }
    private var totalAssetBytes: Int { historyStore.items.reduce(0) { $0 + $1.assetByteCount } }
    private var hotkeyStatusColor: Color {
        switch hotkeySettings.registrationStatus {
        case .registered: return .green
        case .failed, .eventHandlerFailed: return .orange
        default: return .secondary
        }
    }
    private func typeColor(_ kind: ClipboardKind) -> Color {
        switch kind { case .text: return .gray; case .image: return .pink; case .link: return .blue; case .color: return .orange; case .file: return .cyan; case .code: return .purple; case .concealed: return .yellow }
    }
    private func refreshStorage() {
        storageBytes = ["", "-wal", "-shm"].reduce(0) { result, suffix in
            let size = try? FileManager.default.attributesOfItem(atPath: PasteLiteDatabasePaths.historyDatabaseURL.path + suffix)[.size] as? NSNumber
            return result + (size?.int64Value ?? 0)
        }
    }
    private func report(_ result: HistoryStoreMutationResult) {
        operationMessage = result.isSuccess ? "History cleared. Pinned items were kept." : { if case let .failure(message) = result { return message }; return "" }()
    }
    private func appName(_ identifier: String) -> String {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier).map { $0.deletingPathExtension().lastPathComponent } ?? identifier
    }
    private func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.prompt = "Exclude Apps"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            if let identifier = Bundle(url: url)?.bundleIdentifier, !preferences.excludedApps.contains(identifier) { preferences.excludedApps.append(identifier) }
        }
    }
}
