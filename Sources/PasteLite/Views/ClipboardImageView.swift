import AppKit
import SwiftUI

struct ClipboardImageView: View {
    let item: ClipboardItem
    @ObservedObject var historyStore: SQLiteHistoryStore
    let maxPixelSize: Int
    var contentMode: ContentMode = .fit
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            }
        }
        .task(id: "\(item.id):\(item.contentHash):\(maxPixelSize)") {
            image = nil
            let loaded = await historyStore.image(for: item, maxPixelSize: maxPixelSize)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
