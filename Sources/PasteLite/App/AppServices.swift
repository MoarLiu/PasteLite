import Foundation

@MainActor
final class AppServices {
    static let shared = AppServices()
    let historyStore: SQLiteHistoryStore
    init() {
        historyStore = SQLiteHistoryStore(limit: AppPreferences.shared.historyLimit)
    }
}
