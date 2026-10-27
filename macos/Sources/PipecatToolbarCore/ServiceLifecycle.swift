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
    /// A server the app did not start answers on `port` (adopted from its `server.hello`).
    /// The app never signals, stops or deletes it; `ServiceLifecycle` issues no effect that could.
    case external(Int, ExternalInfo)

    public var isExternal: Bool {
        if case .external = self { return true }
        return false
    }
}

/// What the `server.hello` of an adopted (External) server reported. Unlike
/// `ServiceRunningInfo` it has no pid: the app did not start the process.
public struct ExternalInfo: Equatable, Sendable {
    public var backendName: String
    public var model: String?
    public var rate: Int?
    public var protocolVersion: String?

    public init(backendName: String, model: String? = nil, rate: Int? = nil, protocolVersion: String? = nil) {
        self.backendName = backendName
        self.model = model
        self.rate = rate
        self.protocolVersion = protocolVersion
    }

    public init(hello: ServerHelloFrame) {
        self.init(
            backendName: hello.backendName, model: hello.model, rate: hello.rate, protocolVersion: hello.protocolVersion)
    }
}

/// Why a discovery re-probe says an External server is gone.
public enum ExternalLostReason: Equatable, Sendable {
    /// Connection refused: one failed probe (a KeepAlive restart may be under way).
    case refused
    /// Accepted but no hello in time: one failed probe.
    case timeout
    /// Something else holds the port now (another backend, a silent listener, a token
    /// wall): the service moves to checking at once, without counting.
    case mismatch
}

/// What answered on a busy port, for the busy failure's message.
public enum PortFound: Equatable, Sendable {
    /// Only the owner lookup (`lsof`) is known.
    case unknown
    /// A hello from a server that is not this entry.
    case server(backend: String, model: String?)
    /// The handshake got HTTP 401 or 403.
    case needsToken
    /// Accepted, then closed without a hello.
    case silent
    /// Accepted, no hello before the deadline.
    case noAnswer
}

public struct ServiceFailure: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case install, download, portBusy(PortProbe.Owner, found: PortFound = .unknown), startup(code: String?), crashed(status: Int32)
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

    static func portBusy(
        port: Int, owner: PortProbe.Owner, found: PortFound = .unknown, displayName: String = "this service"
    ) -> ServiceFailure {
        var message: String
        switch found {
        case .unknown:
            message = "Port \(port) is already in use by \(owner.summary)."
        case .server(let backend, let model):
            let what = model.map { "\(backend) (\($0))" } ?? backend
            message = "Port \(port) is held by a server that identified itself as \(what), not \(displayName)."
            if owner.pid != nil || owner.command != nil { message += " Held by \(owner.summary)." }
        case .needsToken:
            message =
                "Port \(port) is in use: the connection was refused with HTTP 401 or 403, so whatever listens there wants a token."
        case .silent:
            message = "Port \(port) is in use, but nothing identified itself: it closed the connection without a server.hello."
        case .noAnswer:
            message = "Port \(port) is in use, but nothing answered within \(Int(ExternalProbe.helloTimeout)) seconds."
        }
        if let label = owner.launchdLabel {
            message += " A launchd agent (\(label)) is loaded; stop it before starting here."
        }
        return ServiceFailure(kind: .portBusy(owner, found: found), title: "Port \(port) is busy", message: message)
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
    /// Discovery found a server for this service on its port. `epoch` is the
    /// `LifecycleState.externalEpoch` read when the probe started.
    case externalFound(epoch: Int, info: ExternalInfo)
    /// A discovery re-probe lost (or replaced) the External server; `epoch` as for `externalFound`.
    case externalLost(epoch: Int, reason: ExternalLostReason)
    /// The outcome of the Start-path probe `tag` (`LifecycleState.probe`), issued by `.probeExternal`.
    case startProbeResult(tag: Int, outcome: ExternalProbe.Outcome)
    /// The user wants Try it on an External row (the session opens on demand, not at adoption).
    case tryItRequested

    /// The event's case, for the classification tables (`owner`, `isNonOwning`).
    public enum Kind: CaseIterable, Sendable {
        case refreshRequested, environmentRead, refreshed, environmentChanged, installRequested, cancelInstallRequested
        case installStage, installEnded, appleSpeechInstallEnded, startRequested, portOwnerFound, launched, launchFailed
        case nativeLaunched, nativeBound, nativeFailed, ready, supervisedError, readyTimedOut, exited, stopRequested
        case shutdownRequested, shutdownServers, removeRequested, removalResumed, removalFailed, removalFinished
        case dismissFailure, externalFound, externalLost, startProbeResult, tryItRequested
    }

    /// Which owner a result must name to be applied (`.none`: a user intent or
    /// a synchronous effect result, always current).
    public enum Owner: Sendable {
        case none, epoch, install, probe, removal, server, native
        /// Gated by `LifecycleState.externalEpoch` (discovery results).
        case external
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
        case .externalFound: .externalFound
        case .externalLost: .externalLost
        case .startProbeResult: .startProbeResult
        case .tryItRequested: .tryItRequested
        }
    }
}

