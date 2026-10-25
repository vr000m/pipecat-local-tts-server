import Foundation

// The per-service lifecycle as a pure state machine: `ServiceLifecycle.reduce`
// maps (state, event) to (state', effects). It decides every phase change and,
// through one rule (`reduce`), every guard against a late result: a result is
// applied only while the owner it was issued for (the epoch, an install, probe
// or removal slot, a ServerID) is current. `ServiceDriver` runs the effects;
// the app's `ServiceModel` only publishes the driver's state and forwards intents.

/// Where one service is in its lifecycle (what the UI shows).
public enum ServicePhase: Equatable, Sendable {
    case checking
    /// Can't run on this Mac (OS too old, language unsupported).
    case unavailable(String)
    case notInstalled
    /// The environment is installed but the model weights are missing (e.g. a cancelled download).
    case needsModel
    case installing(InstallStage)
    case installed
    case starting
    case running
    case stopping
    case removing
    case failed(ServiceFailure)
}

public struct ServiceFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case install, download, portBusy(PortProbe.Owner), startup(code: String?), crashed(status: Int32)
    }
    public var kind: Kind
    public var title: String
    public var message: String
    public var logTail: [String]

    public init(kind: Kind, title: String, message: String, logTail: [String] = []) {
        self.kind = kind
        self.title = title
        self.message = message
        self.logTail = logTail
    }

    /// Failures of a server the user started (shown with the running services).
    public var isRuntime: Bool {
        switch kind {
        case .portBusy, .startup, .crashed: true
        case .install, .download: false
        }
    }

    static func portBusy(port: Int, owner: PortProbe.Owner) -> ServiceFailure {
        var message = "Port \(port) is already in use by \(owner.summary)."
        if let label = owner.launchdLabel {
            message += " A launchd agent (\(label)) is loaded; stop it before starting here."
        }
        return ServiceFailure(kind: .portBusy(owner), title: "Port \(port) is busy", message: message)
    }
}

public struct ServiceRunningInfo: Equatable, Sendable {
    public var pid: Int32
    public var port: Int
    public var rate: Int
    public var model: String?
    public var since: Date

    public init(pid: Int32, port: Int, rate: Int, model: String?, since: Date) {
        self.pid = pid
        self.port = port
        self.rate = rate
        self.model = model
        self.since = since
    }
}

/// One launched server (a subprocess or the in-process Apple Speech server).
/// Events name the server they come from, so one from a replaced server is ignored.
public struct ServerID: Hashable, Sendable, CustomStringConvertible {
    public let raw: Int
    public init(_ raw: Int) { self.raw = raw }
    public var description: String { "#\(raw)" }
}

/// A supervised server's `{"event":"error"}` line (or the ready timeout).
public struct SupervisedError: Equatable, Sendable {
    public var code: String?
    public var message: String?
    public init(code: String?, message: String?) {
        self.code = code
        self.message = message
    }
}

/// What a finished install does next.
public enum InstallContinuation: Equatable, Sendable {
    case refresh
    /// The package refresh `start()` runs for an outdated environment: start once
    /// it is in (only if the refresh after it is still current, see `startAfterRead`).
    case refreshThenStart
}

public enum InstallOutcome: Equatable, Sendable {
    case finished
    case cancelled
    /// `stage` is the step that failed (`.model` reads as a download failure).
    case failed(stage: InstallStage, message: String, logTail: [String])
}

