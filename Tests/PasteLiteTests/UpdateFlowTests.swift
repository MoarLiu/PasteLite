import AppKit
import Testing
@testable import PasteLite

@Suite(.serialized)
@MainActor
struct UpdateFlowTests {
    @Test(arguments: [false, true])
    func manualCheckDownloadsButWaitsForInstall(automaticInstall: Bool) async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.automaticDownloads = automaticInstall
        let model = fixture.makeModel()

        await model.check()

        #expect(fixture.requests.count == 1)
        #expect(fixture.stagedVersions == ["v0.3.2"])
        #expect(model.stagedApp == fixture.app)
        #expect(!model.isChecking && !model.isDownloading)
        #expect(model.lastChecked != nil)
        #expect(fixture.installedApps.isEmpty)
        model.install()
        #expect(fixture.installedApps == [fixture.app])
    }

    @Test
    func manualCheckWorksWithAutomaticChecksDisabled() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.automaticUpdates = false
        let model = fixture.makeModel()
        await model.check()
        #expect(model.stagedApp == fixture.app)
        #expect(fixture.installedApps.isEmpty)
    }

    @Test(arguments: [false, true])
    func backgroundCheckRespectsAutomaticInstall(automaticInstall: Bool) async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.preferences.automaticDownloads = automaticInstall
        let model = fixture.makeModel()
        await model.check(trigger: .automatic)
        #expect(model.release?.tag_name == "v0.3.2")
        #expect(fixture.stagedVersions == (automaticInstall ? ["v0.3.2"] : []))
        #expect(fixture.installedApps == (automaticInstall ? [fixture.app] : []))
    }

    @Test
    func currentVersionDoesNotDownloadOrInstall() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.version = "v0.3.1"
        let model = fixture.makeModel()
        await model.check()
        #expect(model.release == nil)
        #expect(model.stagedApp == nil)
        #expect(fixture.stagedVersions.isEmpty)
        #expect(fixture.installedApps.isEmpty)
        #expect(model.message.contains("You’re up to date"))
    }

    @Test
    func failedDownloadCanBeRetriedInsideTheApp() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.stageError = UpdateFlowFixture.Failure()
        let model = fixture.makeModel()
        await model.check()
        #expect(model.stagedApp == nil)
        #expect(model.release?.tag_name == "v0.3.2")
        #expect(model.message.contains("Could not prepare the update"))
        #expect(!model.isChecking && !model.isDownloading)
        fixture.stageError = nil
        await model.download()
        #expect(model.stagedApp == fixture.app)
        #expect(fixture.stagedVersions == ["v0.3.2", "v0.3.2"])
        #expect(fixture.installedApps.isEmpty)
    }

    @Test
    func failedCheckDoesNotPrepareAnUpdate() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.statusCode = 503
        let model = fixture.makeModel()
        await model.check()
        #expect(model.stagedApp == nil)
        #expect(model.release == nil)
        #expect(model.message.contains("Could not check for updates"))
        #expect(fixture.stagedVersions.isEmpty)
        #expect(fixture.installedApps.isEmpty)
        #expect(!model.isChecking && !model.isDownloading)
    }

    @Test
    func readyUpdateSurvivesAnotherCheck() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        let model = fixture.makeModel()
        await model.check()
        await model.check(trigger: .automatic)
        await model.download()
        #expect(model.stagedApp == fixture.app)
        #expect(FileManager.default.fileExists(atPath: fixture.app.path))
        #expect(fixture.requests.count == 1)
        #expect(fixture.stagedVersions.count == 1)
        #expect(fixture.installedApps.isEmpty)
    }

    @Test
    func failedInstallKeepsTheVerifiedUpdateAvailable() async throws {
        let fixture = try UpdateFlowFixture()
        defer { fixture.cleanUp() }
        fixture.installError = UpdateFlowFixture.Failure()
        let model = fixture.makeModel()
        await model.check()
        model.install()
        #expect(model.stagedApp == fixture.app)
        #expect(model.message.contains("Could not install the update"))
        fixture.installError = nil
        model.install()
        #expect(fixture.installedApps == [fixture.app, fixture.app])
    }
}

@MainActor
private final class UpdateFlowFixture {
    struct Failure: LocalizedError {
        var errorDescription: String? { "Update fixture failure." }
    }

    let suite = "PasteLite.UpdateFlow.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-UpdateFlow-\(UUID())")
    let defaults: UserDefaults
    let preferences: AppPreferences
    var app: URL { directory.appendingPathComponent("PasteLite.app") }
    var version = "v0.3.2"
    var statusCode = 200
    var stageError: Error?
    var installError: Error?
    var requests: [URLRequest] = []
    var stagedVersions: [String] = []
    var installedApps: [URL] = []

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
        preferences = AppPreferences(defaults: defaults)
        preferences.automaticUpdates = true
        preferences.automaticDownloads = false
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
    }

    func makeModel() -> UpdateModel {
        UpdateModel(preferences: preferences, currentVersion: "0.3.1", fetchRelease: { [self] request in
            requests.append(request)
            let requestURL = try #require(request.url)
            let response = try #require(HTTPURLResponse(url: requestURL, statusCode: statusCode,
                                                      httpVersion: nil, headerFields: nil))
            let data = try JSONSerialization.data(withJSONObject: [
                "tag_name": version, "html_url": "https://github.com/MoarLiu/PasteLite/releases/tag/\(version)",
                "draft": false, "prerelease": false, "assets": []
            ])
            return (data, response)
        }, stageRelease: { [self] release in
            stagedVersions.append(release.tag_name)
            if let stageError { throw stageError }
            return app
        }, installRelease: { [self] app in
            installedApps.append(app)
            if let installError { throw installError }
        })
    }

    func cleanUp() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: directory)
    }
}
