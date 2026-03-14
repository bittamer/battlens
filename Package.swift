// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "battlens",
    platforms: [
        .macOS(.v13)
    ],
    targets: [
        .executableTarget(
            name: "battlens",
            path: "Sources"
        ),
    ]
)
