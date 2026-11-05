import Foundation

enum UpdateCheckResult: Equatable {
    case notConfigured
    case upToDate(currentVersion: String)
    case updateAvailable(currentVersion: String, latestVersion: String, releaseURL: URL?)
}

enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case invalidReleaseData

    var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "The update server returned an invalid response."
        case .invalidReleaseData:
            return "The update server did not include a release version."
        }
    }
}

struct UpdateChecker {
    private let endpoint: URL?
    private let currentVersion: String

    init(endpoint: URL? = AppInfo.updateCheckURL, currentVersion: String = AppInfo.version) {
        self.endpoint = endpoint
        self.currentVersion = currentVersion
    }

    func check() async throws -> UpdateCheckResult {
        guard let endpoint else { return .notConfigured }

        let (data, response) = try await URLSession.shared.data(from: endpoint)
        guard let httpResponse = response as? HTTPURLResponse,
              (200..<300).contains(httpResponse.statusCode) else {
            throw UpdateCheckError.invalidResponse
        }

        let release = try JSONDecoder().decode(UpdateRelease.self, from: data)
        guard let latestVersion = release.version else {
            throw UpdateCheckError.invalidReleaseData
        }

        if Self.compareVersions(latestVersion, currentVersion) == .orderedDescending {
            return .updateAvailable(
                currentVersion: currentVersion,
                latestVersion: latestVersion,
                releaseURL: release.releaseURL
            )
        }

        return .upToDate(currentVersion: currentVersion)
    }

    static func compareVersions(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)

        for index in 0..<count {
            let leftValue = index < left.count ? left[index] : 0
            let rightValue = index < right.count ? right[index] : 0
            if leftValue < rightValue { return .orderedAscending }
            if leftValue > rightValue { return .orderedDescending }
        }

        let leftPrerelease = prerelease(lhs)
        let rightPrerelease = prerelease(rhs)
        if leftPrerelease == rightPrerelease { return .orderedSame }
        if leftPrerelease.isEmpty { return .orderedDescending }
        if rightPrerelease.isEmpty { return .orderedAscending }
        for index in 0..<max(leftPrerelease.count, rightPrerelease.count) {
            guard index < leftPrerelease.count else { return .orderedAscending }
            guard index < rightPrerelease.count else { return .orderedDescending }
            let left = leftPrerelease[index], right = rightPrerelease[index]
            if left == right { continue }
            if let a = Int(left), let b = Int(right) { return a < b ? .orderedAscending : .orderedDescending }
            if Int(left) != nil { return .orderedAscending }
            if Int(right) != nil { return .orderedDescending }
            return left.compare(right, options: .literal)
        }
        return .orderedSame
    }

    private static func prerelease(_ version: String) -> [String] {
        let noBuild = version.split(separator: "+", maxSplits: 1).first.map(String.init) ?? version
        let parts = noBuild.split(separator: "-", maxSplits: 1)
        return parts.count == 2 ? parts[1].split(separator: ".").map(String.init) : []
    }

    private static func versionComponents(_ version: String) -> [Int] {
        version
            .trimmingCharacters(in: CharacterSet(charactersIn: "vV").union(.whitespacesAndNewlines))
            .split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init).map {
                $0.split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
            } ?? []
    }
}

private struct UpdateRelease: Decodable {
    var tagName: String?
    var versionValue: String?
    var htmlURL: URL?
    var url: URL?

    var version: String? {
        let value = versionValue ?? tagName
        return value?.trimmingCharacters(in: CharacterSet(charactersIn: "vV").union(.whitespacesAndNewlines))
    }

    var releaseURL: URL? {
        htmlURL ?? url
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case versionValue = "version"
        case htmlURL = "html_url"
        case url
    }
}
