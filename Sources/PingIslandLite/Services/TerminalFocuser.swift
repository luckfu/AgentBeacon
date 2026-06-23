import AppKit
import Foundation
import IslandShared

/// 一键跳回终端 / IDE。
///
/// 思路：BridgeEnvelope.terminalContext 已经带了 lite 需要的全部上下文
///（terminalBundleID / terminalProgram / iTermSessionID / tty / tmuxSession / ideBundleID），
/// 不用再去主仓那套 31KB IDE 扩展安装器。
///
/// 路由顺序：
/// 1. tmux：有 tmuxSession 就先 `tmux select-window` 切到对应 pane，再激活宿主终端。
/// 2. iTerm2：用 iTermSessionID 精确选 tab；没有 ID 时按 tty 匹配。
/// 3. Ghostty：用 terminalSessionID 精确选 terminal。
/// 4. Terminal.app：按 tty 匹配 tab。
/// 5. 兜底：按 ideBundleID / terminalBundleID 直接 `NSWorkspace.activate`。
///
/// 全部 osascript 操作走子进程，不阻塞主线程；激活操作回到主线程。
/// 失败统一打日志、不抛异常——用户点不动顶多没反应，不能把主程崩了。
enum TerminalFocuser {

    /// 入口：根据 envelope 跳回对应窗口。
    /// 返回值仅用于日志/测试，UI 不必 await 也不必看结果。
    @discardableResult
    static func focus(_ envelope: BridgeEnvelope) async -> Bool {
        let ctx = envelope.terminalContext

        // —— 路径 1：tmux 优先 ——
        // tmux 是终端无关的复用层，无论宿主是 iTerm/Terminal/Ghostty，
        // 先把 tmux 焦点切对再激活宿主，体验最稳。
        if let tmuxSession = ctx.tmuxSession?.nonEmpty {
            let okTmux = runTmuxFocus(session: tmuxSession, pane: ctx.tmuxPane?.nonEmpty)
            // 即便 tmux 切失败也继续走宿主激活；至少能 raise 终端到前台。
            let _ = await activateHostBundle(ctx)
            return okTmux
        }

        // —— 路径 2：按宿主终端走专用 AppleScript ——
        let bundle = (ctx.terminalBundleID ?? "").lowercased()
        let program = (ctx.terminalProgram ?? "").lowercased()

        if bundle.contains("iterm") || program.contains("iterm") {
            if await focusITerm(sessionID: ctx.iTermSessionID?.nonEmpty,
                                tty: ctx.tty?.nonEmpty) {
                return true
            }
            // iTerm 选 tab 失败 → 兜底激活 iTerm 进程。
            return await activateBundle("com.googlecode.iterm2")
        }

        if bundle.contains("ghostty") || program.contains("ghostty") {
            if await focusGhostty(sessionID: ctx.terminalSessionID?.nonEmpty,
                                  bundleID: ctx.terminalBundleID?.nonEmpty
                                  ?? "com.mitchellh.ghostty") {
                return true
            }
            return await activateBundle(ctx.terminalBundleID ?? "com.mitchellh.ghostty")
        }

        if bundle.contains("apple.terminal") || program == "apple_terminal" || program == "terminal" {
            if await focusTerminalApp(tty: ctx.tty?.nonEmpty) {
                return true
            }
            return await activateBundle("com.apple.Terminal")
        }

        // —— 路径 3：IDE 系（VS Code / Cursor / Qoder / CodeBuddy / Trae）兜底激活 ——
        // lite 阶段一不做 IDE 扩展安装（主仓 IDEExtensionInstaller 31KB 太重，阶段二再说），
        // 至少把对应应用 raise 到前台，让用户能自己定位到 Agent 那个 tab。
        return await activateHostBundle(ctx)
    }

    // MARK: - tmux

    /// 调用 `tmux select-window -t <session>:<pane>`。如果 pane 含 `.`（window.pane），
    /// 还顺手 `select-pane`。失败一律返回 false，不抛出。
    private static func runTmuxFocus(session: String, pane: String?) -> Bool {
        let tmuxPath = tmuxExecutablePath() ?? "/usr/local/bin/tmux"
        // pane 形如 "1.2"（window 1, pane 2）；纯数字则当作 window 索引。
        let target: String
        if let pane, !pane.isEmpty {
            target = "\(session):\(pane)"
        } else {
            target = session
        }

        let switchOK = runProcess(launchPath: tmuxPath,
                                  arguments: ["switch-client", "-t", target]) == 0
        // 在多数情况下 switch-client 已经够用；select-window 是为了纯 attach 场景兜底。
        let selectOK = runProcess(launchPath: tmuxPath,
                                  arguments: ["select-window", "-t", target]) == 0
        return switchOK || selectOK
    }

