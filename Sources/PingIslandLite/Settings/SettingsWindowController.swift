import AppKit
import SwiftUI

/// 偏好窗口控制器：独立 NSWindow + NSHostingController 装 SwiftUI 视图。
///
/// 为啥要走 AppKit 而不是 SwiftUI 的 `Settings { ... }` scene：
/// 1. lite 是菜单栏型 app（非 LSUIElement = false 的标准 app），SwiftUI 3.0 的
///    `Settings` scene 只在 `App` 协议里有效；而 lite 走的是经典 NSApplication +
///    AppDelegate 模式，没法用 SwiftUI scene。
/// 2. NSWindowController 单例 + NSHostingController 是 macOS 12 最稳的做法。
///
/// 用法：`SettingsWindowController.shared.show()`。窗口会自动 raise 到前台。
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {

    static let shared = SettingsWindowController()

    private convenience init() {
        // 先做一个空窗口，loadWindow() 阶段再装 SwiftUI 内容。
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentBeacon · 偏好设置"
        window.titlebarAppearsTransparent = false
        window.isReleasedWhenClosed = false  // 关闭按 X 时只是隐藏，不释放，下次 show() 复用。
        window.center()

        // 装 SwiftUI 视图。
        let hosting = NSHostingController(rootView: SettingsView(store: SettingsStore.shared))
        window.contentViewController = hosting

        self.init(window: window)
        window.delegate = self
    }

    /// 打开偏好窗口；如果窗口已存在则 raise 到前台。
    func show() {
        // 用户按 X 关闭后再次打开时，frame 已经被保存；我们只 makeKeyAndOrderFront 即可。
        guard let window = self.window else { return }
        if !window.isVisible {
            window.center()
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
