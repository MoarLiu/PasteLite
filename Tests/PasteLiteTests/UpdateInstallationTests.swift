import AppKit
import CryptoKit
import Testing
@testable import PasteLite

@Suite(.serialized)
struct UpdateInstallationTests {
    @Test(arguments: [true, false])
    func installerReplacesOrRestoresOnlyItsTarget(launchSucceeds: Bool) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite Installer ' $ (fixture) \(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("Current App.app")
        let staging = directory.appendingPathComponent("Staging")
        let replacement = staging.appendingPathComponent("PasteLite.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: replacement, withIntermediateDirectories: true)
        try Data("old".utf8).write(to: current.appendingPathComponent("marker"))
        try Data("new".utf8).write(to: replacement.appendingPathComponent("marker"))
        let process = try ReleaseInstaller.launchInstaller(staged: replacement, current: current, parentPID: .max,
            opener: URL(fileURLWithPath: launchSucceeds ? "/usr/bin/true" : "/usr/bin/false"))
        let status = await wait(process)
        #expect(status == (launchSucceeds ? 0 : 1))
        #expect(try String(contentsOf: current.appendingPathComponent("marker")) == (launchSucceeds ? "new" : "old"))
        #expect(!FileManager.default.fileExists(atPath: current.path + ".previous"))
        #expect(!FileManager.default.fileExists(atPath: current.path + ".new"))
        #expect(FileManager.default.fileExists(atPath: staging.path) == !launchSucceeds)
    }

    @Test func missingStagedAppPreservesTheCurrentApp() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteInstallFailure-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("PasteLite.app")
        try FileManager.default.createDirectory(at: current, withIntermediateDirectories: true)
        try Data("original".utf8).write(to: current.appendingPathComponent("marker"))
        let process = try ReleaseInstaller.launchInstaller(staged: directory.appendingPathComponent("missing/PasteLite.app"),
            current: current, parentPID: .max, opener: URL(fileURLWithPath: "/usr/bin/true"))
        #expect(await wait(process) != 0)
        #expect(try String(contentsOf: current.appendingPathComponent("marker")) == "original")
        #expect(!FileManager.default.fileExists(atPath: current.path + ".new"))
    }

    @Test func existingBackupIsNeverOverwritten() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteInstallBackup-\(UUID())")
        defer { try? FileManager.default.removeItem(at: directory) }
        let current = directory.appendingPathComponent("PasteLite.app")
        let backup = URL(fileURLWithPath: current.path + ".previous")
        try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
        try Data("backup".utf8).write(to: backup.appendingPathComponent("marker"))
        #expect(throws: ReleaseInstaller.InstallError.self) {
            _ = try ReleaseInstaller.launchInstaller(staged: directory.appendingPathComponent("new/PasteLite.app"), current: current, parentPID: .max)
        }
        #expect(try String(contentsOf: backup.appendingPathComponent("marker")) == "backup")
    }

    @Test func packagedAppPassesTheActualUpdateStager() async throws {
        guard let fixture = ProcessInfo.processInfo.environment["PASTELITE_UPDATE_TEST_APP"] else { return }
        let app = URL(fileURLWithPath: fixture)
        let version = try #require(Bundle(url: app)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLiteStager-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let archive = directory.appendingPathComponent("update.zip")
        let zipper = Process()
        zipper.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zipper.arguments = ["-c", "-k", "--norsrc", "--noextattr", "--keepParent", app.path, archive.path]
        try zipper.run()
        #expect(await wait(zipper) == 0)
        let digest = SHA256.hash(data: try Data(contentsOf: archive)).map { String(format: "%02x", $0) }.joined()
        let checksum = Data("\(digest)  update.zip\n".utf8)
        let staged = try await ReleaseInstaller.validateAndExtract(archive: archive, checksum: checksum, version: "v" + version)
        defer { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        #expect(Bundle(url: staged)?.bundleIdentifier == "com.xia.PasteLite")
        #expect(Bundle(url: staged)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String == version)
        await #expect(throws: ReleaseInstaller.InstallError.self) {
            _ = try await ReleaseInstaller.validateAndExtract(archive: archive, checksum: Data("incorrect".utf8), version: version)
        }
        await #expect(throws: ReleaseInstaller.InstallError.self) {
            _ = try await ReleaseInstaller.validateAndExtract(archive: archive, checksum: checksum, version: "99.0.0")
        }
    }

    private func wait(_ process: Process) async -> Int32 {
        for _ in 0..<1000 {
            if !process.isRunning { return process.terminationStatus }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        process.terminate()
        Issue.record("Installer fixture did not finish within 10 seconds.")
        return -1
    }
}
