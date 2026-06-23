# AGENTS.md

AgentBeacon 是从 PingIsland 分叉的 macOS 12+ 兼容版，独立仓库、独立维护。当前 SwiftPM target / 源码目录仍沿用 `PingIslandLite`，用户可见产品名使用 AgentBeacon。

## Mission

- 目标平台：**macOS 12.0+**（Monterey 起）
- 工程类型：Swift Package Manager（不依赖 Xcode 工程文件，便于纯 CLI 构建）
- UI 框架：以 **AppKit 为主**，必要时局部使用 **macOS 12 兼容子集的 SwiftUI**
- 严格禁止使用 macOS 13/14 才引入的 API；任何 `if #available(macOS 13/14, *)` 必须有 macOS 12 fallback

## Repo Map

```
ping-island-lite/
├── Sources/PingIslandLite/
│   ├── App/         ← 应用生命周期：main、AppDelegate、MenuBarController
│   ├── UI/          ← AppKit 视图：NSPopover、NSTableView、设置窗口
│   ├── Services/    ← Hook Socket、通知、终端聚焦、Agent 安装器
│   ├── Models/      ← 数据模型（与原版尽量保持兼容）
│   └── Resources/   ← 图标、声音、本地化、吉祥物素材
└── Tests/PingIslandLiteTests/
```

## 与原版 PingIsland 的对应关系

AgentBeacon 是分叉，不与原版共享代码。但 hook 协议、客户端识别、终端跳转等逻辑参考自原版：

- 原版 `Prototype/Sources/IslandBridge/` → 后续移植为 `Services/Bridge/`
- 原版 `PingIsland/Services/Hooks/HookSocketServer.swift` → 移植为 `Services/Hooks/HookSocketServer.swift`，移除 macOS 14 API
- 原版 `PingIsland/UI/Components/MascotView.swift` → 移植为 `UI/Components/MascotView.swift`，降级 SwiftUI API

## Change Routing

- 改 hook 协议：参考原版 [HookSocketServer.swift](../PingIsland/Services/Hooks/HookSocketServer.swift)，但以本仓库为准。
- 改吉祥物：动画逻辑必须在 macOS 12 SwiftUI 子集上验证。原版的 `.onChange(of:) { _, new in }` 双参数语法**禁用**，必须改写为单参数版本。
- 改 Agent hook 安装器：每家 Agent 一个独立文件，例如 `Services/AgentInstallers/ClaudeInstaller.swift`，统一遵循 `AgentInstaller` 协议。

## macOS 12 API 黑名单（禁用）

构建时如发现以下 API 调用，必须重写：

| 黑名单 API | 替代方案 |
|---|---|
| `.onChange(of:) { _, new in }` 双参数 | `.onChange(of:) { new in }` 单参数 |
| `@Observable` 宏 | `ObservableObject` + `@Published` |
| `MenuBarExtra` | `NSStatusItem` + `NSMenu` |
| `NavigationStack` | `NavigationView` 或自定义路由 |
| `NavigationSplitView` | `NSSplitView` 或 `HSplitView` |
| `ContentUnavailableView` | 手写空状态视图 |
| `.scrollPosition`、`.scrollTargetBehavior` | 自管 `NSScrollView` |
| `.symbolEffect`、`.contentTransition` | 用 `NSAnimationContext` 替代 |
| `LabeledContent` | `HStack` + `Text` 自己摆 |
| Swift 6 actor 严格隔离 | 保留 actor，但避免 `nonisolated(unsafe)` 等新语法 |

## Build And Test

```bash
# 调试构建
swift build

# 运行
swift run AgentBeacon

# 测试
swift test

# Release 构建
swift build -c release
```

## Working Rules

- 所有新代码必须能在 macOS 12 上跑起来（开发机如果是 macOS 14+，请用 deployment target 构建配置验证）
- 提交前在 macOS 12 真机上至少冒烟测试一次（菜单栏图标可见 + 通知可弹出）
- 每完成一个阶段更新 `README.md` 的进度勾选

## Verification Checklist

- 是否有任何 `@available(macOS 13, *)` 或 `@available(macOS 14, *)` 没有 macOS 12 fallback？
- `swift build -c release` 是否在 macOS 12 SDK 下编译通过？
- 菜单栏图标是否仍能显示？
- Hook 通知是否仍能正常弹出？
