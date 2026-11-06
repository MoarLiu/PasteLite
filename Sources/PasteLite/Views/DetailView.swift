import AppKit
import SwiftUI
import LinkPresentation

struct DetailView: View {
    let item: ClipboardItem?
    @ObservedObject var historyStore: SQLiteHistoryStore
    var onCopy: (ClipboardItem) -> Void = { _ in }
    var onPin: (ClipboardItem) -> Void = { _ in }
    var onCopyText: (String) -> Void = { _ in }
    var savedItem: LibraryItem?
    var onEdit: () -> Void = {}
    @StateObject private var reveal = ConcealedRevealModel()
    @ObservedObject var preferences = AppPreferences.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let item {
                HStack {
                    Text(typeTitle(item)).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button { onCopy(item) } label: { Image(systemName: "doc.on.doc") }.help("Copy to clipboard")
                    if item.origin == .library {
                        Button(action: onEdit) { Image(systemName: "pencil") }.help("Edit saved item")
                    } else if item.kind != .concealed {
                        let saved = historyStore.savedSnapshot(for: item) != nil
                        Button { onPin(item) } label: {
                            Image(systemName: saved ? "star.fill" : "star")
                                .foregroundColor(saved ? .accentColor : .secondary)
                        }.help(saved ? "Remove from saved" : "Save to library")
                    }
                }.buttonStyle(.borderless).padding(.horizontal, 20).frame(height: 46)
                preview(item).frame(maxWidth: .infinity, maxHeight: .infinity)
                Divider()
                VStack(spacing: 10) {
                    if let savedItem {
                        infoRow("Name", savedItem.name)
                        if savedItem.type == .snapshot { infoRow("Original", savedItem.content.title) }
                    }
                    infoRow("Source", item.sourceAppName ?? "Unknown App", icon: SourceAppIcon.image(for: item.sourceBundleIdentifier))
                    infoRow(item.origin == .library ? "Saved" : "Copied", RelativeDateTimeFormatter().localizedString(for: item.copiedAt, relativeTo: Date()) + "  " + item.copiedAt.formatted(date: .abbreviated, time: .standard))
                    infoRow("Size", sizeDescription(item))
                    infoRow("Used", "\(item.useCount) \(item.useCount == 1 ? "time" : "times")")
                }.font(.system(size: 11.5)).padding(20)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.clipboard").font(.system(size: 34)).foregroundStyle(.tertiary)
                    Text("Select an item to preview").font(.system(size: 13)).foregroundStyle(.secondary)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
            .onChange(of: item?.id) { _ in reveal.reset() }
            .onDisappear { reveal.reset() }
    }

