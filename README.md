# AgentBeacon

> macOS 12+ 兼容版的 PingIsland，面向无法升级到 macOS 14 的老 Mac 用户。

AgentBeacon 是 [PingIsland](https://github.com/) 的独立分叉版本，目标是在 macOS 12 (Monterey) 及以上系统上提供 AI 编码 Agent 的统一通知与跳转能力。

## Screenshots

Screenshots live under `docs/images/`. Recommended captures:

- `menu-activity.png` — menu bar activity list with session badges and Codex usage.
- `settings-mascots.png` — mascot selector.
- `session-detail.png` — session detail window.

## 与原版的差异

| 维度 | 原版 PingIsland | AgentBeacon |
|---|---|---|
| 最低 macOS | 14 (Sonoma) | **12 (Monterey)** |
| UI 形态 | 灵动岛 / 悬浮胶囊 | 菜单栏图标 + 弹出面板 |
| 吉祥物 | 完整动画 | **完整动画**（保留） |
| 支持 Agent | 14 家 | **14 家**（一致） |
| 通知形态 | 自定义岛内提示 | macOS 原生通知中心 |
| 终端跳转 | ✅ | ✅ |
| SSH 远程桥接 | ✅ | 计划中 |

## 当前进度

- [x] 阶段 1：项目骨架与菜单栏图标
- [x] 阶段 1：HookSocketServer 移植
- [x] 阶段 1：原生通知接入
- [ ] 阶段 2：吉祥物完整档移植
- [ ] 阶段 3：14 家 Agent hook 安装器
- [x] 阶段 4：设置面板 + 终端跳转 + 本地 .app 打包脚手架
- [ ] 阶段 4：Sparkle 更新与签名发布

## 本地运行

```bash
cd ping-island-lite
swift run AgentBeacon
```

启动后菜单栏右上角会出现 AgentBeacon 图标。Cmd+Q 退出。

本地打包成 `.app`：

```bash
./scripts/build-app.sh
open build/AgentBeacon.app
```

## 系统要求

- macOS 12.0 或更高
- 首次运行会请求"通知"权限；后续阶段会请求"辅助功能"和"自动化"权限以支持终端聚焦。

## 目录结构

```
ping-island-lite/
├── Package.swift            ← SPM 工程（macOS 12+）
├── Sources/PingIslandLite/   ← 当前 Swift target 源码目录（产品名已改为 AgentBeacon）
│   ├── App/                 ← AppDelegate、MenuBarController
│   ├── UI/                  ← AppKit 弹出面板（NSPopover + NSTableView）
│   ├── Services/            ← Hook Socket、通知、终端聚焦、Agent 安装器
│   ├── Models/              ← SessionState、ClientProfile 等数据模型
│   └── Resources/           ← 图标、声音、吉祥物资源
└── Tests/PingIslandLiteTests/
```

## License

跟主项目一致。详见 [LICENSE.md](./LICENSE.md)。