    /// 找 tmux 可执行文件路径。lite 不引入 LaunchServices 复杂查找，
    /// 用最常见的两条路径 + `which` 兜底。
    private static func tmuxExecutablePath() -> String? {
        for candidate in ["/opt/homebrew/bin/tmux", "/usr/local/bin/tmux", "/usr/bin/tmux"] {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }
        // 调用 /usr/bin/which 兜底
        let pipe = Pipe()
        let proc = Process()
        proc.launchPath = "/usr/bin/which"
        proc.arguments = ["tmux"]
        proc.standardOutput = pipe
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            let path = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return path?.isEmpty == false ? path : nil
        } catch {
            return nil
        }
    }

    // MARK: - iTerm2

    private static func focusITerm(sessionID: String?, tty: String?) async -> Bool {
        // sessionID / tty 都没有时无法精确匹配，让上层走 activateBundle 兜底。
        guard sessionID != nil || tty != nil else { return false }
        let lines = iTermSelectionScript(sessionID: sessionID, tty: tty)
        return await runAppleScript(lines) == "ok"
    }

    /// 主仓 iTermSelectionScriptLines 的极简移植：
    /// - 有 sessionID 时按 id 精确匹配
    /// - 否则按 tty（同时容忍 `xxx` 和 `/dev/xxx` 两种写法）
    private static func iTermSelectionScript(sessionID: String?, tty: String?) -> [String] {
        var lines: [String] = [
            "tell application id \"com.googlecode.iterm2\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "repeat with theSession in sessions of theTab"
        ]
        if let sid = sessionID {
            lines.append(contentsOf: [
                "try",
                "if (id of theSession as text) is \"\(escapeAS(sid))\" then",
                "select theTab",
                "select theSession",
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "select resolvedWindow",
                "activate",
                "return \"ok\"",
                "end if",
                "end try"
            ])
        }
        if let rawTTY = tty {
            let normalized = rawTTY.replacingOccurrences(of: "/dev/", with: "")
            let full = "/dev/\(normalized)"
            lines.append(contentsOf: [
                "set sessionTTY to tty of theSession",
                "if sessionTTY is \"\(escapeAS(normalized))\" or sessionTTY is \"\(escapeAS(full))\" then",
                "select theTab",
                "select theSession",
                "set targetWindowId to (id of theWindow)",
                "set resolvedWindow to first window whose id is targetWindowId",
                "select resolvedWindow",
                "activate",
                "return \"ok\"",
                "end if"
            ])
        }
        lines.append(contentsOf: [
            "end repeat",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ])
        return lines
    }

    // MARK: - Ghostty

    private static func focusGhostty(sessionID: String?, bundleID: String) async -> Bool {
        guard let sid = sessionID else { return false }
        let lines: [String] = [
            "tell application id \"\(escapeAS(bundleID))\"",
            "set targetTerminalID to \"\(escapeAS(sid))\"",
            "try",
            "set targetTerminal to first terminal whose id is targetTerminalID",
            "focus targetTerminal",
            "return \"ok\"",
            "end try",
            "return \"not-found\"",
            "end tell"
        ]
        return await runAppleScript(lines) == "ok"
    }

    // MARK: - Terminal.app

    private static func focusTerminalApp(tty: String?) async -> Bool {
        guard let rawTTY = tty else { return false }
        let normalized = rawTTY.replacingOccurrences(of: "/dev/", with: "")
        let full = "/dev/\(normalized)"
        let lines: [String] = [
            "tell application id \"com.apple.Terminal\"",
            "repeat with theWindow in windows",
            "repeat with theTab in tabs of theWindow",
            "set tabTTY to tty of theTab",
            "if tabTTY is \"\(escapeAS(normalized))\" or tabTTY is \"\(escapeAS(full))\" then",
            "set selected of theTab to true",
            "set frontmost of theWindow to true",
            "activate",
            "return \"ok\"",
            "end if",
            "end repeat",
            "end repeat",
            "return \"not-found\"",
            "end tell"
        ]
        return await runAppleScript(lines) == "ok"
    }

    // MARK: - 兜底：激活宿主 bundle

    /// 按 ideBundleID > terminalBundleID 顺序激活；都没有就返回 false。
    private static func activateHostBundle(_ ctx: TerminalContext) async -> Bool {
        if let ide = ctx.ideBundleID?.nonEmpty {
            return await activateBundle(ide)
        }
        if let term = ctx.terminalBundleID?.nonEmpty {
            return await activateBundle(term)
        }
        return false
    }

    /// 主线程 `NSWorkspace.shared.runningApplications` 找进程并 activate。
    /// 找不到运行实例则用 NSWorkspace.shared.urlForApplication 启动该应用。
    @MainActor
    private static func activateBundleOnMain(_ bundleID: String) -> Bool {
        let workspace = NSWorkspace.shared
        if let app = workspace.runningApplications.first(where: { $0.bundleIdentifier == bundleID }) {
            // macOS 12 上 .activateAllWindows 标志最稳，能把所有 window 一起 raise。
            return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
        }
        // 没在跑就启一个；用户起码能拿到一个新窗口。
        if let url = workspace.urlForApplication(withBundleIdentifier: bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            workspace.openApplication(at: url, configuration: config) { _, _ in }
            return true
        }
        return false
    }

    private static func activateBundle(_ bundleID: String) async -> Bool {
        await MainActor.run { activateBundleOnMain(bundleID) }
    }

    // MARK: - AppleScript / 子进程小工具

    /// 跑一段 AppleScript，返回 trim 后的 stdout；失败返回 nil。
    /// 由 MainActor 跑——NSAppleScript 不是 Sendable，且这条调用极轻。
    @MainActor
    private static func runAppleScriptOnMain(_ lines: [String]) -> String? {
        let source = lines.joined(separator: "\n")
        var errorInfo: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return nil }
        let result = script.executeAndReturnError(&errorInfo)
        if errorInfo != nil { return nil }
        return result.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func runAppleScript(_ lines: [String]) async -> String? {
        await MainActor.run { runAppleScriptOnMain(lines) }
    }

    /// 跑子进程，返回 exit code（异常时 -1）。stdout/stderr 静默掉。
    @discardableResult
    private static func runProcess(launchPath: String, arguments: [String]) -> Int32 {
        let proc = Process()
        proc.launchPath = launchPath
        proc.arguments = arguments
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        do {
            try proc.run()
            proc.waitUntilExit()
            return proc.terminationStatus
        } catch {
            return -1
        }
    }

    /// AppleScript 字符串内嵌转义：双引号、反斜杠。
    private static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }
}

// MARK: - 小工具

private extension String {
    /// 空串 / 全空白返回 nil，方便链式 `?.nonEmpty`。
    var nonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
