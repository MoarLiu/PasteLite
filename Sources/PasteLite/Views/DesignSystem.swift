import AppKit
import SwiftUI

struct KeyCap: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 5).frame(minWidth: 18, minHeight: 18)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
    }
}

struct VisualEffect: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) { view.material = material }
}

struct AppIconView: View {
    var size: CGFloat = 24
    var body: some View {
        Group {
            if let image = NSImage(named: "AppIcon") {
                Image(nsImage: image).resizable().scaledToFit()
            } else {
                Image(systemName: "doc.on.clipboard.fill").foregroundStyle(PL.Brand.pasteRed)
            }
        }.frame(width: size, height: size)
    }
}

@MainActor
enum SourceAppIcon {
    private static let cache = NSCache<NSString, NSImage>()
    static func image(for identifier: String?) -> NSImage? {
        guard let identifier else { return nil }
        if let image = cache.object(forKey: identifier as NSString) { return image }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: identifier) else { return nil }
        let image = NSWorkspace.shared.icon(forFile: url.path)
        cache.setObject(image, forKey: identifier as NSString)
        return image
    }
}

enum ClipboardTime {
    static func relative(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, now.timeIntervalSince(date))
        if seconds < 60 { return "Just now" }
        if seconds < 3600 { return "\(Int(seconds / 60))m ago" }
        if seconds < 86400 { return "\(Int(seconds / 3600))h ago" }
        return "\(Int(seconds / 86400))d ago"
    }
}

struct HighlightedText: View {
    let value: String
    var query: String = ""
    var body: some View {
        var text = Text("")
        var rest = value[...]
        if !query.isEmpty {
            while let range = rest.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) {
                text = text + Text(String(rest[..<range.lowerBound]))
                    + Text(String(rest[range])).bold().foregroundColor(.accentColor)
                rest = rest[range.upperBound...]
            }
        }
        return text + Text(String(rest))
    }
}
