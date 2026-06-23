import AppKit
import Combine
import Foundation

/// 应用的全局生命周期协调者。
///
/// 这是 AgentBeacon 的"总开关"——所有子系统都从这里启动与关停。
///
/// 阶段 1 接入清单：
/// 1. MenuBarController（菜单栏图标）
/// 2. NotificationCenterClient（hook 事件 → 三层通知：控制台/菜单栏/系统通知）
/// 3. HookSocketServer（Unix Socket，监听 PingIslandBridge CLI 发来的 hook 事件）
/// 4. SettingsStore（用户偏好持久化）同步 → NotificationSoundPlayer
final class AppDelegate: NSObject, NSApplicationDelegate {

    private var menuBarController: MenuBarController?
    private var notificationClient: NotificationCenterClient?
    private var hookServer: HookSocketServer?
    private var soundModeCancellable: AnyCancellable?
    private var bannerEnabledCancellable: AnyCancellable?
    private var defaultMascotCancellable: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 0. 偏好读取：启动时先把当前 soundMode 同步给 NotificationSoundPlayer，
        //    以后设置面板切换时走 Combine sink 同步。
        //    systemBannerEnabled 同理：缓存到 NotificationCenterClient。
        let store = SettingsStore.shared
        NotificationSoundPlayer.setMode(store.soundMode)
        NotificationCenterClient.setSystemBannerEnabled(store.systemBannerEnabled)
        soundModeCancellable = store.$soundMode
            .removeDuplicates()
            .sink { mode in
                NotificationSoundPlayer.setMode(mode)
            }
        bannerEnabledCancellable = store.$systemBannerEnabled
            .removeDuplicates()
            .sink { enabled in
                NotificationCenterClient.setSystemBannerEnabled(enabled)
            }

        // 1. 菜单栏图标
        let mbc = MenuBarController()
        mbc.start()
        mbc.setDefaultMascot(store.defaultMascot)
        defaultMascotCancellable = store.$defaultMascot
            .removeDuplicates()
            .sink { mascot in
                mbc.setDefaultMascot(mascot)
            }
        menuBarController = mbc

        // 2. 三层通知器（控制台 + 菜单栏徽标 + osascript 系统通知）
        let notifier = NotificationCenterClient(menuBarController: mbc)
        notificationClient = notifier

        // 3. Hook Socket 服务器：把每个 envelope 嗂给通知器
        let server = HookSocketServer { envelope in
            notifier.deliver(envelope: envelope)
        }
        let approvalResponder: MenuBarController.ApprovalResponder = { requestID, decision, reason in
            Task {
                _ = await server.respond(
                    requestID: requestID,
                    decision: decision,
                    reason: reason
                )
            }
        }
        mbc.setApprovalResponder(approvalResponder)
        Task { @MainActor in
            SessionDetailWindowController.shared.setApprovalResponder { requestID, decision, reason in
                approvalResponder(requestID, decision, reason)
            }
        }
        hookServer = server

        Task {
            do {
                try await server.start()
                let path = HookSocketServer.defaultSocketPath
                FileHandle.standardError.write(
                    Data("[startup] HookSocketServer listening at \(path)\n".utf8)
                )
            } catch {
                FileHandle.standardError.write(
                    Data("[startup] HookSocketServer failed: \(error)\n".utf8)
                )
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        // 关停顺序与启动相反，避免 server 还在收事件时通知器已被释放。
        if let server = hookServer {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                await server.stop()
                semaphore.signal()
            }
            // 给最多 0.5s 让 socket 干净关闭，否则放弃。
            _ = semaphore.wait(timeout: .now() + 0.5)
        }
        hookServer = nil
        notificationClient = nil
        soundModeCancellable?.cancel()
        soundModeCancellable = nil
        bannerEnabledCancellable?.cancel()
        bannerEnabledCancellable = nil
        defaultMascotCancellable?.cancel()
        defaultMascotCancellable = nil
        menuBarController?.stop()
        menuBarController = nil
    }

    // 我们没有 Dock 图标，点 Dock 也不会触发任何窗口
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        return false
    }
}
