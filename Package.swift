// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "battlens",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(
            name: "battlens",
            targets: ["battlens"]
        ),
    ],
    targets: [
        .executableTarget(
            name: "battlens",
            path: "Sources"
        ),
        .testTarget(
            name: "battlensTests",
            dependencies: ["battlens"],
            path: "Tests"
        ),
    ]
)
