// swift-tools-version: 6.0

import PackageDescription

// SimAgentationPlus, the optional in-app SDK: add this repository's URL in
// Xcode (File > Add Package Dependencies) and link SimAgentationPlus. The
// host and the web UI build separately (see host/Package.swift and
// package.json); this manifest is the SDK alone.
let package = Package(
    name: "SimAgentationPlus",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SimAgentationPlus", targets: ["SimAgentationPlus"]),
    ],
    targets: [
        .target(name: "SimAgentationPlus", path: "sdk/SimAgentationPlus/Sources/SimAgentationPlus"),
    ]
)
