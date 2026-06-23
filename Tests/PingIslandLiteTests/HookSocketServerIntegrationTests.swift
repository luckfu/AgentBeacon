import XCTest
@testable import PingIslandLite
import IslandShared

/// HookSocketServer 集成测试：起一个 server 监听临时 socket 路径，
/// 用 POSIX socket 客户端发一个 envelope，验证 handler 被调用。
///
/// 这等价于 AgentBeaconTestSender 的程序化版本，专门防止 socket 链路回归。
final class HookSocketServerIntegrationTests: XCTestCase {

    func testEnvelopeRoundTripThroughSocket() async throws {
        // 1. 准备临时 socket 路径，避免污染 /tmp/island.sock
        let socketPath = "/tmp/island-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        // 2. 起 server，handler 用 actor 收 envelope 备查
        let collector = EnvelopeCollector()
        let server = HookSocketServer(socketPath: socketPath) { envelope in
            await collector.append(envelope)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        // 3. 构造 envelope 并通过 socket 发送
        let envelope = BridgeEnvelope(
            provider: .claude,
            eventType: "PreToolUse",
            sessionKey: "integration-\(UUID().uuidString.prefix(6))",
            title: "Integration Test",
            preview: "envelope round trip"
        )
        let payload = try BridgeCodec.encodeEnvelope(envelope)
        let response = try Self.sendSync(payload: payload, to: socketPath)

        // 4. 等 handler 被调用（最多等 2s）
        let received = try await collector.waitForFirst(timeoutSeconds: 2)
        XCTAssertEqual(received.provider, .claude)
        XCTAssertEqual(received.eventType, "PreToolUse")
        XCTAssertEqual(received.sessionKey, envelope.sessionKey)

        // 5. 服务端应当回了一个 BridgeResponse JSON
        XCTAssertFalse(response.isEmpty, "服务端必须返回响应，否则 Bridge CLI 会卡住")
        let decoded = try BridgeCodec.decodeResponse(response)
        XCTAssertEqual(decoded.requestID, envelope.id)
    }

    func testHealthCheck() async throws {
        let socketPath = "/tmp/island-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let server = HookSocketServer(socketPath: socketPath) { _ in
            XCTFail("Health check 不应触发 envelope handler")
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let request = Data(#"{"type":"ping-island-health-check"}"#.utf8)
        let response = try Self.sendSync(payload: request, to: socketPath)
        let text = String(data: response, encoding: .utf8) ?? ""
        XCTAssertTrue(text.contains("\"ok\":true"), "Health check 应当返回 {\"ok\":true}, got: \(text)")
    }

    func testExpectedResponseWaitsForExplicitDecision() async throws {
        let socketPath = "/tmp/island-test-\(UUID().uuidString.prefix(8)).sock"
        defer { unlink(socketPath) }

        let collector = EnvelopeCollector()
        let server = HookSocketServer(socketPath: socketPath) { envelope in
            await collector.append(envelope)
        }
        try await server.start()
        defer { Task { await server.stop() } }

        let envelope = BridgeEnvelope(
            provider: .claude,
            eventType: "PreToolUse",
            sessionKey: "approval-\(UUID().uuidString.prefix(6))",
            title: "Approval Test",
            preview: "wait for menu response",
            intervention: InterventionRequest(
                sessionID: "approval-session",
                kind: .approval,
                title: "Needs approval",
                message: "Approve tool use?"
            ),
            expectsResponse: true
        )
        let fd = try Self.openConnectedSocket(to: socketPath)
        defer { close(fd) }
        try Self.writeAll(try BridgeCodec.encodeEnvelope(envelope), to: fd)
        shutdown(fd, SHUT_WR)

        let received = try await collector.waitForFirst(timeoutSeconds: 2)
        XCTAssertEqual(received.id, envelope.id)
        XCTAssertEqual(received.expectsResponse, true)

        XCTAssertFalse(
            try Self.waitForReadableData(on: fd, timeoutMilliseconds: 150),
            "expectsResponse=true 不应在 respond() 前写回响应"
        )

        let didRespond = await server.respond(
            requestID: envelope.id,
            decision: .deny,
            reason: "Denied by test"
        )
        XCTAssertTrue(didRespond)

        let response = try Self.readAll(from: fd)
        let decoded = try BridgeCodec.decodeResponse(response)
        XCTAssertEqual(decoded.requestID, envelope.id)
        XCTAssertEqual(decoded.decision, .deny)
        XCTAssertEqual(decoded.reason, "Denied by test")
    }

    // MARK: - Helpers

    /// 同步 socket 发包：与 AgentBeaconTestSender 内的实现一致。
    private static func sendSync(payload: Data, to socketPath: String) throws -> Data {
        let fd = try openConnectedSocket(to: socketPath)
        defer { close(fd) }

        try writeAll(payload, to: fd)
        shutdown(fd, SHUT_WR)

        return try readAll(from: fd)
    }

    private static func openConnectedSocket(to socketPath: String) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw POSIXError(.EIO) }

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let utf8 = socketPath.utf8CString.map(UInt8.init(bitPattern:))
        guard utf8.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            throw POSIXError(.ENAMETOOLONG)
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: utf8)
        }

        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else {
            close(fd)
            throw POSIXError(.ECONNREFUSED)
        }
        return fd
    }

    private static func writeAll(_ payload: Data, to fd: Int32) throws {
        var remaining = payload
        while !remaining.isEmpty {
            let written = remaining.withUnsafeBytes { buffer -> Int in
                guard let base = buffer.baseAddress else { return -1 }
                return write(fd, base, remaining.count)
            }
            if written <= 0 { throw POSIXError(.EIO) }
            remaining = remaining.dropFirst(written)
        }
    }

    private static func readAll(from fd: Int32) throws -> Data {
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

    private static func waitForReadableData(on fd: Int32, timeoutMilliseconds: Int32) throws -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let result = poll(&descriptor, 1, timeoutMilliseconds)
        if result < 0 { throw POSIXError(.EIO) }
        return result > 0 && (descriptor.revents & Int16(POLLIN)) != 0
    }
}

/// 收集 handler 被调用的 envelope，actor 保证线程安全。
private actor EnvelopeCollector {
    private var envelopes: [BridgeEnvelope] = []

    func append(_ envelope: BridgeEnvelope) {
        envelopes.append(envelope)
    }

    func waitForFirst(timeoutSeconds: Double) async throws -> BridgeEnvelope {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        while Date() < deadline {
            if let first = envelopes.first {
                return first
            }
            try await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
        throw NSError(domain: "EnvelopeCollector", code: 1, userInfo: [
            NSLocalizedDescriptionKey: "等了 \(timeoutSeconds)s 没有收到 envelope"
        ])
    }
}
