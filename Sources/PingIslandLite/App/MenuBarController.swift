import AppKit
import Foundation
import IslandShared

/// 菜单栏图标控制器。
///
/// 这是用户在 macOS 12 上唯一能看见 AgentBeacon 的入口——
/// 屏幕右上角菜单栏里那个小图标。点它会弹出菜单。
///
/// 当前实现：动态图标 + 会话计数 + 最近活动列表 + 吉祥物状态展示。
///
/// 之所以用 `NSStatusItem` 而不是 SwiftUI 的 `MenuBarExtra`：
/// `MenuBarExtra` 是 macOS 13+ API，本项目目标 macOS 12，必须使用 AppKit 老 API。
final class MenuBarController {

    typealias ApprovalResponder = @Sendable (UUID, InterventionDecision, String?) -> Void

    private var statusItem: NSStatusItem?
    private var approvalResponder: ApprovalResponder?

    // MARK: - 事件展示状态

    private var sessionSnapshot = SessionStoreLite.Snapshot(sessions: [], totalEventCount: 0)
    private var resolvedApprovalIDs: Set<UUID> = []
    private var codexUsageSnapshot: CodexUsageLiteSnapshot?

    /// 当前在菜单顶部露脸的吉祥物。默认 idle 门面；hook 事件到达后按 provider 切换。
    private var currentMascot: MascotKind = .defaultIdle
    private var defaultMascot: MascotKind = .defaultIdle

    /// 吉祥物的当前心情。默认 idle；按 hook eventType 推导（工作中 / 需要关注 / 待命）。
    private var currentStatus: MascotStatus = .idle
    private var statusDotPulseOn = true
    private var statusDotTimer: Timer?
    private var completedResetTimer: Timer?
    private var workingResetTimer: Timer?

    /// 启动菜单栏图标。必须在主线程调用。
    func start() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item

