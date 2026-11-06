import AppKit
import SwiftUI

struct HistoryRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    @ObservedObject var historyStore: SQLiteHistoryStore
    var accent: PL.Accent = .blue
    var shortcut: Int? = nil
    var query = ""

    var body: some View {
        HStack(spacing: 10) {
            icon.frame(width: 32, height: 32)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                HighlightedText(value: item.title, query: isSelected ? "" : query)
                    .font(.system(size: 13, weight: .medium)).lineLimit(1)
                HStack(spacing: 4) {
                    if let icon = SourceAppIcon.image(for: item.sourceBundleIdentifier) {
                        Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                    }
                    Text(item.sourceAppName ?? "Unknown App")
                    Text("·")
                    Text(ClipboardTime.relative(item.copiedAt))
                }
                .font(.system(size: 11.5))
                .foregroundColor(isSelected ? accent.foregroundColor : .secondary)
                .lineLimit(1)
            }
            Spacer(minLength: 2)
            VStack(alignment: .trailing, spacing: 3) {
                if let shortcut { Text("⌘\(shortcut)").font(.system(size: 11)) }
                if item.isPinned { Image(systemName: "pin.fill").font(.system(size: 10)) }
            }.foregroundColor(isSelected ? accent.foregroundColor : .secondary)
        }
        .foregroundColor(isSelected ? accent.foregroundColor : .primary)
        .padding(.horizontal, 8).padding(.vertical, 7)
        .frame(minHeight: 50)
        .background(isSelected ? accent.color : .clear, in: RoundedRectangle(cornerRadius: PL.Radius.row))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    @ViewBuilder private var icon: some View {
        if item.kind == .image {
            ClipboardImageView(item: item, historyStore: historyStore, maxPixelSize: 96, contentMode: .fill)
        } else if item.kind == .color, let color = ColorDetector.color(from: item.previewText) {
            Color(nsColor: color)
        } else {
            Image(systemName: item.kind.symbol)
                .font(.system(size: 17))
                .foregroundColor(isSelected ? accent.foregroundColor : tint)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(isSelected ? .white.opacity(0.2) : tint.opacity(0.1))
        }
    }
    private var tint: Color {
        switch item.kind {
        case .code: return PL.Functional.typeCode
        case .link, .file: return .accentColor
        case .concealed: return PL.Functional.typeConcealed
        default: return .secondary
        }
    }
}
