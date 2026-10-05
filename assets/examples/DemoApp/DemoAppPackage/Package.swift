// swift-tools-version: 6.2
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "DemoAppFeature",
    platforms: [.iOS(.v26)],
    products: [
        // Products define the executables and libraries a package produces, making them visible to other packages.
        .library(
            name: "DemoAppFeature",
            targets: ["DemoAppFeature"]
        ),
    ],
    dependencies: [
        .package(path: "../../../.."), // this repository: the SimAgentationPlus SDK
    ],
    targets: [
        // Targets are the basic building blocks of a package, defining a module or a test suite.
        // Targets can depend on other targets in this package and products from dependencies.
        .target(
            name: "DemoAppFeature",
            dependencies: [.product(name: "SimAgentationPlus", package: "sim-agentation")]
        ),
        .testTarget(
            name: "DemoAppFeatureTests",
            dependencies: [
                "DemoAppFeature"
            ]
        ),
    ]
)
