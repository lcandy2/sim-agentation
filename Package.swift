// swift-tools-version: 6.0

import PackageDescription

// SimAgentationPlus, the optional in-app SDK: add this repository's URL in
// Xcode (File > Add Package Dependencies) and link SimAgentationPlus. The
// host and the web UI build separately (see host/Package.swift and
// package.json); this manifest is the SDK alone.
//
// It builds for every Apple platform. Where UIKit draws the interface
// (iOS, iPadOS, Mac Catalyst, tvOS, visionOS) a snapshot walks the views
// and layers; on macOS and watchOS it carries the `.simTag()` views only.
let package = Package(
    name: "SimAgentationPlus",
    platforms: [.iOS(.v17), .macCatalyst(.v17), .macOS(.v14), .tvOS(.v17), .watchOS(.v10), .visionOS(.v1)],
    products: [
        .library(name: "SimAgentationPlus", targets: ["SimAgentationPlus"]),
    ],
    targets: [
        .target(name: "SimAgentationPlus"),
    ]
)
