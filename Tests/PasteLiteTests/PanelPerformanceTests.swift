import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct PanelPerformanceTests {
    @Test func measureWindowAndQueryRenderingWithReferenceDataset() async throws {
        guard let output = ProcessInfo.processInfo.environment["PASTELITE_PANEL_BENCHMARK_OUTPUT"] else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLitePanelBenchmark-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("History.sqlite3")
        let bootstrap = HistoryRepository(databaseURL: url, limit: 5000)
        _ = await bootstrap.loadLibrary()
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let seed = Process()
        seed.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        seed.arguments = [root.appendingPathComponent("script/seed_benchmark.py").path, url.path]
        try seed.run(); seed.waitUntilExit()
        #expect(seed.terminationStatus == 0)
        let store = SQLiteHistoryStore(databaseURL: url, limit: 5000)
        await store.loadRecentItems(limit: 5000); await store.loadLibrary()
        #expect(store.items.count == 5000 && store.libraryItems.count == 200)
        let state = AppState()
        let controller = HistoryPanelController(appState: state, historyStore: store, pasteService: PasteService(historyStore: store))
        let target = NSRunningApplication.current
        controller.toggle(target: target)
        try await resultsReady(state)
        try await Task.sleep(nanoseconds: 50_000_000)
        controller.close()
        var shows: [Double] = [], queries: [Double] = []
        for index in 0..<30 {
            let start = ProcessInfo.processInfo.systemUptime
            controller.toggle(target: target)
            try await resultsReady(state)
            await Task.yield()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
            shows.append((ProcessInfo.processInfo.systemUptime - start) * 1000)
            let queryStart = ProcessInfo.processInfo.systemUptime
            state.searchText = index.isMultiple(of: 2) ? "Entry 1" : "中文"
            try await resultsReady(state)
            await Task.yield()
            controller.window?.contentView?.layoutSubtreeIfNeeded()
            controller.window?.displayIfNeeded()
            queries.append((ProcessInfo.processInfo.systemUptime - queryStart) * 1000)
            controller.close()
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        let result: [String: Any] = ["version": AppInfo.fallbackVersion, "system": ProcessInfo.processInfo.operatingSystemVersionString,
            "history": 5000, "saved": 200, "samples": 30,
            "method": "Programmatic native panel/query update through AppKit layout and display; physical key delivery excluded.",
            "show_ms": shows, "query_ms": queries, "show_p95_ms": shows.sorted()[28], "query_p95_ms": queries.sorted()[28]]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
        print("Panel rendering p95: show \(shows.sorted()[28]) ms, query \(queries.sorted()[28]) ms")
    }
}
