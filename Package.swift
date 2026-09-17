// swift-tools-version: 6.0
import PackageDescription

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
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
            ])]
        ),
        .testTarget(
            name: "CATAnalysisTests",
            dependencies: ["CATAnalysis"],
            swiftSettings: [.unsafeFlags(["-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"])],
            linkerSettings: [.unsafeFlags([
                "-F", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/Frameworks",
                "-Xlinker", "-rpath", "-Xlinker", "/Library/Developer/CommandLineTools/Library/Developer/usr/lib",
            ])]
        ),
    ]
)
