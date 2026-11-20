// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Ration",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Ration", targets: ["Ration"]),
        .executable(name: "ration-hook", targets: ["ration-hook"]),
        .library(name: "RationCore", targets: ["RationCore"]),
    ],
    targets: [
        // Data layer: no UI dependencies, so a CLI or widget can reuse it later.
        .target(name: "RationCore"),
        // Menu bar app (SwiftUI).
        .executableTarget(
            name: "Ration",
            dependencies: ["RationCore"]
        ),
        // Tiny helper Claude Code hooks call (optional "hooks mode").
        .executableTarget(
            name: "ration-hook",
            dependencies: ["RationCore"]
        ),
        .testTarget(
            name: "RationCoreTests",
            dependencies: ["RationCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
