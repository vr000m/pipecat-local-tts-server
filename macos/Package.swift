// swift-tools-version: 6.0
// Pipecat Service Toolbar: a native macOS menu bar app that installs local
// Pipecat speech services (TTS and STT) and serves them on loopback ports.
// Build the .app with `just app-build`; run unbundled with `just app-run`.
import PackageDescription

let package = Package(
    name: "PipecatServiceToolbar",
    platforms: [.macOS(.v15)],
    targets: [
        .target(
            name: "PipecatToolbarCore",
            path: "Sources/PipecatToolbarCore",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .executableTarget(
            name: "PipecatServiceToolbar",
            dependencies: ["PipecatToolbarCore"],
            path: "Sources/PipecatServiceToolbar",
            swiftSettings: [.swiftLanguageMode(.v6)],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("AVFoundation"),
                .linkedFramework("Accelerate"),
                .linkedFramework("Speech"),
                .linkedFramework("Network"),
            ]
        ),
        .testTarget(
            name: "PipecatServiceToolbarTests",
            // Core only: the lifecycle state machine lives there (`ServiceLifecycle`, `ServiceDriver`).
            dependencies: ["PipecatToolbarCore"],
            path: "Tests/PipecatServiceToolbarTests",
            // Read by path: real server frames, verified by tests/test_macos_catalog_drift.py.
            exclude: ["Fixtures"]
        ),
    ]
)
