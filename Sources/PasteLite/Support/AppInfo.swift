import Foundation

enum AppInfo {
    static let fallbackVersion = "0.1.1"
    static let fallbackBuild = "11"
    static let defaultUpdateCheckURL = URL(string: "https://api.github.com/repos/MoarLiu/PasteLite/releases/latest")

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
        guard let rawValue = bundleString(for: "PasteLiteUpdateCheckURL")?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return defaultUpdateCheckURL
        }
        return URL(string: rawValue)
    }

    private static func bundleString(for key: String) -> String? {
        Bundle.main.object(forInfoDictionaryKey: key) as? String
    }
}