extension LifecycleEvent.Kind {
    /// The closed set of events that do not advance the epoch. Each changes no
    /// phase, no owner slot (install, probe, removal, server, native) and no
    /// `requested`, and issues no tagged work (`ServiceLifecycleTests.everyKindIsClassified`).
    public var isNonOwning: Bool {
        switch self {
        // `externalLost` is classified owning: its Nth failure changes the phase. A count-only
        // loss changes no phase or slot, so `reduce` leaves the epoch alone for it
        // (`keepsEpochWhenItOnlyCounts`, the one exception to this table).
        case .cancelInstallRequested, .environmentRead, .supervisedError, .tryItRequested: true
        case .refreshRequested, .refreshed, .environmentChanged, .installRequested, .installStage, .installEnded,
            .appleSpeechInstallEnded, .startRequested, .portOwnerFound, .launched, .launchFailed, .nativeLaunched,
            .nativeBound, .nativeFailed, .ready, .readyTimedOut, .exited, .stopRequested, .shutdownRequested,
            .shutdownServers, .removeRequested, .removalResumed, .removalFailed, .removalFinished, .dismissFailure,
            .externalFound, .externalLost, .startProbeResult:
            false
        }
    }

    /// The owning kinds that can also apply without changing a phase or an owner slot: a
    /// below-threshold `externalLost` only counts a failure (the External service stays
    /// External), and `reduce` then restores `epoch` as for a non-owning event.
    public var keepsEpochWhenItOnlyCounts: Bool {
        switch self {
        case .externalLost: true
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .installRequested,
            .cancelInstallRequested, .installStage, .installEnded, .appleSpeechInstallEnded, .startRequested,
            .portOwnerFound, .launched, .launchFailed, .nativeLaunched, .nativeBound, .nativeFailed, .ready,
            .supervisedError, .readyTimedOut, .exited, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested, .removalResumed, .removalFailed, .removalFinished, .dismissFailure, .externalFound,
            .startProbeResult, .tryItRequested:
            false
        }
    }

    /// Start, Install, Stop, quit and Delete advance `LifecycleState.externalEpoch` when they
    /// change anything (the transitions into and out of `.external` advance it on their own).
    /// Start and Install begin an owned activity that settles a fresher answer about the port
    /// than any discovery probe that began before them, so such a probe must not land after.
    public var changesExternalEpoch: Bool {
        switch self {
        case .startRequested, .installRequested, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested:
            true
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .cancelInstallRequested,
            .installStage, .installEnded, .appleSpeechInstallEnded, .portOwnerFound, .launched, .launchFailed,
            .nativeLaunched, .nativeBound, .nativeFailed, .ready, .supervisedError, .readyTimedOut, .exited,
            .removalResumed, .removalFailed, .removalFinished, .dismissFailure, .externalFound, .externalLost,
            .startProbeResult, .tryItRequested:
            false
        }
    }

