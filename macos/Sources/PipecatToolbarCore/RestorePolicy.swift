import Foundation

/// Why a wanted service is not started at launch.
public enum SkipReason: Equatable, Sendable {
    case notWanted, preferenceOff, external, notInstalled, modelNotCached, alreadyActive
}

public enum RestoreDecision: Equatable, Sendable {
    case start
    case skip(SkipReason)
}

/// Which services to start after `.bootstrapDone`, as a pure function of the persisted
/// wanted set and the services' lifecycle states.
public enum RestorePolicy {
    /// Whether `AppModel` runs the launch restore now: once per process (`alreadyRan`), and only
    /// from a bootstrap that ended in `ready` (a quit or failure that overtook it restores nothing).
    /// The `restoreOnLaunch` preference is `plan`'s `preferenceOn`, not part of this gate.
    public static func shouldRun(alreadyRan: Bool, phase: AppPhase) -> Bool {
        !alreadyRan && phase == .ready
    }

    /// One decision per service in `states`. An installed service with an outdated environment
    /// is `start`: the reducer turns that into a packages refresh.
    public static func plan(
        wanted: Set<Service>, states: [Service: LifecycleState], preferenceOn: Bool
    ) -> [Service: RestoreDecision] {
        states.reduce(into: [:]) { plan, entry in
            plan[entry.key] = decision(
                wanted: wanted.contains(entry.key), state: entry.value, preferenceOn: preferenceOn)
        }
    }

    /// Per-service arms, first match wins.
    public static func decision(wanted: Bool, state: LifecycleState, preferenceOn: Bool) -> RestoreDecision {
        if !wanted { return .skip(.notWanted) }
        if !preferenceOn { return .skip(.preferenceOff) }
        switch state.phase {
        case .external: return .skip(.external)
        case .starting, .running, .stopping: return .skip(.alreadyActive)
        // A server that crashed this process is `isActive`; the user sees the failure, so no retry.
        case .failed(let failure) where failure.isRuntime: return .skip(.alreadyActive)
        case .needsModel: return .skip(.modelNotCached)
        case .installed:
            return state.isReadyToStart ? .start : .skip(.modelNotCached)
        // Not installed, still checking, unavailable, mid-install or removal, or an install failure.
        case .notInstalled, .checking, .unavailable, .installing, .removing, .failed:
            return .skip(.notInstalled)
        }
    }
}
