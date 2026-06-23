import XCTest
@testable import PingIslandLite

/// 阶段 1 的最简冒烟测试。
///
/// 这里不测 UI（AppKit 在测试环境下需要 `NSApp.run` 才能完整跑起来），
/// 只验证：
/// - 模块能被链接进来；
/// - MenuBarController 能被实例化（不会因初始化崩溃）。
///
/// 阶段 2 起会陆续加入：
/// - HookSocketServer 的协议解析单测；
/// - 吉祥物状态机切换的逻辑单测；
/// - Agent 安装器的写入/卸载/幂等单测。
final class MenuBarControllerSmokeTests: XCTestCase {

    func testMenuBarControllerCanBeInstantiated() {
        let controller = MenuBarController()
        XCTAssertNotNil(controller)
    }
}
