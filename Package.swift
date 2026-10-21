// swift-tools-version: 6.0
import Foundation
import PackageDescription

// Command Line Tools ships Swift Testing but SwiftPM does not pass its macro
// plugin to the module-emit step. Xcode toolchains do not need the flag.
var testSwiftSettings: [SwiftSetting] = []
let cltTestingPlugin = "/Library/Developer/CommandLineTools/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"
if FileManager.default.fileExists(atPath: cltTestingPlugin) {
    testSwiftSettings.append(.unsafeFlags(["-load-plugin-library", cltTestingPlugin]))
}

let package = Package(
    name: "StarryHaven",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "StarryHaven", targets: ["StarryHavenApp"]),
        .executable(name: "starryhaven-cli", targets: ["StarryHavenCLI"]),
        .library(name: "StarryHavenCore", targets: ["StarryHavenCore"]),
    ],
    targets: [
        .target(
            name: "COnnxRuntime",
            path: "Sources/COnnxRuntime",
            publicHeadersPath: "include"
        ),
        .target(
            name: "StarryHavenCore",
            dependencies: ["COnnxRuntime"],
            path: "Sources/StarryHavenCore"
        ),
        .executableTarget(
            name: "StarryHavenApp",
            dependencies: ["StarryHavenCore"],
            path: "Sources/StarryHavenApp"
        ),
        .executableTarget(
            name: "StarryHavenCLI",
            dependencies: ["StarryHavenCore"],
            path: "Sources/StarryHavenCLI"
        ),
        .testTarget(
            name: "StarryHavenCoreTests",
            dependencies: ["StarryHavenCore"],
            path: "Tests/StarryHavenCoreTests",
            swiftSettings: testSwiftSettings
        ),
    ],
    swiftLanguageModes: [.v5]
)
