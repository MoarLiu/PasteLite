import AppKit
import CryptoKit
import Foundation

struct ReleaseAsset: Decodable {
    var name: String
    var browser_download_url: URL
}

struct InstallableRelease: Decodable {
    var tag_name: String
    var html_url: URL
    var prerelease: Bool?
    var draft: Bool?
    var assets: [ReleaseAsset]?
}

enum UpdateCheckTrigger: Equatable {
    case manual
    case automatic
}

@MainActor
final class UpdateModel: ObservableObject {
    static let shared = UpdateModel()
    @Published private(set) var isChecking = false
    @Published private(set) var isDownloading = false
    @Published private(set) var message = "Check for a new version of PasteLite."
    @Published private(set) var release: InstallableRelease?
    @Published private(set) var stagedApp: URL?
    @Published private(set) var lastChecked: Date?
    private let preferences: AppPreferences
    private let currentVersion: String
    private let fetchRelease: (URLRequest) async throws -> (Data, URLResponse)
    private let stageRelease: (InstallableRelease) async throws -> URL
    private let installRelease: @MainActor (URL) throws -> Void

    init(preferences: AppPreferences? = nil, currentVersion: String = AppInfo.version,
         fetchRelease: @escaping (URLRequest) async throws -> (Data, URLResponse) = { try await URLSession.shared.data(for: $0) },
         stageRelease: @escaping (InstallableRelease) async throws -> URL = { try await ReleaseInstaller.stage($0) },
         installRelease: @escaping @MainActor (URL) throws -> Void = {
             try ReleaseInstaller.install($0)
             NSApp.terminate(nil)
         }) {
        self.preferences = preferences ?? .shared
        self.currentVersion = currentVersion
        self.fetchRelease = fetchRelease
        self.stageRelease = stageRelease
        self.installRelease = installRelease
    }

    func check(trigger: UpdateCheckTrigger = .manual) async {
        guard !isChecking, !isDownloading, stagedApp == nil else { return }
        isChecking = true
        release = nil
        defer { isChecking = false; lastChecked = Date() }
        message = "Checking for updates…"
        do {
            let custom = preferences.updateEndpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            var endpoint = custom.isEmpty ? AppInfo.updateCheckURL : URL(string: custom)
            if preferences.updateChannel == .beta, custom.isEmpty {
                endpoint = URL(string: "https://api.github.com/repos/MoarLiu/PasteLite/releases")
            }
            guard let endpoint, endpoint.scheme == "https" else { throw UpdateCheckError.invalidResponse }
            var request = URLRequest(url: endpoint, timeoutInterval: 30)
            request.setValue("PasteLite/\(currentVersion)", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await fetchRelease(request)
            guard let response = response as? HTTPURLResponse, response.statusCode == 200 else { throw UpdateCheckError.invalidResponse }
            let decoder = JSONDecoder()
            let candidates: [InstallableRelease]
            if let list = try? decoder.decode([InstallableRelease].self, from: data) { candidates = list }
            else { candidates = [try decoder.decode(InstallableRelease.self, from: data)] }
            let latest = candidates.filter { $0.draft != true && (preferences.updateChannel == .beta || $0.prerelease != true) }
                .sorted { UpdateChecker.compareVersions($0.tag_name, $1.tag_name) == .orderedDescending }.first
            guard let latest else { throw UpdateCheckError.invalidReleaseData }
            if UpdateChecker.compareVersions(latest.tag_name, currentVersion) == .orderedDescending {
                release = latest
                stagedApp = nil
                message = "PasteLite \(latest.tag_name) is available."
                if trigger == .manual || (preferences.automaticUpdates && preferences.automaticDownloads) {
                    await download()
                    if trigger == .automatic, stagedApp != nil { install() }
                }
            } else {
                release = nil
                message = "You’re up to date. PasteLite \(currentVersion) is the latest version."
            }
        } catch { message = "Could not check for updates: \(error.localizedDescription)" }
    }

    func download() async {
        guard !isDownloading, stagedApp == nil, let release else { return }
        isDownloading = true
        defer { isDownloading = false }
        message = "Downloading and verifying update…"
        do {
            stagedApp = try await stageRelease(release)
            message = "Update verified. Choose Install & Relaunch to finish updating."
        } catch { message = "Could not prepare the update: \(error.localizedDescription)" }
    }

    func install() {
        guard let stagedApp else { return }
        do {
            try installRelease(stagedApp)
        } catch { message = "Could not install the update: \(error.localizedDescription)" }
    }
}

enum ReleaseInstaller {
    @MainActor private static var pendingProcess: Process?
    @MainActor static func cancelPendingInstall() {
        if pendingProcess?.isRunning == true { pendingProcess?.terminate() }
        pendingProcess = nil
    }
    enum InstallError: LocalizedError {
        case invalid(String)
        var errorDescription: String? { if case let .invalid(message) = self { return message }; return nil }
    }
    static func stage(_ release: InstallableRelease) async throws -> URL {
        let arch = "arm64"
        guard let zip = release.assets?.first(where: { $0.name.hasSuffix("-macos-\(arch).app.zip") }),
              let checksum = release.assets?.first(where: { $0.name == zip.name + ".sha256" }),
              [zip, checksum].allSatisfy({
                  $0.browser_download_url.scheme == "https" && $0.browser_download_url.host == "github.com" &&
                  $0.browser_download_url.path.hasPrefix("/MoarLiu/PasteLite/releases/download/")
              }) else {
            throw InstallError.invalid("This release has no verified \(arch) app archive. Please check for updates again later.")
        }
        let (archive, response) = try await URLSession.shared.download(from: zip.browser_download_url)
        defer { try? FileManager.default.removeItem(at: archive) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateCheckError.invalidResponse }
        let (checksumData, checksumResponse) = try await URLSession.shared.data(from: checksum.browser_download_url)
        guard (checksumResponse as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateCheckError.invalidResponse }
        return try await validateAndExtract(archive: archive, checksum: checksumData, version: release.tag_name)
    }