/// Everything that reaches the reducer. A result of async work names the owner
/// it was issued for (an `epoch`, `install`, `probe` or `removal` tag, or a
/// `ServerID`); `ServiceLifecycle.reduce` drops it unless that owner is current.
public enum LifecycleEvent: Equatable, Sendable {
    /// A re-read of the phase was asked for (bootstrap, Reset, a sibling).
    case refreshRequested
    /// The read issued under `epoch` found the environment (its slow cache probe is still running).
    case environmentRead(EnvironmentStatus, epoch: Int)
    /// The read issued under `epoch` finished (nil: leave that field as it is;
    /// `cache: .some(nil)` clears the cache status).
    case refreshed(
        ServicePhase, environment: EnvironmentStatus? = nil, requested: Bool? = nil, cache: ModelCacheStatus?? = nil,
        epoch: Int)
    /// A sibling variant changed the shared environment (nil: no manager yet).
    case environmentChanged(EnvironmentStatus?)
    case installRequested(managerAvailable: Bool)
    case cancelInstallRequested
    case installStage(InstallStage, install: Int)
    case installEnded(InstallOutcome, then: InstallContinuation, install: Int)
    case appleSpeechInstallEnded(InstallOutcome, install: Int)
    case startRequested(appAvailable: Bool, managerAvailable: Bool, portFree: Bool)
    /// The answer to the port probe `probe` (`LifecycleState.probe`).
    case portOwnerFound(PortProbe.Owner, probe: Int)
    /// The synchronous results of a `.launch` / `.launchNative` effect (same main-actor turn).
    case launched(ServerID)
    case launchFailed(String)
    case nativeLaunched(ServerID)
    case nativeBound(ServerID, port: Int, pid: Int32, at: Date)
    case nativeFailed(ServerID, String)
    case ready(ServerID, port: Int, pid: Int32, rate: Int, model: String?, at: Date)
    case supervisedError(ServerID, SupervisedError)
    case readyTimedOut(ServerID)
    case exited(ServerID, status: Int32, logTail: [String])
    case stopRequested
    /// App quit, first step: cancel an Apple Speech install.
    case shutdownRequested
    /// App quit (and removal), second step: stop the server.
    case shutdownServers
    case removeRequested(deleteModel: Bool, managerAvailable: Bool)
    /// The removal's cancelled install has unwound.
    case removalResumed(deleteModel: Bool, removal: Int)
    case removalFailed(String, removal: Int)
    case removalFinished(removal: Int)
    case dismissFailure

    /// The event's case, for the classification tables (`owner`, `isNonOwning`).
    public enum Kind: CaseIterable, Sendable {
        case refreshRequested, environmentRead, refreshed, environmentChanged, installRequested, cancelInstallRequested
        case installStage, installEnded, appleSpeechInstallEnded, startRequested, portOwnerFound, launched, launchFailed
        case nativeLaunched, nativeBound, nativeFailed, ready, supervisedError, readyTimedOut, exited, stopRequested
        case shutdownRequested, shutdownServers, removeRequested, removalResumed, removalFailed, removalFinished
        case dismissFailure
    }

    /// Which owner a result must name to be applied (`.none`: a user intent or
    /// a synchronous effect result, always current).
    public enum Owner: Sendable {
        case none, epoch, install, probe, removal, server, native
    }

    public var kind: Kind {
        switch self {
        case .refreshRequested: .refreshRequested
        case .environmentRead: .environmentRead
        case .refreshed: .refreshed
        case .environmentChanged: .environmentChanged
        case .installRequested: .installRequested
        case .cancelInstallRequested: .cancelInstallRequested
        case .installStage: .installStage
        case .installEnded: .installEnded
        case .appleSpeechInstallEnded: .appleSpeechInstallEnded
        case .startRequested: .startRequested
        case .portOwnerFound: .portOwnerFound
        case .launched: .launched
        case .launchFailed: .launchFailed
        case .nativeLaunched: .nativeLaunched
        case .nativeBound: .nativeBound
        case .nativeFailed: .nativeFailed
        case .ready: .ready
        case .supervisedError: .supervisedError
        case .readyTimedOut: .readyTimedOut
        case .exited: .exited
        case .stopRequested: .stopRequested
        case .shutdownRequested: .shutdownRequested
        case .shutdownServers: .shutdownServers
        case .removeRequested: .removeRequested
        case .removalResumed: .removalResumed
        case .removalFailed: .removalFailed
        case .removalFinished: .removalFinished
        case .dismissFailure: .dismissFailure
        }
    }
}

