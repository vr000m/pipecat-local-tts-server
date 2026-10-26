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

    /// "not responding" while the failed re-probe count (`LifecycleState.externalFailures`) is above zero.
    public static func isNotResponding(failures: Int) -> Bool { failures > 0 }

    /// The one-line status for the row: `External · <source>` or `Not responding`.
    public static func statusLine(port: Int, launchdLabel: String?, hasLaunchdFamily: Bool, failures: Int) -> String {
        isNotResponding(failures: failures)
            ? "Not responding"
            : "External · " + source(port: port, launchdLabel: launchdLabel, hasLaunchdFamily: hasLaunchdFamily)
    }

    /// Which row actions an External service offers. The app never stops, deletes or
    /// installs a server it did not start.
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

        /// The actions for `phase`: the External set for `.external`, nil for every other phase
        /// (they use their normal actions).
        public static func forPhase(_ phase: ServicePhase) -> Actions? {
            guard phase.isExternal else { return nil }
            return Actions(
                stop: false, delete: false, get: false, install: false, reset: false,
                copyURL: true, copyPipecatService: true, copyEnvironment: true, tryIt: true)
        }
    }
}
