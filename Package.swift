// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "ClaudeUsageBar",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "ClaudeUsageBar", targets: ["ClaudeUsageBar"])
    ],
    targets: [
        .target(
            name: "ClaudeUsageBarCore",
            path: "Sources/ClaudeUsageBarCore"
        ),
        .executableTarget(
            name: "ClaudeUsageBar",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Sources/ClaudeUsageBar"
        ),
        .testTarget(
            name: "ClaudeUsageBarCoreTests",
            dependencies: ["ClaudeUsageBarCore"],
            path: "Tests/ClaudeUsageBarCoreTests"
        )
    ]
)
