// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NaiveFlowIP",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "NaiveFlowIP",
            targets: ["NaiveFlowIP"]
        ),
    ],
    targets: [
        .target(
            name: "NaiveFlowIP"
        ),
        .testTarget(name: "NaiveFlowIPTests", dependencies: ["NaiveFlowIP"]),
    ]
)
