import AppKit
import Foundation

@MainActor
final class ConcealedRevealModel: ObservableObject {
    @Published private(set) var text: String?
    @Published private(set) var errorMessage: String?
    private var token = UUID()
    private(set) var loadTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?

    func reset() {
        token = UUID()
        loadTask?.cancel()
        loadTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        text = nil
        errorMessage = nil
    }

    func show(_ item: ClipboardItem, resolve: @escaping @MainActor (ClipboardItem) async throws -> ClipboardItem) {
        reset()
        let request = token
        loadTask = Task { [weak self] in
            do {
                let loaded = try await resolve(item)
                try Task.checkCancellation()
                guard let self, self.token == request, !loaded.isExpired else { return }
                self.text = loaded.assets.first(where: { $0.pasteboardType == .string })
                    .flatMap { String(data: $0.data, encoding: .utf8) } ?? "No text representation"
                let remaining = max(0, loaded.copiedAt.addingTimeInterval(86400).timeIntervalSinceNow)
                self.expiryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: UInt64(remaining * 1_000_000_000)) }
                    catch { return }
                    guard let self, self.token == request else { return }
                    self.reset()
                }
            } catch {
                guard !Task.isCancelled, let self, self.token == request else { return }
                self.errorMessage = error.localizedDescription
            }
        }
    }
}

enum WebsitePreviewPolicy {
    static func permits(_ url: URL, enabled: Bool) -> Bool {
        enabled && ["https", "http"].contains(url.scheme?.lowercased() ?? "") &&
            url.host != nil && url.user == nil && url.password == nil
    }
}
