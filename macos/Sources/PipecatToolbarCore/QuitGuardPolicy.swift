import Foundation

/// What `applicationShouldTerminate` does, as a pure function of what it knows.
public enum QuitGuardDecision: Equatable, Sendable {
    /// `.terminateNow`: a shutdown is already draining; behave as before.
    case proceedNow
    /// `.terminateLater` and `shutdownAll()`: nothing to protect, or the system is quitting us.
    case proceedAfterShutdown
    /// Ask first (Quit anyway / Cancel) with this prompt.
    case confirm(QuitPrompt)
    /// `.terminateCancel`: a terminate arrived while the prompt is already showing.
    case cancel
}

/// The whole quit confirmation's text: `title` is the alert's message text, `body` (one line per
/// busy service) and `footer` make its informative text. The app target renders it and owns the
/// alert's button titles and default button.
public struct QuitPrompt: Equatable, Sendable {
    public let title: String
    public let body: String
    public let footer: String

    /// `body` and `footer`, a blank line apart: the alert's informative text.
    public var informativeText: String { body + "\n\n" + footer }
}

public enum QuitGuardPolicy {
    /// Client count per owned service: no owned port means no probe at all (the blocking lsof is not
    /// run), otherwise one `probe` call over the distinct ports (services may share a port) and
    /// `counts(ports:byPort:)` for the mapping. This is the one place the app's quit-guard count
    /// pipeline is assembled; the app passes `PortProbe.clientCounts` as `probe`.
    public static func counts(
        ports: [Service: Int], probe: ([Int]) -> [Int: ClientCount]
    ) -> [Service: ClientCount] {
        guard !ports.isEmpty else { return [:] }
        return counts(ports: ports, byPort: probe(Array(Set(ports.values)).sorted()))
    }

    /// Client count per owned service from a per-port probe result; a port the probe did not
    /// report is `.unknown` (which the guard asks about).
    public static func counts(
        ports: [Service: Int], byPort: [Int: ClientCount]
    ) -> [Service: ClientCount] {
        ports.mapValues { byPort[$0] ?? .unknown }
    }

    /// Arms, first match wins: drain in progress, prompt showing, system quit, any client or
    /// unknown count, otherwise no clients. `counts` is keyed by service, owned servers only. It
    /// is a closure the policy calls at most once, and only when no earlier arm has decided, so the
    /// caller's (blocking) lsof probe never runs for a drain, a showing prompt or a system quit:
    /// this function is the single owner of the arm order.
    public static func decide(
        counts: () -> [Service: ClientCount],
        systemQuit: Bool,
        drainInProgress: Bool,
        promptShowing: Bool
    ) -> QuitGuardDecision {
        if drainInProgress { return .proceedNow }
        if promptShowing { return .cancel }
        if systemQuit { return .proceedAfterShutdown }
        let busy = counts().filter { $0.value != .known(0) }
        if busy.isEmpty { return .proceedAfterShutdown }
        return .confirm(prompt(busy))
    }

    /// The prompt for the busy services (none of them `known(0)`). The title and footer claim
    /// connections only when at least one count is known; when every count is unknown they say
    /// clients may be connected.
    static func prompt(_ busy: [Service: ClientCount]) -> QuitPrompt {
        let lines = busy.sorted { $0.key.rawValue < $1.key.rawValue }.map { service, count in
            switch count {
            case .known(let n): "\(service.info.displayName): \(n) connected client\(n == 1 ? "" : "s")"
            case .unknown: "\(service.info.displayName): could not check for connected clients"
            }
        }
        let anyKnown = busy.values.contains { if case .known = $0 { true } else { false } }
        return QuitPrompt(
            title: anyKnown ? "Clients are connected" : "Clients may be connected",
            body: lines.joined(separator: "\n"),
            footer: anyKnown
                ? "Quitting stops these servers and drops the connections."
                : "Quitting stops these servers and drops any connections they have.")
    }
}
