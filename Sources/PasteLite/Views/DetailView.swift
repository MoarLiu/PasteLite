import AppKit
import SwiftUI

struct DetailView: View {
    let item: ClipboardItem?
    @ObservedObject var historyStore: SQLiteHistoryStore

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            information
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var preview: some View {
        if let item {
            switch item.kind {
            case .color:
                ColorPreview(item: item)
            case .image:
                ImagePreview(item: item, historyStore: historyStore)
            case .file, .link, .text:
                TextPreview(item: item)
            }
        } else {
            EmptyDetailView()
        }
    }

    private var information: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Information")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 0) {
                infoRow("Source", item?.sourceAppName ?? "-")
                infoRow("Content type", item?.kind.title ?? "-")
                if let item,
                   shouldShowTextMetrics(for: item) {
                    infoRow("Characters", "\(textValue(for: item).count)")
                    infoRow("Words", "\(wordCount(for: item))")
                }
                infoRow("Created", item?.copiedAt.formatted(date: .abbreviated, time: .standard) ?? "-")
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(spacing: 0) {
            HStack {
                Text(label)
                    .foregroundStyle(.secondary)
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(value)
                    .font(.system(size: 11))
                    .lineLimit(1)
            }
            .padding(.vertical, 6)

            Divider()
        }
    }

    private func shouldShowTextMetrics(for item: ClipboardItem) -> Bool {
        item.kind == .text || item.kind == .link || item.kind == .color
    }

    private func textValue(for item: ClipboardItem) -> String {
        item.previewText.isEmpty ? item.title : item.previewText
    }

    private func wordCount(for item: ClipboardItem) -> Int {
        textValue(for: item)
            .split { $0.isWhitespace || $0.isNewline }
            .count
    }
}

private struct TextPreview: View {
    let item: ClipboardItem

    var body: some View {
        ScrollView {
            Text(item.previewText.isEmpty ? item.title : item.previewText)
                .font(.system(size: 13))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.vertical, 16)
        }
    }
}

private struct ColorPreview: View {
    let item: ClipboardItem

    var body: some View {
        VStack(spacing: 18) {
            if let color = ColorDetector.color(from: item.previewText) {
                Circle()
                    .fill(Color(nsColor: color))
                    .frame(width: 104, height: 104)
                    .shadow(radius: 12)
            }
            Text(item.previewText)
                .font(.system(size: 16, weight: .medium, design: .monospaced))
        }
    }
}

private struct ImagePreview: View {
    let item: ClipboardItem
    @ObservedObject var historyStore: SQLiteHistoryStore

    var body: some View {
        ClipboardImageView(item: item, historyStore: historyStore, maxPixelSize: 1600)
            .padding(24)
    }
}

private struct EmptyDetailView: View {
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "clipboard")
                .font(.system(size: 28))
            Text("No Selection")
                .font(.system(size: 13, weight: .semibold))
        }
        .foregroundStyle(.secondary)
    }
}
