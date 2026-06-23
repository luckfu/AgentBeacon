import AppKit
import Foundation

/// 把 hook eventType 映射到 5 种「语义事件」，再按 SoundMode 选音。
///
/// 设计取自主仓 `PingIsland/Core/SoundPackCatalog.swift` 中
/// `NotificationEvent`（开始处理 / 需要介入 / 完成 / 失败 / 资源受限）。
public enum NotificationSoundEvent: String, CaseIterable, Sendable {
    /// 工具开始/结束执行、阶段切换之类的「Agent 在干活」节奏点。
    case processingStarted
    /// 等审批、等回答、等用户点确认 —— 必须让用户立刻抬头那种。
    case attentionRequired
    /// 这一轮处理结束，回到等待下一条 prompt。
    case taskCompleted
    /// 工具或子代理执行失败。
    case taskError
    /// PreCompact / Compacting，上下文逼近上限。
    case resourceLimit

    /// 8-bit 音效文件名（不含扩展名）—— 跟主仓 `island8Bit` 模式下
    /// `_island8Bit*Sound` 的默认值一一对齐（参见 `PingIsland/Core/Settings.swift` 1406-1420）。
    /// .wav 资源从主仓 `PingIsland/Resources/Sounds/` 拷到本包的 `Resources/Sounds/`。
    var eightBitResourceName: String {
        switch self {
        case .processingStarted: return "8bit_menu_select"     // 对齐主仓 .menuSelect
        case .attentionRequired: return "8bit_approval_alert"   // 对齐主仓 .approvalAlert
        case .taskCompleted:     return "8bit_submit_blip"      // 对齐主仓 .submitBlip
        case .taskError:         return "8bit_hurt"             // 对齐主仓 .hurt
        case .resourceLimit:     return "8bit_complete_ding"    // 对齐主仓 .completeDing
        }
    }

    /// macOS 自带系统音名。挑的都是默认 NSSound 标准库里都存在的，
    /// 避免某些机型缺音导致放不出来。
    var systemSoundName: String {
        switch self {
        case .processingStarted: return "Tink"     // 短促节拍点
        case .attentionRequired: return "Glass"    // 清脆提醒
        case .taskCompleted:     return "Hero"     // 完成感
        case .taskError:         return "Basso"    // 低沉警示
        case .resourceLimit:     return "Funk"     // 略带紧张
        }
    }

    /// 把 Bridge 协议里的 `envelope.eventType` 字符串归到 5 类。
    /// 返回 nil 表示「这种事件不响声」（例如 SessionStart 静默上线）。
    public init?(eventType: String) {
        switch eventType {
        case "Notification",
             "PermissionRequest",
             "ApprovalRequest",
             "UserPromptSubmit":
            self = .attentionRequired
        case "PostToolUseFailure",
             "ToolError":
            self = .taskError
        case "Compacting",
             "PreCompact":
            self = .resourceLimit
        case "SessionEnd",
             "Stop":
            self = .taskCompleted
        case "PreToolUse",
             "PostToolUse",
             "ToolResult":
            self = .processingStarted
        default:
            // SessionStart 以及未识别事件类型 —— 默默走视觉提示就好，不要打扰。
            return nil
        }
    }
}

/// 极简播放器：按 hook 事件挑一颗音放出来。
///
/// 设计原则：
/// 1. 模式切换：`mode` 由 SettingsStore.soundMode 同步过来（mute / system / eightBit）。
/// 2. 0.8 秒去抖：PreToolUse + PostToolUse 经常连发，避免叮叮叮轰耳朵。
/// 3. `mute` / `themePack` 直接什么也不放（themePack 在 lite v1 尚未实现）。
/// 4. 内存缓存：8-bit 的 NSSound 加载一次后驻留，避免反复磁盘 IO。
public enum NotificationSoundPlayer {

    /// 当前声音模式。由 AppDelegate 启动时和 SettingsStore.soundMode 变更时同步过来。
    /// 默认 8-bit，跟主仓出厂默认一致。
    private static var _mode: SoundMode = .eightBit
    private static let modeLock = NSLock()

    /// 同一类事件的去抖窗口；窗口内重复事件直接忽略。
    private static let debounceWindow: TimeInterval = 0.8

    private static var lastPlayedAt: [String: Date] = [:]
    private static let lock = NSLock()

    /// 预加载的 NSSound 缓存：第一次 play 后留在内存。
    /// 系统音和 8-bit 共用同一张表，按 "mode-event" 组合 key 区分。
    private static var soundCache: [String: NSSound] = [:]
    private static let cacheLock = NSLock()

    /// 由 AppDelegate / SettingsStore 调用，更新当前模式。
    public static func setMode(_ mode: SoundMode) {
        modeLock.lock()
        _mode = mode
        modeLock.unlock()
    }

    public static var mode: SoundMode {
        modeLock.lock()
        defer { modeLock.unlock() }
        return _mode
    }

    /// 入口：交给 hook eventType 字符串即可。返回是否真的播放了。
    @discardableResult
    public static func play(eventType: String) -> Bool {
        let activeMode = mode
        // 静音 / 主题包占位 → 什么也不放。
        if activeMode == .mute || activeMode == .themePack { return false }
        guard let event = NotificationSoundEvent(eventType: eventType) else { return false }

        // 去抖：同一语义事件 0.8s 内不重复响。
        lock.lock()
        let now = Date()
        if let last = lastPlayedAt[event.rawValue],
           now.timeIntervalSince(last) < debounceWindow {
            lock.unlock()
            return false
        }
        lastPlayedAt[event.rawValue] = now
        lock.unlock()

        // NSSound 必须主线程调度，play() 内部异步真正放声。
        DispatchQueue.main.async {
            guard let sound = loadSound(for: event, mode: activeMode) else { return }
            // 如果上一波还在跟随播放要先 stop 再 play，避免重叠啸鸣。
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
        return true
    }

    /// 试听一颗音（设置面板「试听」按钮用）。绕开去抖，立即重放。
    public static func preview(event: NotificationSoundEvent, mode: SoundMode) {
        // mute / themePack 试听也不响。
        if mode == .mute || mode == .themePack { return }
        DispatchQueue.main.async {
            guard let sound = loadSound(for: event, mode: mode) else { return }
            if sound.isPlaying { sound.stop() }
            sound.play()
        }
    }

    // MARK: - 加载

    private static func loadSound(for event: NotificationSoundEvent, mode: SoundMode) -> NSSound? {
        let cacheKey = "\(mode.rawValue)-\(event.rawValue)"
        cacheLock.lock()
        defer { cacheLock.unlock() }
        if let cached = soundCache[cacheKey] { return cached }

        let sound: NSSound?
        switch mode {
        case .system:
            sound = NSSound(named: NSSound.Name(event.systemSoundName))
        case .eightBit:
            sound = loadEightBit(for: event)
        case .mute, .themePack:
            return nil
        }
        if let s = sound {
            soundCache[cacheKey] = s
        }
        return sound
    }

    /// 从 SwiftPM 资源包加载 8-bit .wav。
    private static func loadEightBit(for event: NotificationSoundEvent) -> NSSound? {
        guard let url = Bundle.module.url(
            forResource: event.eightBitResourceName,
            withExtension: "wav",
            subdirectory: "Sounds"
        ) ?? Bundle.module.url(
            forResource: event.eightBitResourceName,
            withExtension: "wav"
        ) else {
            return nil
        }
        return NSSound(contentsOf: url, byReference: false)
    }
}
