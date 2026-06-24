import Foundation
import IslandShared

/// 吉祥物种类（13 家独立 Agent + Trae 复用 Claude = 14 个 GIF 资源）。
///
/// 这是 PingIsland Lite 的简化版枚举，去掉了原版 `MascotView.MascotKind` 对
/// `SessionState` / `SessionClientInfo` / `MascotStatus.warning` 等运行时状态的耦合。
/// 这里只关心：**给定一个 Agent，要显示哪只吉祥物的 GIF**。
///
/// GIF 文件由原仓库 `scripts/render-mascots.sh` 用 macOS 14 的 SwiftUI Canvas 渲染生成，
/// 但 .gif 是普通图片文件，macOS 12 用 NSImage 解码播放完全没问题。
public enum MascotKind: String, CaseIterable, Identifiable, Sendable {
    case claude
    case codex
    case gemini
    case hermes
    case pi
    case qwen
    case openclaw
    case opencode
    case cursor
    case qoder
    case codebuddy
    case copilot
    case kimi
    case trae

    public var id: String { rawValue }

    /// 在菜单里展示的中文标题（吉祥物的"昵称"）。
    public var displayName: String {
        switch self {
        case .claude:    return "Claude · 桌前橘猫"
        case .codex:     return "Codex · 终端云团"
        case .gemini:    return "Gemini · 蓝色双子星灵"
        case .hermes:    return "Hermes · 翼盔信使狐"
        case .pi:        return "Pi · 终端星核"
        case .qwen:      return "Qwen · 卡皮巴拉"
        case .openclaw:  return "OpenClaw · 双钳小龙虾"
        case .opencode:  return "OpenCode · 白色小章鱼"
        case .cursor:    return "Cursor · 黑曜晶体"
        case .qoder:     return "Qoder · Q 仔"
        case .codebuddy: return "CodeBuddy · 宇航员猫"
        case .copilot:   return "Copilot · 黑框眼镜机器人"
        case .kimi:      return "Kimi · 蓝色键盘球"
        case .trae:      return "Trae · 桌前橘猫"
        }
    }

    /// 资源 bundle 里 .gif 的文件名（不带扩展名）。
    public var gifResourceName: String {
        // trae 复用 claude.gif（和原版策略一致）。
        switch self {
        case .trae: return "claude"
        default:    return rawValue
        }
    }

    /// 菜单栏图标 PNG 的资源名（不带扩展名）。
    /// 返回 nil 表示该 Agent 没有 PNG logo（Pi 是 SVG，macOS 12 NSImage 不支持），
    /// 需要调用方用 SF Symbol 兑底。文件名格式为 `<provider>-logo.png`。
    public var menuBarIconResourceName: String? {
        switch self {
        case .pi:   return nil           // SVG 不支持，由调用方用 SF Symbol 兑底
        case .trae: return "claude-logo" // 复用 claude logo（和吉祥物一致）
        default:    return "\(rawValue)-logo"
        }
    }

    /// 从 BridgeEnvelope 的 AgentProvider 推导默认吉祥物。
    /// Bridge 协议层目前只有少量顶层 provider；更细的 IDE/CLI profile 通过 hook 参数
    /// 进入会话元数据，菜单行展示时再按 session 信息补充品牌标签。
    public init(provider: AgentProvider) {
        switch provider {
        case .claude:  self = .claude
        case .codex:   self = .codex
        case .copilot: self = .copilot
        case .kimi:    self = .kimi
        case .gemini:  self = .gemini
        }
    }

    /// 默认门面：还没收到任何 hook 事件时，菜单里露脸的那只。
    public static let defaultIdle: MascotKind = .claude
}
