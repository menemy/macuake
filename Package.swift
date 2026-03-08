// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Macuake",
    platforms: [
        .macOS(.v14)
    ],
    dependencies: [
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.0.0"),
        .package(url: "https://github.com/modelcontextprotocol/swift-sdk.git", from: "0.7.1"),
    ],
    targets: [
        .binaryTarget(
            name: "GhosttyKit",
            path: "vendor/ghostty/macos/GhosttyKit.xcframework"
        ),
        .executableTarget(
            name: "Macuake",
            dependencies: [
                "KeyboardShortcuts",
                "GhosttyKit",
                .product(name: "Sparkle", package: "Sparkle"),
                .product(name: "MCP", package: "swift-sdk"),
            ],
            path: "MaQuake/Sources/MaQuake",
            resources: [
                .process("../../Resources"),
            ],
            linkerSettings: [
                .linkedFramework("Metal"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("CoreText"),
                .linkedFramework("IOKit"),
            ]
        ),
        .testTarget(
            name: "MacuakeTests",
            dependencies: ["Macuake"],
            path: "MaQuake/Tests/MaQuakeTests"
        ),
    ]
)