extension LifecycleEvent.Kind {
    /// The closed set of events that do not advance the epoch. Each changes no
    /// phase, no owner slot (install, probe, removal, server, native) and no
    /// `requested`, and issues no tagged work (`ServiceLifecycleTests.everyKindIsClassified`).
    public var isNonOwning: Bool {
        switch self {
        case .cancelInstallRequested, .environmentRead, .supervisedError: true
        case .refreshRequested, .refreshed, .environmentChanged, .installRequested, .installStage, .installEnded,
            .appleSpeechInstallEnded, .startRequested, .portOwnerFound, .launched, .launchFailed, .nativeLaunched,
            .nativeBound, .nativeFailed, .ready, .readyTimedOut, .exited, .stopRequested, .shutdownRequested,
            .shutdownServers, .removeRequested, .removalResumed, .removalFailed, .removalFinished, .dismissFailure:
            false
        }
    }

    public var owner: LifecycleEvent.Owner {
        switch self {
        case .environmentRead, .refreshed: .epoch
        case .installStage, .installEnded, .appleSpeechInstallEnded: .install
        case .portOwnerFound: .probe
        case .removalResumed, .removalFailed, .removalFinished: .removal
        case .ready, .supervisedError, .readyTimedOut, .exited: .server
        case .nativeBound, .nativeFailed: .native
        case .refreshRequested, .environmentChanged, .installRequested, .cancelInstallRequested, .startRequested,
            .launched, .launchFailed, .nativeLaunched, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested, .dismissFailure:
            .none
        }
    }
}

/// Work for `ServiceDriver`, in order. Effects never change the phase themselves;
/// their results come back as events, carrying the tag the effect was issued with.
public enum LifecycleEffect: Equatable, Sendable {
    /// Re-reads the phase; its results carry `epoch`.
    case refresh(epoch: Int)
    case familyChanged
    case runInstall(InstallMode, then: InstallContinuation, install: Int)
    case runAppleSpeechInstall(install: Int)
    /// Cancels the install in flight (remembered for `awaitInstall`).
    case cancelInstall
    /// Waits for the cancelled install to unwind; `bounded` caps it at the quit drain.
    case awaitInstall(bounded: Bool)
    case probePortOwner(port: Int, probe: Int)
    /// Stops the port-owner probe `probe` (its `lsof`): the probe ended some
    /// other way than its own answer (Stop, a launch, a removal).
    case cancelProbe(probe: Int)
    case launch(port: Int)
    case launchNative(port: Int)
    /// Stops a native server that bound after Stop or a relaunch.
    case discardNative(ServerID)
    case stopNative
    case startReadyTimer(ServerID)
    case openTryIt(port: Int)
    case detachTryIt
    /// Ends the running session: Try it, the log file.
    case tearDown(note: String)
    /// SIGTERM, then SIGKILL after the stop grace; `wait` awaits the exit.
    case stopServer(ServerID, wait: Bool)
    case appendLog(String)
    case startDetail(String)
    case resumeRemoval(deleteModel: Bool, removal: Int)
    case shutdown
    case removeEnvironment(deleteModel: Bool, removal: Int)
    case clearLog
    /// `start()` (a current refresh after a package refresh asked for it).
    case start
}

public struct LifecycleState: Equatable, Sendable {
    public let runtime: ServiceRuntime
    public let port: Int
    public let displayName: String

    public var phase: ServicePhase = .checking
    public var environment: EnvironmentStatus = .missing
    /// Installed by the user (a variant's family environment can exist without it).
    public var requested = false
    /// The last cache probe a current read reported.
    public var cache: ModelCacheStatus?
    public var running: ServiceRunningInfo?
    /// The current server subprocess.
    public var server: ServerID?
    /// The current in-process (Apple Speech) server.
    public var native: ServerID?
    /// Stop (or quit, or removal) asked the current server to exit.
    public var stopRequested = false
    /// App quit began.
    public var shuttingDown = false
    /// The install in flight: the epoch it was started under.
    public var install: Int?
    /// The removal in flight: the epoch it was started under.
    public var removal: Int?
    /// The port-owner probe in flight: the epoch it was issued under. It lives
    /// only while the phase is `.starting` with no server.
    public var probe: Int?
    public var supervisedError: SupervisedError?
    /// Advanced by every event outside the non-owning set; a read (refresh)
    /// issued under an older epoch is dropped.
    public var epoch = 0
    /// The read in flight: the epoch it was issued under.
    public var reading: Int?
    /// The read in flight starts the service when it lands current (refreshThenStart).
    public var startAfterRead = false
    /// The user cancelled an Apple Speech download: a refresh that still sees
    /// the system downloading does not attach to it again.
    public var declinedSystemDownload = false

