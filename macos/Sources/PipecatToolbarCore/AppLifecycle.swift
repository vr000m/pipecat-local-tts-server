import Foundation

// The app-wide lifecycle: locating the tools (bootstrap), Reset and quit. A
// pure reducer, like `ServiceLifecycle` for a single service; `AppModel` is
// its adapter (it runs the effects and sends their results back).
//
// The one rule: at most one app-wide job (a bootstrap or a Reset) runs at a
// time, and the phase names it. An intent sets the phase synchronously, before
// any task starts, so a second request in the same window is refused. Quit is
// accepted from every phase but `shuttingDown`, always runs the full shutdown
// (servers, bootstrap subprocesses, the environment manager and its probes),
// and waits for the job in flight; once quit began, no job's result moves the
// phase again.

/// Where the app is, app-wide.
public enum AppPhase: Equatable, Sendable {
    /// Launched; the first bootstrap has not been asked for yet.
    case idle
    /// Locating the tools (maybe building the dev wheel) and reading every service.
    case bootstrapping
    /// Reset: the old manager is shutting down and the environments are deleted.
    case resetting
    case ready
    /// The bootstrap failed (the message is shown with Try Again).
    case failed(String)
    /// App quit began.
    case shuttingDown
}

public enum AppEvent: Equatable, Sendable {
    /// App launch.
    case bootstrap
    /// Try Again after a failed bootstrap.
    case retry
    /// Reset the environments; `servicesBusy`: a service holds live work
    /// (`LifecycleState.blocksReset`), which refuses it.
    case reset(servicesBusy: Bool)
    case quit
    case bootstrapDone
    case bootstrapFailed(String)
    /// Reset's shutdown and deletion finished.
    case resetDone

    public enum Kind: CaseIterable, Sendable {
        case bootstrap, retry, reset, quit, bootstrapDone, bootstrapFailed, resetDone
    }

    public var kind: Kind {
        switch self {
        case .bootstrap: .bootstrap
        case .retry: .retry
        case .reset: .reset
        case .quit: .quit
        case .bootstrapDone: .bootstrapDone
        case .bootstrapFailed: .bootstrapFailed
        case .resetDone: .resetDone
        }
    }
}

/// Work for `AppModel`. `runBootstrap` and `runReset` start the one job; their
/// ends come back as `bootstrapDone` / `bootstrapFailed` / `resetDone`.
public enum AppEffect: Equatable, Sendable {
    case runBootstrap
    /// Swaps out the manager, shuts the old one down, deletes the environments.
    case runReset
    /// Reset forgets which services were wanted running and each category's last-used model
    /// (`AppModel` clears both stores); emitted before `runReset`.
    case clearWantedServices
    /// Quit: stop every server and subprocess, then wait for the job in flight.
    case shutdown
}

extension AppPhase {
    /// A bootstrap or Reset is in flight.
    public var hasJob: Bool { self == .bootstrapping || self == .resetting }

    /// Shown as "Checking services…": nothing is known yet, or it is being re-read.
    public var isChecking: Bool { self == .idle || hasJob }

    /// Try Again is offered only for a failed bootstrap (never while one runs).
    public var canRetryBootstrap: Bool {
        if case .failed = self { return true }
        return false
    }

    /// Reset is offered only when no job runs and quit has not begun; the
    /// services' live work refuses it too (`AppEvent.reset`).
    public var canReset: Bool {
        switch self {
        case .ready, .failed: true
        case .idle, .bootstrapping, .resetting, .shuttingDown: false
        }
    }

    /// The one Reset rule, for the reducer and the Reset button alike: no job,
    /// quit not begun, and no service's live work (`LifecycleState.blocksReset`).
    public func allowsReset(servicesBusy: Bool) -> Bool { canReset && !servicesBusy }

    /// Whether a service's Get / Start / Delete can run now. A Python service
    /// needs the environment manager, which a bootstrap installs and a Reset
    /// takes away, and its row shows the old state until the job's re-read, so
    /// its actions wait for the job. Apple Speech needs neither. Nothing new
    /// starts once quit began.
    public func acceptsServiceActions(usesPython: Bool, managerInstalled: Bool) -> Bool {
        guard self != .shuttingDown else { return false }
        return !usesPython || (managerInstalled && !hasJob)
    }

    public var setupError: String? {
        if case .failed(let message) = self { return message }
        return nil
    }
}

public enum AppLifecycle {
    public static func reduce(_ phase: inout AppPhase, _ event: AppEvent) -> [AppEffect] {
        switch (phase, event) {
        // Quit began: nothing moves the phase again, a second quit included.
        case (.shuttingDown, _):
            return []
        case (_, .quit):
            phase = .shuttingDown
            return [.shutdown]
        case (.idle, .bootstrap), (.failed, .retry):
            phase = .bootstrapping
            return [.runBootstrap]
        case (_, .reset(let servicesBusy)) where phase.allowsReset(servicesBusy: servicesBusy):
            phase = .resetting
            return [.clearWantedServices, .runReset]
        case (.bootstrapping, .bootstrapDone):
            phase = .ready
            return []
        case (.bootstrapping, .bootstrapFailed(let message)):
            phase = .failed(message)
            return []
        case (.resetting, .resetDone):
            phase = .bootstrapping
            return [.runBootstrap]
        // Refused: a second bootstrap/retry/reset while a job runs (or where it
        // isn't offered), and a job's end that doesn't match the job in flight.
        default:
            return []
        }
    }
}
