import Foundation

/// PingIslandLite 的 hook 安装器（lite 版）。
///
/// 已覆盖主仓 ClientProfileRegistry 中全部 17 个 ManagedHookClientProfile，
/// 但实现采取「最小可用」策略：
/// - jsonHooks 类（12 家）：完整复用主仓的事件清单和写入语义；
/// - tomlHooks 类（Kimi）：自己写一个轻量 [[hooks]] 段操作器，不引入完整 TOML 解析；
/// - pluginFile / pluginDirectory / hookDirectory（5 家非 JSON）：
///   只生成「最简转发器」脚本（每家 ~30 行 JS/TS/Python/MD），
///   功能上能在那家 CLI 里调起 PingIslandBridge 把 envelope 投递到 lite socket 即可。
///   主仓里上千行的 plugin 源码（终端 / tmux / iTerm 透视、IDE 透视等）lite 不需要。
///
/// 安装原则（所有 kind 共用）：
/// 1. **完整保留**用户配置文件里的非 hook 字段（env / model / providers 等）
/// 2. 仅增删 PingIsland 自管理的项，识别方式：command 字串含 "PingIslandBridge"
/// 3. 写入前自动备份（.ping-island-bak），atomic 写入
/// 4. 卸载时若 hooks 节点变空，整个节点一并摘掉
public enum HookInstaller {

    // MARK: - 错误与状态

    public enum InstallError: Error, CustomStringConvertible {
        case bridgeNotFound(String)
        case readSettingsFailed(URL, underlying: Error)
        case parseSettingsFailed(URL, message: String)
        case writeSettingsFailed(URL, underlying: Error)

        public var description: String {
            switch self {
            case .bridgeNotFound(let detail): return "Bridge 定位失败：\(detail)"
            case .readSettingsFailed(let url, let err): return "读取 \(url.path) 失败：\(err.localizedDescription)"
            case .parseSettingsFailed(let url, let msg): return "\(url.path) 不是合法 JSON：\(msg)"
            case .writeSettingsFailed(let url, let err): return "写入 \(url.path) 失败：\(err.localizedDescription)"
            }
        }
    }

    public enum InstallStatus {
        case notInstalled
        case installed
        case staleBridgePath(String)
    }

    // MARK: - Kind / Template

    /// hook 配置文件的存储形态。
    public enum Kind {
        /// 通用 JSON 文件，hooks 节点存事件 → group 数组。Claude / Codex / Gemini / Qwen 等大多数家
        case jsonHooks
        /// 单文件插件（OpenCode：~/.config/opencode/plugins/ping-island.js）
        case pluginFile
        /// 插件目录（Hermes：~/.hermes/plugins/ping_island/；Pi：~/.pi/agent/extensions/ping_island/）
        case pluginDirectory
        /// hook 目录 + 激活配置（OpenClaw：~/.openclaw/hooks/ping-island-openclaw/ + openclaw.json 启用）
        case hookDirectory
        /// TOML 配置文件的 [[hooks]] 段（Kimi：~/.kimi/config.toml）
        case tomlHooks
    }

    /// 单个事件 group 的写入模板。
    /// - .plain：`[{ "hooks": [...] }]`（无 matcher，例：Claude UserPromptSubmit）
    /// - .matcher("*")：`[{ "matcher": "*", "hooks": [...] }]`
    /// - .direct：`[{ "type":"command", "command":"..." }]`（无 group 包装，Cursor 专用）
    public enum Template: Equatable {
        case plain
        case matcher(String)
        case direct
    }

    /// hook entry 的字段命名风格（Copilot 用 `bash` 而非 `command`，并把 timeout 叫 `timeoutSec`）。
    public enum EntryShape {
        case standard          // {type, command, timeout?}
        case copilot           // {type, bash, timeoutSec?}
    }

    /// 一条事件描述。
    public struct EventSpec {
        public let name: String
        public let templates: [Template]
        public let timeout: Int?
        public init(_ name: String, templates: [Template], timeout: Int? = nil) {
            self.name = name
            self.templates = templates
            self.timeout = timeout
        }
    }

    // MARK: - Provider（17 家）

    /// 主仓 ClientProfileRegistry.managedHookProfiles 全量映射。
    public enum Provider: String, CaseIterable {
        case claude
        case codex
        case gemini
        case qwen           // qwen-code-hooks
        case codebuddy      // codebuddy-hooks（IDE）
        case codebuddyCli   // codebuddy-cli-hooks
        case workbuddy
        case cursor
        case qoder          // qoder-hooks（IDE）
        case qoderCli       // qoder-cli-hooks
        case qoderwork
        case copilot
        case hermes
        case pi
        case opencode
        case openclaw
        case kimi

