// swift-tools-version:5.7
// 注意：Swift 5.7 工具链对应 Xcode 14，能在 macOS 12 上构建。
// 我们刻意不用 Swift 6.x 的并发语法（actor isolation 等），保持对老系统友好。
import PackageDescription

let package = Package(
    name: "PingIslandLite",
    platforms: [
        .macOS(.v12)
    ],
    products: [
        .executable(name: "AgentBeacon", targets: ["PingIslandLite"]),
        .executable(name: "PingIslandLite", targets: ["PingIslandLite"]),
        // 本地验证辅助：构造一个假 envelope 发送到运行中的 AgentBeacon，
        // 代替启动真实 Claude Code 来验证社 socket 链路是否联通。
        .executable(name: "AgentBeaconTestSender", targets: ["PingIslandLiteTestSender"]),
        .executable(name: "PingIslandLiteTestSender", targets: ["PingIslandLiteTestSender"])
    ],
    dependencies: [
        // Bridge 子包：Hook 协议层 + Bridge CLI executable。
        // 用 path 依赖，便于本地同步开发。
        .package(path: "Bridge")
    ],
    targets: [
        .executableTarget(
            name: "PingIslandLite",
            dependencies: [
                .product(name: "IslandShared", package: "Bridge")
            ],
            path: "Sources/PingIslandLite",
            exclude: [],
            resources: [
                // 14 家 Agent 的吉祥物 GIF（来自原仓库 docs/images/mascots/，
                // 由 scripts/render-mascots.sh 用 macOS 14 渲染后导出，
                // 但 .gif 文件本身和 macOS 版本无关，老系统可以正常播放）。
                .process("Resources/Mascots"),
                // 菜单栏 button 图标：14 家 logo PNG（Pi 为 SVG 不受 macOS 12
                // NSImage 支持，走 SF Symbol 兑底），原始文件从 PingIsland/Assets.xcassets/
                // <Xxx>Logo.imageset 复制过来。
                .process("Resources/MenuBarIcons"),
                // 8-bit 复古音效：从主仓 PingIsland/Resources/Sounds/ 拷的 5 颗核心音，
                // 对齐主仓 island8Bit 模式下 5 态 NotificationEvent 默认映射。
                .process("Resources/Sounds")
            ]
        ),
        .executableTarget(
            name: "PingIslandLiteTestSender",
            dependencies: [
                .product(name: "IslandShared", package: "Bridge")
            ],
            path: "Sources/PingIslandLiteTestSender"
        ),
        .testTarget(
            name: "PingIslandLiteTests",
            dependencies: ["PingIslandLite"],
            path: "Tests/PingIslandLiteTests"
        )
    ]
)
