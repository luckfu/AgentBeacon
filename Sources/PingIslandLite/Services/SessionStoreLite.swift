import Foundation
import IslandShared

/// Lite 版的轻量会话状态仓库。
///
/// 目标不是完整复刻主仓 SessionStore，而是先把 hook 事件从“最近日志”
/// 升级成稳定的会话快照：菜单、详情窗口、Codex 补充同步都读同一份状态。
final class SessionStoreLite: @unchecked Sendable {
    static let shared = SessionStoreLite()

    struct SessionSnapshot: Equatable, Identifiable {
        let id: String
        let provider: AgentProvider
        let title: String
        let preview: String
        let cwd: String?
        let status: SessionStatus?
        let terminalContext: TerminalContext
        let intervention: InterventionRequest?
        let expectsResponse: Bool
        let metadata: [String: String]
        let latestEnvelope: BridgeEnvelope
        let firstSeenAt: Date
        let lastSeenAt: Date
        let eventCount: Int
        let events: [BridgeEnvelope]

        var requiresAttention: Bool {
            expectsResponse || intervention != nil || status?.requiresAttention == true
        }
    }

    struct Snapshot: Equatable {
        let sessions: [SessionSnapshot]
        let totalEventCount: Int
    }

    private struct MutableSession {
        var provider: AgentProvider
        var title: String
        var preview: String
        var cwd: String?
        var status: SessionStatus?
        var terminalContext: TerminalContext
        var intervention: InterventionRequest?
        var expectsResponse: Bool
        var metadata: [String: String]
        var latestEnvelope: BridgeEnvelope
        var firstSeenAt: Date
        var lastSeenAt: Date
        var eventCount: Int
        var events: [BridgeEnvelope]
    }

    private let lock = NSLock()
    private var sessions: [String: MutableSession] = [:]
    private var totalEventCount = 0
    private let maxEventsPerSession = 80
    private let maxVisibleSessions = 20

    @discardableResult
    func record(_ envelope: BridgeEnvelope) -> Snapshot {
        lock.lock()
        defer { lock.unlock() }

        totalEventCount += 1
        let id = envelope.sessionKey
        if var session = sessions[id] {
            session.provider = envelope.provider
            session.title = Self.bestTitle(from: envelope, fallback: session.title)
            session.preview = Self.bestPreview(from: envelope, fallback: session.preview)
            session.cwd = envelope.cwd ?? envelope.terminalContext.currentDirectory ?? session.cwd
            session.status = envelope.status ?? session.status
            session.terminalContext = envelope.terminalContext
            session.intervention = envelope.intervention ?? session.intervention
            session.expectsResponse = envelope.expectsResponse
            session.metadata = session.metadata.merging(envelope.metadata) { _, new in new }
            session.latestEnvelope = envelope
            session.lastSeenAt = envelope.sentAt
            session.eventCount += 1
            session.events.append(envelope)
            if session.events.count > maxEventsPerSession {
                session.events.removeFirst(session.events.count - maxEventsPerSession)
            }
            sessions[id] = session
        } else {
            sessions[id] = MutableSession(
                provider: envelope.provider,
                title: Self.bestTitle(from: envelope, fallback: envelope.eventType),
                preview: Self.bestPreview(from: envelope, fallback: envelope.eventType),
                cwd: envelope.cwd ?? envelope.terminalContext.currentDirectory,
                status: envelope.status,
                terminalContext: envelope.terminalContext,
                intervention: envelope.intervention,
                expectsResponse: envelope.expectsResponse,
                metadata: envelope.metadata,
                latestEnvelope: envelope,
                firstSeenAt: envelope.sentAt,
                lastSeenAt: envelope.sentAt,
                eventCount: 1,
                events: [envelope]
            )
        }
        pruneIfNeeded()
        return snapshotLocked()
    }

    func clear() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        sessions.removeAll()
        totalEventCount = 0
        return snapshotLocked()
    }

    func snapshot() -> Snapshot {
        lock.lock()
        defer { lock.unlock() }
        return snapshotLocked()
    }

    func session(id: String) -> SessionSnapshot? {
        lock.lock()
        defer { lock.unlock() }
        guard let session = sessions[id] else { return nil }
        return snapshot(id: id, session: session)
    }

    private func pruneIfNeeded() {
        guard sessions.count > maxVisibleSessions else { return }
        let keep = Set(sessions
            .sorted { lhs, rhs in lhs.value.lastSeenAt > rhs.value.lastSeenAt }
            .prefix(maxVisibleSessions)
            .map(\.key))
        sessions = sessions.filter { keep.contains($0.key) }
    }

    private func snapshotLocked() -> Snapshot {
        let rows = sessions
            .map { snapshot(id: $0.key, session: $0.value) }
            .sorted { lhs, rhs in
                if lhs.requiresAttention != rhs.requiresAttention {
                    return lhs.requiresAttention
                }
                return lhs.lastSeenAt > rhs.lastSeenAt
            }
        return Snapshot(sessions: rows, totalEventCount: totalEventCount)
    }

    private func snapshot(id: String, session: MutableSession) -> SessionSnapshot {
        SessionSnapshot(
            id: id,
            provider: session.provider,
            title: session.title,
            preview: session.preview,
            cwd: session.cwd,
            status: session.status,
            terminalContext: session.terminalContext,
            intervention: session.intervention,
            expectsResponse: session.expectsResponse,
            metadata: session.metadata,
            latestEnvelope: session.latestEnvelope,
            firstSeenAt: session.firstSeenAt,
            lastSeenAt: session.lastSeenAt,
            eventCount: session.eventCount,
            events: session.events
        )
    }

    private static func bestTitle(from envelope: BridgeEnvelope, fallback: String) -> String {
        if let intervention = envelope.intervention, !intervention.title.isEmpty {
            return intervention.title
        }
        if let title = envelope.title, !title.isEmpty {
            return title
        }
        return fallback
    }

    private static func bestPreview(from envelope: BridgeEnvelope, fallback: String) -> String {
        if let intervention = envelope.intervention, !intervention.message.isEmpty {
            return intervention.message
        }
        if let preview = envelope.preview, !preview.isEmpty {
            return preview
        }
        return fallback
    }
}
