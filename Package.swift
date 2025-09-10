// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "ExtWSClient",
    platforms: [
            .iOS(.v14),
            .macOS(.v10_15)
        ],
    products: [
        .library(
            name: "ExtWSClient",
            targets: ["ExtWSClient"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log", from: "1.6.4"),
    ],
    targets: [
        .target(
            name: "ExtWSClient",
            dependencies: [
                .product(name: "Logging", package: "swift-log")
            ]),
        .testTarget(
            name: "ExtWSClientTests",
            dependencies: ["ExtWSClient"]
        ),
    ]
)
