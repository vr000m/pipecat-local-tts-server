import Foundation

/// What `applicationShouldTerminate` does, as a pure function of what it knows.
public enum QuitGuardDecision: Equatable, Sendable {
    /// `.terminateNow`: a shutdown is already draining; behave as before.
    case proceedNow
    /// `.terminateLater` and `shutdownAll()`: nothing to protect, or the system is quitting us.
    case proceedAfterShutdown
    /// Ask first (Quit anyway / Cancel) with this message.
    case confirm(message: String)
    /// `.terminateCancel`: a terminate arrived while the prompt is already showing.
    case cancel
}

public enum QuitGuardPolicy {
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
        return .confirm(message: message(busy))
    }

    static func message(_ busy: [Service: ClientCount]) -> String {
        let lines = busy.sorted { $0.key.rawValue < $1.key.rawValue }.map { service, count in
            switch count {
            case .known(let n): "\(service.info.displayName): \(n) connected client\(n == 1 ? "" : "s")"
            case .unknown: "\(service.info.displayName): could not check for connected clients"
            }
        }
        return lines.joined(separator: "\n")
    }
}
