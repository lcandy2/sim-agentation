// swift-tools-version: 6.0

import PackageDescription

// No third-party dependencies: CoreSimulator and SimulatorKit are private
// frameworks loaded at runtime with dlopen, and HTTP/WebSocket is built on
// BSD sockets.
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
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("CoreImage"),
            ]
        ),
        .executableTarget(
            name: "sim-agentation",
            dependencies: ["SimBridge"]
        ),
        // No simulator: requests are stand-in objects with the same keys, and
        // trees are saved native walks.
        .testTarget(
            name: "SimBridgeTests",
            dependencies: ["SimBridge"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
