import Foundation

/// The counting behind the menu: what is running, startable or blocking Reset, as a pure
/// function of the services' lifecycle states. External services count as running;
/// only services the app started count toward the Quit title (Quit stops those and leaves
/// External servers alone).
public struct ServiceCounts: Equatable, Sendable {
    /// Menu bar icon state.
    public enum Badge: Equatable, Sendable { case none, running, installing }

    /// Running, or an External server that answers (shown as running).
    public let running: Int
    /// Running servers the app started (`.running`); what Quit stops.
    public let owned: Int
    public let installed: Int
    /// Started by the user or External: shown in the main menu.
    public let active: Int
    /// Installed (or downloading) and not active: what the menu offers to start.
    public let startable: Int
    public let installing: Int
    /// A server, install or removal still uses an environment Reset would delete.
    public let blocksReset: Bool

    public init(_ states: [LifecycleState]) {
        running = states.filter(Self.isRunning).count
        owned = states.filter(Self.isOwned).count
        installed = states.filter(\.isInstalled).count
        active = states.filter(\.isActive).count
        startable = states.filter(Self.isStartable).count
        installing = states.filter(\.isInstalling).count
        blocksReset = states.contains { $0.blocksReset }
    }

    /// The app started this service's server (a subprocess or the in-process Apple Speech one),
    /// whatever its phase: Quit stops it. An External server is never owned.
    static func isOwned(_ s: LifecycleState) -> Bool {
        s.server != nil || s.native != nil
    }

    /// Port of each owned service: what the quit guard counts clients on. External servers are
    /// not the app's to protect, so they are absent.
    public static func ownedPorts(_ states: [Service: LifecycleState]) -> [Service: Int] {
        states.filter { isOwned($0.value) }.mapValues(\.port)
    }

    /// A server answers for this service: one the app runs, or an External one.
    public static func isRunning(_ s: LifecycleState) -> Bool {
        switch s.phase {
        case .running, .external: true
        default: false
        }
    }

    /// Installed (or downloading) and not active: what the menu offers to start. Wider than
    /// `LifecycleState.isReadyToStart` (it admits a model still installing or needing a download)
    /// and unrelated to `ServiceLifecycle.acceptsStart`, the reducer's accept guard.
    public static func isStartable(_ s: LifecycleState) -> Bool {
        !s.isActive && (s.isInstalled || s.isInstalling)
    }

    public var badge: Badge {
        if installing > 0 { return .installing }
        return running == 0 ? .none : .running
    }

    /// The panel's one-line status.
    public func summary(bootstrapping: Bool) -> String {
        if bootstrapping { return "Checking services…" }
        switch (running, installed) {
        case (0, 0): return "Add a model to get started"
        case (0, _): return "Nothing running · \(installed) installed"
        case (1, _): return "1 service running"
        default: return "\(running) services running"
        }
    }

    /// "Stop All & Quit" only when the app started a server; External ones are left running.
    public var quitTitle: String { owned == 0 ? "Quit" : "Stop All & Quit" }
}