        public var displayName: String {
            switch self {
            case .claude:       return "Claude Code"
            case .codex:        return "Codex"
            case .gemini:       return "Gemini CLI"
            case .qwen:         return "Qwen Code"
            case .codebuddy:    return "CodeBuddy IDE"
            case .codebuddyCli: return "CodeBuddy CLI"
            case .workbuddy:    return "WorkBuddy"
            case .cursor:       return "Cursor"
            case .qoder:        return "Qoder IDE"
            case .qoderCli:     return "Qoder CLI"
            case .qoderwork:    return "QoderWork"
            case .copilot:      return "GitHub Copilot"
            case .hermes:       return "Hermes"
            case .pi:           return "Pi Agent"
            case .opencode:     return "OpenCode"
            case .openclaw:     return "OpenClaw"
            case .kimi:         return "Kimi CLI"
            }
        }

        /// 主配置文件相对于 $HOME 的位置（用于诊断 / 状态展示）。
        public var settingsRelativePath: String {
            switch self {
            case .claude:       return ".claude/settings.json"
            case .codex:        return ".codex/hooks.json"
            case .gemini:       return ".gemini/settings.json"
            case .qwen:         return ".qwen/settings.json"
            case .codebuddy:    return ".codebuddy/settings.json"
            case .codebuddyCli: return ".codebuddy/settings.json"
            case .workbuddy:    return ".workbuddy/settings.json"
            case .cursor:       return ".cursor/hooks.json"
            case .qoder:        return ".qoder/settings.json"
            case .qoderCli:     return ".qoder/settings.json"
            case .qoderwork:    return ".qoderwork/settings.json"
            case .copilot:      return ".github/hooks/island.json"
            case .hermes:       return ".hermes/plugins/ping_island"
            case .pi:           return ".pi/agent/extensions/ping_island"
            case .opencode:     return ".config/opencode/plugins/ping-island.js"
            case .openclaw:     return ".openclaw/hooks/ping-island-openclaw"
            case .kimi:         return ".kimi/config.toml"
            }
        }

        /// `PingIslandBridge --source <x>` 的取值。
        public var bridgeSourceArgument: String {
            switch self {
            case .claude, .qwen, .codebuddy, .codebuddyCli, .workbuddy,
                 .cursor, .qoder, .qoderCli, .qoderwork,
                 .hermes, .pi, .opencode, .openclaw:
                return "claude"          // 共用 Claude-compatible 协议
            case .codex:    return "codex"
            case .gemini:   return "gemini"
            case .copilot:  return "copilot"
            case .kimi:     return "kimi"
            }
        }

        /// 透传给 bridge 的额外 client-kind / client-name 等参数（保持与主仓 ClientProfileRegistry 对齐）。
        public var bridgeExtraArguments: [String] {
            switch self {
            case .claude, .codex: return []
            case .gemini:
                return ["--client-kind", "gemini", "--client-name", "Gemini CLI",
                        "--client-origin", "cli", "--client-originator", "Gemini CLI",
                        "--thread-source", "gemini-hooks"]
            case .qwen:
                return ["--client-kind", "qwen-code", "--client-name", "Qwen Code",
                        "--client-origin", "cli", "--client-originator", "Qwen Code",
                        "--thread-source", "qwen-code-hooks"]
            case .codebuddy:
                return ["--client-kind", "codebuddy", "--client-name", "CodeBuddy",
                        "--client-originator", "CodeBuddy"]
            case .codebuddyCli:
                return ["--client-kind", "codebuddy-cli", "--client-name", "CodeBuddy CLI",
                        "--client-origin", "cli", "--client-originator", "CodeBuddy"]
            case .workbuddy:
                return ["--client-kind", "workbuddy", "--client-name", "WorkBuddy",
                        "--client-originator", "WorkBuddy"]
            case .cursor:
                return ["--client-kind", "cursor", "--client-name", "Cursor",
                        "--client-originator", "Cursor"]
            case .qoder:
                return ["--client-kind", "qoder"]
            case .qoderCli:
                return ["--client-kind", "qoder-cli", "--client-name", "Qoder CLI",
                        "--client-origin", "cli", "--client-originator", "Qoder"]
            case .qoderwork:
                return ["--client-kind", "qoderwork", "--client-name", "QoderWork"]
            case .copilot:
                return []
            case .hermes:
                return ["--client-kind", "hermes", "--client-name", "Hermes",
                        "--client-origin", "cli", "--client-originator", "Hermes",
                        "--thread-source", "hermes-plugin"]
            case .pi:
                return ["--client-kind", "pi", "--client-name", "Pi Agent",
                        "--client-origin", "cli", "--client-originator", "Pi",
                        "--thread-source", "pi-extension"]
            case .opencode:
                return ["--client-kind", "opencode", "--client-name", "OpenCode",
                        "--client-origin", "cli", "--client-originator", "OpenCode",
                        "--thread-source", "opencode-plugin"]
            case .openclaw:
                return ["--client-kind", "openclaw", "--client-name", "OpenClaw",
                        "--client-origin", "gateway", "--client-originator", "OpenClaw",
                        "--thread-source", "openclaw-hooks"]
            case .kimi:
                return ["--client-kind", "kimi", "--client-name", "Kimi CLI",
                        "--client-origin", "cli", "--client-originator", "Kimi CLI",
                        "--thread-source", "kimi-hooks"]
            }
        }

