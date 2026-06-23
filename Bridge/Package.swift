// swift-tools-version:5.7
// Bridge 子包：Hook 协议层 + Bridge CLI executable。
// 故意与主 App 解耦：可独立 build/test，且没有任何 SwiftUI/AppKit 依赖。
// macOS 12 兼容由这里统一把关。

import PackageDescription

let package = Package(
    name: "PingIslandLiteBridge",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        // 协议层：JSON 编解码、Hook 载荷映射、模型、运行时配置。给主 App 依赖用。
        .library(name: "IslandShared", targets: ["IslandShared"]),
        // CLI 可执行文件：被各家 Agent（Claude/Codex/...）作为 hook 调起，
        // 通过 Unix Socket 把事件发回主 App。
        .executable(name: "PingIslandBridge", targets: ["PingIslandBridge"])
    ],
    dependencies: [],
    targets: [
        .target(
            name: "IslandShared",
            path: "Sources/IslandShared"
        ),
        .executableTarget(
            name: "PingIslandBridge",
            dependencies: ["IslandShared"],
            path: "Sources/PingIslandBridge"
        ),
        .testTarget(
            name: "IslandSharedTests",
            dependencies: ["IslandShared"],
            path: "Tests/IslandSharedTests"
        )
    ]
)
