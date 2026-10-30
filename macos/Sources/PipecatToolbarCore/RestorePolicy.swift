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
            return state.cache?.cached == false ? .skip(.modelNotCached) : .start
        // Not installed, still checking, unavailable, mid-install or removal, or an install failure.
        case .notInstalled, .checking, .unavailable, .installing, .removing, .failed:
            return .skip(.notInstalled)
        }
    }
}

/// How the per-service "wanted running" flag changes on a lifecycle event. Precedence, first
/// match wins: (0) once app quit began (`quitting`), every kind but the user's own
/// `stopRequested` / `removeRequested` keeps (a quit never changes the flag: not a `ready` the
/// drain still reads, nor a failure the shutdown causes); (1) the phase newly enters `.failed`
/// clears; (2) `stopRequested` clears; (3) `removeRequested` clears; (4) `ready` / `nativeBound`
/// with the phase newly `.running` sets; (5) everything else keeps. The kind switch has no
/// `default`: a new event kind must choose its effect here.
public enum WantedTransition {
    public static func next(
        wanted: Bool, kind: LifecycleEvent.Kind, before: ServicePhase, after: ServicePhase, quitting: Bool = false
    ) -> Bool {
        if quitting, kind != .stopRequested, kind != .removeRequested { return wanted }
        if case .failed = after {
            if case .failed = before {} else { return false }
        }
        switch kind {
        case .stopRequested, .removeRequested:
            return false
        case .ready, .nativeBound:
            return before != .running && after == .running ? true : wanted
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .installRequested,
            .cancelInstallRequested, .installStage, .installEnded, .appleSpeechInstallEnded, .startRequested,
            .portOwnerFound, .launched, .launchFailed, .nativeLaunched, .nativeFailed, .supervisedError,
            .readyTimedOut, .exited, .shutdownRequested, .shutdownServers, .removalResumed, .removalFailed,
            .removalFinished, .dismissFailure, .externalFound, .externalLost, .startProbeResult, .tryItRequested:
            return wanted
        }
    }
}
