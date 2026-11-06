#if DEBUG
import AppKit
import Foundation

@MainActor
enum PreviewFixtures {
    static func seed(_ store: SQLiteHistoryStore) async {
        await store.loadRecentItems()
        guard store.items.isEmpty else { return }
        let groupID = await store.createGroup("Development").itemID
        let examples: [(ClipboardKind, String, String, String)] = [
            (.code, "ssh deploy@example.local", "ssh deploy@example.local", "Terminal"),
            (.color, "#FF5A4E", "#FF5A4E", "Figma"),
            (.text, "A little less searching. A little more making.", "A little less searching.\nA little more making.\n\nKeep everything you copy close at hand. Find it, preview it, and paste it with one keystroke.", "Notes"),
            (.link, "PasteLite · Clipboard history for macOS", "https://github.com/MoarLiu/PasteLite", "Safari"),
            (.code, "A small SwiftUI view", "import SwiftUI\n\nstruct WelcomeView: View {\n    var body: some View {\n        Text(\"Hello, PasteLite\")\n            .font(.title)\n    }\n}", "Xcode"),
            (.file, "PasteLite-Design-Kit", "/Users/Shared/PasteLite-Design-Kit", "Finder"),
            (.concealed, "Concealed content", "", "Password Manager")
        ]
        for (index, value) in examples.enumerated() {
            var item = ClipboardItem(title: value.1, kind: value.0, sourceAppName: value.3,
                sourceBundleIdentifier: value.3 == "Safari" ? "com.apple.Safari" : value.3 == "Notes" ? "com.apple.Notes" : value.3 == "Finder" ? "com.apple.finder" : nil,
                copiedAt: Date().addingTimeInterval(-Double(index + 1) * 120),
                contentHash: "preview-\(index)", previewText: value.2,
                assets: [.init(index: 0, pasteboardType: .string, data: Data((value.0 == .concealed ? "Demo secret, for UI testing only" : value.2).utf8))])
            item.useCount = index == 0 ? 37 : index
            _ = await store.add(item)
            if index < 2 {
                let draft = LibraryDraft(type: .snapshot, name: index == 0 ? "Deploy to staging" : "Brand color",
                                         groupID: index == 0 ? groupID : nil, body: "", kind: item.kind,
                                         source: item, generation: store.libraryGeneration)
                _ = await store.saveLibrary(draft)
            }
        }
        if let image = NSImage(named: "AppIcon"), let tiff = image.tiffRepresentation {
            let item = ClipboardItem(title: "Image 1024 × 1024", kind: .image, sourceAppName: "Preview",
                contentHash: "preview-image", previewText: "", assets: [.init(index: 0, pasteboardType: .tiff, data: tiff)])
            _ = await store.add(item)
        }
        _ = await store.saveLibrary(LibraryDraft(type: .snippet, name: "需求整理", groupID: groupID,
                                                body: "请整理以下需求：\n\n1. 用户场景\n2. 功能范围\n3. 验收标准\n",
                                                kind: .text, generation: store.libraryGeneration))
    }
}
#endif
