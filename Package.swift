// swift-tools-version:6.0
import PackageDescription

// Three pieces. AthanorCore holds everything that doesn't need a window: the
// scripts.toml format, the log line format, the restart policy and the libproc
// and posix_spawn plumbing. athanor-shim is the small process that sits between
// Athanor and each running script. Athanor is the menu bar app.
//
// Cross-target symbols use `package` rather than `public`: nothing outside this
// package links these modules.
let package = Package(
    name: "Athanor",
    platforms: [.macOS(.v14)],
    targets: [
        .target(
            name: "AthanorCore",
            path: "Sources/AthanorCore"
        ),
        // One per running script. It owns the script's pipes, so output keeps
        // reaching the log, with timestamps, while Athanor is quit.
        .executableTarget(
            name: "athanor-shim",
            dependencies: ["AthanorCore"],
            path: "Sources/athanor-shim"
        ),
        // AppKit and SwiftUI callbacks are main-thread by contract; Swift 5 mode
        // keeps that from turning into annotations on every closure.
        .executableTarget(
            name: "Athanor",
            dependencies: ["AthanorCore"],
            path: "Sources/Athanor",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Depends on the shim so `swift test` builds it: the shim tests run
        // the real binary.
        .testTarget(
            name: "AthanorCoreTests",
            dependencies: ["AthanorCore", "athanor-shim"],
            path: "Tests/AthanorCoreTests"
        )
    ]
)