        public var kind: Kind {
            switch self {
            case .claude, .codex, .gemini, .qwen, .codebuddy, .codebuddyCli,
                 .workbuddy, .cursor, .qoder, .qoderCli, .qoderwork, .copilot:
                return .jsonHooks
            case .hermes, .pi:  return .pluginDirectory
            case .opencode:     return .pluginFile
            case .openclaw:     return .hookDirectory
            case .kimi:         return .tomlHooks
            }
        }

        public var entryShape: EntryShape {
            self == .copilot ? .copilot : .standard
        }

        /// 卸载时给用户的"什么数据被保留了"提示文案。
        public var uninstallPreservedHint: String {
            switch self {
            case .claude:
                return "~/.claude/settings.json 中由 PingIsland 管理的项已清理，env / permissions / 用户自定义 hook 均保留。"
            case .codex:
                return "~/.codex/hooks.json 中由 PingIsland 管理的项已清理；config.toml / auth.json 没动过。"
            case .qoder, .qoderCli:
                return "~/.qoder/settings.json 中由 PingIsland 管理的项已清理，另一个 Qoder profile 与用户自定义内容保留。"
            case .codebuddy, .codebuddyCli:
                return "~/.codebuddy/settings.json 中由 PingIsland 管理的项已清理，另一个 CodeBuddy profile 与用户自定义内容保留。"
            case .hermes, .pi:
                return "~/\(settingsRelativePath) 目录已删除，其余 plugins/extensions 未动。"
            case .opencode:
                return "~/.config/opencode/plugins/ping-island.js 已删除，其余 plugin 未动。"
            case .openclaw:
                return "~/.openclaw/hooks/ping-island-openclaw 已删除，openclaw.json 中的 PingIsland 启用条目已清理。"
            case .kimi:
                return "~/.kimi/config.toml 中由 PingIsland 管理的 [[hooks]] 段已清理，providers / models / loop_control 等其它段保留。"
            default:
                return "~/\(settingsRelativePath) 中由 PingIsland 管理的项已清理，用户自定义内容保留。"
            }
        }
    }

    // MARK: - Public API

    @discardableResult
    public static func install(_ provider: Provider) throws -> String {
        let bridgePath: String
        do {
            bridgePath = try BridgeBinaryLocator.locate()
        } catch {
            throw InstallError.bridgeNotFound(String(describing: error))
        }

        let url = settingsURL(for: provider)
        switch provider.kind {
        case .jsonHooks:        try installJSONHooks(provider, bridgePath: bridgePath, at: url)
        case .pluginFile:       try installPluginFile(provider, bridgePath: bridgePath, at: url)
        case .pluginDirectory:  try installPluginDirectory(provider, bridgePath: bridgePath, at: url)
        case .hookDirectory:    try installHookDirectory(provider, bridgePath: bridgePath, at: url)
        case .tomlHooks:        try installTOMLHooks(provider, bridgePath: bridgePath, at: url)
        }
        return bridgePath
    }

    public static func uninstall(_ provider: Provider) throws {
        let url = settingsURL(for: provider)
        switch provider.kind {
        case .jsonHooks:        try uninstallJSONHooks(provider, at: url)
        case .pluginFile:       try uninstallPluginFile(provider, at: url)
        case .pluginDirectory:  try uninstallPluginDirectory(provider, at: url)
        case .hookDirectory:    try uninstallHookDirectory(provider, at: url)
        case .tomlHooks:        try uninstallTOMLHooks(provider, at: url)
        }
    }

    public static func status(_ provider: Provider) -> InstallStatus {
        let url = settingsURL(for: provider)
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return .notInstalled }

