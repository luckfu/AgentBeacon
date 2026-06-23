import AppKit
import Foundation

/// 吉祥物的"心情"——从 hook 事件类型推导而来。
///
/// 原版 PingIsland 的 MascotStatus 有 4 种：idle / working / warning / dragging。
/// 轻量版砍掉 dragging，并把完成 / 错误拆成单独状态，方便顶部状态栏
/// 用系统风格的小状态点表达，不持续播放 GIF。
///
/// 顶部状态栏视觉策略：
/// - `idle`：静态吉祥物。
/// - `working`：蓝点轻微脉冲。
/// - `warning`：橙点闪烁。
/// - `error`：红点。
/// - `completed`：绿点短暂显示，随后由菜单控制器回落到 idle。
public enum MascotStatus: String, CaseIterable, Sendable {
    case idle
    case working
    case warning
    case error
    case completed

    /// 中文短描述，叠在吉祥物名字下方做副标题用。
    public var shortLabel: String {
        switch self {
        case .idle: return "待命中"
        case .working: return "工作中"
        case .warning: return "需要关注"
        case .error: return "出错"
        case .completed: return "已完成"
        }
    }

    public var menuBarDotColor: NSColor? {
        switch self {
        case .idle:
            return nil
        case .working:
            return .systemBlue
        case .warning:
            return .systemOrange
        case .error:
            return .systemRed
        case .completed:
            return .systemGreen
        }
    }

    /// 把 hook eventType（来自 Bridge 协议层的 `envelope.eventType` 字符串）
    /// 映射到 mascot 的"心情"。
    ///
    /// 映射规则（参考原版 `MascotStatus(from sessionPhase:)` 和
    /// `closedNotchStatus(...)`，按事件类型粗粒度推导）：
    /// - `Notification` / `UserPromptSubmit` / `PermissionRequest` / `ApprovalRequest`
    ///   → warning（用户得动手处理）
    /// - `PreToolUse` / `ToolResult` / `Compacting`
    ///   → working（Agent 正在干活）
    /// - `PostToolUseFailure` / `Error` → error
    /// - `PostToolUse` → working（工具刚结束，保持短暂活跃感）
    /// - `SessionEnd` / `Stop` / `Completed` → completed
    /// - `SessionStart` / 其他未知 → idle
    public init(eventType: String) {
        switch eventType {
        case "Notification",
             "UserPromptSubmit",
             "PermissionRequest",
             "ApprovalRequest":
            self = .warning
        case "PreToolUse",
             "PostToolUse",
             "ToolResult",
             "Compacting":
            self = .working
        case "PostToolUseFailure",
             "Error":
            self = .error
        case "SessionEnd",
             "Stop",
             "Completed":
            self = .completed
        default:
            // SessionStart / 未识别 一律按 idle 处理。
            self = .idle
        }
    }
}