    public var owner: LifecycleEvent.Owner {
        switch self {
        case .environmentRead, .refreshed: .epoch
        case .installStage, .installEnded, .appleSpeechInstallEnded: .install
        case .portOwnerFound, .startProbeResult: .probe
        case .externalFound, .externalLost: .external
        case .removalResumed, .removalFailed, .removalFinished: .removal
        case .ready, .supervisedError, .readyTimedOut, .exited: .server
        case .nativeBound, .nativeFailed: .native
        case .refreshRequested, .environmentChanged, .installRequested, .cancelInstallRequested, .startRequested,
            .launched, .launchFailed, .nativeLaunched, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested, .dismissFailure, .tryItRequested:
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
    /// The Start-path hello probe (`ServiceHost.probeExternal`); its outcome returns as
    /// `startProbeResult(tag: probe, ...)`. The only prober the reducer asks for.
    case probeExternal(port: Int, probe: Int)
    /// Stops the probe `probe` (a port-owner `lsof` or the hello probe): the probe ended some
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
    /// What answered the Start-path hello probe, held while the port-owner lookup
    /// that follows runs (it ends in the busy failure).
    public var busyFound: PortFound?
    /// The probe in flight follows a launch that lost the bind race (`EADDRINUSE`):
    /// only an `adopt` ends it well, every other outcome stays the busy failure.
    public var probeAfterBind = false
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
    /// Gates discovery events (`externalFound`, `externalLost`): `reduce` bumps it on every
    /// transition into or out of `.external` and when Start, Install, Stop, Delete or quit
    /// changes anything (`LifecycleEvent.Kind.changesExternalEpoch`), so a probe that started
    /// earlier can not resurrect or demote a service. No other event touches it.
    /// `ExternalDiscovery` reads it when it starts a probe and the outcome carries it back.
    public var externalEpoch = 0
    /// Consecutive failed re-probes (refused or timeout) of the External server; reset by a
    /// found. The `externalFailureThreshold`th moves the service to checking.
    public var externalFailures = 0

    public init(info: ServiceInfo) {
        runtime = info.runtime
        port = info.port
        displayName = info.displayName
    }
}

extension LifecycleState {
    /// An install is in flight.
    public var installing: Bool { install != nil }

    /// Ends the Start-path probe chain: `probe`, `busyFound` and `probeAfterBind` describe one
    /// probe in flight and are only ever cleared together, here.
    mutating func endStartProbe() {
        probe = nil
        busyFound = nil
        probeAfterBind = false
    }

    /// A server, an install, a probe or a removal owns the phase: a refresh must
    /// not overwrite it (only the event that ends that work moves the phase on). A
    /// server already asked to stop no longer owns it (Stop and removal hold
    /// their own phase until its exit).
    public var hasLiveWork: Bool {
        if install != nil || removal != nil || (server != nil && !stopRequested) || native != nil || probe != nil {
            return true
        }
        switch phase {
        case .starting, .running, .stopping, .removing, .external: return true
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
        case .starting, .running, .stopping, .external: true
        case .failed(let failure): failure.isRuntime
        default: false
        }
    }

    public var isInstalled: Bool {
        switch phase {
        case .installed, .needsModel, .starting, .running, .stopping: true
        case .unavailable, .notInstalled, .checking: false
        case .installing, .removing: requested
        // The app's own install, not the external server: installed here only if the user installed
        // this service (as `installedPhase` reads it; a sibling variant can build the shared environment).
        case .external: requested && environment != .missing
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
    /// Failed re-probes (refused or timeout) in a row before an External service is
    /// re-read. It counts discovery passes, not time: with the panel left open the passes
    /// are 15 s apart (about 45 s, meant to outlast a KeepAlive restart), but the bootstrap
    /// pass and every panel open add one, so reopening the panel reaches it sooner. The
    /// cold-start measurement that would confirm 45 s is still open (plan Findings, Phase 1 (b)).
    public static let externalFailureThreshold = 3

    /// The phases a discovery `externalFound` adopts from; `ExternalDiscoveryPolicy.probes`
    /// probes only these (the others are owned, or not yet readable), and both also exclude
    /// Apple Speech, which has no port to probe.
    public static func acceptsDiscovery(_ phase: ServicePhase) -> Bool {
        switch phase {
        case .notInstalled, .installed, .failed, .checking, .external: true
        case .unavailable, .needsModel, .installing, .starting, .running, .stopping, .removing: false
        }
    }

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
        case .startProbeResult(let tag, _): tag == s.probe
        case .externalFound(let epoch, _), .externalLost(let epoch, _): epoch == s.externalEpoch
        case .removalResumed(_, let removal), .removalFailed(_, let removal), .removalFinished(let removal):
            removal == s.removal
        case .ready(let id, _, _, _, _, _), .supervisedError(let id, _), .readyTimedOut(let id), .exited(let id, _, _):
            id == s.server
        case .nativeBound(let id, _, _, _), .nativeFailed(let id, _): id == s.native
        case .refreshRequested, .environmentChanged, .installRequested, .cancelInstallRequested, .startRequested,
            .launched, .launchFailed, .nativeLaunched, .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested, .dismissFailure, .tryItRequested:
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
    ///    phase, or when the phase is `.external` (otherwise the owner's own end
    ///    re-reads it; External has no such end until the server is lost, and its
    ///    `isInstalled` reads what the read records). It never carries a start
    ///    with it, and only a read already in flight is re-issued.
    /// 5. `externalEpoch` advances after the event ran, only when it was applied: on every
    ///    transition into or out of `.external`, and for the kinds in `changesExternalEpoch`.
    ///    A kind in `keepsEpochWhenItOnlyCounts` (a count-only `externalLost`) that left an
    ///    External service External leaves `epoch` alone. All three tables sit together with
    ///    `owner` and `isNonOwning` (`everyKindIsClassified`).
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
        if event.kind.keepsEpochWhenItOnlyCounts, before.phase.isExternal, s.phase.isExternal { s.epoch = before.epoch }
        if s.phase.isExternal != before.phase.isExternal || event.kind.changesExternalEpoch { s.externalEpoch += 1 }
        if s.phase != .starting || s.server != nil || s.native != nil { s.endStartProbe() }
        // First: the driver runs effects in order, so a cancel after a refresh
        // would wait for its (slow) cache probe while `lsof` kept running.
        if let probe = before.probe, s.probe != probe, event.kind != .portOwnerFound, event.kind != .startProbeResult {
            effects.insert(.cancelProbe(probe: probe), at: 0)
        }
        if let reading = s.reading, reading != s.epoch {
            s.startAfterRead = false
            // External has no owner's end that re-reads until the server is lost, yet its
            // `isInstalled` depends on what the read records: re-issue it there too.
            if s.hasLiveWork, !s.phase.isExternal {
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
            // External reads installed from `requested`, and `.external` counts as live work, so a
            // refresh that lands after the adoption must still record it; the phase itself stays
            // put. A read in flight when the adoption advanced the epoch is re-issued under the new
            // one (`reduce` rule 4), so this is the refresh that answers it.
            if let requested, case .external = s.phase { s.requested = requested }
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
            guard s.install == nil, s.removal == nil, !s.phase.isExternal else { return [] }
            if s.runtime == .appleSpeech {
                s.declinedSystemDownload = false
                s.install = s.epoch
                s.phase = .installing(.model)
                return [.runAppleSpeechInstall(install: s.epoch)]
            }
            guard managerAvailable else { return [] }
            return beginInstall(&s, mode: installMode(environment: s.environment, phase: s.phase), then: .refresh)

        case .cancelInstallRequested:
            // An External service has no install to cancel.
            return s.phase.isExternal ? [] : [.cancelInstall]

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
                s.phase != .removing, !s.phase.isExternal
            else { return [] }
            if s.runtime.usesPython, case .outdated = s.environment, managerAvailable {
                // The app was updated since this env was built: refresh its packages, then start.
                return beginInstall(&s, mode: .packages, then: .refreshThenStart)
            }
            guard portFree else {
                s.phase = .starting
                s.endStartProbe()
                // Apple Speech runs in the app: only the owner lookup, never a hello probe.
                let probe = s.runtime == .appleSpeech ? probePort(&s) : probeExternal(&s)
                return [.startDetail("Checking port \(s.port)…"), probe]
            }
            return s.runtime == .appleSpeech ? [.launchNative(port: s.port)] : [.launch(port: s.port)]

        case .portOwnerFound(let owner, _):
            guard s.phase == .starting else { return [] }
            let found = s.busyFound ?? .unknown
            s.endStartProbe()
            s.phase = .failed(.portBusy(port: s.port, owner: owner, found: found, displayName: s.displayName))
            return []

        case .startProbeResult(_, let outcome):
            guard s.phase == .starting, s.server == nil, s.native == nil else { return [] }
            let afterBind = s.probeAfterBind
            s.endStartProbe()
            if let info = outcome.adoptedInfo(onPort: s.port) {
                return adopt(&s, info)
            }
            if afterBind {
                // The launch lost the bind race and the holder is not ours: the busy failure, as before.
                return [chainOwnerLookup(&s, found: Self.found(outcome))]
            }
            switch outcome {
            case .unreachable:
                // Nothing listens: start the app's own server.
                return [.launch(port: s.port)]
            case .mismatch, .adopt:
                return [chainOwnerLookup(&s, found: Self.found(outcome))]
            case .needsToken, .silent, .timeout:
                s.phase = .failed(
                    .portBusy(port: s.port, owner: PortProbe.Owner(), found: Self.found(outcome), displayName: s.displayName))
                return []
            }

        case .externalFound(_, let info):
            guard !s.shuttingDown, s.server == nil, s.native == nil, s.install == nil, s.removal == nil,
                s.runtime != .appleSpeech, acceptsDiscovery(s.phase)
            else { return [] }
            return adopt(&s, info)

        case .externalLost(_, let reason):
            guard case .external = s.phase else { return [] }
            if reason != .mismatch {
                s.externalFailures += 1
                if s.externalFailures < externalFailureThreshold { return [] }
            }
            // Gone for good, or something else holds the port: re-read the state.
            s.externalFailures = 0
            s.phase = .checking
            return [.tearDown(note: "external server lost"), read(&s)]

        case .tryItRequested:
            guard case .external(let port, _) = s.phase else { return [] }
            return [.openTryIt(port: port)]

        case .launched(let id):
            // Only a launch effect sends this, and none is issued for an External service.
            guard !s.phase.isExternal else { return [] }
            s.server = id
            s.stopRequested = false
            s.supervisedError = nil
            s.phase = .starting
            return [.startDetail("Loading model…"), .startReadyTimer(id)]

        case .launchFailed(let message):
            guard !s.phase.isExternal else { return [] }
            s.phase = .failed(ServiceFailure(kind: .startup(code: nil), title: "Couldn't start", message: message))
            return []

        case .nativeLaunched(let id):
            guard !s.phase.isExternal else { return [] }
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
                s.endStartProbe()
                // A KeepAlive restart may have won the port: one hello probe adopts it.
                if s.runtime == .appleSpeech { return effects + [probePort(&s)] }
                s.probeAfterBind = true
                return effects + [probeExternal(&s)]
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
                s.endStartProbe()
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
            // An External service is never deleted (its server is not ours, nor its environment's business).
            guard s.runtime.usesPython, managerAvailable, s.phase != .removing, s.removal == nil, !s.phase.isExternal
            else { return [] }
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
            return s.phase.isExternal ? [] : [read(&s)]
        }
    }

    /// Goes (or stays) External. Only called from the phases that accept a discovery.
    private static func adopt(_ s: inout LifecycleState, _ info: ExternalInfo) -> [LifecycleEffect] {
        s.endStartProbe()
        s.startAfterRead = false
        s.externalFailures = 0
        s.phase = .external(s.port, info)
        return []
    }

    private static func found(_ outcome: ExternalProbe.Outcome) -> PortFound {
        switch outcome {
        case .mismatch(let hello), .adopt(_, let hello): .server(backend: hello.backendName, model: hello.model)
        case .needsToken: .needsToken
        case .silent: .silent
        case .timeout: .noAnswer
        case .unreachable: .unknown
        }
    }

    /// Looks up who holds the port, then fails busy with what answered (`busyFound`).
    private static func chainOwnerLookup(_ s: inout LifecycleState, found: PortFound) -> LifecycleEffect {
        s.busyFound = found
        return probePort(&s)
    }

    /// Issues a read under the current epoch (it replaces any read in flight).
    private static func read(_ s: inout LifecycleState, thenStart: Bool = false) -> LifecycleEffect {
        s.reading = s.epoch
        s.startAfterRead = thenStart
        return .refresh(epoch: s.epoch)
    }

    private static func probeExternal(_ s: inout LifecycleState) -> LifecycleEffect {
        s.probe = s.epoch
        return .probeExternal(port: s.port, probe: s.epoch)
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
