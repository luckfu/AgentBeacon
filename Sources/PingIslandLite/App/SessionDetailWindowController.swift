import AppKit
import Foundation
import IslandShared

@MainActor
final class SessionDetailWindowController: NSWindowController {
    static let shared = SessionDetailWindowController()

    typealias ApprovalResponder = (UUID, InterventionDecision, String?) -> Void

    private var approvalResponder: ApprovalResponder?
    private var currentSessionID: String?

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 620, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "AgentBeacon · 会话详情"
        window.center()
        super.init(window: window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionDetailWindowController 不支持 nib 加载")
    }

    func setApprovalResponder(_ responder: @escaping ApprovalResponder) {
        approvalResponder = responder
    }

    func show(session: SessionStoreLite.SessionSnapshot) {
        currentSessionID = session.id
        window?.title = "AgentBeacon · \(session.title)"
        window?.contentView = SessionDetailView(session: session) { [weak self] requestID, decision, reason in
            self?.approvalResponder?(requestID, decision, reason)
            self?.refreshCurrentSession()
        }
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func refreshCurrentSession() {
        guard let currentSessionID,
              let session = SessionStoreLite.shared.session(id: currentSessionID) else { return }
        window?.contentView = SessionDetailView(session: session) { [weak self] requestID, decision, reason in
            self?.approvalResponder?(requestID, decision, reason)
            self?.refreshCurrentSession()
        }
    }
}

private final class SessionDetailView: NSView {
    init(
        session: SessionStoreLite.SessionSnapshot,
        respond: @escaping (UUID, InterventionDecision, String?) -> Void
    ) {
        super.init(frame: NSRect(x: 0, y: 0, width: 620, height: 520))
        wantsLayer = true
        layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor

        let scroll = NSScrollView(frame: bounds.insetBy(dx: 18, dy: 18))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 4, left: 4, bottom: 16, right: 12)

        stack.addArrangedSubview(Self.label(session.title, size: 20, weight: .semibold, color: .labelColor))
        stack.addArrangedSubview(Self.label(Self.summaryLine(for: session), size: 12, weight: .medium, color: .secondaryLabelColor))

        if session.requiresAttention {
            stack.addArrangedSubview(Self.attentionBox(for: session, respond: respond))
        }

        stack.addArrangedSubview(Self.separator(width: 560))
        stack.addArrangedSubview(Self.label("Preview", size: 13, weight: .semibold, color: .labelColor))
        stack.addArrangedSubview(Self.wrappingLabel(session.preview, width: 560))

        if let cwd = session.cwd, !cwd.isEmpty {
            stack.addArrangedSubview(Self.label("Working Directory", size: 13, weight: .semibold, color: .labelColor))
            stack.addArrangedSubview(Self.monoLabel(cwd, width: 560))
        }

        stack.addArrangedSubview(Self.separator(width: 560))
        stack.addArrangedSubview(Self.label("Events", size: 13, weight: .semibold, color: .labelColor))
        for event in session.events.suffix(30).reversed() {
            stack.addArrangedSubview(Self.eventRow(event))
        }

        stack.translatesAutoresizingMaskIntoConstraints = false
        scroll.documentView = stack
        addSubview(scroll)

        NSLayoutConstraint.activate([
            stack.widthAnchor.constraint(equalToConstant: 570)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SessionDetailView 不支持 nib 加载")
    }

    private static func summaryLine(for session: SessionStoreLite.SessionSnapshot) -> String {
        let client = session.metadata["client_name"] ?? session.provider.rawValue
        let terminal = session.terminalContext.ideName
            ?? session.terminalContext.terminalProgram
            ?? session.terminalContext.tmuxSession
            ?? "unknown terminal"
        return "\(client) · \(terminal) · \(session.eventCount) events"
    }

    private static func attentionBox(
        for session: SessionStoreLite.SessionSnapshot,
        respond: @escaping (UUID, InterventionDecision, String?) -> Void
    ) -> NSView {
        let box = NSBox(frame: NSRect(x: 0, y: 0, width: 560, height: 96))
        box.boxType = .custom
        box.fillColor = NSColor.systemOrange.withAlphaComponent(0.10)
        box.borderColor = NSColor.systemOrange.withAlphaComponent(0.35)
        box.cornerRadius = 8

        let title = label(session.intervention?.title ?? "Needs your response", size: 13, weight: .semibold, color: .labelColor)
        title.frame = NSRect(x: 14, y: 62, width: 530, height: 18)
        box.addSubview(title)

        let message = wrappingLabel(session.intervention?.message ?? "This session is waiting for a response.", width: 530)
        message.frame = NSRect(x: 14, y: 34, width: 530, height: 24)
        box.addSubview(message)

        let requestID = session.latestEnvelope.id
        let approve = button("批准") { respond(requestID, .approve, nil) }
        approve.frame = NSRect(x: 14, y: 8, width: 72, height: 24)
        box.addSubview(approve)

        let deny = button("拒绝") { respond(requestID, .deny, "Denied from AgentBeacon") }
        deny.frame = NSRect(x: 92, y: 8, width: 72, height: 24)
        box.addSubview(deny)

        let cancel = button("取消") { respond(requestID, .cancel, "Cancelled from AgentBeacon") }
        cancel.frame = NSRect(x: 170, y: 8, width: 72, height: 24)
        box.addSubview(cancel)

        return box
    }

    private static func eventRow(_ event: BridgeEnvelope) -> NSView {
        let view = NSView(frame: NSRect(x: 0, y: 0, width: 560, height: 44))
        let title = label("\(event.eventType) · \(event.title ?? "-")", size: 12, weight: .medium, color: .labelColor)
        title.frame = NSRect(x: 0, y: 22, width: 560, height: 16)
        view.addSubview(title)
        let preview = monoLabel(event.preview ?? event.metadata["tool_name"] ?? event.sessionKey, width: 560)
        preview.frame = NSRect(x: 0, y: 2, width: 560, height: 16)
        view.addSubview(preview)
        return view
    }

    private static func separator(width: CGFloat) -> NSView {
        let line = NSBox(frame: NSRect(x: 0, y: 0, width: width, height: 1))
        line.boxType = .separator
        return line
    }

    private static func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    private static func wrappingLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = .systemFont(ofSize: 12, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.frame.size.width = width
        return label
    }

    private static func monoLabel(_ text: String, width: CGFloat) -> NSTextField {
        let label = NSTextField(labelWithString: text)
        label.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        label.textColor = .secondaryLabelColor
        label.lineBreakMode = .byTruncatingMiddle
        label.frame.size.width = width
        return label
    }

    private static func button(_ title: String, action: @escaping () -> Void) -> NSButton {
        let button = ClosureButton(title: title, target: nil, action: nil)
        button.bezelStyle = .rounded
        button.onClick = action
        return button
    }
}

private final class ClosureButton: NSButton {
    var onClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        onClick?()
    }
}
