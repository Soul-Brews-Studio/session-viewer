// swift-tools-version:5.9
import PackageDescription

// Three targets, and the split is a BUILD-LAYOUT REQUIREMENT rather than taste:
// SwiftPM cannot import an `executableTarget` from a `testTarget`, so any logic living in
// the executable is permanently untestable. Everything therefore lives in the
// SessionViewerCore library; the executable is only top-level dispatch (the one thing a
// library cannot hold), and the tests import the library.
let package = Package(
    name: "session-viewer",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "session-viewer", targets: ["session-viewer"]),
        .library(name: "SessionViewerCore", targets: ["SessionViewerCore"]),
    ],
    targets: [
        .target(
            name: "SessionViewerCore",
            path: "Sources/SessionViewerCore",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "session-viewer",
            dependencies: ["SessionViewerCore"],
            path: "Sources/session-viewer"
        ),
        .testTarget(
            name: "SessionViewerCoreTests",
            dependencies: ["SessionViewerCore"],
            path: "Tests/SessionViewerCoreTests"
        ),
    ]
)
