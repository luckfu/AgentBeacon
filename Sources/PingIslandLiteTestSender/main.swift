import Foundation
import IslandShared

/// 端到端验证用的最小测试客户端：构造一个假 envelope 并发到 AgentBeacon
/// 监听的 Unix Socket，方便不启动真实 Claude Code 也能验证 hook 链路是否联通。
///
/// 用法：
///   终端 1：`swift run AgentBeacon`
///   终端 2：`swift run AgentBeaconTestSender`
///   预期：终端 1 打印 `[hook] claude | ...`；菜单栏数字 +1；macOS 通知中心弹一条通知。
///
/// 可用环境变量：
///   ISLAND_SOCKET_PATH       Socket 路径（默认 /tmp/island.sock）
///   PINGISLAND_TEST_PROVIDER 提供方：claude / codex / copilot / kimi / gemini（默认 claude）
///   PINGISLAND_TEST_EVENT    事件类型（默认 SessionStart）
///   PINGISLAND_TEST_TITLE    标题（默认带表情的"端到端测试"）

@main
struct PingIslandLiteTestSender {
    static func main() {
        let env = ProcessInfo.processInfo.environment
        let socketPath = env["ISLAND_SOCKET_PATH"] ?? "/tmp/island.sock"
        let providerRaw = env["PINGISLAND_TEST_PROVIDER"] ?? "claude"
        let eventType = env["PINGISLAND_TEST_EVENT"] ?? "SessionStart"
        let title = env["PINGISLAND_TEST_TITLE"] ?? "🎉 端到端测试"

        guard let provider = AgentProvider(rawValue: providerRaw) else {
            fputs("ERROR: PINGISLAND_TEST_PROVIDER='\(providerRaw)' 不在 \(AgentProvider.allCases.map(\.rawValue))\n", stderr)
            exit(64)
        }

        let envelope = BridgeEnvelope(
            provider: provider,
            eventType: eventType,
            sessionKey: "test-\(UUID().uuidString.prefix(8))",
            title: title,
            preview: "如果你在菜单栏看到我，说明全链路通了！"
        )

        do {
            let payload = try BridgeCodec.encodeEnvelope(envelope)
            let response = try sendBlocking(payload: payload, to: socketPath)

            print("✅ 已发送 envelope 到 \(socketPath)")
            print("   provider=\(provider.rawValue) eventType=\(eventType)")
            if !response.isEmpty,
               let decoded = try? BridgeCodec.decodeResponse(response) {
                print("✅ 收到响应：requestID=\(decoded.requestID)")
            } else {
                print("⚠️  服务端未返回有效响应（envelope 可能仍被处理了）。")
            }
        } catch {
            fputs("❌ 发送失败：\(error)\n", stderr)
            fputs("   请确认 AgentBeacon 已启动并监听 \(socketPath)\n", stderr)
            exit(1)
        }
    }

    /// 阻塞式发包：connect → write 全部 → shutdown(WR) → readAll → close。
    /// 故意不引入额外依赖，纯 POSIX，与 PingIslandBridge CLI 行为一致。
    private static func sendBlocking(payload: Data, to socketPath: String) throws -> Data {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        defer { close(fd) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let connectResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connectResult == 0 else {
            throw POSIXError(.ECONNREFUSED)
        }

        // 全量写入
        var remaining = payload
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, remaining.count)
            }
            if written <= 0 {
                throw POSIXError(.EIO)
            }
            remaining = remaining.dropFirst(written)
        }

        // 必须 shutdown(SHUT_WR)，否则服务端 readAll 读不到 EOF
        shutdown(fd, SHUT_WR)

        // 读响应直到 EOF
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 { throw POSIXError(.EIO) }
            if count == 0 { break }
            response.append(buffer, count: count)
        }
        return response
    }
}
