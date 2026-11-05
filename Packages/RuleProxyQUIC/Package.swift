// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "RuleProxyQUIC",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "RuleProxyQUIC",
            targets: ["RuleProxyQUIC"]
        )
    ],
    targets: [
        .target(
            name: "RuleProxyQUIC"
        ),
    ]
)
