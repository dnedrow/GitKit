// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "GitKit",
    platforms: [
        .macOS(.v15),
        .iOS(.v18),
        .tvOS(.v18),
        .watchOS(.v11)
    ],
    products: [
        .library(
            name: "GitKit",
            targets: ["GitKit"]
        ),
    ],
    targets: [
        .target(
            name: "GitKit",
            path: "Sources/GitKit"
        ),
        .testTarget(
            name: "GitKitTests",
            dependencies: ["GitKit"]
        ),
    ]
)
