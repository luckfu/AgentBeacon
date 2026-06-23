import SwiftUI
import AppKit

/// lite 偏好窗口主视图（独立 NSWindow，不依赖刘海 / 不依赖菜单栏 Popover）。
///
/// 三个 tab，跟主仓 SettingsWindowView 的"General / Mascot / Sound"分组对齐，
/// 但每个 tab 内的项目数量大幅精简——lite 阶段一只暴露真正需要的开关。
struct SettingsView: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        TabView {
            GeneralTab(store: store)
                .tabItem { Label("通用", systemImage: "gearshape") }
                .tag(0)

            MascotTab(store: store)
                .tabItem { Label("吉祥物", systemImage: "face.smiling") }
                .tag(1)

            SoundTab(store: store)
                .tabItem { Label("声音", systemImage: "speaker.wave.2") }
                .tag(2)
        }
        .padding(20)
        .frame(width: 520, height: 420)
    }
}

// MARK: - General

private struct GeneralTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Label("通知", systemImage: "bell")) {
                Toggle("hook 事件到达时弹系统横幅通知", isOn: $store.systemBannerEnabled)
                    .toggleStyle(.switch)
                Text("使用 osascript display notification 兜底弹原生通知。\n关掉后菜单栏图标和声音仍然工作。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, 4)

            GroupBox(label: Label("Bridge", systemImage: "link")) {
                Text(bridgeStatus)
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer()
        }
    }

    private var bridgeStatus: String {
        if let path = BridgeBinaryLocator.locateOrNil() {
            return "PingIslandBridge：\(path)"
        }
        return "PingIslandBridge：未找到。请先 `swift build -c release`。"
    }
}

// MARK: - Mascot

private struct MascotTab: View {
    @ObservedObject var store: SettingsStore

    /// 用户可选的"默认吉祥物"门面 —— 14 个全展开（与菜单栏 mascot 列表保持一致）。
    private let allMascots: [MascotKind] = MascotKind.allCases

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("当 hook 还没进来、菜单顶部需要露脸时，默认显示这位吉祥物。")
                .font(.caption)
                .foregroundColor(.secondary)

            // 网格：每行 4 个，14 个吉祥物 → 4 行
            ScrollView {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 4), spacing: 12) {
                    ForEach(allMascots, id: \.rawValue) { kind in
                        MascotPickerCell(kind: kind, isSelected: store.defaultMascot == kind) {
                            store.defaultMascot = kind
                        }
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }
}

/// 单个吉祥物头像格。带 GIF 动画 + 选中描边。
private struct MascotPickerCell: View {
    let kind: MascotKind
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                MascotGIFView(kind: kind)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.08))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
                    )
                Text(kind.displayName)
                    .font(.caption2)
                    .foregroundColor(isSelected ? .accentColor : .secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
    }
}

/// 把 AppKit 的 MascotImageView 包成 SwiftUI 视图。
private struct MascotGIFView: NSViewRepresentable {
    let kind: MascotKind

    func makeNSView(context: Context) -> MascotImageView {
        MascotImageView(kind: kind, status: .idle, mascotSize: 56, showsTitle: false)
    }

    func updateNSView(_ nsView: MascotImageView, context: Context) {
        // ForEach 里每个 cell 的 kind 是固定的（id 就是 rawValue），
        // 实际不会走这里。MascotImageView 现在也不暴露可变接口，留空。
    }
}

// MARK: - Sound

private struct SoundTab: View {
    @ObservedObject var store: SettingsStore

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            GroupBox(label: Label("声音模式", systemImage: "music.note")) {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(SoundMode.allCases, id: \.rawValue) { mode in
                        modeRow(mode)
                    }
                }
                .padding(.vertical, 4)
            }

            GroupBox(label: Label("试听", systemImage: "play.circle")) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("点按下面任意一颗，立刻听当前模式（\(store.soundMode.displayName)）下对应的音。")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    HStack(spacing: 8) {
                        ForEach(NotificationSoundEvent.allCases, id: \.rawValue) { event in
                            Button(eventShortLabel(event)) {
                                NotificationSoundPlayer.preview(event: event, mode: store.soundMode)
                            }
                            .buttonStyle(.bordered)
                            .disabled(store.soundMode == .mute || store.soundMode == .themePack)
                        }
                    }
                }
                .padding(.vertical, 4)
            }

            Spacer()
        }
    }

    @ViewBuilder
    private func modeRow(_ mode: SoundMode) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: store.soundMode == mode ? "largecircle.fill.circle" : "circle")
                .foregroundColor(store.soundMode == mode ? .accentColor : .secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(mode.displayName)
                    .foregroundColor(mode.isDisabledInSettings ? .secondary : .primary)
                Text(mode.detail)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            guard !mode.isDisabledInSettings else { return }
            store.soundMode = mode
        }
        .opacity(mode.isDisabledInSettings ? 0.55 : 1.0)
    }

    private func eventShortLabel(_ event: NotificationSoundEvent) -> String {
        switch event {
        case .processingStarted: return "处理中"
        case .attentionRequired: return "需关注"
        case .taskCompleted:     return "完成"
        case .taskError:         return "失败"
        case .resourceLimit:     return "资源紧"
        }
    }
}