    public init(info: ServiceInfo) {
        runtime = info.runtime
        port = info.port
        displayName = info.displayName
    }
}

extension LifecycleState {
    /// An install is in flight.
    public var installing: Bool { install != nil }

    /// A server, an install, a probe or a removal owns the phase: a refresh must
    /// not overwrite it (only the event that ends that work moves the phase on). A
    /// server already asked to stop no longer owns it (Stop and removal hold
    /// their own phase until its exit).
    public var hasLiveWork: Bool {
        if install != nil || removal != nil || (server != nil && !stopRequested) || native != nil || probe != nil {
            return true
        }
        switch phase {
        case .starting, .running, .stopping, .removing: return true
        default: return false
        }
    }

    /// Reset is refused: a server, or an install or removal, still uses the
    /// environment Reset would delete (quit never waits on this; it stops them).
    public var blocksReset: Bool {
        if install != nil || removal != nil || server != nil || native != nil { return true }
        switch phase {
        case .starting, .running, .stopping, .installing, .removing: return true
        default: return false
        }
    }

    /// Started by the user: shown in the main menu (running, on its way up or
    /// down, or failed at runtime).
    public var isActive: Bool {
        switch phase {
        case .starting, .running, .stopping: true
        case .failed(let failure): failure.isRuntime
        default: false
        }
    }

    public var isInstalled: Bool {
        switch phase {
        case .installed, .needsModel, .starting, .running, .stopping: true
        case .unavailable, .notInstalled, .checking: false
        case .installing, .removing: requested
        case .failed(let failure): failure.isRuntime || requested
        }
    }

    public var isInstalling: Bool {
        if case .installing = phase { return true }
        return false
    }

    public var isBusy: Bool {
        switch phase {
        case .checking, .installing, .starting, .stopping, .removing: true
        default: false
        }
    }
}

public enum ServiceLifecycle {
    /// The install a user's Install runs, from the environment and the phase.
    public static func installMode(environment: EnvironmentStatus, phase: ServicePhase) -> InstallMode {
        switch (environment, phase) {
        case (.missing, _): .full
        case (_, .needsModel): .model
        case (_, .failed(let f)) where f.kind == .download: .model
        // The manager skips the steps a sibling's environment already covers.
        default: .full
        }
    }

    /// The stage an install shows before its first progress event.
    public static func firstStage(mode: InstallMode, environment: EnvironmentStatus) -> InstallStage {
        switch (mode, environment) {
        case (.model, _), (.full, .ready): .model
        case (.packages, _), (.full, .outdated): .packages
        case (.full, .missing): .python
        }
    }

    /// The phase a refresh reads from disk (Python services).
    public static func installedPhase(environment: EnvironmentStatus, requested: Bool, cached: Bool?) -> ServicePhase {
        guard requested else { return .notInstalled }
        switch environment {
        case .missing: return .notInstalled
        // Packages are reinstalled before the next start; assume weights are fine.
        case .outdated: return .installed
        case .ready: return (cached ?? true) ? .installed : .needsModel
        }
    }

    /// Whether `event` names an owner that is still current in `s`.
    public static func isCurrent(_ event: LifecycleEvent, in s: LifecycleState) -> Bool {
        switch event {
        case .environmentRead(_, let epoch), .refreshed(_, _, _, _, let epoch): epoch == s.epoch
        case .installStage(_, let install), .installEnded(_, _, let install), .appleSpeechInstallEnded(_, let install):
            install == s.install
        case .portOwnerFound(_, let probe): probe == s.probe
        case .removalResumed(_, let removal), .removalFailed(_, let removal), .removalFinished(let removal):
            removal == s.removal
        case .ready(let id, _, _, _, _, _), .supervisedError(let id, _), .readyTimedOut(let id), .exited(let id, _, _):
            id == s.server
        case .nativeBound(let id, _, _, _), .nativeFailed(let id, _): id == s.native
        case .refreshRequested, .environmentChanged, .installRequested, .cancelInstallRequested, .startRequested,
            .launched, .launchFailed, .nativeLaunched, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested, .dismissFailure:
            true
        }
    }