        let foundCommands: [String]
        switch provider.kind {
        case .jsonHooks:
            guard let root = try? readJSONObject(url: url),
                  let hooks = root["hooks"] as? [String: Any] else { return .notInstalled }
            foundCommands = collectPingIslandCommands(from: hooks)
        case .pluginFile, .pluginDirectory, .hookDirectory:
            // 这些类型「目录/文件存在 + 含 sentinel marker」即视为已装。
            return containsPingIslandSentinel(at: url) ? .installed : .notInstalled
        case .tomlHooks:
            guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .notInstalled }
            foundCommands = TOMLHookHelper.collectPingIslandCommands(in: content)
        }

        if foundCommands.isEmpty { return .notInstalled }
        if let current = BridgeBinaryLocator.locateOrNil(),
           foundCommands.contains(where: { $0.contains(current) }) {
            return .installed
        }
        return .staleBridgePath(foundCommands.first ?? "")
    }

    public static func settingsURL(for provider: Provider) -> URL {
        homeURL().appendingPathComponent(provider.settingsRelativePath)
    }

    // MARK: - Home 注入（仅供 --smoke-hooks 等测试入口使用，生产路径为 nil）

    /// 测试期可以把它指向 /tmp/xxx 沙盒；生产路径保持 nil，回退到真实 home。
    public static var homeOverride: URL?

    /// 统一入口：测试时走 override，生产走 FileManager 真实 home。
    static func homeURL() -> URL {
        if let override = homeOverride { return override }
        return FileManager.default.homeDirectoryForCurrentUser
    }

    // MARK: - JSON Hooks 实现

    private static func installJSONHooks(_ provider: Provider, bridgePath: String, at url: URL) throws {
        var root = try readJSONObject(url: url)

        // 先剥掉旧的同 provider 项再合并新的（避免重复条目堆积）。
        let preserved: [String: Any] = (root["hooks"] as? [String: Any]).map {
            stripPingIslandHooks($0, for: provider)
        } ?? [:]

        let fresh = buildJSONHooks(for: provider, bridgePath: bridgePath)
        var merged = preserved
        for (event, value) in fresh {
            // 若用户已有同事件的 group（非 PingIsland），按 "PingIsland 写的放前面" 合并
            if let existing = merged[event] as? [Any], let newGroups = value as? [Any] {
                merged[event] = newGroups + existing
            } else {
                merged[event] = value
            }
        }
        root["hooks"] = merged

        // 共享文件特殊处理：Qoder 与 Qoder CLI 共享 ~/.qoder/settings.json；
        // CodeBuddy IDE 与 CodeBuddy CLI 共享 ~/.codebuddy/settings.json。
        // 这里的 stripPingIslandHooks(_:for:) 已经按 client-kind 区分，互不影响。
        try writeJSONObject(root, to: url)
    }

    private static func uninstallJSONHooks(_ provider: Provider, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        var root = try readJSONObject(url: url)

        if let hooks = root["hooks"] as? [String: Any] {
            let filtered = stripPingIslandHooks(hooks, for: provider)
            if filtered.isEmpty {
                root.removeValue(forKey: "hooks")
            } else {
                root["hooks"] = filtered
            }
        }
        try writeJSONObject(root, to: url)
    }

    /// 构造 hooks 字段（按 provider 的事件清单 + 模板 + entryShape）。
    private static func buildJSONHooks(for provider: Provider, bridgePath: String) -> [String: Any] {
        let command = buildBridgeCommand(provider: provider, bridgePath: bridgePath)
        var result: [String: Any] = [:]
        for event in eventsFor(provider) {
            var groups: [Any] = []
            for template in event.templates {
                let entry = makeHookEntry(command: command, shape: provider.entryShape, timeout: event.timeout)
                switch template {
                case .plain:
                    groups.append(["hooks": [entry]])
                case .matcher(let m):
                    groups.append(["matcher": m, "hooks": [entry]])
                case .direct:
                    groups.append(entry)
                }
            }
            result[event.name] = groups
        }
        return result
    }

    private static func makeHookEntry(command: String, shape: EntryShape, timeout: Int?) -> [String: Any] {
        switch shape {
        case .standard:
            var e: [String: Any] = ["type": "command", "command": command]
            if let t = timeout { e["timeout"] = t }
            return e
        case .copilot:
            var e: [String: Any] = ["type": "command", "bash": command]
            if let t = timeout { e["timeoutSec"] = t }
            return e
        }
    }

    /// 剥掉 PingIsland 写的 hook 项（按 client-kind 区分共享文件场景下的不同 profile）。
    private static func stripPingIslandHooks(_ hooks: [String: Any], for provider: Provider) -> [String: Any] {
        let kindMarker = provider.clientKindMarker          // 例如 "--client-kind qoder-cli"，nil 表示按 PingIslandBridge 通用识别
        var output: [String: Any] = [:]
        for (eventName, eventValue) in hooks {
            guard let groups = eventValue as? [Any] else {
                output[eventName] = eventValue
                continue
            }
            let cleaned: [Any] = groups.compactMap { group -> Any? in
                // group 可能是 {"hooks":[...]} 包装，也可能是直接 {"type":"command",...}（cursor .direct）
                if let dict = group as? [String: Any] {
                    if let hookList = dict["hooks"] as? [[String: Any]] {
                        let kept = hookList.filter { !isOwnedByProvider($0, kindMarker: kindMarker) }
                        if kept.isEmpty { return nil }
                        var g = dict
                        g["hooks"] = kept
                        return g
                    }
                    // direct 模板
                    if isOwnedByProvider(dict, kindMarker: kindMarker) {
                        return nil
                    }
                    return dict
                }
                return group
            }
            if !cleaned.isEmpty { output[eventName] = cleaned }
        }
        return output
    }

    /// 判定一条 hook entry 是不是「当前 provider」写的：
    /// - 必须是 PingIslandBridge 的 command
    /// - 若 provider 有 client-kind 标识，命令字串还必须含该 client-kind（区分共享文件场景）
    private static func isOwnedByProvider(_ entry: [String: Any], kindMarker: String?) -> Bool {
        guard let cmd = hookCommandString(from: entry), isPingIslandCommand(cmd) else { return false }
        if let marker = kindMarker { return cmd.contains(marker) }
        return true
    }

    /// 收集所有 PingIsland 写的 command（用于 status 判定 stale bridge path）。
    private static func collectPingIslandCommands(from hooks: [String: Any]) -> [String] {
        var commands: [String] = []
        for (_, value) in hooks {
            guard let groups = value as? [Any] else { continue }
            for group in groups {
                guard let dict = group as? [String: Any] else { continue }
                if let hookList = dict["hooks"] as? [[String: Any]] {
                    for hook in hookList {
                        if let cmd = hookCommandString(from: hook), isPingIslandCommand(cmd) {
                            commands.append(cmd)
                        }
                    }
                } else if let cmd = hookCommandString(from: dict), isPingIslandCommand(cmd) {
                    commands.append(cmd)
                }
            }
        }
        return commands
    }

    /// 从 entry 里取出命令字串（兼容 standard 的 `command` 和 copilot 的 `bash`）。
    private static func hookCommandString(from entry: [String: Any]) -> String? {
        for key in ["command", "bash", "powershell"] {
            if let s = entry[key] as? String, !s.trimmingCharacters(in: .whitespaces).isEmpty {
                return s
            }
        }
        return nil
    }

    private static func isPingIslandCommand(_ command: String) -> Bool {
        command.contains("PingIslandBridge") && command.contains("--source")
    }

    // MARK: - Plugin File（OpenCode）

    private static func installPluginFile(_ provider: Provider, bridgePath: String, at url: URL) throws {
        let content = PluginSources.source(for: provider, bridgePath: bridgePath)
        try ensureParentDirectory(of: url)
        try writeText(content, to: url)
        try activatePluginIfNeeded(provider)
    }

    private static func uninstallPluginFile(_ provider: Provider, at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try deactivatePluginIfNeeded(provider)
    }

    // MARK: - Plugin Directory（Hermes / Pi）

    private static func installPluginDirectory(_ provider: Provider, bridgePath: String, at url: URL) throws {
        try ensureDirectory(at: url)
        let files = PluginSources.directoryFiles(for: provider, bridgePath: bridgePath)
        for (name, content) in files {
            try writeText(content, to: url.appendingPathComponent(name))
        }
    }

    private static func uninstallPluginDirectory(_ provider: Provider, at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Hook Directory（OpenClaw）

    private static func installHookDirectory(_ provider: Provider, bridgePath: String, at url: URL) throws {
        try ensureDirectory(at: url)
        let files = PluginSources.directoryFiles(for: provider, bridgePath: bridgePath)
        for (name, content) in files {
            try writeText(content, to: url.appendingPathComponent(name))
        }
        // OpenClaw 还需要在 ~/.openclaw/openclaw.json 里启用这条 hook 名。
        try activatePluginIfNeeded(provider)
    }

    private static func uninstallHookDirectory(_ provider: Provider, at url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        try deactivatePluginIfNeeded(provider)
    }

    // MARK: - TOML Hooks（Kimi）

    private static func installTOMLHooks(_ provider: Provider, bridgePath: String, at url: URL) throws {
        try ensureParentDirectory(of: url)
        let existing = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let stripped = TOMLHookHelper.removePingIslandHooks(in: existing)
        let command = buildBridgeCommand(provider: provider, bridgePath: bridgePath)
        let entries = eventsFor(provider).flatMap { event -> [TOMLHookHelper.Entry] in
            if event.templates.isEmpty {
                return [TOMLHookHelper.Entry(event: event.name, matcher: nil, command: command, timeout: event.timeout)]
            }
            return event.templates.map { template -> TOMLHookHelper.Entry in
                let matcher: String?
                switch template {
                case .plain, .direct: matcher = nil
                case .matcher(let m): matcher = m
                }
                return TOMLHookHelper.Entry(event: event.name, matcher: matcher, command: command, timeout: event.timeout)
            }
        }
        let updated = TOMLHookHelper.append(entries: entries, to: stripped)
        backupIfPossible(url: url)
        do { try updated.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw InstallError.writeSettingsFailed(url, underlying: error) }
    }

    private static func uninstallTOMLHooks(_ provider: Provider, at url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let updated = TOMLHookHelper.removePingIslandHooks(in: content)
        backupIfPossible(url: url)
        do { try updated.write(to: url, atomically: true, encoding: .utf8) }
        catch { throw InstallError.writeSettingsFailed(url, underlying: error) }
    }

    // MARK: - Plugin 激活（OpenCode opencode.json / OpenClaw openclaw.json）

    private static func activatePluginIfNeeded(_ provider: Provider) throws {
        switch provider {
        case .opencode:
            // OpenCode 默认会自动加载 plugins/ 目录下所有文件，不需要额外激活；
            // 这里仍写一个 hint 文件以便用户排查。
            return
        case .openclaw:
            let url = homeURL().appendingPathComponent(".openclaw/openclaw.json")
            try ensureParentDirectory(of: url)
            var root = (try? readJSONObject(url: url)) ?? [:]
            var hooks = (root["hooks"] as? [String: Any]) ?? [:]
            hooks["ping-island-openclaw"] = ["enabled": true]
            root["hooks"] = hooks
            try writeJSONObject(root, to: url)
        default: return
        }
    }

    private static func deactivatePluginIfNeeded(_ provider: Provider) throws {
        switch provider {
        case .openclaw:
            let url = homeURL().appendingPathComponent(".openclaw/openclaw.json")
            guard FileManager.default.fileExists(atPath: url.path) else { return }
            var root = try readJSONObject(url: url)
            if var hooks = root["hooks"] as? [String: Any] {
                hooks.removeValue(forKey: "ping-island-openclaw")
                if hooks.isEmpty { root.removeValue(forKey: "hooks") } else { root["hooks"] = hooks }
            }
            try writeJSONObject(root, to: url)
        default: return
        }
    }

    // MARK: - 检查 sentinel

    private static func containsPingIslandSentinel(at url: URL) -> Bool {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return false }
        let marker = "Ping Island managed"
        if !isDir.boolValue {
            return (try? String(contentsOf: url, encoding: .utf8))?.contains(marker) == true
        }
        // 目录：扫所有子文件找 sentinel marker
        guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil) else {
            return false
        }
        for item in items {
            if let s = try? String(contentsOf: item, encoding: .utf8), s.contains(marker) {
                return true
            }
        }
        return false
    }

    // MARK: - 命令构造 / 共享辅助

    /// 形如 `'<bridge>' --source claude --client-kind qoder-cli ...`
    static func buildBridgeCommand(provider: Provider, bridgePath: String) -> String {
        let parts: [String] = [bridgePath, "--source", provider.bridgeSourceArgument]
            + provider.bridgeExtraArguments
        return parts.map(shellEscape).joined(separator: " ")
    }

    /// shell-escape：单引号包裹，内部 ' 转 '\''。
    static func shellEscape(_ raw: String) -> String {
        "'" + raw.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    // MARK: - 文件 IO

    private static func readJSONObject(url: URL) throws -> [String: Any] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return [:] }
        let data: Data
        do { data = try Data(contentsOf: url) }
        catch { throw InstallError.readSettingsFailed(url, underlying: error) }
        if data.isEmpty { return [:] }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: []),
              let dict = object as? [String: Any] else {
            throw InstallError.parseSettingsFailed(url, message: "顶层不是 JSON 对象")
        }
        return dict
    }

    private static func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try ensureParentDirectory(of: url)
        do {
            let data = try JSONSerialization.data(
                withJSONObject: object,
                options: [.prettyPrinted, .sortedKeys]
            )
            backupIfPossible(url: url)
            try data.write(to: url, options: .atomic)
        } catch {
            throw InstallError.writeSettingsFailed(url, underlying: error)
        }
    }

    private static func writeText(_ text: String, to url: URL) throws {
        do {
            backupIfPossible(url: url)
            try text.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            throw InstallError.writeSettingsFailed(url, underlying: error)
        }
    }

    private static func ensureDirectory(at url: URL) throws {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    private static func ensureParentDirectory(of url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private static func backupIfPossible(url: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: url.path) else { return }
        let backupURL = url.appendingPathExtension("ping-island-bak")
        try? fm.removeItem(at: backupURL)
        try? fm.copyItem(at: url, to: backupURL)
    }

    // MARK: - 事件清单（数据，全部对齐主仓 ClientProfileRegistry）

    private static func eventsFor(_ provider: Provider) -> [EventSpec] {
        switch provider {
        case .claude:       return claudeEvents
        case .codex:        return codexEvents
        case .gemini:       return geminiEvents
        case .qwen:         return qwenEvents
        case .codebuddy:    return codebuddyEvents
        case .codebuddyCli: return codebuddyCliEvents
        case .workbuddy:    return workbuddyEvents
        case .cursor:       return cursorEvents
        case .qoder:        return qoderEvents
        case .qoderCli:     return qoderCliEvents
        case .qoderwork:    return qoderworkEvents
        case .copilot:      return copilotEvents
        case .kimi:         return kimiEvents
        // pluginDirectory / pluginFile / hookDirectory 类不走事件清单
        case .hermes, .pi, .opencode, .openclaw: return []
        }
    }

    // 以下事件清单照搬主仓 PingIsland/Models/ClientProfile.swift 中的 ManagedHookClientProfile.events。
    private static let claudeEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit",   templates: [.plain]),
        EventSpec("PreToolUse",         templates: [.matcher("*")]),
        EventSpec("PostToolUse",        templates: [.matcher("*")]),
        EventSpec("PermissionRequest",  templates: [.matcher("*")], timeout: 86_400),
        EventSpec("Notification",       templates: [.matcher("*")]),
        EventSpec("Stop",               templates: [.plain]),
        EventSpec("SubagentStop",       templates: [.plain]),
        EventSpec("SessionStart",       templates: [.plain]),
        EventSpec("SessionEnd",         templates: [.plain]),
        EventSpec("PreCompact",         templates: [.matcher("auto"), .matcher("manual")]),
    ]
    private static let codexEvents: [EventSpec] = [
        EventSpec("SessionStart",       templates: [.matcher("*")]),
        EventSpec("UserPromptSubmit",   templates: [.matcher("*")]),
        EventSpec("PreToolUse",         templates: [.matcher("*")]),
        EventSpec("PostToolUse",        templates: [.matcher("*")]),
        EventSpec("PermissionRequest",  templates: [.matcher("*")], timeout: 86_400),
        EventSpec("Stop",               templates: [.matcher("*")]),
    ]
    /// Gemini 的 BeforeTool/AfterTool 用正则 `.*`，其余为 plain。
    private static let geminiEvents: [EventSpec] = [
        EventSpec("SessionStart",   templates: [.plain]),
        EventSpec("SessionEnd",     templates: [.plain]),
        EventSpec("BeforeAgent",    templates: [.plain]),
        EventSpec("AfterAgent",     templates: [.plain]),
        EventSpec("BeforeTool",     templates: [.matcher(".*")]),
        EventSpec("AfterTool",      templates: [.matcher(".*")]),
        EventSpec("Notification",   templates: [.plain]),
        EventSpec("PreCompress",    templates: [.plain]),
    ]
    private static let qwenEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit",     templates: [.plain]),
        EventSpec("PreToolUse",           templates: [.matcher("*")]),
        EventSpec("PostToolUse",          templates: [.matcher("*")]),
        EventSpec("PostToolUseFailure",   templates: [.matcher("*")]),
        EventSpec("Notification",         templates: [.matcher("*")]),
        EventSpec("SessionStart",         templates: [.matcher("*")]),
        EventSpec("SessionEnd",           templates: [.matcher("*")]),
        EventSpec("Stop",                 templates: [.plain]),
        EventSpec("SubagentStart",        templates: [.matcher("*")]),
        EventSpec("SubagentStop",         templates: [.matcher("*")]),
        EventSpec("PreCompact",           templates: [.matcher("manual"), .matcher("auto")]),
        EventSpec("PermissionRequest",    templates: [.matcher("*")], timeout: 86_400),
    ]
    private static let codebuddyEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit", templates: [.plain]),
        EventSpec("PreToolUse",       templates: [.matcher("*")]),
        EventSpec("PostToolUse",      templates: [.matcher("*")]),
        EventSpec("Notification",     templates: [.matcher("*")]),
        EventSpec("Stop",             templates: [.plain]),
        EventSpec("SubagentStop",     templates: [.plain]),
        EventSpec("SessionStart",     templates: [.plain]),
        EventSpec("SessionEnd",       templates: [.plain]),
        EventSpec("PreCompact",       templates: [.matcher("auto"), .matcher("manual")]),
    ]
    private static let codebuddyCliEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit",  templates: [.plain]),
        EventSpec("PreToolUse",        templates: [.matcher("*")], timeout: 86_400),
        EventSpec("PostToolUse",       templates: [.matcher("*")]),
        EventSpec("PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
        EventSpec("Notification",      templates: [.matcher("*")]),
        EventSpec("Stop",              templates: [.plain]),
        EventSpec("SubagentStop",      templates: [.plain]),
        EventSpec("SessionStart",      templates: [.matcher("startup"), .matcher("resume"),
                                                  .matcher("clear"), .matcher("compact")]),
        EventSpec("SessionEnd",        templates: [.matcher("clear"), .matcher("logout"),
                                                  .matcher("prompt_input_exit"), .matcher("other")]),
        EventSpec("PreCompact",        templates: [.matcher("auto"), .matcher("manual")]),
    ]
    private static let workbuddyEvents: [EventSpec] = codebuddyEvents
    private static let cursorEvents: [EventSpec] = [
        EventSpec("beforeSubmitPrompt", templates: [.direct]),
        EventSpec("preToolUse",         templates: [.direct]),
        EventSpec("postToolUse",        templates: [.direct]),
        EventSpec("stop",               templates: [.direct]),
        EventSpec("subagentStop",       templates: [.direct]),
        EventSpec("sessionStart",       templates: [.direct]),
        EventSpec("sessionEnd",         templates: [.direct]),
        EventSpec("preCompact",         templates: [.direct]),
    ]
    private static let qoderEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit",   templates: [.plain]),
        EventSpec("PreToolUse",         templates: [.matcher("*")]),
        EventSpec("PostToolUse",        templates: [.matcher("*")]),
        EventSpec("PostToolUseFailure", templates: [.matcher("*")]),
        EventSpec("PermissionRequest",  templates: [.matcher("*")]),
        EventSpec("Notification",       templates: [.matcher("*")]),
        EventSpec("Stop",               templates: [.plain]),
    ]
    private static let qoderCliEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit",  templates: [.plain]),
        EventSpec("PreToolUse",        templates: [.matcher("*")], timeout: 86_400),
        EventSpec("PostToolUse",       templates: [.matcher("*")]),
        EventSpec("PermissionRequest", templates: [.matcher("*")], timeout: 86_400),
        EventSpec("Notification",      templates: [.matcher("*")]),
        EventSpec("Stop",              templates: [.plain]),
        EventSpec("SubagentStop",      templates: [.plain]),
        EventSpec("SessionStart",      templates: [.plain]),
        EventSpec("SessionEnd",        templates: [.plain]),
        EventSpec("PreCompact",        templates: [.matcher("auto"), .matcher("manual")]),
    ]
    private static let qoderworkEvents: [EventSpec] = qoderEvents
    private static let copilotEvents: [EventSpec] = [
        EventSpec("sessionStart",         templates: [.matcher("*")]),
        EventSpec("sessionEnd",           templates: [.matcher("*")]),
        EventSpec("userPromptSubmitted",  templates: [.matcher("*")]),
        EventSpec("preToolUse",           templates: [.matcher("*")]),
        EventSpec("postToolUse",          templates: [.matcher("*")]),
        EventSpec("agentStop",            templates: [.matcher("*")]),
        EventSpec("subagentStop",         templates: [.matcher("*")]),
        EventSpec("errorOccurred",        templates: [.matcher("*")]),
    ]
    private static let kimiEvents: [EventSpec] = [
        EventSpec("UserPromptSubmit", templates: [.plain]),
        EventSpec("PreToolUse",       templates: [.matcher("*")]),
        EventSpec("PostToolUse",      templates: [.matcher("*")]),
        EventSpec("Notification",     templates: [.matcher("*")]),
        EventSpec("Stop",             templates: [.plain]),
        EventSpec("SessionStart",     templates: [.plain]),
        EventSpec("SessionEnd",       templates: [.plain]),
    ]
}

// MARK: - Provider 私有属性扩展（避开方法体内访问其它静态成员的可见性问题）

private extension HookInstaller.Provider {
    /// JSON hook command 里可以用来识别“这条是本 profile 写的”的子串。
    /// 注意 command 是 shellEscape 之后的产物，每个 arg 都被单引号包裹：
    ///   '/path/bridge' '--source' 'claude' '--client-kind' 'codebuddy' ...
    /// 以“带单引号的完整 token”作为 marker，能同时避免 codebuddy 误匹配 codebuddy-cli。
    var clientKindMarker: String? {
        switch self {
        case .qoder:        return "'--client-kind' 'qoder'"
        case .qoderCli:     return "'--client-kind' 'qoder-cli'"
        case .codebuddy:    return "'--client-kind' 'codebuddy'"
        case .codebuddyCli: return "'--client-kind' 'codebuddy-cli'"
        default:            return nil
        }
    }
}
