// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "NaiveFlowQUIC",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "NaiveFlowQUIC",
            targets: ["NaiveFlowQUIC"]
        )
    ],
    targets: [
        .target(
            name: "NaiveFlowQUIC"
        ),
    ]
)
