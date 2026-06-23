import Foundation
import IslandShared

/// 把 hook 事件以"原生通知"形式呈现给用户。
///
/// 阶段 1 实现策略（务实优先，能看见为王）：
/// 1. 控制台 print（Debug，永远能看）
/// 2. 调用菜单栏 controller 更新事件计数 / 预览（永远能看）
/// 3. 用 `osascript display notification` 兜底弹系统通知
///    —— 这是 `swift run` 调试模式下的"曲线救国"：因为非 .app bundle 进程
///    在 macOS 11+ 上无法直接调 UNUserNotificationCenter 显示通知。
///    阶段 4 打包成 .app 后会切回 UNUserNotificationCenter。
///
/// 所有方法都是非阻塞的，可以从 socket actor 里安全调用。
final class NotificationCenterClient: @unchecked Sendable {

    /// 上层把菜单栏 controller 注入进来，让通知器顺带更新菜单栏 UI。
    /// 用 weak 引用避免循环引用——controller 由 AppDelegate 持有。
    weak var menuBarController: MenuBarController?
    private let sessionStore: SessionStoreLite

    init(menuBarController: MenuBarController? = nil, sessionStore: SessionStoreLite = .shared) {
        self.menuBarController = menuBarController
        self.sessionStore = sessionStore
    }

    func deliver(envelope: BridgeEnvelope) {
        // 层 1：控制台打印（开发期最可靠）
        Self.printToConsole(envelope: envelope)

        // 层 2：菜单栏更新（同步主线程更新，因为 MenuBarController 操作 NSStatusItem）
        let title = Self.formatTitle(envelope: envelope)
        let preview = Self.formatPreview(envelope: envelope)
        let summary = "\(title) — \(preview)"
        let snapshot = sessionStore.record(envelope)
        let controller = menuBarController
        DispatchQueue.main.async {
            controller?.recordEvent(summary: summary, snapshot: snapshot)
        }

        // 层 3：声音提示（按 5 态语义映射；带 0.8s 去抖避免轰耳朵；模式读 SettingsStore.soundMode）
        NotificationSoundPlayer.play(eventType: envelope.eventType)

        // 层 4：osascript 兜底弹系统通知（受偏好面板 systemBannerEnabled 控制）
        if Self.shouldFireSystemBanner() {
            Self.fireSystemNotification(title: title, body: preview)
        }
    }
    
    /// 本地缓存 systemBanner 开关。SettingsStore 是 @MainActor，
    /// 但 deliver 会被 socket actor / 后台线程调。于是 AppDelegate 启动时同步初值 +
    /// 推 store.$systemBannerEnabled 变动时 sink 进来。读取走 NSLock，跨线程安全。
    private static var _systemBannerEnabled: Bool = true
    private static let bannerLock = NSLock()
    
    static func setSystemBannerEnabled(_ enabled: Bool) {
        bannerLock.lock(); defer { bannerLock.unlock() }
        _systemBannerEnabled = enabled
    }
    
    private static func shouldFireSystemBanner() -> Bool {
        bannerLock.lock(); defer { bannerLock.unlock() }
        return _systemBannerEnabled
    }

    // MARK: - 文案格式化

    /// "Claude Code · PreToolUse" / "Codex · SessionStart" 这种紧凑标题
    private static func formatTitle(envelope: BridgeEnvelope) -> String {
        let providerLabel: String
        switch envelope.provider {
        case .claude: providerLabel = "Claude Code"
        case .codex: providerLabel = "Codex"
        case .copilot: providerLabel = "Copilot"
        case .kimi: providerLabel = "Kimi"
        case .gemini: providerLabel = "Gemini"
        }
        return "\(providerLabel) · \(envelope.eventType)"
    }

    /// 优先 title → preview → "(no detail)"
    private static func formatPreview(envelope: BridgeEnvelope) -> String {
        if let t = envelope.title, !t.isEmpty { return t }
        if let p = envelope.preview, !p.isEmpty { return p }
        return "(no detail)"
    }

    // MARK: - 各层实现

    private static func printToConsole(envelope: BridgeEnvelope) {
        // 拼成单行日志方便扫，避免长 transcript 把终端淹了。
        let line = "[hook] \(envelope.provider.rawValue) | \(envelope.eventType) | session=\(envelope.sessionKey) | title=\(envelope.title ?? "-")"
        FileHandle.standardError.write(Data((line + "\n").utf8))
    }

    /// 通过 `osascript -e 'display notification ...'` 弹原生通知。
    ///
    /// 为什么不直接用 UNUserNotificationCenter：
    ///   非 .app bundle 进程在 macOS 11+ 调 UN center.add(...) 不会显示，
    ///   因为系统找不到对应的 bundle 来登记通知权限。osascript 由系统自带的
    ///   AppleScript runtime 触发，权限走的是另一条路径，可以正常显示。
    private static func fireSystemNotification(title: String, body: String) {
        let escapedTitle = escape(title)
        let escapedBody = escape(body)
        let script = "display notification \"\(escapedBody)\" with title \"AgentBeacon\" subtitle \"\(escapedTitle)\""

        let task = Process()
        task.launchPath = "/usr/bin/osascript"
        task.arguments = ["-e", script]
        // 静默掉 stdout/stderr 噪音，失败也不影响主流程。
        task.standardOutput = Pipe()
        task.standardError = Pipe()
        do {
            try task.run()
            // 不 wait——通知 fire-and-forget。
        } catch {
            // 失败时降级到控制台，至少不丢事件。
            FileHandle.standardError.write(Data("[notify-fallback] \(title): \(body)\n".utf8))
        }
    }

    /// 用最小集合转义防 AppleScript 注入：双引号、反斜杠、换行
    private static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
    }
}
