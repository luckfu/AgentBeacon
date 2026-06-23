import Foundation
import IslandShared

/// Unix Domain Socket 服务器：接收 PingIslandBridge CLI 发来的 hook 事件。
///
/// 设计取舍（与 Prototype 版的差异）：
/// 1. **去掉 SessionStore 强依赖**：用一个闭包 handler 把 envelope 抛给上层，让 App 自由决定怎么消费
///    （Lite 阶段 1 只是弹原生通知，未来可以接吉祥物动画、会话列表等）。
/// 2. **支持轻量审批响应**：普通事件秒回空响应；`expectsResponse=true` 的事件保留 fd，
///    等菜单栏显式 approve / deny / cancel 后再写回，避免 hook 端提前放行。
/// 3. **保留 health check**：未来 Hook 安装器会用这个 ping 探活，先把约定留好。
///
/// 与 Bridge CLI 的协议约定：
/// - Socket 路径：`/tmp/island.sock`（可由 `ISLAND_SOCKET_PATH` 环境变量覆盖）
/// - 帧协议：客户端写完后会 shutdown(SHUT_WR)，所以服务端读到 EOF 再开始解码。
actor HookSocketServer {

    /// 上层（AppDelegate / 通知器 / 未来的 SessionStore）实现的事件回调。
    /// 闭包应当是非阻塞的——否则会卡住 socket 读循环。
    typealias EventHandler = @Sendable (BridgeEnvelope) async -> Void

    private static let healthCheckRequest = #"{"type":"ping-island-health-check"}"#
    private static let healthCheckResponse = #"{"ok":true}"#

    private let socketPath: String
    private let handler: EventHandler

    private var listenerFD: Int32 = -1
    private var acceptTask: Task<Void, Never>?

    /// 挨批批表：requestID → 该 hook 连接的 socket fd。
    /// expectsResponse=true 的 envelope 进来后 fd 不被 close，
    /// 一直趴到上层调 respond() 或 stop() 才释放。
    private var pendingApprovals: [UUID: Int32] = [:]

    init(socketPath: String = HookSocketServer.defaultSocketPath, handler: @escaping EventHandler) {
        self.socketPath = socketPath
        self.handler = handler
    }

    /// 与 Bridge CLI 默认值一致，确保 hook 不带环境变量也能找到我们。
    static var defaultSocketPath: String {
        ProcessInfo.processInfo.environment["ISLAND_SOCKET_PATH"] ?? "/tmp/island.sock"
    }

    func start() async throws {
        await stop()

        unlink(socketPath) // 清掉残留的 socket 文件，否则 bind 会 EADDRINUSE。

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else {
            throw POSIXError(.EIO)
        }
        listenerFD = fd

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)

        let maxLength = MemoryLayout.size(ofValue: address.sun_path)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= maxLength else {
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let bindResult = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bindResult == 0 else {
            throw POSIXError(.EADDRINUSE)
        }

        guard listen(fd, 16) == 0 else {
            throw POSIXError(.EIO)
        }

        // 0o600：只有当前用户可读写，避免别的本机用户偷窥 hook 流量。
        chmod(socketPath, 0o600)

        let listenerFDLocal = fd
        acceptTask = Task.detached { [weak self] in
            while !Task.isCancelled {
                let clientFD = accept(listenerFDLocal, nil, nil)
                if clientFD < 0 {
                    if Task.isCancelled { break }
                    continue
                }
                if Task.isCancelled {
                    close(clientFD)
                    break
                }
                guard let self else {
                    close(clientFD)
                    break
                }
                Task.detached { [weak self] in
                    guard let self else { close(clientFD); return }
                    await self.handleClient(fd: clientFD)
                }
            }
        }
    }

    func stop() async {
        let task = acceptTask
        acceptTask = nil
        task?.cancel()

        let fd = listenerFD
        listenerFD = -1
        if fd >= 0 {
            // 让 accept() 立刻返回，detached task 才能退出。
            Self.wakeListener(socketPath: socketPath)
            shutdown(fd, SHUT_RDWR)
            close(fd)
        }
        if let task {
            await task.value
        }
        unlink(socketPath)

        // 退出前关掉所有挨批批的 socket，避免 hook 端死等。
        for (_, pendingFD) in pendingApprovals {
            let cancelResponse = BridgeResponse(
                requestID: UUID(),
                decision: .cancel,
                reason: "AgentBeacon shutting down",
                updatedInput: nil,
                errorMessage: nil
            )
            if let payload = try? BridgeCodec.encodeResponse(cancelResponse) {
                _ = payload.withUnsafeBytes { buffer in
                    write(pendingFD, buffer.baseAddress, buffer.count)
                }
            }
            close(pendingFD)
        }
        pendingApprovals.removeAll()
    }

    // MARK: - Per-client handling

    /// 处理一个 hook 连接。原本是 static（不需访问 actor 状态），
    /// 现在有了 pendingApprovals，改成 instance method，actor 隔离会由
    /// Swift 运行时自动保证字典不会同时读写。
    private func handleClient(fd: Int32) async {
        do {
            let data = try Self.readAll(from: fd)
            let trimmed = String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            if trimmed == Self.healthCheckRequest {
                try Self.writeHealthResponse(to: fd)
                close(fd)
                return
            }

            let envelope = try BridgeCodec.decodeEnvelope(data)
            await handler(envelope)

            if envelope.expectsResponse {
                // 挨批批：fd 暂不 close，留给 respond() 后续写回。
                pendingApprovals[envelope.id] = fd
                return
            }

            // 不需响应的事件：回一个空响应避免 Bridge CLI readAll 卡 EOF。
            let response = BridgeResponse(requestID: envelope.id)
            if let payload = try? BridgeCodec.encodeResponse(response) {
                _ = payload.withUnsafeBytes { buffer in
                    write(fd, buffer.baseAddress, buffer.count)
                }
            }
            close(fd)
        } catch {
            // 任何失败都尝试回个错误响应，避免对端等死。
            let fallback = BridgeResponse(requestID: UUID(), errorMessage: error.localizedDescription)
            if let payload = try? BridgeCodec.encodeResponse(fallback) {
                _ = payload.withUnsafeBytes { buffer in
                    write(fd, buffer.baseAddress, buffer.count)
                }
            }
            close(fd)
        }
    }

    // MARK: - Approval response

    /// 上层（菜单栏点击批准/拒绝）调这个出口把决策写回等待中的 hook 连接。
    /// 主仓 BridgeResponse JSON 形状：{"requestID":"…","decision":{"approve":{}},…}
    @discardableResult
    func respond(
        requestID: UUID,
        decision: InterventionDecision,
        reason: String? = nil,
        updatedInput: [String: JSONValue]? = nil
    ) -> Bool {
        guard let fd = pendingApprovals.removeValue(forKey: requestID) else {
            return false
        }
        let response = BridgeResponse(
            requestID: requestID,
            decision: decision,
            reason: reason,
            updatedInput: updatedInput,
            errorMessage: nil
        )
        defer { close(fd) }
        guard let payload = try? BridgeCodec.encodeResponse(response) else {
            return false
        }
        let result = payload.withUnsafeBytes { buffer -> Int in
            guard let base = buffer.baseAddress else { return -1 }
            return write(fd, base, payload.count)
        }
        return result == payload.count
    }

    // MARK: - Low-level helpers

    private static func readAll(from fd: Int32) throws -> Data {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count < 0 {
                throw POSIXError(.EIO)
            }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func writeHealthResponse(to fd: Int32) throws {
        let data = Data(healthCheckResponse.utf8)
        let ok = data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else { return false }
            return write(fd, base, data.count) == data.count
        }
        guard ok else { throw POSIXError(.EIO) }
    }

    /// 通过自连一次让阻塞的 accept() 立刻返回，从而让监听任务能干净退出。
    private static func wakeListener(socketPath: String) {
        let clientFD = socket(AF_UNIX, SOCK_STREAM, 0)
        guard clientFD >= 0 else { return }
        defer { close(clientFD) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else { return }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }
        _ = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(clientFD, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}