    /// The one rule every event goes through:
    /// 1. A result whose owner is no longer current changes nothing, the epoch
    ///    included (a stale native bind only releases the server it holds).
    /// 2. Every event outside the non-owning set advances the epoch before it
    ///    runs, so the work it issues is tagged with the new epoch and any read
    ///    issued earlier is stale. An event that then changes nothing (its guard
    ///    rejected it: no state change, no effect) leaves the epoch as it was.
    /// 3. A probe lives only while the phase is `.starting` with no server; a
    ///    probe that ends any other way than its own answer is cancelled, by
    ///    the first effect (so no other effect's wait delays it).
    /// 4. A read the advance orphaned is issued again when nothing owns the
    ///    phase (otherwise the owner's own end re-reads it); it never carries a
    ///    start with it.
    public static func reduce(_ s: inout LifecycleState, _ event: LifecycleEvent) -> [LifecycleEffect] {
        guard isCurrent(event, in: s) else {
            if case .nativeBound(let id, _, _, _) = event { return [.discardNative(id)] }
            return []
        }
        let before = s
        if !event.kind.isNonOwning { s.epoch += 1 }
        var effects = apply(&s, event)
        var unchanged = s
        unchanged.epoch = before.epoch
        if effects.isEmpty, unchanged == before {
            s = before
            return []
        }
        if s.phase != .starting || s.server != nil || s.native != nil { s.probe = nil }
        // First: the driver runs effects in order, so a cancel after a refresh
        // would wait for its (slow) cache probe while `lsof` kept running.
        if let probe = before.probe, s.probe != probe, event.kind != .portOwnerFound {
            effects.insert(.cancelProbe(probe: probe), at: 0)
        }
        if let reading = s.reading, reading != s.epoch {
            s.startAfterRead = false
            if s.hasLiveWork {
                s.reading = nil
            } else {
                effects.append(read(&s))
            }
        }
        return effects
    }

