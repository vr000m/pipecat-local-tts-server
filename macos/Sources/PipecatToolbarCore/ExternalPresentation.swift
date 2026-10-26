import Foundation

/// How an External service (a server the app did not start) is shown and what a person may
/// do with it. Pure, so the menu and the detail view share one decision and tests can pin it.
public enum ExternalPresentation {
    /// Where the server comes from, for the "External" source line.
    ///
    /// - `launchdLabel`: the LaunchAgent label, only when `PortProbe.owner` confirmed the
    ///   port holder's pid is that agent's pid. Pass nil when unconfirmed or not yet looked up.
    /// - `hasLaunchdFamily`: whether the service has a LaunchAgent label at all
    ///   (`ServiceInfo.launchdLabel != nil`). Variants and Apple Speech do not, so they never
    ///   show a label even if one is passed.
    public static func source(port: Int, launchdLabel: String?, hasLaunchdFamily: Bool) -> String {
        if hasLaunchdFamily, let launchdLabel, !launchdLabel.isEmpty { return launchdLabel }
        return "\(ServiceCatalog.host):\(port)"
    }

    /// When the source line's LaunchAgent label is looked up (`PortProbe.owner`, read-only), and
    /// what a finished lookup leaves behind. `ServiceModel` keeps the label (presentation state,
    /// not lifecycle state, so not in `LifecycleState`) and runs the lookup on every discovery
    /// pass; every decision about it is here, gated by `externalEpoch` like discovery itself.
    public enum OwnerLookup: Equatable, Sendable {
        /// Not External, or no LaunchAgent family: there is no label to show.
        case clear
        /// Look up who holds `port`; the answer belongs to the adoption current at `epoch`.
        case lookUp(port: Int, epoch: Int)

        public static func step(for state: LifecycleState, hasLaunchdFamily: Bool) -> OwnerLookup {
            guard hasLaunchdFamily, case .external(let port, _) = state.phase else { return .clear }
            return .lookUp(port: port, epoch: state.externalEpoch)
        }

        /// The label after a lookup started at `epoch` found `found` (nil: not that agent's pid).
        /// A cancelled lookup (Quit) changes nothing; one whose adoption ended or was replaced
        /// since it began (`externalEpoch` moved, or the service is no longer External) clears
        /// the label, so a label is only ever the confirmed answer for the current adoption.
        public static func settle(
            found: String?, startedAt epoch: Int, cancelled: Bool, current: String?, in state: LifecycleState
        ) -> String? {
            if cancelled { return current }
            guard state.phase.isExternal, state.externalEpoch == epoch else { return nil }
            return found
        }
    }

    /// "not responding" while the failed re-probe count (`LifecycleState.externalFailures`) is above zero.
    public static func isNotResponding(failures: Int) -> Bool { failures > 0 }

    /// The one-line status for the row: `External · <source>`, or `External · not responding`
    /// during the re-probe window (the row still says the server is not the app's).
    public static func statusLine(port: Int, launchdLabel: String?, hasLaunchdFamily: Bool, failures: Int) -> String {
        isNotResponding(failures: failures)
            ? "External · not responding"
            : "External · " + source(port: port, launchdLabel: launchdLabel, hasLaunchdFamily: hasLaunchdFamily)
    }

    /// Which row actions an External service offers. The app never stops, deletes or
    /// installs a server it did not start. Every view that shows an External row reads its
    /// buttons from here (`ServiceModel.externalActions`): the running row and the menu
    /// (Stop, Copy URL), the catalog row (Get / Install), Delete Model (`canDeleteModel`),
    /// the detail view (Open Try It) and the STT Try it card (Record). `reset` is pinned for
    /// completeness: Reset is app-wide and gated by `LifecycleState.blocksReset`.
    public struct Actions: Equatable, Sendable {
        public var stop: Bool
        public var delete: Bool
        public var get: Bool
        public var install: Bool
        public var reset: Bool
        public var copyURL: Bool
        public var copyPipecatService: Bool
        public var copyEnvironment: Bool
        public var tryIt: Bool
        /// STT Try it may record from the microphone. Off for External: the server is trusted
        /// by its `server.hello` alone (any local process can hold a catalog port), so only the
        /// bundled test clip and typed text go to it, never live speech.
        public var microphone: Bool

        /// The actions for `phase`: the External set for `.external`, nil for every other phase
        /// (they use their normal actions).
        public static func forPhase(_ phase: ServicePhase) -> Actions? {
            guard phase.isExternal else { return nil }
            return Actions(
                stop: false, delete: false, get: false, install: false, reset: false,
                copyURL: true, copyPipecatService: true, copyEnvironment: true, tryIt: true, microphone: false)
        }
    }
}
