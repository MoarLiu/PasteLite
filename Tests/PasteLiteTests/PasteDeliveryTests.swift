import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct PasteDeliveryTests {
    enum Interruption: CaseIterable, Sendable {
        case activationFailure, activationTimeout, changedFocus, changedClipboard, revokedPermission, targetExited
    }

    @Test
    func pasteWaitsForTargetBeforeSendingOneCommand() async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        let store = DeliveryStore()
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        var preparationCount = 0
        let result = await service.paste(store.item, into: .current) {
            preparationCount += 1
            #expect(pasteboard.string(forType: .string) == "history item")
        }
        #expect(result == .success)
        #expect(preparationCount == 1)
        #expect(environment.activationCount == 1)
        #expect(environment.waitCount == 2)
        #expect(environment.sentCount == 1)
    }

    @Test(arguments: Interruption.allCases)
    func interruptionsNeverPostPaste(interruption: Interruption) async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        switch interruption {
        case .activationFailure:
            environment.activationSucceeds = false
        case .activationTimeout:
            environment.targetIsActive = false
        case .changedFocus:
            environment.onWait = { environment.frontmostProcessIdentifier = NSRunningApplication.current.processIdentifier + 1 }
        case .changedClipboard:
            environment.onWait = {
                pasteboard.clearContents()
                _ = pasteboard.setString("new content", forType: .string)
            }
        case .revokedPermission:
            environment.onWait = { environment.isAccessibilityTrusted = false }
        case .targetExited:
            environment.onWait = { environment.targetIsTerminated = true }
        }
        defer { environment.onWait = nil }
        let store = DeliveryStore()
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        let result = await service.paste(store.item, into: .current)
        #expect(!result.isSuccess)
        #expect(environment.sentCount == 0)
        #expect(environment.waitCount <= 51)
        if interruption == .changedClipboard {
            #expect(pasteboard.string(forType: .string) == "new content")
        }
    }

    @Test
    func missingPermissionLeavesClipboardUntouched() async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        environment.isAccessibilityTrusted = false
        let store = DeliveryStore()
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        let result = await service.paste(store.item, into: .current)
        #expect(!result.isSuccess)
        #expect(environment.activationCount == 0)
        #expect(environment.sentCount == 0)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test
    func cancellingWhileWaitingNeverPostsPaste() async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        let store = DeliveryStore()
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        var task: Task<PasteServiceResult, Never>?
        environment.onWait = { task?.cancel() }
        task = Task { await service.paste(store.item, into: .current) }
        let result = await task?.value
        #expect(result == .failure("Paste cancelled."))
        #expect(environment.sentCount == 0)
        environment.onWait = nil
    }

    @Test
    func focusChangingDuringAttachmentLoadDoesNotWriteOrActivate() async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        let store = DeliveryStore()
        store.onResolve = { environment.frontmostProcessIdentifier = NSRunningApplication.current.processIdentifier + 1 }
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        let result = await service.paste(store.item.metadataOnly, into: .current)
        #expect(!result.isSuccess)
        #expect(environment.activationCount == 0)
        #expect(environment.sentCount == 0)
        #expect(pasteboard.string(forType: .string) == "original")
    }

    @Test
    func keystrokeDeliveryFailureIsReported() async {
        let pasteboard = board()
        defer { pasteboard.releaseGlobally() }
        let environment = ControlledPasteEnvironment()
        environment.deliverySucceeds = false
        let store = DeliveryStore()
        let service = PasteService(historyStore: store, pasteboard: pasteboard, environment: environment)
        let result = await service.paste(store.item, into: .current)
        #expect(!result.isSuccess)
        #expect(environment.sentCount == 1)
    }

    private func board() -> NSPasteboard {
        let pasteboard = NSPasteboard(name: NSPasteboard.Name("PasteDeliveryTests.\(UUID().uuidString)"))
        pasteboard.clearContents()
        _ = pasteboard.setString("original", forType: .string)
        return pasteboard
    }
}

@MainActor
private final class ControlledPasteEnvironment: PasteEnvironment {
    let ownProcessIdentifier: pid_t = -1
    var frontmostProcessIdentifier: pid_t? = NSRunningApplication.current.processIdentifier
    var uptime: TimeInterval = 0
    var isAccessibilityTrusted = true
    var targetIsTerminated = false
    var targetIsActive = true
    var activationSucceeds = true
    var deliverySucceeds = true
    var onWait: (() -> Void)?
    private(set) var activationCount = 0
    private(set) var waitCount = 0
    private(set) var sentCount = 0

    func requestAccessibility() -> Bool { isAccessibilityTrusted }
    func isTerminated(_ app: NSRunningApplication) -> Bool { targetIsTerminated }
    func isActive(_ app: NSRunningApplication) -> Bool { targetIsActive }
    func activate(_ app: NSRunningApplication) -> Bool {
        activationCount += 1
        return activationSucceeds
    }
    func waitForActivation() async throws {
        waitCount += 1
        uptime += 0.02
        onWait?()
    }
    func sendPaste(to app: NSRunningApplication) -> Bool {
        sentCount += 1
        return deliverySucceeds
    }
}

@MainActor
private final class DeliveryStore: HistoryStore {
    @Published var items: [ClipboardItem] = []
    let item = ClipboardItem(title: "history item", kind: .text, contentHash: "delivery-test", previewText: "history item",
        assets: [ClipboardAsset(index: 0, pasteboardType: .string, data: Data("history item".utf8))])
    var onResolve: (() -> Void)?

    func loadRecentItems(limit: Int) async {}
    func add(_ item: ClipboardItem) async -> HistoryStoreMutationResult { .success }
    func remove(id: UUID) async -> HistoryStoreMutationResult { .success }
    func clear() async -> HistoryStoreMutationResult { .success }
    func resolve(_ item: ClipboardItem) async throws -> ClipboardItem {
        onResolve?()
        return self.item
    }
}
