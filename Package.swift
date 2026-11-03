// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CodexUsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "CodexUsageMonitor", targets: ["CodexUsageMonitor"]),
        .executable(name: "PreviewRendererTool", targets: ["PreviewRendererTool"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        .target(
            name: "CodexUsageUI",
            path: "Sources/CodexUsageUI",
            resources: [.process("Resources")],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(
            name: "CodexUsageMonitor",
            dependencies: ["CodexUsageUI", .product(name: "Sparkle", package: "Sparkle")],
            path: "Sources/CodexUsageMonitor",
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]
        ),
        .executableTarget(
            name: "PreviewRendererTool",
            dependencies: ["CodexUsageUI"],
            path: "Sources/PreviewRendererTool"
        ),
        .testTarget(
            name: "CodexUsageUITests",
            dependencies: ["CodexUsageUI"],
            path: "Tests/CodexUsageUITests"
        )
    ]
)
