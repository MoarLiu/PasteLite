import AppKit
import SwiftUI

struct HistoryRowView: View {
    let item: ClipboardItem
    let isSelected: Bool
    @ObservedObject var historyStore: SQLiteHistoryStore

    var body: some View {
        HStack(spacing: 9) {
            itemIcon

            Text(rowTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(.primary)
                .lineLimit(1)

            Spacer(minLength: 8)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(minHeight: 38)
        .background(rowBackground)
    }

    @ViewBuilder
    private var itemIcon: some View {
        if item.kind == .image {
            ClipboardImageView(item: item, historyStore: historyStore, maxPixelSize: 64, contentMode: .fill)
                .frame(width: 22, height: 22)
                .clipShape(RoundedRectangle(cornerRadius: 2, style: .continuous))
        } else {
            kindIcon
                .font(.system(size: 16, weight: .regular))
                .foregroundColor(.primary)
                .frame(width: 22, height: 22)
        }
    }

    private var kindIcon: some View {
        Group {
            switch item.kind {
            case .text:
                Image(systemName: "text.alignleft")
            case .link:
                Image(systemName: "link")
            case .color:
                if let color = ColorDetector.color(from: item.previewText) {
                    Circle()
                        .fill(Color(nsColor: color))
                        .frame(width: 14, height: 14)
                } else {
                    Image(systemName: "paintpalette")
                }
            case .image:
                Image(systemName: "photo")
            case .file:
                Image(systemName: "doc")
            }
        }
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(isSelected ? Color.primary.opacity(0.10) : Color.clear)
    }

    private var rowTitle: String {
        let title = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? item.kind.title : title
    }

}
