// swift-tools-version: 5.9

import Foundation
import PackageDescription

func selectedDeveloperDirectory() -> String? {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcode-select")
    process.arguments = ["-p"]
    process.standardOutput = pipe
    process.standardError = Pipe()
    guard (try? process.run()) != nil else { return nil }
    process.waitUntilExit()
    guard process.terminationStatus == 0 else { return nil }

    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)?
        .trimmingCharacters(in: .whitespacesAndNewlines)
}

let developerDirectories = (
    [
        ProcessInfo.processInfo.environment["DEVELOPER_DIR"],
        selectedDeveloperDirectory(),
        "/Applications/Xcode.app/Contents/Developer",
        "/Library/Developer/CommandLineTools"
    ].compactMap { $0 }
).reduce(into: [String]()) { directories, directory in
    guard !directories.contains(directory),
          FileManager.default.fileExists(atPath: directory) else {
        return
    }
    directories.append(directory)
}

func firstExistingPath(_ paths: [String]) -> String? {
    paths.first { FileManager.default.fileExists(atPath: $0) }
}

func swiftTestingMacroSettings() -> [SwiftSetting] {
    let testingMacroPluginSuffixes = [
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib",
        "usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
    ]
    let testingMacroPluginPaths = developerDirectories.flatMap { directory in
        testingMacroPluginSuffixes.map { "\(directory)/\($0)" }
    }

    guard let pluginPath = firstExistingPath(testingMacroPluginPaths) else {
        return []
    }

    return [
        .unsafeFlags([
            "-load-plugin-library",
            pluginPath
        ])
    ]
}

func swiftTestingLinkerSettings() -> [LinkerSetting] {
    let candidateDirectories = [
        "Library/Developer/Frameworks",
        "Library/Developer/usr/lib",
        "Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx"
    ].flatMap { suffix in
        developerDirectories.map { "\($0)/\(suffix)" }
    }.filter { FileManager.default.fileExists(atPath: $0) }

    guard !candidateDirectories.isEmpty else { return [] }

    let flags = candidateDirectories.flatMap { directory in
        ["-Xlinker", "-rpath", "-Xlinker", directory]
    }

    return [.unsafeFlags(flags)]
}

let package = Package(
    name: "PasteLite",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "PasteLite", targets: ["PasteLite"])
    ],
    targets: [
        .executableTarget(
            name: "PasteLite",
            path: "Sources/PasteLite"
        ),
        .testTarget(
            name: "PasteLiteTests",
            dependencies: ["PasteLite"],
            path: "Tests/PasteLiteTests",
            swiftSettings: swiftTestingMacroSettings(),
            linkerSettings: swiftTestingLinkerSettings()
        )
    ]
)
