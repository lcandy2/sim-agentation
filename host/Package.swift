// swift-tools-version: 6.0

import PackageDescription

// No third-party dependencies: CoreSimulator and SimulatorKit are private
// frameworks loaded at runtime with dlopen, and HTTP/WebSocket is built on
// Network.framework.
let package = Package(
    name: "SimAgentationHost",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "sim-agentation", targets: ["sim-agentation"]),
        .library(name: "SimBridge", targets: ["SimBridge"]),
    ],
    targets: [
        .target(
            name: "SimBridge",
            exclude: ["LICENSE-baguette", "LICENSE-sim-use"],
            linkerSettings: [
                .linkedFramework("IOSurface"),
                .linkedFramework("CoreVideo"),
                .linkedFramework("ImageIO"),
            ]
        ),
        .executableTarget(
            name: "sim-agentation",
            dependencies: ["SimBridge"]
        ),
    ]
)
