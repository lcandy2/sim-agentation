// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SimAgentationPlus",
    platforms: [.iOS(.v17)],
    products: [
        .library(name: "SimAgentationPlus", targets: ["SimAgentationPlus"]),
    ],
    targets: [
        .target(name: "SimAgentationPlus"),
    ]
)
