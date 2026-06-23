import XCTest
@testable import IslandShared

/// 冒烟测试：确认 IslandShared 在 Swift 5.7 / macOS 12 工具链下能编译并跑起来。
/// 真实业务测试覆盖应在后续阶段从 Prototype/Tests 选择性移植。
final class BridgeCodecSmokeTests: XCTestCase {
    func testEnvelopeRoundTrip() throws {
        let envelope = BridgeEnvelope(
            provider: .claude,
            eventType: "SessionStart",
            sessionKey: "smoke-session",
            title: "Smoke",
            preview: "hello"
        )
        let data = try BridgeCodec.encodeEnvelope(envelope)
        let decoded = try BridgeCodec.decodeEnvelope(data)
        XCTAssertEqual(decoded.sessionKey, "smoke-session")
        XCTAssertEqual(decoded.eventType, "SessionStart")
        XCTAssertEqual(decoded.provider, .claude)
    }
}
