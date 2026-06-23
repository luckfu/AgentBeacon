import XCTest
@testable import PingIslandLite
import IslandShared

final class SessionStoreLiteTests: XCTestCase {
    func testRecordsAndCoalescesEventsBySessionKey() {
        let store = SessionStoreLite()
        let sessionKey = "session-a"

        _ = store.record(BridgeEnvelope(
            provider: .codex,
            eventType: "SessionStart",
            sessionKey: sessionKey,
            title: "Start",
            preview: "starting"
        ))
        let snapshot = store.record(BridgeEnvelope(
            provider: .codex,
            eventType: "PreToolUse",
            sessionKey: sessionKey,
            title: "Bash",
            preview: "running command",
            metadata: ["tool_name": "Bash"]
        ))

        XCTAssertEqual(snapshot.totalEventCount, 2)
        XCTAssertEqual(snapshot.sessions.count, 1)
        XCTAssertEqual(snapshot.sessions.first?.id, sessionKey)
        XCTAssertEqual(snapshot.sessions.first?.eventCount, 2)
        XCTAssertEqual(snapshot.sessions.first?.title, "Bash")
        XCTAssertEqual(snapshot.sessions.first?.metadata["tool_name"], "Bash")
    }

    func testAttentionSessionsSortBeforeNewerNonAttentionSessions() {
        let store = SessionStoreLite()
        _ = store.record(BridgeEnvelope(
            provider: .codex,
            eventType: "PreToolUse",
            sessionKey: "older-attention",
            title: "Needs approval",
            intervention: InterventionRequest(
                sessionID: "older-attention",
                kind: .approval,
                title: "Approve?",
                message: "Approve this action?"
            ),
            expectsResponse: true,
            sentAt: Date(timeIntervalSince1970: 100)
        ))
        let snapshot = store.record(BridgeEnvelope(
            provider: .codex,
            eventType: "SessionStart",
            sessionKey: "newer-idle",
            title: "Idle",
            sentAt: Date(timeIntervalSince1970: 200)
        ))

        XCTAssertEqual(snapshot.sessions.map(\.id), ["older-attention", "newer-idle"])
        XCTAssertTrue(snapshot.sessions[0].requiresAttention)
        XCTAssertFalse(snapshot.sessions[1].requiresAttention)
    }
}
