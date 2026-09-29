// swift-tools-version: 6.0
import Foundation
import PackageDescription

// With only the Command Line Tools installed (no Xcode), Swift Testing lives in a framework
// directory SwiftPM doesn't search by default. Point the test targets at it only when that
// framework is actually there, rather than hard-coding the paths for every setup.
let commandLineToolsFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let needsCommandLineToolsTesting = FileManager.default.fileExists(atPath: commandLineToolsFrameworks + "/Testing.framework")
let testSwiftSettings: [SwiftSetting] = needsCommandLineToolsTesting
    ? [.unsafeFlags(["-F", commandLineToolsFrameworks])]
    : []
let testLinkerSettings: [LinkerSetting] = needsCommandLineToolsTesting
    ? [.unsafeFlags([
        "-F", commandLineToolsFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", commandLineToolsFrameworks,
        "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
    ])]
    : []

let package = Package(
    name: "core-audio-tester",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "CATEngine",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("AVFAudio"),
            ]
        ),
        .target(
            name: "CATAnalysis",
            dependencies: ["CATEngine"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Accelerate")]
        ),
        .executableTarget(
            name: "core-audio-tester",
            dependencies: ["CATEngine", "CATAnalysis"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CATEngineTests",
            dependencies: ["CATEngine"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
        .testTarget(
            name: "CATAnalysisTests",
            dependencies: ["CATEngine", "CATAnalysis"],
            swiftSettings: testSwiftSettings,
            linkerSettings: testLinkerSettings
        ),
    ]
)