    static func validateAndExtract(archive: URL, checksum: Data, version: String) async throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("PasteLite-Update-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            let data = try Data(contentsOf: archive, options: .mappedIfSafe)
            let actual = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            let expected = String(decoding: checksum, as: UTF8.self).split(whereSeparator: \.isWhitespace).first.map(String.init)
            guard expected?.lowercased() == actual else { throw InstallError.invalid("Update checksum does not match.") }
            let zipURL = directory.appendingPathComponent("update.zip")
            try FileManager.default.copyItem(at: archive, to: zipURL)
            let entries = try await run("/usr/bin/unzip", ["-Z1", zipURL.path])
            let details = try await run("/usr/bin/unzip", ["-Z", "-l", zipURL.path])
            try validateArchiveEntries(entries, details: details)
            _ = try await run("/usr/bin/ditto", ["-xk", zipURL.path, directory.path])
            let app = directory.appendingPathComponent("PasteLite.app")
            let bundle = Bundle(url: app)
            guard bundle?.bundleIdentifier == "com.xia.PasteLite",
                  bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ==
                    normalizedVersion(version) else {
                throw InstallError.invalid("The downloaded app identity does not match the release.")
            }
            if let minimum = bundle?.object(forInfoDictionaryKey: "LSMinimumSystemVersion") as? String {
                let parts = minimum.split(separator: ".", omittingEmptySubsequences: false)
                let components = parts.compactMap { Int($0) }
                guard (1...3).contains(components.count), components.count == parts.count,
                      components.allSatisfy({ $0 >= 0 }),
                      ProcessInfo.processInfo.isOperatingSystemAtLeast(OperatingSystemVersion(
                        majorVersion: components[0], minorVersion: components.count > 1 ? components[1] : 0,
                        patchVersion: components.count > 2 ? components[2] : 0)) else {
                    throw InstallError.invalid("This update requires macOS \(minimum) or later.")
                }
            }
            _ = try await run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path])
            let architectures = try await run("/usr/bin/lipo", ["-archs", app.appendingPathComponent("Contents/MacOS/PasteLite").path])
            guard architectures.split(whereSeparator: \.isWhitespace).contains(Substring(architecture)) else {
                throw InstallError.invalid("The update is for a different Mac architecture.")
            }
            return app
        } catch {
            try? FileManager.default.removeItem(at: directory)
            throw error
        }
    }

    @MainActor static func install(_ staged: URL) throws {
        pendingProcess = try launchInstaller(staged: staged, current: Bundle.main.bundleURL,
                                            parentPID: ProcessInfo.processInfo.processIdentifier)
    }

    static func launchInstaller(staged: URL, current: URL, parentPID: Int32,
                                opener: URL = URL(fileURLWithPath: "/usr/bin/open")) throws -> Process {
        guard current.pathExtension == "app", FileManager.default.isWritableFile(atPath: current.deletingLastPathComponent().path) else {
            throw InstallError.invalid("Move PasteLite to a writable Applications folder, then try again.")
        }
        // Arguments are passed separately. Paths never become shell source.
        let script = """
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        if ! /usr/bin/ditto "$2" "$3.new"; then
          /bin/rm -rf "$3.new"
          "$5" "$3"
          exit 1
        fi
        if ! /bin/mv "$3" "$3.previous"; then
          /bin/rm -rf "$3.new"
          "$5" "$3"
          exit 1
        fi
        if /bin/mv "$3.new" "$3"; then
          if "$5" "$3"; then
            /bin/rm -rf "$3.previous" "$4"
          else
            /bin/rm -rf "$3"
            /bin/mv "$3.previous" "$3"
            "$5" "$3"
          fi
        else
          /bin/mv "$3.previous" "$3"
          "$5" "$3"
        fi
        """
        guard !FileManager.default.fileExists(atPath: current.path + ".previous"),
              !FileManager.default.fileExists(atPath: current.path + ".new") else {
            throw InstallError.invalid("A previous update needs attention. Remove the adjacent .new or .previous copy after checking it.")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "pastelite-update", String(parentPID),
                             staged.path, current.path, staged.deletingLastPathComponent().path, opener.path]
        try process.run()
        return process
    }

    static var architecture: String {
        return "arm64"
    }

    private static func normalizedVersion(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.first == "v" || trimmed.first == "V" ? String(trimmed.dropFirst()) : trimmed
    }

    static func validateArchiveEntries(_ entries: String, details: String) throws {
        let paths = entries.split(separator: "\n")
        guard !paths.isEmpty,
              !details.split(separator: "\n").contains(where: { $0.hasPrefix("l") }),
              paths.allSatisfy({
                  ($0.hasPrefix("PasteLite.app/") || $0 == "PasteLite.app") &&
                  !$0.hasPrefix("/") && !$0.split(separator: "/").contains("..")
              }) else {
            throw InstallError.invalid("The update archive contains an invalid path.")
        }
    }

    private static func run(_ executable: String, _ arguments: [String]) async throws -> String {
        try await Task.detached {
            let process = Process(), output = Pipe()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw InstallError.invalid("Update validation failed.") }
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
