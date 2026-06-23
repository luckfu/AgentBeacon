import Foundation

/// Kimi CLI 的 ~/.kimi/config.toml 是用户主配置文件，里面除了 [[hooks]] 段
/// 还有 providers / models / loop_control 等大量段，我们必须只动 [[hooks]] 不破其它。
///
/// 主仓有完整的 TOMLHookConfigParser 文件，会区分顶层段 / 数组段 / 注释 / 空行。
/// Lite 阶段用最简策略：
/// - 「我们的 [[hooks]] 段」用 `# Ping Island managed` 注释作为 sentinel；
/// - 卸载时按 sentinel 行 + 紧跟着的 [[hooks]] 段一起删（删到下一个 `[`、`[[` 段或文件结束）；
/// - 安装时先剥旧的，再在文件末尾追加新的（每个事件一段 [[hooks]]）。
///
/// 这套策略不解析任何字段语义，对用户其它 [[hooks]]（没带 sentinel）完全不动。
enum TOMLHookHelper {

    static let sentinelLine = "# Ping Island managed hook"

    struct Entry {
        let event: String
        let matcher: String?
        let command: String
        let timeout: Int?
    }

    // MARK: - 拼接

    /// 在已有 TOML 内容（已剥掉旧的我们写的 [[hooks]] 之后）末尾追加新的 [[hooks]] 段。
    static func append(entries: [Entry], to content: String) -> String {
        guard !entries.isEmpty else { return content }
        var output = content
        // 保证与已有内容之间有空行分隔
        if !output.isEmpty && !output.hasSuffix("\n") { output += "\n" }
        if !output.isEmpty && !output.hasSuffix("\n\n") { output += "\n" }

        for entry in entries {
            output += sentinelLine + "\n"
            output += "[[hooks]]\n"
            output += "event = \(tomlString(entry.event))\n"
            if let matcher = entry.matcher, !matcher.isEmpty {
                output += "matcher = \(tomlString(matcher))\n"
            }
            output += "command = \(tomlString(entry.command))\n"
            if let timeout = entry.timeout {
                output += "timeout = \(timeout)\n"
            }
            output += "\n"
        }
        return output
    }

    // MARK: - 剥离

    /// 从 content 里删掉所有由 PingIsland 写的 [[hooks]] 段（识别 sentinel 注释）。
    /// 保留其它一切（providers / models / loop_control / 用户自己加的 [[hooks]]）。
    static func removePingIslandHooks(in content: String) -> String {
        let lines = content.components(separatedBy: "\n")
        var output: [String] = []
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 命中 sentinel：跳过它本身 + 紧跟的 [[hooks]] 段（到下一个段标志或文件结束）
            if trimmed.hasPrefix(sentinelLine) {
                i += 1
                // 跳过 [[hooks]] 头
                if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces) == "[[hooks]]" {
                    i += 1
                }
                // 跳过该段的所有 key=value 行，直到遇到下一个 `[` / `[[` 或空行
                while i < lines.count {
                    let t = lines[i].trimmingCharacters(in: .whitespaces)
                    if t.isEmpty || t.hasPrefix("[") { break }
                    i += 1
                }
                // 顺便吞掉一个紧跟的空行（保持版面清爽）
                if i < lines.count && lines[i].trimmingCharacters(in: .whitespaces).isEmpty {
                    i += 1
                }
                continue
            }
            output.append(line)
            i += 1
        }
        return output.joined(separator: "\n")
    }

    // MARK: - status 用：收集我们写的命令

    /// 收集 PingIsland 写的 command 行的值（用于 status 判定 stale bridge path）。
    static func collectPingIslandCommands(in content: String) -> [String] {
        let lines = content.components(separatedBy: "\n")
        var commands: [String] = []
        var inIslandBlock = false
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(sentinelLine) { inIslandBlock = true; continue }
            if trimmed.hasPrefix("[") { inIslandBlock = (trimmed == "[[hooks]]" && inIslandBlock) ? true : false }
            if !inIslandBlock { continue }
            if trimmed.hasPrefix("command") {
                if let eq = trimmed.firstIndex(of: "=") {
                    let raw = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                    if let parsed = parseTOMLString(String(raw)) {
                        commands.append(parsed)
                    }
                }
            }
        }
        return commands
    }

    // MARK: - 字符串编码 / 解码

    /// 把字符串编码成 TOML 字面量（双引号 + 转义反斜杠 / 引号 / 控制字符）。
    static func tomlString(_ value: String) -> String {
        var escaped = ""
        for ch in value {
            switch ch {
            case "\\":  escaped += "\\\\"
            case "\"":  escaped += "\\\""
            case "\n":  escaped += "\\n"
            case "\r":  escaped += "\\r"
            case "\t":  escaped += "\\t"
            default:    escaped.append(ch)
            }
        }
        return "\"" + escaped + "\""
    }

    /// 解析 TOML 双引号 / 单引号字符串（极简，不处理多行字符串）。
    static func parseTOMLString(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("\"") && s.hasSuffix("\"") && s.count >= 2 {
            let inner = String(s.dropFirst().dropLast())
            var result = ""
            var i = inner.startIndex
            while i < inner.endIndex {
                let ch = inner[i]
                if ch == "\\", inner.index(after: i) < inner.endIndex {
                    let next = inner[inner.index(after: i)]
                    switch next {
                    case "n":  result += "\n"
                    case "r":  result += "\r"
                    case "t":  result += "\t"
                    case "\"": result += "\""
                    case "\\": result += "\\"
                    default:   result.append(next)
                    }
                    i = inner.index(i, offsetBy: 2)
                } else {
                    result.append(ch)
                    i = inner.index(after: i)
                }
            }
            return result
        }
        if s.hasPrefix("'") && s.hasSuffix("'") && s.count >= 2 {
            s = String(s.dropFirst().dropLast())
            return s
        }
        return nil
    }
}
