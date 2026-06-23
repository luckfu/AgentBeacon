import Foundation
import SwiftUI

/// lite 偏好持久化。
///
/// 设计取舍：
/// 1. **UserDefaults**：所有偏好用一个固定 suite，避免污染默认 domain；
///    不引 Codable，老老实实存原子类型 / String，方便老 macOS、方便 defaults 命令排查。
/// 2. **ObservableObject**：SwiftUI 偏好窗口直接 `@StateObject` / `@EnvironmentObject` 绑定。
/// 3. **单例 `shared`**：UserDefaults 本身就是全局态，套 ObservableObject 是为了 SwiftUI 才方便。
///    其他模块（NotificationSoundPlayer 等）读它的属性即可。
/// 4. **只读取一次默认值再做 didSet**：避免初始化阶段 didSet 反复写 UserDefaults。
///
/// 持久化的偏好（v1 设置面板范围）：
/// - 声音模式：mute / system / eightBit / themePack（themePack 占位，未启用）
/// - 是否在 hook 事件到达时弹原生通知（osascript display notification）
/// - 默认吉祥物（当没有 hook 进来时，菜单顶部露脸的 idle 门面）
@MainActor
public final class SettingsStore: ObservableObject {

    public static let shared = SettingsStore()

    // MARK: - UserDefaults Keys（集中常量，方便用 `defaults read` 排查）

    private enum Keys {
        static let soundMode = "lite.sound.mode"
        static let notificationEnabled = "lite.notification.systemBannerEnabled"
        static let defaultMascot = "lite.mascot.defaultIdle"
    }

    private let defaults: UserDefaults

    // MARK: - Published 偏好

    /// 声音模式。默认 8-bit（已经在前一阶段把 5 颗 .wav 打进资源包，主仓也是这套作出厂默认）。
    @Published public var soundMode: SoundMode {
        didSet {
            guard oldValue != soundMode else { return }
            defaults.set(soundMode.rawValue, forKey: Keys.soundMode)
        }
    }

    /// 是否弹系统横幅通知。默认开（lite 阶段一就是靠它兜底显示，不能关默认）。
    @Published public var systemBannerEnabled: Bool {
        didSet {
            guard oldValue != systemBannerEnabled else { return }
            defaults.set(systemBannerEnabled, forKey: Keys.notificationEnabled)
        }
    }

    /// 默认吉祥物（无活跃 hook 时菜单顶部那位）。
    /// rawValue 存到 UserDefaults；MascotKind 反序列化失败则回 defaultIdle。
    @Published public var defaultMascot: MascotKind {
        didSet {
            guard oldValue != defaultMascot else { return }
            defaults.set(defaultMascot.rawValue, forKey: Keys.defaultMascot)
        }
    }

    // MARK: - Init

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        // 读历史值；都没有就用默认。Published 不能在 init 之前发通知，因此先用 _xxx 形式写底层值。
        let modeRaw = defaults.string(forKey: Keys.soundMode) ?? SoundMode.eightBit.rawValue
        self.soundMode = SoundMode(rawValue: modeRaw) ?? .eightBit

        // .object(forKey:) 区分"没设过"和"设过 false"，避免覆盖用户主动关掉的状态。
        if let obj = defaults.object(forKey: Keys.notificationEnabled) as? Bool {
            self.systemBannerEnabled = obj
        } else {
            self.systemBannerEnabled = true
        }

        let mascotRaw = defaults.string(forKey: Keys.defaultMascot) ?? MascotKind.defaultIdle.rawValue
        self.defaultMascot = MascotKind(rawValue: mascotRaw) ?? .defaultIdle
    }
}

// MARK: - SoundMode

/// 声音模式枚举。
///
/// 与主仓 `PingIsland/Core/SoundPackCatalog.swift` 中 `SoundTheme`
/// 的三档（系统音 / Island8Bit / SoundPack）对齐，外加一档 `mute` 兜底关静音。
///
/// themePack 在 lite v1 仅占位（不在 UI 上启用），等 SoundPack 导入功能上线再放开。
public enum SoundMode: String, CaseIterable, Codable, Sendable {
    /// 全部静音。
    case mute
    /// macOS 系统音（Glass / Tink / Basso 那一套）。
    case system
    /// 主仓 island8Bit 复古风（5 颗 .wav 已随包发布）。
    case eightBit
    /// 主题包（lite v1 占位，尚未实现）。
    case themePack

    public var displayName: String {
        switch self {
        case .mute:      return "静音"
        case .system:    return "macOS 系统音"
        case .eightBit:  return "8-bit 复古"
        case .themePack: return "主题包（即将支持）"
        }
    }

    public var detail: String {
        switch self {
        case .mute:
            return "所有 hook 事件都不发声"
        case .system:
            return "用系统自带的 Glass / Tink / Basso 等提示音"
        case .eightBit:
            return "用主仓出厂默认的 8-bit 复古音效（开箱即用，与主仓一致）"
        case .themePack:
            return "导入第三方主题包（v1 暂未启用，先看 8-bit / 系统音）"
        }
    }

    /// 在设置面板上是否禁用单选项（v1 主题包占位禁用）。
    public var isDisabledInSettings: Bool {
        self == .themePack
    }
}
