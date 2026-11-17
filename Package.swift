// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "ClaudeBar",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "ClaudeBar", targets: ["ClaudeBar"]),
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
        .testTarget(
            name: "ClaudeBarCoreTests",
            dependencies: ["ClaudeBarCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
