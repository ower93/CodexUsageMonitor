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
    targets: [
        .target(
            name: "CodexUsageUI",
            path: "Sources/CodexUsageUI"
        ),
        .executableTarget(
            name: "CodexUsageMonitor",
            dependencies: ["CodexUsageUI"],
            path: "Sources/CodexUsageMonitor"
        ),
        .executableTarget(
            name: "PreviewRendererTool",
            dependencies: ["CodexUsageUI"],
            path: "Sources/PreviewRendererTool"
        )
    ]
)