    @ViewBuilder private func preview(_ item: ClipboardItem) -> some View {
        switch item.kind {
        case .image:
            ClipboardImageView(item: item, historyStore: historyStore, maxPixelSize: 1600)
                .padding(20).background(Checkerboard().opacity(0.18)).padding(.horizontal, 20).padding(.bottom, 20)
        case .color:
            ColorDetail(item: item, onCopy: onCopyText).padding(.horizontal, 20).padding(.bottom, 20)
        case .code:
            VStack(spacing: 0) {
              ScrollView([.horizontal, .vertical]) {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        Text(CodeDetector.language(for: item.previewText) ?? "Code")
                        Spacer()
                        Text("\(item.previewText.components(separatedBy: "\n").count) \(item.previewText.contains("\n") ? "lines" : "line")")
                    }.font(.system(size: 11)).foregroundStyle(.secondary).padding(12)
                    Divider()
                    HStack(alignment: .top, spacing: 12) {
                        Text((1...max(1, item.previewText.components(separatedBy: "\n").count)).map(String.init).joined(separator: "\n"))
                            .foregroundStyle(.tertiary)
                        Text(item.previewText).textSelection(.enabled)
                    }.font(.system(size: 12, design: .monospaced)).lineSpacing(5).padding(14)
                }.frame(minWidth: 470, alignment: .leading)
              }
                .frame(height: min(224, CGFloat(item.previewText.components(separatedBy: "\n").count) * 20 + 54))
                .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
              Spacer(minLength: 0)
            }.padding(.horizontal, 20).padding(.bottom, 20)
        case .link:
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let url = URL(string: item.previewText), ["https", "http"].contains(url.scheme?.lowercased() ?? "") {
                        Label(url.host ?? "Website", systemImage: "globe").font(.system(size: 14, weight: .semibold))
                        if WebsitePreviewPolicy.permits(url, enabled: preferences.fetchLinkPreviews) {
                            WebsitePreview(url: url).id(url)
                        }
                        Text(item.title).font(.system(size: 17, weight: .medium)).textSelection(.enabled)
                        Text(item.previewText).font(.system(size: 12)).foregroundColor(.accentColor).textSelection(.enabled)
                        Button("Open in Browser") { NSWorkspace.shared.open(url) }
                    } else { Text(item.previewText).textSelection(.enabled) }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
                    .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12)).padding(20)
            }
        case .concealed:
            VStack(spacing: 14) {
                Image(systemName: reveal.text == nil ? "lock.shield" : "lock.open").font(.system(size: 36)).foregroundColor(PL.Functional.typeConcealed)
                Text("Concealed content").font(PL.Font.titleLarge)
                Text(reveal.text ?? "••••••••••••••••").font(.system(size: 14, design: .monospaced)).lineLimit(6)
                Text("Hidden for your privacy. Automatically deleted after 24 hours.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity)
                Button(reveal.text == nil ? "Reveal Content" : "Hide Content") {
                    if reveal.text != nil { reveal.reset() }
                    else { reveal.show(item) { try await historyStore.resolve($0) } }
                }
                if let error = reveal.errorMessage { Text(error).font(.caption).foregroundColor(.red) }
            }.padding(28).frame(maxWidth: .infinity)
        case .file:
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(item.previewText.components(separatedBy: "\n"), id: \.self) { path in
                        HStack(spacing: 12) {
                            Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().frame(width: 36, height: 36)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(URL(fileURLWithPath: path).lastPathComponent).font(.system(size: 13, weight: .medium))
                                Text(path).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
                                if !FileManager.default.fileExists(atPath: path) {
                                    Text("File unavailable").font(.system(size: 11)).foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) } label: {
                                Image(systemName: "magnifyingglass")
                            }.help("Reveal in Finder").disabled(!FileManager.default.fileExists(atPath: path))
                        }.padding(12).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
                    }
                }.padding(20)
            }
        case .text:
            ScrollView {
                Text(item.previewText.isEmpty ? item.title : item.previewText)
                    .font(.system(size: 14)).lineSpacing(7).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 20).padding(.bottom, 20)
            }
        }
    }
    private func infoRow(_ label: String, _ value: String, icon: NSImage? = nil) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            if let icon { Image(nsImage: icon).resizable().frame(width: 14, height: 14) }
            Text(value).lineLimit(1).truncationMode(.middle).help(value)
        }
    }
    private func typeTitle(_ item: ClipboardItem) -> String {
        if item.kind == .code { return "CODE · \((CodeDetector.language(for: item.previewText) ?? "Code").uppercased())" }
        return item.kind.title.uppercased()
    }
    private func sizeDescription(_ item: ClipboardItem) -> String {
        let bytes = ByteCountFormatter.string(fromByteCount: Int64(item.assetByteCount), countStyle: .file)
        return [.text, .code, .link, .color].contains(item.kind) ? "\(item.previewText.count) characters · \(bytes)" : bytes
    }
}

private struct WebsitePreview: View {
    let url: URL
    @State private var metadata: LPLinkMetadata?
    @State private var provider: LPMetadataProvider?
    var body: some View {
        Group {
            if let metadata {
                NativeLinkCard(metadata: metadata).frame(maxWidth: .infinity).frame(height: 170)
            } else { Color.clear.frame(height: 1) }
        }
        .onAppear {
            let provider = LPMetadataProvider()
            provider.timeout = 6
            self.provider = provider
            provider.startFetchingMetadata(for: url) { metadata, _ in
                let snapshot = WebsiteMetadataSnapshot(metadata)
                Task { @MainActor in self.metadata = snapshot?.take() }
            }
        }
        .onDisappear { provider?.cancel(); provider = nil }
    }
}

