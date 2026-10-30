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

/// How the per-service "wanted running" flag changes on a lifecycle event. Every event kind
/// chooses two effects in one exhaustive switch (`rule`, no `default`, so a new kind must choose
/// both): one before app quit began and one after (`quitting`, which callers always pass).
///
/// Before quit: (1) the phase newly entering `.failed` clears, whatever the kind; otherwise the
/// kind's effect: `stopRequested` / `removeRequested` clear, `ready` / `nativeBound` set when the
/// phase is newly `.running`, everything else keeps.
///
/// After quit began: the failure rule is off (a quit never changes the flag: not a `ready` the
/// drain still reads, nor a failure the shutdown causes) and only the user's own `stopRequested`
/// / `removeRequested` clear; every other kind keeps. `ServiceDriver` refuses `remove()` (and
/// every other new intent but Stop) once quitting, so in practice only a Stop reaches this with
/// `quitting`; the `removeRequested` row records what a Delete would mean there, not a second
/// gate. Which events can occur is the driver's; what each does to the flag is only this.
public enum WantedTransition {
    /// What one event kind does to the flag.
    enum Effect: Equatable, Sendable {
        case keep, clear, setWhenNewlyRunning
    }

    /// The kind's effect before quit began, and after.
    struct Rule: Equatable, Sendable {
        var normal: Effect
        var quitting: Effect
    }

    static func rule(_ kind: LifecycleEvent.Kind) -> Rule {
        switch kind {
        case .stopRequested, .removeRequested:
            Rule(normal: .clear, quitting: .clear)
        case .ready, .nativeBound:
            Rule(normal: .setWhenNewlyRunning, quitting: .keep)
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .installRequested,
            .cancelInstallRequested, .installStage, .installEnded, .appleSpeechInstallEnded, .startRequested,
            .portOwnerFound, .launched, .launchFailed, .nativeLaunched, .nativeFailed, .supervisedError,
            .readyTimedOut, .exited, .shutdownRequested, .shutdownServers, .removalResumed, .removalFailed,
            .removalFinished, .dismissFailure, .externalFound, .externalLost, .startProbeResult, .tryItRequested:
            Rule(normal: .keep, quitting: .keep)
        }
    }

    public static func next(
        wanted: Bool, kind: LifecycleEvent.Kind, before: ServicePhase, after: ServicePhase, quitting: Bool
    ) -> Bool {
        let rule = rule(kind)
        if !quitting, case .failed = after {
            if case .failed = before {} else { return false }
        }
        switch quitting ? rule.quitting : rule.normal {
        case .clear: return false
        case .keep: return wanted
        case .setWhenNewlyRunning: return before != .running && after == .running ? true : wanted
        }
    }
}
