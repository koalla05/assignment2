// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "apd-hw-2",
    platforms: [
        .macOS(.v10_15),
        .iOS(.v13)
    ],
    products: [
        .library(name: "TaskProcessor", targets: ["TaskProcessor"])
    ],
    targets: [
        .target(name: "TaskProcessor"),
        .testTarget(
            name: "TaskProcessorTests",
            dependencies: ["TaskProcessor"]
        )
    ]
)