        configureButton(item.button)
        refreshCodexUsage()
        item.menu = buildMenu()
    }

    func setApprovalResponder(_ responder: @escaping ApprovalResponder) {
        approvalResponder = responder
    }

    func setDefaultMascot(_ mascot: MascotKind) {
        defaultMascot = mascot
        guard sessionSnapshot.totalEventCount == 0 else { return }
        currentMascot = mascot
        refreshUI()
    }

    /// 停止并移除菜单栏图标。
    func stop() {
        if let item = statusItem {
            NSStatusBar.system.removeStatusItem(item)
        }
        statusItem = nil
    }

    /// 上层（NotificationCenterClient）每次收到 hook 事件时调用。
    /// 必须在主线程调用——NSStatusItem 不是线程安全的。
    func recordEvent(summary: String, snapshot: SessionStoreLite.Snapshot) {
        sessionSnapshot = snapshot
        refreshCodexUsage()
        guard let latest = snapshot.sessions.max(by: { $0.lastSeenAt < $1.lastSeenAt }) else {
            refreshUI()
            return
        }
        // 最近一次事件出自哪家 Agent，菜单里露脸的就是那家的吉祥物。
        currentMascot = MascotKind(provider: latest.provider)
        // PreToolUse → 工作中，Notification → 需要关注，SessionStart → 待命。
        currentStatus = MascotStatus(eventType: latest.latestEnvelope.eventType)
        scheduleStatusTimers(for: currentStatus)
        refreshUI()
    }

    /// 重置计数（菜单"清空记录"项使用）。
    @objc private func resetEvents() {
        sessionSnapshot = SessionStoreLite.shared.clear()
        currentMascot = defaultMascot
        currentStatus = .idle
        stopStatusTimers()
        refreshUI()
    }

    @objc private func menuActionRespondToApproval(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? ApprovalMenuCommand else { return }
        resolvedApprovalIDs.insert(command.requestID)
        approvalResponder?(command.requestID, command.decision, command.reason)
        refreshUI()
    }

    /// 点击"最近事件"行 → 跳回对应终端 / IDE。
    /// representedObject 存索引；representedObject 内容必须是 NSNumber 才能跨菜单存活。
    @objc private func menuActionFocusRecent(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue,
              index >= 0, index < sessionSnapshot.sessions.count else { return }
        focusRecent(at: index)
    }

    @objc private func menuActionOpenSessionDetail(_ sender: NSMenuItem) {
        guard let index = (sender.representedObject as? NSNumber)?.intValue,
              index >= 0, index < sessionSnapshot.sessions.count else { return }
        Task { @MainActor in
            SessionDetailWindowController.shared.show(session: sessionSnapshot.sessions[index])
        }
    }

    private func focusRecent(at index: Int) {
        guard index >= 0, index < sessionSnapshot.sessions.count else { return }
        let envelope = sessionSnapshot.sessions[index].latestEnvelope
        // TerminalFocuser 内部已经处理主线程切换，这里只管投递。
        Task.detached {
            await TerminalFocuser.focus(envelope)
        }
    }

    // MARK: - Hooks install/uninstall

    /// 构建 Hooks 子菜单。数据驱动：遍历 Provider.allCases，按 kind 分组渲染。
    /// 17 家太多，直接纵列会超屏，于是重新按 kind 平铺出 5 组 sub-submenu：
    /// - Claude-compatible JSON hooks（大多数）
    /// - Plugin file / directory / hook directory（非 JSON）
    /// - TOML hooks（Kimi）
    private func buildHooksSubmenu() -> NSMenu {
        let submenu = NSMenu(title: "Hooks 安装")

        let groups: [(String, [HookInstaller.Provider])] = [
            ("JSON hooks", HookInstaller.Provider.allCases.filter { $0.kind == .jsonHooks }),
            ("Plugin (文件 / 目录)", HookInstaller.Provider.allCases.filter {
                $0.kind == .pluginFile || $0.kind == .pluginDirectory || $0.kind == .hookDirectory
            }),
            ("TOML hooks", HookInstaller.Provider.allCases.filter { $0.kind == .tomlHooks }),
        ]

        for (groupTitle, providers) in groups where !providers.isEmpty {
            let header = NSMenuItem(title: "— \(groupTitle) —", action: nil, keyEquivalent: "")
            header.isEnabled = false
            submenu.addItem(header)

            for provider in providers {
                let entry = NSMenuItem(title: providerMenuTitle(provider), action: nil, keyEquivalent: "")
                entry.submenu = providerActionsMenu(for: provider)
                submenu.addItem(entry)
            }
            submenu.addItem(.separator())
        }

        // 底部露出 bridge 路径
        let bridgePathText: String
        if let path = BridgeBinaryLocator.locateOrNil() {
            bridgePathText = "Bridge: \(path)"
        } else {
            bridgePathText = "Bridge: 未找到（请先 swift build -c release）"
        }
        let bridgeRow = NSMenuItem(title: bridgePathText, action: nil, keyEquivalent: "")
        bridgeRow.isEnabled = false
        submenu.addItem(bridgeRow)

        return submenu
    }

    /// 单 provider 在主子菜单中的显示名：名称 + 状态小纯文本。
    private func providerMenuTitle(_ provider: HookInstaller.Provider) -> String {
        let suffix: String
        switch HookInstaller.status(provider) {
        case .notInstalled:           suffix = "未安装"
        case .installed:              suffix = "已安装 ✓"
        case .staleBridgePath:        suffix = "Bridge 路径已变"
        }
        return "\(provider.displayName)  ·  \(suffix)"
    }

    /// 单 provider 的安装/卸载动作子菜单。
    private func providerActionsMenu(for provider: HookInstaller.Provider) -> NSMenu {
        let menu = NSMenu(title: provider.displayName)

        let hint = NSMenuItem(title: "配置路径：~/\(provider.settingsRelativePath)", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        menu.addItem(.separator())

        let installItem = NSMenuItem(
            title: "安装 / 更新",
            action: #selector(menuActionInstall(_:)),
            keyEquivalent: ""
        )
        installItem.target = self
        installItem.representedObject = provider.rawValue
        menu.addItem(installItem)

        let uninstallItem = NSMenuItem(
            title: "卸载",
            action: #selector(menuActionUninstall(_:)),
            keyEquivalent: ""
        )
        uninstallItem.target = self
        uninstallItem.representedObject = provider.rawValue
        if case .notInstalled = HookInstaller.status(provider) {
            uninstallItem.isEnabled = false
        }
        menu.addItem(uninstallItem)

        return menu
    }

    @objc private func menuActionInstall(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = HookInstaller.Provider(rawValue: raw) else { return }
        runInstall(provider)
    }

    @objc private func menuActionUninstall(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let provider = HookInstaller.Provider(rawValue: raw) else { return }
        runUninstall(provider)
    }

    /// 打开偏好设置窗口。
    /// SettingsWindowController.shared 是 @MainActor 单例；菜单 action 默认在主线程触发。
    /// Swift 隔离检查要求从 nonisolated 跳 MainActor 需要显式 Task。
    @objc private func menuActionOpenSettings() {
        Task { @MainActor in
            SettingsWindowController.shared.show()
        }
    }

    private func runInstall(_ provider: HookInstaller.Provider) {
        do {
            let bridgePath = try HookInstaller.install(provider)
            showAlert(
                title: "已安装 \(provider.displayName) hooks",
                message: "配置路径：~/\(provider.settingsRelativePath)\nBridge：\(bridgePath)\n\n下次启动 \(provider.displayName) 即可看到 lite 接收事件。"
            )
        } catch {
            showAlert(title: "\(provider.displayName) 安装失败", message: String(describing: error), style: .warning)
        }
        refreshUI()
    }

    private func runUninstall(_ provider: HookInstaller.Provider) {
        do {
            try HookInstaller.uninstall(provider)
            showAlert(
                title: "已卸载 \(provider.displayName) hooks",
                message: provider.uninstallPreservedHint
            )
        } catch {
            showAlert(title: "\(provider.displayName) 卸载失败", message: String(describing: error), style: .warning)
        }
        refreshUI()
    }

    /// 给最近事件行生成 tooltip：露出准备跳到哪种终端 / IDE / tmux。
    /// 让用户在点之前心里有数（避免点了发现根本没起反应）。
    private func focusTooltip(for envelope: BridgeEnvelope) -> String {
        let ctx = envelope.terminalContext
        if let tmux = ctx.tmuxSession, !tmux.isEmpty {
            let pane = ctx.tmuxPane.map { ".\($0)" } ?? ""
            return "跳回 tmux：\(tmux)\(pane)"
        }
        if let ide = ctx.ideName, !ide.isEmpty {
            return "激活 IDE：\(ide)"
        }
        if let term = ctx.terminalProgram, !term.isEmpty {
            if let tty = ctx.tty, !tty.isEmpty {
                return "跳回 \(term)（tty=\(tty)）"
            }
            return "跳回 \(term)"
        }
        return "跳回最后一次活跃的终端 / IDE"
    }

    private func showAlert(title: String, message: String, style: NSAlert.Style = .informational) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = style
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    // MARK: - UI 刷新

    private func refreshUI() {
        guard let item = statusItem else { return }
        // 图标旁带个小数字，让用户瞥一眼就知道有几条新事件。
        if let button = item.button {
            button.title = sessionSnapshot.totalEventCount > 0 ? " \(sessionSnapshot.totalEventCount)" : ""
            // 顶部状态栏图标用静态吉祥物 + 小状态点表达运行态，避免 GIF 在系统状态项里抢注意力。
            button.image = loadStatusBarIcon(for: currentMascot, status: currentStatus)
        }
        item.menu = buildMenu()
    }

    private func refreshCodexUsage() {
        codexUsageSnapshot = CodexUsageLiteLoader.load()
    }

    /// 菜单栏图标缓存。裁透明边要扫像素，每个 kind 只扫一次。
    private var iconCache: [MascotKind: NSImage] = [:]

    /// 按 MascotKind 加载菜单栏小图标。多一层兑底：
    /// 1. 存在 PNG 资源 → 读出来 + 裁透明边 + 缩到 22×22。
    /// 2. PNG 不存在（如 Pi）→ SF Symbol “p.circle”。
    /// 3. 连 SF Symbol 都拿不到 → 默认 “circle.dashed”。
    private func loadStatusBarIcon(for kind: MascotKind, status: MascotStatus) -> NSImage? {
        guard let base = loadMenuBarIcon(for: kind) else { return nil }
        guard let dotColor = status.menuBarDotColor else { return base }

        let dotAlpha: CGFloat
        switch status {
        case .working:
            dotAlpha = statusDotPulseOn ? 0.95 : 0.45
        case .warning:
            dotAlpha = statusDotPulseOn ? 1 : 0.15
        default:
            dotAlpha = 1
        }

        let size = NSSize(width: 24, height: 22)
        let image = NSImage(size: size)
        image.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .none

        base.draw(in: NSRect(x: 1, y: 0, width: 22, height: 22))

        let dotRect = NSRect(x: 15.5, y: 13.5, width: 8, height: 8)
        NSColor.white.withAlphaComponent(0.92).setFill()
        NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5)).fill()
        NSColor.black.withAlphaComponent(0.18).setStroke()
        let ring = NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.5, dy: -1.5))
        ring.lineWidth = 0.8
        ring.stroke()
        dotColor.withAlphaComponent(dotAlpha).setFill()
        NSBezierPath(ovalIn: dotRect).fill()

        image.unlockFocus()
        image.isTemplate = false
        return image
    }

    private func loadMenuBarIcon(for kind: MascotKind) -> NSImage? {
        if let cached = iconCache[kind] {
            return cached
        }

        // 22×22 是 macOS 菜单栏完整高度。
        let menuBarIconSize = NSSize(width: 22, height: 22)

        if let resourceName = kind.menuBarIconResourceName,
           let url = Bundle.module.url(forResource: resourceName, withExtension: "png"),
           let raw = NSImage(contentsOf: url) {
            // 关键一步：裁掉透明边距。Gemini / Copilot 这种原图四周
            // 带大量空白，不裁的话 22×22 里主体只占中间一小块。
            let trimmed = trimTransparentBorder(raw)
            trimmed.size = menuBarIconSize
            // 保留品牌色：不设 isTemplate，继续呈原色。
            iconCache[kind] = trimmed
            return trimmed
        }

        // 兑底 1：Pi 用 “p.circle”。
        if kind == .pi,
           let symbol = NSImage(systemSymbolName: "p.circle", accessibilityDescription: "Pi") {
            symbol.isTemplate = true
            iconCache[kind] = symbol
            return symbol
        }

        // 兑底 2：默认虚线圈。
        let fallback = NSImage(systemSymbolName: "circle.dashed", accessibilityDescription: "AgentBeacon")
        fallback?.isTemplate = true
        return fallback
    }

    private func scheduleStatusTimers(for status: MascotStatus) {
        stopStatusTimers()
        statusDotPulseOn = true

        switch status {
        case .working, .warning:
            statusDotTimer = Timer.scheduledTimer(withTimeInterval: status == .working ? 0.75 : 0.45, repeats: true) { [weak self] _ in
                guard let self = self else { return }
                self.statusDotPulseOn.toggle()
                self.refreshUI()
            }
            if status == .working {
                workingResetTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: false) { [weak self] _ in
                    guard let self = self else { return }
                    guard self.currentStatus == .working else { return }
                    self.currentStatus = .idle
                    self.refreshUI()
                }
            }
        case .completed:
            completedResetTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: false) { [weak self] _ in
                guard let self = self else { return }
                guard self.currentStatus == .completed else { return }
                self.currentStatus = .idle
                self.refreshUI()
            }
        default:
            break
        }
    }

    private func stopStatusTimers() {
        statusDotTimer?.invalidate()
        statusDotTimer = nil
        completedResetTimer?.invalidate()
        completedResetTimer = nil
        workingResetTimer?.invalidate()
        workingResetTimer = nil
        statusDotPulseOn = true
    }

    /// 扫像素 alpha 通道找到不透明区域的 bounding box，裁出中间主体。
    /// stride=2 采样 → 1024×1024 原图扫描量约 26 万次，几十毫秒内完成。
    private func trimTransparentBorder(_ image: NSImage) -> NSImage {
        guard let tiff = image.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff) else {
            return image
        }
        let w = rep.pixelsWide
        let h = rep.pixelsHigh
        var minX = w, minY = h, maxX = -1, maxY = -1
        let alphaThreshold: CGFloat = 0.05
        let stride = 2
        var y = 0
        while y < h {
            var x = 0
            while x < w {
                if let color = rep.colorAt(x: x, y: y), color.alphaComponent > alphaThreshold {
                    if x < minX { minX = x }
                    if y < minY { minY = y }
                    if x > maxX { maxX = x }
                    if y > maxY { maxY = y }
                }
                x += stride
            }
            y += stride
        }
        guard maxX > minX, maxY > minY else { return image }

        // 加 2px padding 防贴边。
        let pad = 2
        let cropX = max(0, minX - pad)
        let cropY = max(0, minY - pad)
        let cropW = min(w - cropX, maxX - minX + pad * 2)
        let cropH = min(h - cropY, maxY - minY + pad * 2)

        guard let cgImage = rep.cgImage else { return image }
        // CGImage 坐标原点在左上，和 NSBitmapImageRep 一致（colorAt y 也从上到下）。
        let cropRect = CGRect(x: cropX, y: cropY, width: cropW, height: cropH)
        guard let cropped = cgImage.cropping(to: cropRect) else { return image }

        return NSImage(cgImage: cropped, size: NSSize(width: cropW, height: cropH))
    }

    // MARK: - Button

    private func configureButton(_ button: NSStatusBarButton?) {
        guard let button = button else { return }
    
        // 初始图标走 loadStatusBarIcon 同一条路径；AppDelegate 随后会把用户设置的
        // 默认吉祥物同步进 currentMascot。hook 事件到达后 refreshUI 会跟着切。
        button.image = loadStatusBarIcon(for: currentMascot, status: currentStatus)
        button.toolTip = "AgentBeacon"
        button.imagePosition = .imageLeading
    }

    // MARK: - Menu

    private func buildMenu() -> NSMenu {
        let menu = NSMenu(title: "AgentBeacon")

        // 吉祥物面板（菜单顶部一个 custom view item）。
        // 每次重建菜单都新建一个 MascotImageView 实例：GIF decode 代价很小，
        // 而复用同一个实例会因 NSMenuItem reparent 让 NSImageView 的 GIF 动画停掉。
        let mascotItem = NSMenuItem()
        mascotItem.view = MascotImageView(kind: currentMascot, status: currentStatus, mascotSize: 64)
        mascotItem.isEnabled = false
        menu.addItem(mascotItem)

        menu.addItem(.separator())

        // 状态行
        let statusTitle: String
        if sessionSnapshot.totalEventCount == 0 {
            statusTitle = "AgentBeacon · 待命中（等候 hook 事件）"
        } else {
            statusTitle = "AgentBeacon · \(sessionSnapshot.sessions.count) 个会话 · \(sessionSnapshot.totalEventCount) 条 hook 事件"
        }
        let statusRow = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusRow.isEnabled = false
        menu.addItem(statusRow)

        if let codexUsageSnapshot {
            let usageRow = NSMenuItem(title: codexUsageSnapshot.compactSummary, action: nil, keyEquivalent: "")
            usageRow.isEnabled = false
            menu.addItem(usageRow)
        }

        menu.addItem(.separator())

        // 最近会话 / 活动列表
        if sessionSnapshot.sessions.isEmpty {
            let placeholder = NSMenuItem(title: "（暂无事件）", action: nil, keyEquivalent: "")
            placeholder.isEnabled = false
            menu.addItem(placeholder)
        } else {
            let header = NSMenuItem(title: "最近活动（点击跳回终端 / IDE）：", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for (index, session) in sessionSnapshot.sessions.prefix(7).enumerated() {
                let row = NSMenuItem(
                    title: "",
                    action: #selector(menuActionFocusRecent(_:)),
                    keyEquivalent: ""
                )
                row.target = self
                row.representedObject = NSNumber(value: index)
                row.view = ActivityMenuRowView(session: session) { [weak self] in
                    self?.focusRecent(at: index)
                }
                // tooltip 露一下要跳到哪个终端，避免点之前盲跳。
                row.toolTip = focusTooltip(for: session.latestEnvelope)
                if session.expectsResponse {
                    row.submenu = buildApprovalSubmenu(for: session, index: index)
                    row.action = nil
                } else {
                    row.submenu = buildSessionSubmenu(for: session, index: index)
                    row.action = nil
                }
                menu.addItem(row)
            }
            let clear = NSMenuItem(title: "清空记录", action: #selector(resetEvents), keyEquivalent: "")
            clear.target = self
            menu.addItem(clear)
        }

        menu.addItem(.separator())

        // Hooks 安装管理子菜单。lite-8a 阶段先只支持 Claude Code，
        // 后续刀会扩 Codex / Gemini / 等其他 13 家。
        let hooksItem = NSMenuItem(title: "Hooks 安装", action: nil, keyEquivalent: "")
        hooksItem.submenu = buildHooksSubmenu()
        menu.addItem(hooksItem)

        // 偏好设置入口（独立 NSWindow，TabView 三 tab：通用 / 吉祥物 / 声音）。
        // 用 ⌘, 是 macOS 系偏好的统一约定。
        let prefsItem = NSMenuItem(
            title: "偏好设置…",
            action: #selector(menuActionOpenSettings),
            keyEquivalent: ","
        )
        prefsItem.target = self
        menu.addItem(prefsItem)

        menu.addItem(.separator())

        menu.addItem(NSMenuItem(
            title: "关于 AgentBeacon",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        ))

        let quitItem = NSMenuItem(
            title: "退出",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )
        menu.addItem(quitItem)

        return menu
    }

    private func buildApprovalSubmenu(for session: SessionStoreLite.SessionSnapshot, index: Int) -> NSMenu {
        let menu = NSMenu(title: session.title)

        let detail = NSMenuItem(
            title: "查看详情",
            action: #selector(menuActionOpenSessionDetail(_:)),
            keyEquivalent: ""
        )
        detail.target = self
        detail.representedObject = NSNumber(value: index)
        menu.addItem(detail)

        let focus = NSMenuItem(
            title: "跳回终端 / IDE",
            action: #selector(menuActionFocusRecent(_:)),
            keyEquivalent: ""
        )
        focus.target = self
        focus.representedObject = NSNumber(value: index)
        focus.toolTip = focusTooltip(for: session.latestEnvelope)
        menu.addItem(focus)
        menu.addItem(.separator())

        if resolvedApprovalIDs.contains(session.latestEnvelope.id) {
            let resolved = NSMenuItem(title: "已响应", action: nil, keyEquivalent: "")
            resolved.isEnabled = false
            menu.addItem(resolved)
            return menu
        }

        addApprovalItem(
            title: "批准",
            decision: .approve,
            reason: nil,
            requestID: session.latestEnvelope.id,
            to: menu
        )
        addApprovalItem(
            title: "拒绝",
            decision: .deny,
            reason: "Denied from AgentBeacon",
            requestID: session.latestEnvelope.id,
            to: menu
        )
        addApprovalItem(
            title: "取消",
            decision: .cancel,
            reason: "Cancelled from AgentBeacon",
            requestID: session.latestEnvelope.id,
            to: menu
        )

        return menu
    }

    private func buildSessionSubmenu(for session: SessionStoreLite.SessionSnapshot, index: Int) -> NSMenu {
        let menu = NSMenu(title: session.title)

        let detail = NSMenuItem(
            title: "查看详情",
            action: #selector(menuActionOpenSessionDetail(_:)),
            keyEquivalent: ""
        )
        detail.target = self
        detail.representedObject = NSNumber(value: index)
        menu.addItem(detail)

        let focus = NSMenuItem(
            title: "跳回终端 / IDE",
            action: #selector(menuActionFocusRecent(_:)),
            keyEquivalent: ""
        )
        focus.target = self
        focus.representedObject = NSNumber(value: index)
        focus.toolTip = focusTooltip(for: session.latestEnvelope)
        menu.addItem(focus)

        return menu
    }

    private func addApprovalItem(
        title: String,
        decision: InterventionDecision,
        reason: String?,
        requestID: UUID,
        to menu: NSMenu
    ) {
        let item = NSMenuItem(
            title: title,
            action: #selector(menuActionRespondToApproval(_:)),
            keyEquivalent: ""
        )
        item.target = self
        item.representedObject = ApprovalMenuCommand(
            requestID: requestID,
            decision: decision,
            reason: reason
        )
        menu.addItem(item)
    }

    private final class ActivityMenuRowView: NSView {
        private let onClick: () -> Void

        init(session: SessionStoreLite.SessionSnapshot, onClick: @escaping () -> Void) {
            self.onClick = onClick
            let rowWidth: CGFloat = 560
            let rowHeight: CGFloat = 94
            let rightEdge: CGFloat = rowWidth - 14
            super.init(frame: NSRect(x: 0, y: 0, width: rowWidth, height: rowHeight))
            wantsLayer = true

            let mascot = MascotImageView(
                kind: MascotKind(provider: session.provider),
                status: MascotStatus(eventType: session.latestEnvelope.eventType),
                mascotSize: 34,
                showsTitle: false
            )
            mascot.frame = NSRect(x: 12, y: 30, width: 34, height: 34)
            addSubview(mascot)

            let titleLabel = Self.label(
                text: session.title,
                font: .systemFont(ofSize: 14, weight: .semibold),
                color: .labelColor
            )
            titleLabel.frame = NSRect(x: 60, y: 64, width: 350, height: 18)
            addSubview(titleLabel)

            let detailLabel = Self.label(
                text: Self.rowDetail(for: session),
                font: .systemFont(ofSize: 12, weight: .medium),
                color: session.requiresAttention ? .systemOrange : .secondaryLabelColor
            )
            detailLabel.frame = NSRect(x: 60, y: 41, width: 350, height: 17)
            addSubview(detailLabel)

            let contextLabel = Self.label(
                text: Self.rowContext(for: session),
                font: .monospacedSystemFont(ofSize: 11, weight: .regular),
                color: .secondaryLabelColor
            )
            contextLabel.frame = NSRect(x: 60, y: 20, width: 350, height: 15)
            addSubview(contextLabel)

            let timeBadge = Self.badge(text: Self.ageText(since: session.lastSeenAt), tint: .controlAccentColor)
            timeBadge.frame.origin = NSPoint(x: rightEdge - timeBadge.frame.width, y: 62)
            addSubview(timeBadge)

            let providerBadge = Self.badge(text: Self.clientLabel(for: session), tint: Self.providerTint(session.provider))
            providerBadge.frame.origin = NSPoint(x: rightEdge - providerBadge.frame.width, y: 36)
            addSubview(providerBadge)

            if let terminal = Self.terminalBadgeText(for: session) {
                let terminalBadge = Self.badge(text: terminal, tint: .secondaryLabelColor)
                terminalBadge.frame.origin = NSPoint(x: rightEdge - terminalBadge.frame.width, y: 10)
                addSubview(terminalBadge)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("ActivityMenuRowView 不支持 nib 加载")
        }

        override func mouseDown(with event: NSEvent) {
            onClick()
            enclosingMenuItem?.menu?.cancelTracking()
        }

        override func updateLayer() {
            layer?.backgroundColor = NSColor.clear.cgColor
        }

        private static func label(text: String, font: NSFont, color: NSColor) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = font
            label.textColor = color
            label.lineBreakMode = .byTruncatingTail
            return label
        }

        private static func badge(text: String, tint: NSColor) -> NSTextField {
            let padded = "  \(text)  "
            let label = NSTextField(labelWithString: padded)
            label.font = .systemFont(ofSize: 11, weight: .semibold)
            label.textColor = .labelColor
            label.alignment = .center
            label.wantsLayer = true
            label.layer?.backgroundColor = tint.withAlphaComponent(0.16).cgColor
            label.layer?.cornerRadius = 8
            label.layer?.masksToBounds = true
            label.sizeToFit()
            label.frame.size.width += 8
            label.frame.size.height = 18
            return label
        }

        private static func rowDetail(for session: SessionStoreLite.SessionSnapshot) -> String {
            if session.expectsResponse {
                switch session.intervention?.kind {
                case .question:
                    return "Needs a quick answer before it can continue"
                case .approval:
                    return "Waiting for approval before it can continue"
                case nil:
                    return "Waiting for your response"
                }
            }
            if let status = session.status {
                switch status.kind {
                case .runningTool:
                    return status.detail.map { "Running \($0)" } ?? "Running tool"
                case .thinking:
                    return "Thinking"
                case .completed:
                    return "Completed"
                case .error:
                    return status.detail ?? "Error"
                case .notification:
                    return status.detail ?? "Notification"
                default:
                    break
                }
            }
            return session.preview
        }

        private static func rowContext(for session: SessionStoreLite.SessionSnapshot) -> String {
            let envelope = session.latestEnvelope
            let cwd = session.cwd ?? session.terminalContext.currentDirectory
            let location = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent }.flatMap { $0.isEmpty ? nil : $0 }
            let tool = session.metadata["tool_name"] ?? envelope.title
            let bits = [
                tool.map { envelope.eventType == "PreToolUse" ? "Opening \($0)" : $0 },
                location.map { "in \($0)" },
                session.eventCount > 1 ? "\(session.eventCount) events" : nil
            ].compactMap { $0 }
            return bits.isEmpty ? session.id : bits.joined(separator: " · ")
        }

        private static func ageText(since date: Date) -> String {
            let seconds = max(0, Int(Date().timeIntervalSince(date)))
            if seconds < 60 { return "\(seconds)s" }
            let minutes = seconds / 60
            if minutes < 60 { return "\(minutes)m" }
            return "\(minutes / 60)h"
        }

        private static func clientLabel(for session: SessionStoreLite.SessionSnapshot) -> String {
            if let clientName = session.metadata["client_name"], !clientName.isEmpty {
                return clientName
            }
            switch session.provider {
            case .claude: return "Claude Code"
            case .codex: return "Codex"
            case .copilot: return "Copilot"
            case .kimi: return "Kimi"
            case .gemini: return "Gemini CLI"
            }
        }

        private static func terminalBadgeText(for session: SessionStoreLite.SessionSnapshot) -> String? {
            if let tmux = session.terminalContext.tmuxSession, !tmux.isEmpty {
                return "tmux"
            }
            if let ide = session.terminalContext.ideName, !ide.isEmpty {
                return ide
            }
            if let terminal = session.terminalContext.terminalProgram, !terminal.isEmpty {
                return terminal
            }
            return nil
        }

        private static func providerTint(_ provider: AgentProvider) -> NSColor {
            switch provider {
            case .claude: return .systemOrange
            case .codex: return .systemBlue
            case .copilot: return .systemGreen
            case .kimi: return .systemTeal
            case .gemini: return .systemPurple
            }
        }
    }
}

private final class ApprovalMenuCommand: NSObject {
    let requestID: UUID
    let decision: InterventionDecision
    let reason: String?

    init(requestID: UUID, decision: InterventionDecision, reason: String?) {
        self.requestID = requestID
        self.decision = decision
        self.reason = reason
    }
}