    private static func apply(_ s: inout LifecycleState, _ event: LifecycleEvent) -> [LifecycleEffect] {
        switch event {
        case .refreshRequested:
            return [read(&s)]

        case .environmentRead(let environment, _):
            s.environment = environment
            return []

        case .refreshed(let phase, let environment, let requested, let cache, _):
            let start = s.startAfterRead
            s.reading = nil
            s.startAfterRead = false
            if let environment { s.environment = environment }
            if let cache { s.cache = cache }
            // A server, install, probe or removal owns the phase; only its own end moves it.
            guard !s.hasLiveWork else { return [] }
            if let requested { s.requested = requested }
            if s.runtime == .appleSpeech, case .installing = phase {
                // The user cancelled: don't attach again while the system still downloads.
                if s.declinedSystemDownload {
                    s.phase = .notInstalled
                    return []
                }
                // The system is already downloading the model (an earlier launch or
                // another app): attach to that download so progress and Cancel work.
                s.install = s.epoch
                s.phase = .installing(.model)
                return [.runAppleSpeechInstall(install: s.epoch)]
            }
            s.declinedSystemDownload = false
            s.phase = phase
            return start ? [.start] : []

        case .environmentChanged(let environment):
            // Leave a phase that work in progress (or a failure on screen) owns.
            switch s.phase {
            case .checking, .notInstalled, .needsModel, .installed: return [read(&s)]
            default:
                if let environment { s.environment = environment }
                return []
            }

        case .installRequested(let managerAvailable):
            guard s.install == nil, s.removal == nil else { return [] }
            if s.runtime == .appleSpeech {
                s.declinedSystemDownload = false
                s.install = s.epoch
                s.phase = .installing(.model)
                return [.runAppleSpeechInstall(install: s.epoch)]
            }
            guard managerAvailable else { return [] }
            return beginInstall(&s, mode: installMode(environment: s.environment, phase: s.phase), then: .refresh)

        case .cancelInstallRequested:
            return [.cancelInstall]

        case .installStage(let stage, _):
            // Never over a removal.
            guard s.phase != .removing else { return [] }
            s.phase = .installing(stage)
            return []

        case .installEnded(let outcome, let then, _):
            s.install = nil
            switch outcome {
            case _ where s.phase == .removing:
                // remove() cancelled this install and owns the phase from here.
                return outcome == .finished ? [.familyChanged] : []
            case .finished:
                return [read(&s, thenStart: then == .refreshThenStart), .familyChanged]
            case .cancelled:
                return [read(&s), .familyChanged]
            case .failed(let stage, let message, let logTail):
                let download = stage == .model
                s.phase = .failed(
                    ServiceFailure(
                        kind: download ? .download : .install, title: download ? "Model download failed" : "Install failed",
                        message: message, logTail: logTail))
                return []
            }

        case .appleSpeechInstallEnded(let outcome, _):
            s.install = nil
            switch outcome {
            case .finished: return [read(&s)]
            // Quit cancelled it: the app is going away, nothing to show.
            case _ where s.shuttingDown: return []
            case .cancelled:
                s.declinedSystemDownload = true
                return [read(&s)]
            case .failed(_, let message, _):
                s.phase = .failed(ServiceFailure(kind: .download, title: "Model download failed", message: message))
                return []
            }

        case .startRequested(let appAvailable, let managerAvailable, let portFree):
            guard appAvailable, s.server == nil, s.native == nil, s.install == nil, s.removal == nil,
                s.phase != .removing
            else { return [] }
            if s.runtime.usesPython, case .outdated = s.environment, managerAvailable {
                // The app was updated since this env was built: refresh its packages, then start.
                return beginInstall(&s, mode: .packages, then: .refreshThenStart)
            }
            guard portFree else {
                s.phase = .starting
                return [.startDetail("Checking port \(s.port)…"), probePort(&s)]
            }
            return s.runtime == .appleSpeech ? [.launchNative(port: s.port)] : [.launch(port: s.port)]

        case .portOwnerFound(let owner, _):
            guard s.phase == .starting else { return [] }
            s.probe = nil
            s.phase = .failed(.portBusy(port: s.port, owner: owner))
            return []

        case .launched(let id):
            s.server = id
            s.stopRequested = false
            s.supervisedError = nil
            s.phase = .starting
            return [.startDetail("Loading model…"), .startReadyTimer(id)]

        case .launchFailed(let message):
            s.phase = .failed(ServiceFailure(kind: .startup(code: nil), title: "Couldn't start", message: message))
            return []

        case .nativeLaunched(let id):
            s.native = id
            s.stopRequested = false
            s.phase = .starting
            return [.startDetail("Starting…")]

        case .nativeBound(let id, let port, let pid, let date):
            guard s.phase == .starting else { return [.discardNative(id)] }
            return [.appendLog("listening on \(ServiceCatalog.host):\(port)")]
                + becameReady(&s, port: port, pid: pid, rate: STTWire.rate, model: "SpeechTranscriber", at: date)

        case .nativeFailed(_, let message):
            s.native = nil
            s.phase = .failed(ServiceFailure(kind: .startup(code: nil), title: "Couldn't start", message: message))
            return []

        case .ready(_, let port, let pid, let rate, let model, let date):
            // A ready that lands after Stop/Delete must not flip the phase back to running.
            guard s.phase == .starting else { return [] }
            return becameReady(&s, port: port, pid: pid, rate: rate, model: model, at: date)

        case .supervisedError(_, let error):
            s.supervisedError = error
            return []

        case .readyTimedOut(let id):
            guard s.phase == .starting else { return [] }
            s.supervisedError = SupervisedError(code: "Timeout", message: "The server did not become ready within 10 minutes.")
            return [.stopServer(id, wait: false)]

        case .exited(_, let status, let logTail):
            // A requested exit only completes a Stop (`.stopping` -> `.installed`):
            // it is reported after the stdout drain, up to 2 s after `shutdown()`
            // returned, so a removal (or its failure) may own the phase by then.
            s.server = nil
            s.running = nil
            let effects: [LifecycleEffect] = [.tearDown(note: "exited with status \(status)")]
            if s.stopRequested {
                if s.phase == .stopping { s.phase = .installed }
                return effects
            }
            guard let error = s.supervisedError else {
                s.phase = .failed(
                    ServiceFailure(
                        kind: .crashed(status: status), title: "Server stopped unexpectedly",
                        message: "The \(s.displayName) server exited with status \(status).", logTail: logTail))
                return effects
            }
            if error.code == SupervisedErrorCode.addressInUse.rawValue {
                s.phase = .starting  // still starting: finding who holds the port
                return effects + [probePort(&s)]
            }
            let title = error.code == SupervisedErrorCode.moduleNotFound.rawValue ? "Environment incomplete" : "Couldn't start"
            s.phase = .failed(
                ServiceFailure(
                    kind: .startup(code: error.code), title: title, message: error.message ?? "Startup failed.",
                    logTail: logTail))
            return effects

        case .stopRequested:
            if s.native != nil { return stopNative(&s) }
            guard let id = s.server else {
                // Cancel while the busy port is probed: drop the probe, re-read the phase.
                guard s.probe != nil else { return [] }
                s.probe = nil
                s.phase = .checking
                return [read(&s)]
            }
            s.stopRequested = true
            s.phase = .stopping
            return [.detachTryIt, .stopServer(id, wait: false)]

        case .shutdownRequested:
            // Quit cancels an Apple Speech model install; a Python install is the
            // environment manager's to stop.
            guard s.runtime == .appleSpeech, s.install != nil else { return [] }
            s.shuttingDown = true
            return [.cancelInstall, .awaitInstall(bounded: true)]

        case .shutdownServers:
            if s.native != nil { return stopNative(&s) }
            guard let id = s.server else { return [] }
            s.stopRequested = true
            return [.detachTryIt, .stopServer(id, wait: true)]

        case .removeRequested(let deleteModel, let managerAvailable):
            guard s.runtime.usesPython, managerAvailable, s.phase != .removing, s.removal == nil else { return [] }
            s.phase = .removing
            s.removal = s.epoch
            // An install in flight is cancelled and must unwind (and drop the family
            // lock) before removal; it leaves the phase to the removal.
            return [.cancelInstall, .awaitInstall(bounded: false), .resumeRemoval(deleteModel: deleteModel, removal: s.epoch)]

        case .removalResumed(let deleteModel, let removal):
            s.phase = .removing  // an install that had already finished may have refreshed it
            // Stop the server first so its exit can't race the removal.
            return [.shutdown, .removeEnvironment(deleteModel: deleteModel, removal: removal)]

        case .removalFailed(let message, _):
            s.removal = nil
            s.phase = .failed(ServiceFailure(kind: .install, title: "Couldn't remove", message: message))
            return []

        case .removalFinished:
            // The removal no longer owns the phase: the refresh reads what is left.
            s.removal = nil
            s.phase = .checking
            return [.clearLog, read(&s), .familyChanged]

        case .dismissFailure:
            return [read(&s)]
        }
    }