/// Own a separate copy until the main actor consumes it. The mutable object is
/// private: initialization precedes publication, and all subsequent access is
/// main-actor isolated. Keep item providers intact when handing off the copy.
final class WebsiteMetadataSnapshot: @unchecked Sendable {
    private var metadata: LPLinkMetadata?

    init?(_ metadata: LPLinkMetadata?) {
        guard let copy = metadata?.copy() as? LPLinkMetadata else { return nil }
        self.metadata = copy
    }

    @MainActor
    func take() -> LPLinkMetadata? {
        defer { metadata = nil }
        return metadata
    }
}

private struct NativeLinkCard: NSViewRepresentable {
    let metadata: LPLinkMetadata
    func makeNSView(context: Context) -> LPLinkView { LPLinkView(metadata: metadata) }
    func updateNSView(_ view: LPLinkView, context: Context) { view.metadata = metadata }
}

private struct Checkerboard: View {
    var body: some View {
        Canvas { context, size in
            for x in stride(from: 0, to: size.width, by: 12) {
                for y in stride(from: 0, to: size.height, by: 12) where (Int(x / 12) + Int(y / 12)) % 2 == 0 {
                    context.fill(Path(CGRect(x: x, y: y, width: 12, height: 12)), with: .color(.secondary))
                }
            }
        }
    }
}

private struct ColorDetail: View {
    let item: ClipboardItem
    let onCopy: (String) -> Void
    private var values: [(String, String)] {
        guard let c = ColorDetector.color(from: item.previewText)?.usingColorSpace(.sRGB) else { return [("HEX", item.previewText)] }
        let r = c.redComponent, g = c.greenComponent, b = c.blueComponent
        let high = max(r, g, b), low = min(r, g, b), delta = high - low, l = (high + low) / 2
        let s = delta == 0 ? 0 : delta / (1 - abs(2 * l - 1))
        var h: CGFloat = 0
        if delta != 0 {
            if high == r { h = ((g - b) / delta).truncatingRemainder(dividingBy: 6) }
            else if high == g { h = (b - r) / delta + 2 }
            else { h = (r - g) / delta + 4 }
            h *= 60
            if h < 0 { h += 360 }
        }
        let rgb = "\(Int((r * 255).rounded())), \(Int((g * 255).rounded())), \(Int((b * 255).rounded()))"
        let hsl = "\(Int(h.rounded())), \(Int((s * 100).rounded()))%, \(Int((l * 100).rounded()))%"
        let alpha = String(format: "%.3g", Double(c.alphaComponent))
        return [("HEX", item.previewText.uppercased()),
                (c.alphaComponent < 1 ? "RGBA" : "RGB", c.alphaComponent < 1 ? "rgba(\(rgb), \(alpha))" : "rgb(\(rgb))"),
                (c.alphaComponent < 1 ? "HSLA" : "HSL", c.alphaComponent < 1 ? "hsla(\(hsl), \(alpha))" : "hsl(\(hsl))"),
                ("SwiftUI", String(format: "Color(.sRGB, red: %.3f, green: %.3f, blue: %.3f, opacity: %.3f)", Double(r), Double(g), Double(b), Double(c.alphaComponent)))]
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                if let color = ColorDetector.color(from: item.previewText) {
                    RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: color)).frame(height: 68)
                }
                ForEach(values, id: \.0) { label, value in
                    Button { onCopy(value) } label: {
                        HStack(alignment: .top) {
                            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary).frame(width: 54, alignment: .leading)
                            Text(value).font(.system(size: 11.5, design: .monospaced)).lineLimit(1).truncationMode(.middle)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Image(systemName: "doc.on.doc").font(.system(size: 11)).foregroundStyle(.secondary)
                        }.padding(8).background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 7))
                    }.buttonStyle(.plain).help("Copy \(label)")
                }
            }
        }
    }
}
