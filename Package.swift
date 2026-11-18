// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeBar", targets: ["ClaudeBar"]),
        .executable(name: "claudebar-hook", targets: ["claudebar-hook"]),
        .library(name: "ClaudeBarCore", targets: ["ClaudeBarCore"]),
    ],
    targets: [
        // Data layer: no UI dependencies, so a CLI or widget can reuse it later.
        .target(name: "ClaudeBarCore"),
        // Menu bar app (SwiftUI).
        .executableTarget(
            name: "ClaudeBar",
            dependencies: ["ClaudeBarCore"]
        ),
        // Tiny helper Claude Code hooks call (optional "hooks mode").
        .executableTarget(
            name: "claudebar-hook",
            dependencies: ["ClaudeBarCore"]
        ),
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
