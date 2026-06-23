import Foundation

/// 定位 PingIslandBridge 可执行文件的绝对路径。
///
/// 安装 hook 的时候，需要把一条 shell 命令写到 ~/.claude/settings.json：
///     "command": "<bridge-bin> --source claude"
/// 这条命令会在 Claude Code 进程上下文里执行（不一定继承 PingIslandLite 的环境），
/// 所以必须给它一个**绝对路径**而非依赖 PATH/swift run。
///
/// 查找顺序（命中即返回）：
/// 1. 环境变量 PING_ISLAND_BRIDGE_BIN：人工覆盖优先（CI、测试、开发临时切换）。
/// 2. 与 PingIslandLite 主可执行文件同目录的 PingIslandBridge。
/// 3. 同目录平级 ../release/PingIslandBridge（开发期常见：lite=debug + bridge=release）。
/// 4. 同目录平级 ../debug/PingIslandBridge（反过来：lite=release + bridge=debug）。
/// 5. 仓库 .build/release/PingIslandBridge / .build/debug/PingIslandBridge（最后兜底）。
public enum BridgeBinaryLocator {
    public enum LocateError: Error, CustomStringConvertible {
        case notFound(triedPaths: [String])

        public var description: String {
            switch self {
            case .notFound(let paths):
                return "找不到 PingIslandBridge 可执行文件，已尝试：\n" +
                    paths.map { "  - \($0)" }.joined(separator: "\n") +
                    "\n请先运行：swift build -c release --product PingIslandBridge"
            }
        }
    }

    /// 找 bridge 可执行文件的绝对路径。找不到就抛错。
    public static func locate() throws -> String {
        var tried: [String] = []
        let fm = FileManager.default

        func check(_ path: String) -> String? {
            tried.append(path)
            // isExecutableFile 只判定权限位，确保它真的是可执行二进制。
            return fm.isExecutableFile(atPath: path) ? path : nil
        }

        // 1. 环境变量覆盖
        if let custom = ProcessInfo.processInfo.environment["PING_ISLAND_BRIDGE_BIN"],
           !custom.isEmpty,
           let hit = check(custom) {
            return hit
        }

        // 2 + 3 + 4：以 lite 主可执行文件目录为锚点
        // CommandLine.arguments[0] 在 swift run 下可能是相对路径，所以用 Bundle.main.executableURL 更稳。
        if let executableURL = Bundle.main.executableURL {
            let execDir = executableURL.deletingLastPathComponent()
            // 同目录
            if let hit = check(execDir.appendingPathComponent("PingIslandBridge").path) { return hit }
            // 平级 release / debug（execDir 通常是 .../debug/ 或 .../release/，所以 ../release 等价于 sibling）
            let parentDir = execDir.deletingLastPathComponent()
            if let hit = check(parentDir.appendingPathComponent("release/PingIslandBridge").path) { return hit }
            if let hit = check(parentDir.appendingPathComponent("debug/PingIslandBridge").path) { return hit }
        }

        // 5. 仓库根 .build 兜底（按 source file 推 repo root，仅开发期有效）
        let thisFile = URL(fileURLWithPath: #filePath)
        // <repo>/Sources/PingIslandLite/Services/BridgeBinaryLocator.swift → 上溯 4 层 = <repo>
        let repoRoot = thisFile
            .deletingLastPathComponent()  // Services
            .deletingLastPathComponent()  // PingIslandLite
            .deletingLastPathComponent()  // Sources
            .deletingLastPathComponent()  // <repo>
        if let hit = check(repoRoot.appendingPathComponent(".build/release/PingIslandBridge").path) { return hit }
        if let hit = check(repoRoot.appendingPathComponent(".build/debug/PingIslandBridge").path) { return hit }

        throw LocateError.notFound(triedPaths: tried)
    }

    /// 不抛错版本，找不到就返回 nil。用于"显示状态"等不希望异常打断的场景。
    public static func locateOrNil() -> String? {
        try? locate()
    }
}