    /// Issues a read under the current epoch (it replaces any read in flight).
    private static func read(_ s: inout LifecycleState, thenStart: Bool = false) -> LifecycleEffect {
        s.reading = s.epoch
        s.startAfterRead = thenStart
        return .refresh(epoch: s.epoch)
    }

    private static func probePort(_ s: inout LifecycleState) -> LifecycleEffect {
        s.probe = s.epoch
        return .probePortOwner(port: s.port, probe: s.epoch)
    }

    private static func beginInstall(_ s: inout LifecycleState, mode: InstallMode, then: InstallContinuation)
        -> [LifecycleEffect]
    {
        s.install = s.epoch
        s.phase = .installing(firstStage(mode: mode, environment: s.environment))
        return [.runInstall(mode, then: then, install: s.epoch)]
    }

    private static func becameReady(
        _ s: inout LifecycleState, port: Int, pid: Int32, rate: Int, model: String?, at date: Date
    ) -> [LifecycleEffect] {
        s.running = ServiceRunningInfo(pid: pid, port: port, rate: rate, model: model, since: date)
        s.phase = .running
        return [.openTryIt(port: port)]
    }

    private static func stopNative(_ s: inout LifecycleState) -> [LifecycleEffect] {
        s.native = nil
        s.running = nil
        s.phase = .installed
        return [.stopNative, .tearDown(note: "stopped")]
    }
}
