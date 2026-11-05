// swift-tools-version: 6.4

import PackageDescription

let package = Package(
    name: "RuleProxyIP",
    platforms: [
        .iOS(.v18),
        .macOS(.v15),
        .tvOS(.v18),
    ],
    products: [
        .library(
            name: "RuleProxyIP",
            targets: ["RuleProxyIP"]
        ),
    ],
    targets: [
        .target(
            name: "RuleProxyIP"
        ),
    ]
)
