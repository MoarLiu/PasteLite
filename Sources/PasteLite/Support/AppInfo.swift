import Foundation

enum AppInfo {
    static let fallbackVersion = "0.1.0"
    static let fallbackBuild = "1"

    static var version: String {
        bundleString(for: "CFBundleShortVersionString") ?? fallbackVersion
    }

    static var build: String {
        bundleString(for: "CFBundleVersion") ?? fallbackBuild
    }

    static var displayVersion: String {
        "Version \(version) (\(build))"
    }

    static var updateCheckURL: URL? {
        guard let rawValue = bundleString(for: "PasteLiteUpdateCheckURL"),
              !rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return URL(string: rawValue)
    }

    private static func bundleString(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
