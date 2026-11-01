import Foundation
import Testing

@testable import PipecatToolbarCore

/// `ServiceLifecycle.reduce`, the pure state machine behind every service:
/// late ready/exit/timeout events, Stop, Delete and quit against every phase.
@Suite struct ServiceLifecycleTests {
    static let failure = ServiceFailure(kind: .install, title: "Couldn't remove", message: "no")
    /// What an adopted tone server's hello reported.
    static let externalInfo = ExternalInfo(backendName: "tone", model: nil, rate: 24000, protocolVersion: "0.1")
    static let external = ServicePhase.external(8665, externalInfo)
    static let phases: [ServicePhase] = [
        .checking, .unavailable("old"), .notInstalled, .needsModel, .installing(.model), .installed,
        .starting, .running, .stopping, .removing, .failed(failure), external,
    ]
    static let current = ServerID(1)
    static let stale = ServerID(0)
    static let date = Date(timeIntervalSince1970: 0)
    static let marker = EnvironmentMarker(service: "tone", fingerprint: "w", python: "3.12", createdAt: date)
    /// The tag of the install `state(installing: true)` has in flight.
    static let installTag = 100

    static func state(
        _ phase: ServicePhase, info: ServiceInfo = Service.tone.info, server: ServerID? = current,
        stopRequested: Bool = false, shuttingDown: Bool = false, installing: Bool = false
    ) -> LifecycleState {
        var s = LifecycleState(info: info)
        s.phase = phase
        s.environment = .ready(marker)
        s.requested = true
        // An External service never has a server of ours.
        s.server = phase.isExternal ? nil : server
        s.stopRequested = stopRequested
        s.shuttingDown = shuttingDown
        s.install = installing ? installTag : nil
        return s
    }

    // MARK: - acceptsStart

    /// The pure guard the `.startRequested` arm and the driver's last-used recorder share.
    @Test func acceptsStartRefusesEachGuard() {
        let free = Self.state(.installed, server: nil)
        #expect(ServiceLifecycle.acceptsStart(free, appAvailable: true))
        #expect(!ServiceLifecycle.acceptsStart(free, appAvailable: false))
        #expect(!ServiceLifecycle.acceptsStart(Self.state(.installed, server: Self.current), appAvailable: true))
        var native = free
        native.native = Self.current
        #expect(!ServiceLifecycle.acceptsStart(native, appAvailable: true))
        #expect(!ServiceLifecycle.acceptsStart(Self.state(.installed, server: nil, installing: true), appAvailable: true))
        var removing = free
        removing.removal = 1
        #expect(!ServiceLifecycle.acceptsStart(removing, appAvailable: true))
        #expect(!ServiceLifecycle.acceptsStart(Self.state(.removing, server: nil), appAvailable: true))
        #expect(!ServiceLifecycle.acceptsStart(Self.state(Self.external, server: nil), appAvailable: true))
    }

    /// The reducer and the guard cannot disagree: a refused start changes nothing and emits nothing.
    @Test func startRequestedFollowsAcceptsStartForEveryPhase() {
        for phase in Self.phases {
            for server in [nil, Self.current] as [ServerID?] {
                var s = Self.state(phase, server: server)
                let before = s
                let effects = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
                if !ServiceLifecycle.acceptsStart(before, appAvailable: true) {
                    #expect(effects.isEmpty && s == before, "\(phase) server=\(String(describing: server))")
                } else {
                    #expect(!effects.isEmpty, "\(phase) server=\(String(describing: server))")
                }
            }
        }
    }

    // MARK: - Ported from the app-target ServiceModelTests

    /// {phase} x {requested exit, crash} x {the exiting server is current, or
    /// already replaced}. A requested exit only completes a Stop; in particular
    /// one reported after a removal finished (`.notInstalled`) or failed keeps
    /// that phase. A crash of the current server fails it; a replaced server's
    /// exit changes nothing.
    @Test func everyExitAgainstEveryPhase() {
        // (An External service has no server of ours to exit: `everyEventAgainstEveryState` covers it.)
        for phase in Self.phases where !phase.isExternal {
            for requested in [true, false] {
                for current in [true, false] {
                    var s = Self.state(phase, server: current ? Self.current : ServerID(2), stopRequested: requested)
                    _ = ServiceLifecycle.reduce(&s, .exited(Self.current, status: 0, logTail: []))
                    let label = "\(phase) requested=\(requested) current=\(current)"
                    switch (current, requested) {
                    case (false, _): #expect(s.phase == phase, "\(label)")
                    case (true, true): #expect(s.phase == (phase == .stopping ? .installed : phase), "\(label)")
                    case (true, false):
                        guard case .failed(let f) = s.phase, case .crashed(status: 0) = f.kind else {
                            Issue.record("\(label): \(s.phase)")
                            continue
                        }
                    }
                    #expect(current ? s.server == nil : s.server != nil, "\(label)")
                }
            }
        }
    }

    /// The reported order: remove() -> shutdown() returns -> removal and
    /// refresh finish (`.notInstalled`) -> the drained exit arrives.
    @Test func aLateExitDoesNotReinstallARemovedService() {
        var s = Self.state(.installed)
        _ = ServiceLifecycle.reduce(&s, .removeRequested(deleteModel: true, managerAvailable: true))
        let removal = s.removal!
        _ = ServiceLifecycle.reduce(&s, .removalResumed(deleteModel: true, removal: removal))
        #expect(ServiceLifecycle.reduce(&s, .shutdownServers) == [.detachTryIt, .stopServer(Self.current, wait: true)])
        #expect(
            ServiceLifecycle.reduce(&s, .removalFinished(removal: removal))
                == [.clearLog, .refresh(epoch: s.epoch), .familyChanged])
        _ = ServiceLifecycle.reduce(&s, .refreshed(.notInstalled, environment: .missing, requested: false, epoch: s.epoch))
        _ = ServiceLifecycle.reduce(&s, .exited(Self.current, status: 15, logTail: []))
        #expect(s.phase == .notInstalled)
    }

    // MARK: - The whole state space

    /// Every event, for every phase, with the server current or late (a stale
    /// id), and with or without a Stop/removal (`stopRequested`) and app quit
    /// (`shuttingDown`) under way. Each row names the property that must hold.
    @Test func everyEventAgainstEveryState() {
        let tail = ["last line"]
        for phase in Self.phases {
            for late in [false, true] {
                for stopping in [false, true] {
                    for quitting in [false, true] {
                        let id = late ? Self.stale : Self.current
                        let label = "\(phase) late=\(late) stop=\(stopping) quit=\(quitting)"
                        func run(_ event: LifecycleEvent, info: ServiceInfo = Service.tone.info, installing: Bool = false)
                            -> (before: LifecycleState, after: LifecycleState, effects: [LifecycleEffect])
                        {
                            let before = Self.state(
                                phase, info: info, stopRequested: stopping, shuttingDown: quitting, installing: installing)
                            var after = before
                            let effects = ServiceLifecycle.reduce(&after, event)
                            return (before, after, effects)
                        }

                        // A ready line flips only the current server's `.starting` to running.
                        let ready = run(.ready(id, port: 8665, pid: 9, rate: 24000, model: nil, at: Self.date))
                        if !late && phase == .starting {
                            #expect(ready.after.phase == .running && ready.effects == [.openTryIt(port: 8665)], "\(label)")
                        } else {
                            #expect(ready.after == ready.before && ready.effects.isEmpty, "ready \(label)")
                        }

                        // The ready timeout stops only the current server still starting.
                        let timeout = run(.readyTimedOut(id))
                        if !late && phase == .starting {
                            #expect(timeout.effects == [.stopServer(Self.current, wait: false)], "\(label)")
                        } else {
                            #expect(timeout.after == timeout.before && timeout.effects.isEmpty, "timeout \(label)")
                        }

                        // An exit: a late one changes nothing; a requested one only completes a Stop.
                        let exit = run(.exited(id, status: 1, logTail: tail))
                        if late || phase.isExternal {
                            #expect(exit.after == exit.before && exit.effects.isEmpty, "exit \(label)")
                        } else if stopping {
                            #expect(exit.after.phase == (phase == .stopping ? .installed : phase), "exit \(label)")
                        } else {
                            #expect(exit.after.phase == .failed(ServiceFailure(
                                kind: .crashed(status: 1), title: "Server stopped unexpectedly",
                                message: "The Tone server exited with status 1.", logTail: tail)), "exit \(label)")
                        }
                        if !late { #expect(exit.after.server == nil && exit.after.running == nil, "\(label)") }

                        // Start never runs during a removal or with a server up.
                        let start = run(.startRequested(appAvailable: true, managerAvailable: true, portFree: true))
                        #expect(start.after == start.before && start.effects.isEmpty, "start with a server \(label)")
                        var idle = Self.state(phase, server: nil)
                        let startIdle = ServiceLifecycle.reduce(
                            &idle, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
                        #expect(startIdle == (phase == .removing || phase.isExternal ? [] : [.launch(port: 8665)]), "start \(label)")

                        // Stop moves the current server to `.stopping` from any phase.
                        let stop = run(.stopRequested)
                        if phase.isExternal {
                            #expect(stop.after == stop.before && stop.effects.isEmpty, "stop \(label)")
                        } else {
                            #expect(stop.after.phase == .stopping && stop.after.stopRequested, "stop \(label)")
                        }

                        // An install that ends while a removal owns the phase leaves it alone.
                        for outcome in [InstallOutcome.cancelled, .failed(stage: .model, message: "x", logTail: [])] {
                            let ended = run(.installEnded(outcome, then: .refresh, install: Self.installTag), installing: true)
                            #expect(!ended.after.installing, "\(label)")
                            if phase == .removing {
                                #expect(ended.after.phase == .removing && ended.effects.isEmpty, "install \(label)")
                            }
                        }

                        // Quit cancelled the Apple Speech install: nothing to show.
                        for outcome in [InstallOutcome.cancelled, .failed(stage: .model, message: "x", logTail: [])] {
                            let ended = run(.appleSpeechInstallEnded(outcome, install: Self.installTag), info: Service.appleSpeech.info, installing: true)
                            if quitting {
                                #expect(ended.after.phase == phase && ended.effects.isEmpty, "apple \(label)")
                            } else if outcome == .cancelled {
                                #expect(ended.after.phase == phase && ended.effects == [.refresh(epoch: ended.after.epoch)], "apple \(label)")
                            }
                        }

                        // A second Delete during a removal is a no-op; otherwise Delete takes the phase.
                        let remove = run(.removeRequested(deleteModel: true, managerAvailable: true))
                        if phase == .removing || phase.isExternal {
                            #expect(remove.after == remove.before && remove.effects.isEmpty, "remove \(label)")
                        } else {
                            #expect(remove.after.phase == .removing, "remove \(label)")
                            #expect(remove.effects.first == .cancelInstall, "remove \(label)")
                        }

                        // A sibling's change re-reads only settled phases.
                        let sibling = run(.environmentChanged(.missing))
                        let settled = [.checking, .notInstalled, .needsModel, .installed].contains(phase)
                        #expect(sibling.effects == (settled ? [.refresh(epoch: sibling.after.epoch)] : []), "sibling \(label)")
                        #expect(sibling.after.environment == (settled ? sibling.before.environment : .missing), "\(label)")
                    }
                }
            }
        }
    }

    // MARK: - The one rule: every event kind, classified

    /// The classification, written independently of the reducer. Both switches
    /// are exhaustive: a new `LifecycleEvent.Kind` fails to compile until it is
    /// classified here (and in `LifecycleEvent.kind` / `Kind.owner` / `isNonOwning`).
    static func expectedOwner(_ kind: LifecycleEvent.Kind) -> LifecycleEvent.Owner {
        switch kind {
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

    static func expectedNonOwning(_ kind: LifecycleEvent.Kind) -> Bool {
        switch kind {
        // `externalLost` is owning (its Nth failure changes the phase); a count-only one is the exception
        // `externalLostBelowTheThresholdLeavesTheEpoch` pins.
        case .cancelInstallRequested, .environmentRead, .supervisedError, .tryItRequested: true
        case .refreshRequested, .refreshed, .environmentChanged, .installRequested, .installStage, .installEnded,
            .appleSpeechInstallEnded, .startRequested, .portOwnerFound, .launched, .launchFailed, .nativeLaunched,
            .nativeBound, .nativeFailed, .ready, .readyTimedOut, .exited, .stopRequested, .shutdownRequested,
            .shutdownServers, .removeRequested, .removalResumed, .removalFailed, .removalFinished, .dismissFailure,
            .externalFound, .externalLost, .startProbeResult:
            false
        }
    }

    /// The tags `tagged(_:)` gives each owner slot.
    static let epochTag = 5, probeTag = 4, removalTag = 2, externalTag = 9

    /// A state whose owner slots hold the tags `sample` names (the server or
    /// native one only for the events that name it, the probe only where it can live).
    static func tagged(_ phase: ServicePhase, for kind: LifecycleEvent.Kind) -> LifecycleState {
        let owner = expectedOwner(kind)
        var s = state(phase, info: owner == .native ? Service.appleSpeech.info : Service.tone.info,
                      server: owner == .server ? current : nil, installing: owner == .install)
        s.epoch = epochTag
        s.externalEpoch = externalTag
        if owner == .native { s.native = current }
        if owner == .removal { s.removal = removalTag }
        if phase == .starting, s.server == nil, s.native == nil { s.probe = probeTag }
        return s
    }

    /// One event of `kind`, naming the current owner, or (`stale`) an older one.
    static func sample(_ kind: LifecycleEvent.Kind, stale: Bool) -> LifecycleEvent {
        let d = stale ? 1 : 0
        let id = stale ? Self.stale : current
        switch kind {
        case .refreshRequested: return .refreshRequested
        case .environmentRead: return .environmentRead(.missing, epoch: epochTag - d)
        case .refreshed: return .refreshed(.needsModel, environment: .missing, requested: false, epoch: epochTag - d)
        case .environmentChanged: return .environmentChanged(.missing)
        case .installRequested: return .installRequested(managerAvailable: true)
        case .cancelInstallRequested: return .cancelInstallRequested
        case .installStage: return .installStage(.packages, install: installTag - d)
        case .installEnded: return .installEnded(.finished, then: .refreshThenStart, install: installTag - d)
        case .appleSpeechInstallEnded: return .appleSpeechInstallEnded(.cancelled, install: installTag - d)
        case .startRequested: return .startRequested(appAvailable: true, managerAvailable: true, portFree: false)
        case .portOwnerFound: return .portOwnerFound(PortProbe.Owner(), probe: probeTag - d)
        case .startProbeResult: return .startProbeResult(tag: probeTag - d, outcome: .unreachable)
        // `.mismatch` moves an External service at once, so the loss is an owning event in every row.
        case .externalFound: return .externalFound(epoch: externalTag - d, info: externalInfo)
        case .externalLost: return .externalLost(epoch: externalTag - d, reason: .mismatch)
        case .tryItRequested: return .tryItRequested
        case .launched: return .launched(ServerID(3))
        case .launchFailed: return .launchFailed("x")
        case .nativeLaunched: return .nativeLaunched(ServerID(3))
        case .nativeBound: return .nativeBound(id, port: 1, pid: 1, at: date)
        case .nativeFailed: return .nativeFailed(id, "x")
        case .ready: return .ready(id, port: 1, pid: 1, rate: 24000, model: nil, at: date)
        case .supervisedError: return .supervisedError(id, SupervisedError(code: "x", message: nil))
        case .readyTimedOut: return .readyTimedOut(id)
        case .exited: return .exited(id, status: 1, logTail: [])
        case .stopRequested: return .stopRequested
        case .shutdownRequested: return .shutdownRequested
        case .shutdownServers: return .shutdownServers
        case .removeRequested: return .removeRequested(deleteModel: true, managerAvailable: true)
        case .removalResumed: return .removalResumed(deleteModel: true, removal: removalTag - d)
        case .removalFailed: return .removalFailed("x", removal: removalTag - d)
        case .removalFinished: return .removalFinished(removal: removalTag - d)
        case .dismissFailure: return .dismissFailure
        }
    }

    /// Effects that start async work whose result comes back tagged.
    static func issuesWork(_ effect: LifecycleEffect) -> Bool {
        switch effect {
        case .refresh, .runInstall, .runAppleSpeechInstall, .probePortOwner, .probeExternal, .launch, .launchNative,
            .resumeRemoval, .removeEnvironment, .start:
            true
        default: false
        }
    }

    /// {every event kind} x {every phase} x {result current, stale}: the source
    /// classification matches the table above; a stale result changes nothing
    /// (the epoch included; a stale native bind only releases its server); a
    /// current event advances the epoch exactly when it is not non-owning and
    /// its guard did not reject it (a rejected event changes nothing); a
    /// non-owning one changes no phase, no owner slot and no `requested`, and
    /// issues no tagged work.
    @Test func everyKindIsClassified() {
        #expect(LifecycleEvent.Kind.allCases.count == 32)
        for kind in LifecycleEvent.Kind.allCases {
            #expect(kind.owner == Self.expectedOwner(kind), "\(kind) owner")
            #expect(kind.isNonOwning == Self.expectedNonOwning(kind), "\(kind) non-owning")
            // The other two epoch tables, stated independently of the reducer.
            #expect(kind.keepsEpochWhenItOnlyCounts == (kind == .externalLost), "\(kind) count-only")
            #expect(
                kind.changesExternalEpoch
                    == [.startRequested, .installRequested, .stopRequested, .shutdownRequested, .shutdownServers,
                        .removeRequested].contains(kind), "\(kind) external epoch")
            #expect(Self.sample(kind, stale: false).kind == kind, "\(kind) sample")
            // A probe lives only in `.starting`.
            for phase in Self.phases
            where ((kind != .portOwnerFound && kind != .startProbeResult) || phase == .starting)
                // An External service has no server of ours, so a server's event is never current for it.
                && !(phase.isExternal && kind.owner == .server)
            {
                for stale in [false, true] where !stale || kind.owner != .none {
                    let event = Self.sample(kind, stale: stale)
                    var s = Self.tagged(phase, for: kind)
                    let before = s
                    let effects = ServiceLifecycle.reduce(&s, event)
                    let label = "\(kind) \(phase) stale=\(stale)"
                    #expect(ServiceLifecycle.isCurrent(event, in: before) == !stale, "\(label)")
                    if stale {
                        #expect(s == before, "a stale result changed the state: \(label)")
                        #expect(effects == (kind == .nativeBound ? [.discardNative(Self.stale)] : []), "\(label)")
                        continue
                    }
                    var settled = s
                    settled.epoch = before.epoch
                    let rejected = effects.isEmpty && settled == before
                    let onlyCounted = kind.keepsEpochWhenItOnlyCounts && before.phase.isExternal && s.phase.isExternal
                    #expect(
                        s.epoch == before.epoch + (kind.isNonOwning || rejected || onlyCounted ? 0 : 1), "epoch: \(label)")
                    // `externalEpoch` follows the tables too: a transition into or out of External,
                    // or an applied kind in `changesExternalEpoch`.
                    let movesExternal = !rejected && (s.phase.isExternal != before.phase.isExternal || kind.changesExternalEpoch)
                    #expect(s.externalEpoch == before.externalEpoch + (movesExternal ? 1 : 0), "external epoch: \(label)")
                    if kind.isNonOwning {
                        #expect(s.phase == before.phase && s.requested == before.requested, "\(label)")
                        #expect(
                            s.install == before.install && s.probe == before.probe && s.removal == before.removal
                                && s.server == before.server && s.native == before.native, "slots: \(label)")
                        #expect(!effects.contains(where: Self.issuesWork), "tagged work: \(label)")
                    }
                    // Work is always tagged with the epoch it was issued under.
                    for effect in effects {
                        switch effect {
                        case .refresh(let tag), .runInstall(_, _, let tag), .runAppleSpeechInstall(let tag),
                            .probePortOwner(_, let tag), .probeExternal(_, let tag):
                            #expect(tag == s.epoch, "\(effect): \(label)")
                        default: break
                        }
                    }
                    if s.phase != .starting || s.server != nil || s.native != nil { #expect(s.probe == nil, "\(label)") }
                }
            }
        }
    }

    // MARK: - Async results against the state they land in

    /// Who owns the phase when a result lands.
    enum Owner: CaseIterable { case none, server, stoppedServer, native, install, probe, removal }

    static func owned(_ phase: ServicePhase, by owner: Owner, info: ServiceInfo = Service.tone.info) -> LifecycleState {
        var s = state(
            phase, info: info, server: [.server, .stoppedServer].contains(owner) ? current : nil,
            stopRequested: owner == .stoppedServer, installing: owner == .install)
        if owner == .native { s.native = current }
        if owner == .probe { s.probe = 7 }
        if owner == .removal { s.removal = 7 }
        return s
    }

    /// The contract, stated independently of the reducer: a refresh may move the
    /// phase only when nothing owns it.
    static func live(_ s: LifecycleState) -> Bool {
        if s.install != nil || s.removal != nil || (s.server != nil && !s.stopRequested) || s.native != nil
            || s.probe != nil
        {
            return true
        }
        return [.starting, .running, .stopping, .removing, Self.external].contains(s.phase)
    }

    /// {phase} x {owner} x {refresh issued under the current or an older epoch}
    /// x {Python, Apple Speech}: a stale refresh changes nothing; a current one
    /// re-reads the environment but moves the phase only when nothing owns it.
    @Test func everyRefreshAgainstEveryState() {
        for info in [Service.tone.info, Service.appleSpeech.info] {
            for phase in Self.phases {
                for owner in Owner.allCases where owner != .probe || phase == .starting {
                    for stale in [false, true] {
                        var s = Self.owned(phase, by: owner, info: info)
                        s.epoch = 5
                        let before = s
                        let effects = ServiceLifecycle.reduce(
                            &s, .refreshed(.needsModel, environment: .missing, requested: false, epoch: stale ? 4 : 5))
                        let label = "\(info.service) \(phase) owner=\(owner) stale=\(stale)"
                        #expect(effects.isEmpty, "\(label)")
                        if stale {
                            #expect(s == before, "\(label)")
                        } else if Self.live(before) {
                            // Owned phases keep `requested`; External takes the refreshed value (its
                            // `isInstalled` reads it), and no live phase moves.
                            let isExternal = before.phase == Self.external
                            #expect(s.phase == before.phase, "\(label)")
                            #expect(s.requested == (isExternal ? false : before.requested), "\(label)")
                            #expect(s.environment == .missing, "\(label)")
                        } else {
                            #expect(s.phase == .needsModel && !s.requested && s.environment == .missing, "\(label)")
                        }
                    }
                }
            }
        }
    }

    /// {phase} x {probe tag current, stale, none}: only the current probe of a
    /// start still `.starting` with no server fails it as port-busy.
    @Test func everyPortOwnerAgainstEveryState() {
        for phase in Self.phases {
            for token in [Optional(7), 6, nil] {
                var s = Self.state(phase, server: nil)
                s.probe = phase == .starting ? token : nil
                let before = s
                _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(), probe: 7))
                if phase == .starting && token == 7 {
                    #expect(s.phase == .failed(.portBusy(port: 8665, owner: PortProbe.Owner())) && s.probe == nil, "\(phase)")
                } else {
                    #expect(s == before, "\(phase) token=\(String(describing: token))")
                }
            }
        }
    }

    /// An `error` line from a replaced server never reaches the current one.
    @Test func aStaleSupervisedErrorIsDropped() {
        for phase in Self.phases {
            var s = Self.state(phase)
            _ = ServiceLifecycle.reduce(&s, .supervisedError(Self.stale, SupervisedError(code: "EADDRINUSE", message: nil)))
            #expect(s.supervisedError == nil, "\(phase)")
            _ = ServiceLifecycle.reduce(&s, .exited(Self.current, status: 1, logTail: []))
            if case .failed(let f) = s.phase { #expect(f.kind == .crashed(status: 1), "\(phase)") }
        }
    }

    // MARK: - The reported sequences

    /// Issues a read the way the driver does and returns its tag.
    static func issueRead(_ s: inout LifecycleState) -> Int {
        let effects = ServiceLifecycle.reduce(&s, .refreshRequested)
        guard case .refresh(let tag) = effects.last else {
            Issue.record("no read issued: \(effects)")
            return -1
        }
        return tag
    }

    @Test func startDuringARefreshKeepsTheStart() {
        var s = Self.state(.installed, server: nil)
        let read = Self.issueRead(&s)  // a sibling's refresh begins
        _ = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
        _ = ServiceLifecycle.reduce(&s, .launched(Self.current))
        _ = ServiceLifecycle.reduce(&s, .refreshed(.installed, epoch: read))
        #expect(s.phase == .starting)
        _ = ServiceLifecycle.reduce(&s, .ready(Self.current, port: 8665, pid: 1, rate: 24000, model: nil, at: Self.date))
        #expect(s.phase == .running)
        let fresh = Self.issueRead(&s)  // Reset / Try Again
        _ = ServiceLifecycle.reduce(&s, .refreshed(.installed, epoch: fresh))
        #expect(s.phase == .running)
    }

    /// Delete while the package refresh's read runs: the read is stale when it
    /// lands, so it never starts the service (no `.start`, ever).
    @Test func deleteDuringRefreshThenStartNeverStarts() {
        var s = Self.state(.installing(.packages), server: nil, installing: true)
        let effects = ServiceLifecycle.reduce(&s, .installEnded(.finished, then: .refreshThenStart, install: Self.installTag))
        guard case .refresh(let read) = effects.first else {
            Issue.record("\(effects)")
            return
        }
        #expect(s.startAfterRead)
        var all = effects
        all += ServiceLifecycle.reduce(&s, .removeRequested(deleteModel: false, managerAvailable: true))
        #expect(!s.startAfterRead && s.reading == nil, "the removal did not orphan the start")
        let removal = s.removal!
        all += ServiceLifecycle.reduce(&s, .removalResumed(deleteModel: false, removal: removal))
        all += ServiceLifecycle.reduce(&s, .removalFinished(removal: removal))
        all += ServiceLifecycle.reduce(&s, .refreshed(.installed, environment: .ready(Self.marker), epoch: read))  // late
        #expect(s.phase == .checking)
        all += ServiceLifecycle.reduce(&s, .refreshed(.notInstalled, epoch: s.epoch))
        #expect(s.phase == .notInstalled)
        #expect(!all.contains(.start), "a stale read started a deleted service")
    }

    /// Two refreshes in flight: whichever lands first, only the newer applies.
    @Test func concurrentRefreshesApplyOnlyTheNewest() {
        for newerFirst in [true, false] {
            var s = Self.state(.checking, server: nil)
            let older = Self.issueRead(&s)
            let newer = Self.issueRead(&s)
            #expect(older != newer)
            let results: [LifecycleEvent] = [
                .refreshed(.installed, requested: true, epoch: newer),
                .refreshed(.notInstalled, requested: false, epoch: older),
            ]
            for event in newerFirst ? results : results.reversed() { _ = ServiceLifecycle.reduce(&s, event) }
            #expect(s.phase == .installed && s.requested, "newerFirst=\(newerFirst)")
        }
    }

    /// A sibling's change during the bootstrap read (and in the window after an
    /// install ended, before its read lands): the old read is dropped and a new
    /// one is issued, so the phase is never read from the old environment, and
    /// never stays unread.
    @Test func environmentChangedDuringARefresh() {
        var s = Self.state(.checking, server: nil)
        let bootstrap = Self.issueRead(&s)
        let changed = ServiceLifecycle.reduce(&s, .environmentChanged(.missing))
        guard case .refresh(let fresh) = changed.last else {
            Issue.record("\(changed)")
            return
        }
        _ = ServiceLifecycle.reduce(&s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: bootstrap))
        #expect(s.phase == .checking, "the pre-change read applied")
        _ = ServiceLifecycle.reduce(&s, .refreshed(.notInstalled, environment: .missing, requested: false, epoch: fresh))
        #expect(s.phase == .notInstalled)

        var window = Self.state(.installing(.model), server: nil, installing: true)
        let ended = ServiceLifecycle.reduce(&window, .installEnded(.finished, then: .refresh, install: Self.installTag))
        guard case .refresh(let afterInstall) = ended.first else {
            Issue.record("\(ended)")
            return
        }
        let reissued = ServiceLifecycle.reduce(&window, .environmentChanged(.missing))
        #expect(reissued == [.refresh(epoch: window.epoch)], "the orphaned read was not issued again")
        _ = ServiceLifecycle.reduce(&window, .refreshed(.needsModel, epoch: afterInstall))
        #expect(window.phase == .installing(.model))
        _ = ServiceLifecycle.reduce(&window, .refreshed(.installed, epoch: window.epoch))
        #expect(window.phase == .installed)
    }

    /// Start (port now free) while an earlier Start's port probe is pending: the
    /// launch ends the probe, so its late answer can't fail the server.
    @Test func startDuringAPendingPortProbe() {
        var s = Self.state(.installed, server: nil)
        let busy = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        guard case .probeExternal(_, let probe) = busy.last else {
            Issue.record("\(busy)")
            return
        }
        #expect(ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: true)).first == .launch(port: 8665))
        _ = ServiceLifecycle.reduce(&s, .launched(Self.current))
        #expect(s.probe == nil)
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(), probe: probe))
        #expect(s.phase == .starting, "the old probe failed the launching server")
        _ = ServiceLifecycle.reduce(&s, .ready(Self.current, port: 8665, pid: 1, rate: 24000, model: nil, at: Self.date))
        #expect(s.phase == .running)
    }

    @Test func refreshKeepsARunningAppleSpeechServer() {
        var s = Self.state(.installed, info: Service.appleSpeech.info, server: nil)
        _ = ServiceLifecycle.reduce(&s, .nativeLaunched(Self.current))
        _ = ServiceLifecycle.reduce(&s, .nativeBound(Self.current, port: 9465, pid: 1, at: Self.date))
        #expect(s.phase == .running)
        let read = Self.issueRead(&s)
        _ = ServiceLifecycle.reduce(&s, .refreshed(.installed, epoch: read))
        #expect(s.phase == .running && s.native == Self.current)
    }

    /// {every event kind} in `.starting` with a probe in flight: an event that
    /// ends the probe (other than its own answer) cancels it, exactly once, by
    /// its tag; one that leaves it running cancels nothing.
    @Test func anEndedProbeIsCancelled() {
        for kind in LifecycleEvent.Kind.allCases {
            var s = Self.tagged(.starting, for: kind)
            guard let probe = s.probe else { continue }
            let effects = ServiceLifecycle.reduce(&s, Self.sample(kind, stale: false))
            let cancels = effects.filter { if case .cancelProbe = $0 { true } else { false } }
            if s.probe != probe, kind != .portOwnerFound, kind != .startProbeResult {
                #expect(cancels == [.cancelProbe(probe: probe)], "\(kind): \(effects)")
                #expect(effects.first == .cancelProbe(probe: probe), "the cancel waits behind other work: \(kind): \(effects)")
            } else {
                #expect(cancels.isEmpty, "\(kind): \(effects)")
            }
        }
        // The probe's own answer ends it without a cancel; a second Start replaces it and cancels the first.
        var s = Self.state(.installed, server: nil)
        _ = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        let first = s.probe!
        let again = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        #expect(again.contains(.cancelProbe(probe: first)) && s.probe != first)
    }

    @Test func cancelDuringThePortProbeDropsIt() {
        var s = Self.state(.installed, server: nil)
        let effects = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        let probe = s.probe!
        #expect(effects.last == .probeExternal(port: 8665, probe: probe))
        #expect(ServiceLifecycle.reduce(&s, .stopRequested) == [.cancelProbe(probe: probe), .refresh(epoch: s.epoch)])
        #expect(s.phase == .checking && s.probe == nil)
        _ = ServiceLifecycle.reduce(&s, .refreshed(.installed, epoch: s.epoch))
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(), probe: probe))
        #expect(s.phase == .installed)
        // Delete while probing: the late answer can't fail a removed service.
        _ = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        let second = s.probe!
        _ = ServiceLifecycle.reduce(&s, .removeRequested(deleteModel: true, managerAvailable: true))
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(), probe: second))
        #expect(s.phase == .removing)
    }

    /// Apple Speech reported `.downloading` with no install of ours: attach to
    /// it. A user Cancel sticks: while the system still reports downloading, the
    /// follow-up refresh does not attach again; it reads as not installed until
    /// the system status moves on or the user presses Install.
    @Test func aCancelledSystemDownloadIsNotAttachedAgain() {
        var s = Self.state(.checking, info: Service.appleSpeech.info, server: nil)
        let read = Self.issueRead(&s)
        let attach = ServiceLifecycle.reduce(&s, .refreshed(.installing(.model), epoch: read))
        #expect(attach == [.runAppleSpeechInstall(install: s.epoch)])
        #expect(s.installing && s.phase == .installing(.model))
        #expect(ServiceLifecycle.reduce(&s, .cancelInstallRequested) == [.cancelInstall])
        let ended = ServiceLifecycle.reduce(&s, .appleSpeechInstallEnded(.cancelled, install: s.install!))
        #expect(!s.installing && ended == [.refresh(epoch: s.epoch)])
        // The system is still downloading (another app, or a download outliving our task).
        #expect(ServiceLifecycle.reduce(&s, .refreshed(.installing(.model), epoch: s.epoch)).isEmpty, "Cancel re-attached")
        #expect(s.phase == .notInstalled && !s.installing)
        // Install re-enables it.
        #expect(ServiceLifecycle.reduce(&s, .installRequested(managerAvailable: false)) == [.runAppleSpeechInstall(install: s.epoch)])
        _ = ServiceLifecycle.reduce(&s, .appleSpeechInstallEnded(.cancelled, install: s.install!))
        // The system status moved on: the next download is attached again.
        _ = ServiceLifecycle.reduce(&s, .refreshed(.notInstalled, epoch: s.epoch))
        let next = Self.issueRead(&s)
        #expect(ServiceLifecycle.reduce(&s, .refreshed(.installing(.model), epoch: next)) == [.runAppleSpeechInstall(install: s.epoch)])
    }

    /// The lifecycle's reading of itself (what the menu groups by).
    @Test func derivedFlagsForEveryPhase() {
        let runtime = ServiceFailure(kind: .crashed(status: 1), title: "", message: "")
        for phase in Self.phases + [.failed(runtime)] {
            for requested in [false, true] {
                var s = Self.state(phase, server: nil)
                s.requested = requested
                let active: Bool
                let installed: Bool
                let busy: Bool
                switch phase {
                case .starting, .running, .stopping: (active, installed) = (true, true)
                // The app's own install (the environment is ready here), as `installedPhase` reads it.
                case .external: (active, installed) = (true, requested)
                case .installed, .needsModel: (active, installed) = (false, true)
                case .installing, .removing: (active, installed) = (false, requested)
                case .failed(let f): (active, installed) = (f.isRuntime, f.isRuntime || requested)
                default: (active, installed) = (false, false)
                }
                switch phase {
                case .checking, .installing, .starting, .stopping, .removing: busy = true
                default: busy = false
                }
                #expect(s.isActive == active && s.isInstalled == installed && s.isBusy == busy, "\(phase) \(requested)")
                #expect(s.isInstalling == (phase == .installing(.model)), "\(phase)")
                // Reset is refused in a phase a server, install or removal holds...
                let busyPhases: [ServicePhase] = [.starting, .running, .stopping, .installing(.model), .removing]
                #expect(s.blocksReset == busyPhases.contains(phase), "reset \(phase)")
            }
        }
    }

    /// ...and for any owner slot, whatever the phase reads.
    @Test func blocksResetForEveryOwner() {
        for phase in Self.phases {
            for owner in Owner.allCases {
                let s = Self.owned(phase, by: owner)
                // (An External service holds no server of ours: `owned` leaves that slot empty.)
                let held: [Owner] = phase.isExternal ? [.native, .install, .removal] : [.server, .stoppedServer, .native, .install, .removal]
                let expected = held.contains(owner)
                    || [.starting, .running, .stopping, .installing(.model), .removing].contains(phase)
                #expect(s.blocksReset == expected, "\(phase) \(owner)")
            }
        }
    }

    /// Quit cancels only an Apple Speech install, and waits for it boundedly.
    @Test func shutdownCancelsOnlyAnAppleSpeechInstall() {
        var apple = Self.state(.installing(.model), info: Service.appleSpeech.info, server: nil, installing: true)
        #expect(ServiceLifecycle.reduce(&apple, .shutdownRequested) == [.cancelInstall, .awaitInstall(bounded: true)])
        #expect(apple.shuttingDown)
        var python = Self.state(.installing(.model), server: nil, installing: true)
        #expect(ServiceLifecycle.reduce(&python, .shutdownRequested).isEmpty)
        #expect(!python.shuttingDown)
    }

    /// The native server: a bind that lands after Stop is discarded.
    @Test func aLateNativeBindIsDiscarded() {
        var s = Self.state(.installed, info: Service.appleSpeech.info, server: nil)
        _ = ServiceLifecycle.reduce(&s, .nativeLaunched(Self.current))
        #expect(s.phase == .starting)
        #expect(ServiceLifecycle.reduce(&s, .stopRequested) == [.stopNative, .tearDown(note: "stopped"), .refresh(epoch: s.epoch)])
        #expect(s.phase == .installed)
        #expect(ServiceLifecycle.reduce(&s, .nativeBound(Self.current, port: 9465, pid: 1, at: Self.date)) == [.discardNative(Self.current)])
        #expect(s.phase == .installed)
    }

    /// A supervised error decides how the exit reads.
    @Test func exitAfterSupervisedErrors() {
        var busy = Self.state(.starting)
        _ = ServiceLifecycle.reduce(&busy, .supervisedError(Self.current, SupervisedError(code: "EADDRINUSE", message: nil)))
        #expect(
            ServiceLifecycle.reduce(&busy, .exited(Self.current, status: 1, logTail: [])).last
                == .probeExternal(port: 8665, probe: busy.epoch))
        var missing = Self.state(.starting)
        _ = ServiceLifecycle.reduce(&missing, .supervisedError(Self.current, SupervisedError(code: "ModuleNotFoundError", message: "m")))
        _ = ServiceLifecycle.reduce(&missing, .exited(Self.current, status: 1, logTail: []))
        #expect(missing.phase == .failed(ServiceFailure(kind: .startup(code: "ModuleNotFoundError"), title: "Environment incomplete", message: "m")))
    }

    /// The install's mode and first stage, and an outdated environment refreshed before start.
    @Test func installModesAndOutdatedStart() {
        #expect(ServiceLifecycle.installMode(environment: .missing, phase: .needsModel) == .full)
        #expect(ServiceLifecycle.installMode(environment: .ready(Self.marker), phase: .needsModel) == .model)
        let download = ServiceFailure(kind: .download, title: "", message: "")
        #expect(ServiceLifecycle.installMode(environment: .ready(Self.marker), phase: .failed(download)) == .model)
        #expect(ServiceLifecycle.firstStage(mode: .full, environment: .missing) == .python)
        var outdated = Self.state(.installed, server: nil)
        outdated.environment = .outdated(Self.marker)
        #expect(
            ServiceLifecycle.reduce(&outdated, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
                == [.runInstall(.packages, then: .refreshThenStart, install: outdated.epoch)])
        #expect(outdated.phase == .installing(.packages) && outdated.installing)
        let install = outdated.install!
        #expect(
            ServiceLifecycle.reduce(&outdated, .installEnded(.finished, then: .refreshThenStart, install: install))
                == [.refresh(epoch: outdated.epoch), .familyChanged])
        #expect(outdated.startAfterRead)
        // The read lands current: it starts the service.
        outdated.environment = .ready(Self.marker)
        #expect(ServiceLifecycle.reduce(&outdated, .refreshed(.installed, epoch: outdated.epoch)) == [.start])
    }

    // MARK: - External: discovery events and the ownership invariant

    static let toneHello = try! HelloFixtures.frame(HelloFixtures.json(for: .tone))
    static let kokoroHello = try! HelloFixtures.frame(HelloFixtures.json(for: .kokoro))

    /// An adopted tone service, no server of ours, `externalEpoch` as a probe would have read it.
    static func externalState(failures: Int = 0, epoch: Int = 3) -> LifecycleState {
        var s = state(external, server: nil)
        s.externalEpoch = epoch
        s.externalFailures = failures
        return s
    }

    /// The effects an External service may ever produce: cancel a probe, open Try it, tear its
    /// session down, the read-only owner lookup, and the state re-read.
    static func allowedForExternal(_ effect: LifecycleEffect) -> Bool {
        switch effect {
        case .cancelProbe, .openTryIt, .tearDown, .probePortOwner, .refresh: true
        default: false
        }
    }

    /// A lost External server: its Try it session is torn down, then the state is re-read.
    static func isLossReread(_ effects: [LifecycleEffect], epoch: Int) -> Bool {
        guard effects.count == 2, case .tearDown = effects[0] else { return false }
        return effects[1] == .refresh(epoch: epoch)
    }

    /// Phases that accept a discovery event.
    static let discoverable: [ServicePhase] = [.notInstalled, .installed, .failed(failure), .checking]

    @Test func externalFoundAdoptsFromEveryAcceptingPhase() {
        for phase in Self.discoverable {
            var s = Self.state(phase, server: nil)
            s.externalEpoch = 3
            let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
            #expect(s.phase == Self.external, "\(phase)")
            #expect(s.externalEpoch == 4, "a transition into External advances the epoch: \(phase)")
            #expect(s.server == nil && s.native == nil, "\(phase)")
            #expect(effects.allSatisfy(Self.allowedForExternal), "\(phase): \(effects)")
        }
    }

    /// Adopted from `.checking` while the bootstrap read is in flight: the adoption advances the
    /// epoch and orphans that read, so it is re-issued under the new epoch, and its answer records
    /// `requested` (External's `isInstalled` reads it) without moving the External phase. The
    /// answer to the orphaned read is still dropped.
    @Test func aReadInFlightAtAdoptionIsReissuedAndRecordsRequested() {
        var s = Self.state(.checking, server: nil)
        s.externalEpoch = 3
        s.requested = false
        s.environment = .missing
        let bootstrap = Self.issueRead(&s)
        let adopted = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
        #expect(s.phase == Self.external)
        // Shared: re-issued exactly once under the new epoch, and the orphaned answer is dropped.
        Self.expectOrphanedReadReissuedWhileExternal(&s, adopted, orphaned: bootstrap, "adoption")
        #expect(!s.isInstalled, "the dropped orphaned answer must not record requested")
        // Answer the read the reducer actually issued, not one forged at the current epoch.
        guard case .refresh(let reissued) = adopted.last else {
            Issue.record("no read re-issued: \(adopted)")
            return
        }

        // The re-issued read records `requested` and the environment; External stays put.
        let landed = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: reissued))
        #expect(landed.isEmpty, "\(landed)")
        #expect(s.phase == Self.external, "a refresh never moves External")
        #expect(s.requested && s.environment == .ready(Self.marker))
        #expect(s.isInstalled)
        #expect(s.reading == nil, "the answered read is not issued again")
    }

    /// Asserts `effects` is exactly the re-issued read at the new epoch, the service stayed
    /// External, and the orphaned read's answer (tagged `orphaned`) is dropped.
    static func expectOrphanedReadReissuedWhileExternal(
        _ s: inout LifecycleState, _ effects: [LifecycleEffect], orphaned: Int, _ label: String
    ) {
        #expect(s.phase.isExternal, "\(label): left External")
        #expect(s.epoch != orphaned, "\(label): the epoch did not advance")
        #expect(effects == [.refresh(epoch: s.epoch)], "\(label): \(effects)")
        #expect(effects.allSatisfy(allowedForExternal), "\(label): \(effects)")
        #expect(s.reading == s.epoch && !s.startAfterRead, "\(label)")
        let before = s
        let late = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(marker), requested: true, epoch: orphaned))
        #expect(late.isEmpty && s == before, "\(label): the orphaned read applied")
    }

    /// A sibling's environment change while External, with a read in flight: the change advances
    /// the epoch and orphans the read, which is re-issued (External is not `dropsOrphanedRead`).
    @Test func environmentChangedWhileExternalReissuesTheReadInFlight() {
        var s = Self.externalState()
        s.environment = .missing
        let orphaned = Self.issueRead(&s)
        let effects = ServiceLifecycle.reduce(&s, .environmentChanged(.ready(Self.marker)))
        #expect(s.environment == .ready(Self.marker))
        Self.expectOrphanedReadReissuedWhileExternal(&s, effects, orphaned: orphaned, "environmentChanged")
    }

    /// External to External `externalFound` resets the failure count, which advances the epoch
    /// and orphans the read in flight: it is re-issued under the new epoch.
    @Test func externalFoundOnAnExternalServiceReissuesTheReadInFlight() {
        var s = Self.externalState(failures: 2)
        let orphaned = Self.issueRead(&s)
        let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
        #expect(s.externalFailures == 0)
        Self.expectOrphanedReadReissuedWhileExternal(&s, effects, orphaned: orphaned, "externalFound")
    }

    /// No read in flight: going External still issues exactly one, under the new epoch (an
    /// earlier owner may have dropped one; `reduce` rule 4). Staying External issues none.
    @Test func adoptionWithNoReadInFlightIssuesOneRead() {
        var s = Self.state(.checking, server: nil)
        s.externalEpoch = 3
        #expect(s.reading == nil)
        let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
        #expect(effects == [.refresh(epoch: s.epoch)], "\(effects)")
        #expect(s.phase == Self.external && s.reading == s.epoch && !s.startAfterRead)
        // Answered: a further found on the same server (External to External) issues none.
        _ = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: s.epoch))
        #expect(s.reading == nil)
        let again = ServiceLifecycle.reduce(&s, .externalFound(epoch: s.externalEpoch, info: Self.externalInfo))
        #expect(again.isEmpty && s.reading == nil, "\(again)")
    }

    /// Asserts a transition into External left a stale row re-read: `effects` carries a read at
    /// the current epoch, and its answer records `requested` and the environment.
    static func expectAdoptionRereads(_ s: inout LifecycleState, _ effects: [LifecycleEffect], _ label: String) {
        #expect(s.phase.isExternal, "\(label): \(s.phase)")
        #expect(effects.contains(.refresh(epoch: s.epoch)), "\(label): no read after the adoption: \(effects)")
        #expect(effects.allSatisfy(allowedForExternal), "\(label): \(effects)")
        #expect(s.reading == s.epoch && !s.startAfterRead, "\(label)")
        #expect(!s.isInstalled, "\(label): the stale row already reads installed")
        let landed = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(marker), requested: true, epoch: s.epoch))
        #expect(landed.isEmpty && s.phase.isExternal, "\(label): \(landed)")
        #expect(s.requested && s.environment == .ready(marker) && s.isInstalled, "\(label)")
    }

    /// A read in flight when a busy-port Start begins is dropped (the Start-path probe owns the
    /// phase, `dropsOrphanedRead`); the probe then adopts, an end that re-reads nothing by itself.
    @Test func aReadDroppedByTheStartProbeIsIssuedAgainWhenItAdopts() {
        var s = Self.state(.installed, server: nil)
        s.requested = false
        s.environment = .missing
        let inFlight = Self.issueRead(&s)
        let started = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        guard case .probeExternal(_, let probe)? = started.last else {
            Issue.record("no hello probe: \(started)")
            return
        }
        #expect(s.reading == nil, "the probe dropped the read in flight (dropsOrphanedRead)")
        let adopted = ServiceLifecycle.reduce(
            &s, .startProbeResult(tag: probe, outcome: .adopt(Service.tone.info, Self.toneHello)))
        #expect(s.epoch != inFlight)
        Self.expectAdoptionRereads(&s, adopted, "Start-path adopt")
    }

    /// The bind-race chain: a read issued while the app's server starts is dropped by the
    /// `EADDRINUSE` exit (its `probeAfterBind` probe owns the phase); the probe then adopts.
    @Test func aReadDroppedByTheBindRaceProbeIsIssuedAgainWhenItAdopts() {
        var s = Self.state(.starting)
        s.requested = false
        s.environment = .missing
        _ = Self.issueRead(&s)
        _ = ServiceLifecycle.reduce(&s, .supervisedError(Self.current, SupervisedError(code: "EADDRINUSE", message: nil)))
        let exited = ServiceLifecycle.reduce(&s, .exited(Self.current, status: 1, logTail: []))
        guard case .probeExternal(8665, let probe)? = exited.last else {
            Issue.record("no hello probe: \(exited)")
            return
        }
        #expect(s.probeAfterBind && s.reading == nil, "the probe dropped the read in flight")
        let adopted = ServiceLifecycle.reduce(
            &s, .startProbeResult(tag: probe, outcome: .adopt(Service.tone.info, Self.toneHello)))
        Self.expectAdoptionRereads(&s, adopted, "bind-race adopt")
    }

    /// A read dropped by a Start-path probe that then failed busy (no re-read: the failure is
    /// shown), adopted later by discovery from that `.failed` phase.
    @Test func aReadDroppedBeforeABusyFailureIsIssuedAgainWhenDiscoveryAdopts() {
        var s = Self.state(.installed, server: nil)
        s.requested = false
        s.environment = .missing
        _ = Self.issueRead(&s)
        let started = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        guard case .probeExternal(_, let probe)? = started.last else {
            Issue.record("no hello probe: \(started)")
            return
        }
        let failed = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: .timeout))
        #expect(failed.isEmpty && s.reading == nil, "\(failed)")
        let adopted = ServiceLifecycle.reduce(&s, .externalFound(epoch: s.externalEpoch, info: Self.externalInfo))
        Self.expectAdoptionRereads(&s, adopted, "discovery adopt from .failed")
    }

    /// Every end of owned work that fails it, with a read in flight (issued while the work owned
    /// the phase): the failure orphans the read and drops it (`dropsOrphanedRead`), issuing none,
    /// so the orphaned answer can't replace the failure before the user saw it. Dismiss is the
    /// way out: it issues its own read, whose answer replaces the failure.
    @Test func aFailureDropsTheReadItOrphansAndKeepsItsPhase() {
        var native = Self.state(.starting, info: Service.appleSpeech.info, server: nil)
        native.native = Self.current
        var probing = Self.state(.starting, server: nil)
        probing.probe = 7
        var removing = Self.state(.removing, server: nil)
        removing.removal = 5
        let ends: [(String, LifecycleState, LifecycleEvent)] = [
            ("launchFailed", Self.state(.installed, server: nil), .launchFailed("no")),
            ("nativeFailed", native, .nativeFailed(Self.current, "no")),
            ("portOwnerFound", probing, .portOwnerFound(PortProbe.Owner(pid: 1, command: "other"), probe: 7)),
            ("removalFailed", removing, .removalFailed("no", removal: 5)),
            ("crash", Self.state(.running), .exited(Self.current, status: 1, logTail: [])),
            (
                "installEnded failed", Self.state(.installing(.model), server: nil, installing: true),
                .installEnded(.failed(stage: .model, message: "no", logTail: []), then: .refresh, install: Self.installTag)
            ),
        ]
        for (label, start, end) in ends {
            var s = start
            let orphaned = Self.issueRead(&s)
            let effects = ServiceLifecycle.reduce(&s, end)
            guard case .failed = s.phase else {
                Issue.record("\(label): did not fail: \(s.phase)")
                continue
            }
            let failed = s.phase
            #expect(!effects.contains { if case .refresh = $0 { true } else { false } }, "\(label): \(effects)")
            #expect(s.reading == nil && !s.startAfterRead, "\(label): the orphaned read was kept")
            let before = s
            let late = ServiceLifecycle.reduce(
                &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: orphaned))
            #expect(late.isEmpty && s == before && s.phase == failed, "\(label): the orphaned answer applied")
            let dismissed = ServiceLifecycle.reduce(&s, .dismissFailure)
            #expect(dismissed == [.refresh(epoch: s.epoch)], "\(label): \(dismissed)")
            _ = ServiceLifecycle.reduce(
                &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: s.epoch))
            #expect(s.phase == .installed, "\(label): Dismiss's read did not replace the failure")
        }
    }

    /// A completed Stop is an owner's end, so it re-reads what a read dropped while the server ran
    /// (`dropsOrphanedRead(after:)`): the supervised exit from `.stopping` and the native Stop each
    /// issue exactly one read, whose answer records `requested` and the environment; a repeated
    /// end issues none.
    @Test func aCompletedStopReissuesTheReadDroppedWhileTheServerRan() {
        var native = Self.state(.running, info: Service.appleSpeech.info, server: nil)
        native.native = Self.current
        let cases: [(String, LifecycleState, [LifecycleEvent])] = [
            ("supervised", Self.state(.running), [.stopRequested, .exited(Self.current, status: 0, logTail: [])]),
            ("native", native, [.stopRequested]),
        ]
        for (label, start, stop) in cases {
            var s = start
            _ = Self.issueRead(&s)
            // A sibling's change while the server runs orphans the read, which is dropped.
            _ = ServiceLifecycle.reduce(&s, .environmentChanged(.missing))
            #expect(s.reading == nil, "\(label): the read was not dropped while running")
            var effects: [LifecycleEffect] = []
            for event in stop { effects = ServiceLifecycle.reduce(&s, event) }
            #expect(s.phase == .installed, "\(label): \(s.phase)")
            let reads = effects.filter { if case .refresh = $0 { true } else { false } }
            #expect(reads == [.refresh(epoch: s.epoch)], "\(label): \(effects)")
            #expect(s.reading == s.epoch && !s.startAfterRead, "\(label)")
            // Repeated, the end is stale or a no-op: no second read.
            let again = ServiceLifecycle.reduce(&s, stop.last!)
            #expect(again.isEmpty, "\(label): \(again)")
            _ = ServiceLifecycle.reduce(
                &s, .refreshed(.notInstalled, environment: .missing, requested: false, epoch: s.epoch))
            #expect(s.phase == .notInstalled && !s.requested && s.environment == .missing, "\(label)")
        }
    }

    /// Quit's server stop (`shutdownServers`) is not a Stop: neither its exit nor the native
    /// stop issues a read.
    @Test func quitsServerStopIssuesNoRead() {
        var supervised = Self.state(.running)
        _ = ServiceLifecycle.reduce(&supervised, .shutdownServers)
        let exited = ServiceLifecycle.reduce(&supervised, .exited(Self.current, status: 0, logTail: []))
        #expect(exited == [.tearDown(note: "exited with status 0")], "\(exited)")
        var native = Self.state(.running, info: Service.appleSpeech.info, server: nil)
        native.native = Self.current
        let stopped = ServiceLifecycle.reduce(&native, .shutdownServers)
        #expect(stopped == [.stopNative, .tearDown(note: "stopped")], "\(stopped)")
    }

    /// A read orphaned while a failure is already shown is issued again: Dismiss's read, orphaned
    /// by a sibling's change, still replaces the failure. Only the event that entered `.failed`
    /// drops the read it orphaned (`aFailureDropsTheReadItOrphansAndKeepsItsPhase`).
    @Test func dismissesReadOrphanedBySiblingChangeIsIssuedAgain() {
        var s = Self.state(.failed(Self.failure), server: nil)
        let dismissed = ServiceLifecycle.reduce(&s, .dismissFailure)
        guard case .refresh(let orphaned)? = dismissed.last else {
            Issue.record("no read: \(dismissed)")
            return
        }
        let changed = ServiceLifecycle.reduce(&s, .environmentChanged(.missing))
        #expect(changed == [.refresh(epoch: s.epoch)], "Dismiss's read was dropped: \(changed)")
        #expect(s.epoch != orphaned && s.reading == s.epoch)
        let before = s
        let late = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: orphaned))
        #expect(late.isEmpty && s == before, "the orphaned answer applied")
        _ = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: s.epoch))
        #expect(s.phase == .installed, "the re-issued read did not replace the failure")
    }

    /// A retry that fails again with the very same failure value still entered that failure: Start
    /// from `.failed` re-issues the read in flight (the launch has not answered yet), and the
    /// identical `launchFailed` (no value changes) drops it, so its answer can't replace the new
    /// failure unseen.
    @Test func aRetryFailingIdenticallyDropsTheReadInFlight() {
        let same = ServiceFailure(kind: .startup(code: nil), title: "Couldn't start", message: "no")
        var s = Self.state(.failed(same), server: nil)
        _ = Self.issueRead(&s)
        let started = ServiceLifecycle.reduce(&s, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
        #expect(started == [.launch(port: 8665), .refresh(epoch: s.epoch)], "\(started)")
        let orphaned = s.epoch
        let failed = ServiceLifecycle.reduce(&s, .launchFailed("no"))
        #expect(s.phase == .failed(same), "\(s.phase)")
        #expect(!failed.contains { if case .refresh = $0 { true } else { false } }, "\(failed)")
        #expect(s.reading == nil && !s.startAfterRead, "the read in flight was kept")
        let before = s
        let late = ServiceLifecycle.reduce(
            &s, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: orphaned))
        #expect(late.isEmpty && s == before && s.phase == .failed(same), "the orphaned answer replaced the new failure")
    }

    /// The premise of `dropsOrphanedRead(after:)`: every end of live work re-reads or shows a
    /// failure. Over the phase table (plus the probe, removal and native owner slots) x every event,
    /// any applied event that takes a state with live work (not External) to one without must
    /// issue a read or leave `.failed`. Quit's ends are the named exceptions (`isQuitEnd`).
    @Test func everyEndOfLiveWorkRereadsOrFails() {
        var starts: [(String, LifecycleState)] = []
        for info in [Service.tone.info, Service.appleSpeech.info] {
            for phase in Self.phases where !phase.isExternal {
                for server in [Self.current, nil] as [ServerID?] {
                    for stopping in [false, true] {
                        for quitting in [false, true] {
                            for installing in [false, true] {
                                let s = Self.state(
                                    phase, info: info, server: server, stopRequested: stopping, shuttingDown: quitting,
                                    installing: installing)
                                starts.append(("\(info.service) \(phase) server=\(server != nil) stop=\(stopping) quit=\(quitting) install=\(installing)", s))
                            }
                        }
                    }
                }
            }
            for afterBind in [false, true] {
                var probing = Self.state(.starting, info: info, server: nil)
                probing.probe = 7
                probing.probeAfterBind = afterBind
                starts.append(("\(info.service) probing afterBind=\(afterBind)", probing))
            }
            for server in [Self.current, nil] as [ServerID?] {
                var removing = Self.state(.removing, info: info, server: server, stopRequested: server != nil)
                removing.removal = 5
                starts.append(("\(info.service) removing server=\(server != nil)", removing))
            }
            for phase in [ServicePhase.starting, .running] {
                for quitting in [false, true] {
                    var native = Self.state(phase, info: info, server: nil, shuttingDown: quitting)
                    native.native = Self.current
                    starts.append(("\(info.service) native \(phase) quit=\(quitting)", native))
                }
            }
        }
        let installOutcomes: [InstallOutcome] = [.finished, .cancelled, .failed(stage: .model, message: "no", logTail: [])]
        let probeOutcomes: [ExternalProbe.Outcome] = [
            .unreachable, .timeout, .silent, .needsToken, .mismatch(Self.kokoroHello), .adopt(Service.tone.info, Self.toneHello),
        ]
        var events: [LifecycleEvent] = [
            .refreshRequested, .refreshed(.installed, environment: .ready(Self.marker), requested: true, epoch: 0),
            .environmentRead(.ready(Self.marker), epoch: 0), .environmentChanged(.missing),
            .installRequested(managerAvailable: true), .cancelInstallRequested,
            .startRequested(appAvailable: true, managerAvailable: true, portFree: true),
            .startRequested(appAvailable: true, managerAvailable: true, portFree: false),
            .portOwnerFound(PortProbe.Owner(pid: 1, command: "other"), probe: 7),
            .launched(ServerID(2)), .launchFailed("no"), .nativeLaunched(ServerID(2)),
            .nativeBound(Self.current, port: 8665, pid: 1, at: Self.date), .nativeFailed(Self.current, "no"),
            .ready(Self.current, port: 8665, pid: 1, rate: 24000, model: nil, at: Self.date),
            .supervisedError(Self.current, SupervisedError(code: "EADDRINUSE", message: nil)),
            .readyTimedOut(Self.current), .exited(Self.current, status: 0, logTail: []),
            .exited(Self.current, status: 1, logTail: []), .stopRequested, .shutdownRequested, .shutdownServers,
            .removeRequested(deleteModel: false, managerAvailable: true), .removalResumed(deleteModel: false, removal: 5),
            .removalFailed("no", removal: 5), .removalFinished(removal: 5), .dismissFailure,
            .externalFound(epoch: 0, info: Self.externalInfo), .externalLost(epoch: 0, reason: .mismatch), .tryItRequested,
        ]
        for outcome in installOutcomes {
            events.append(.installEnded(outcome, then: .refresh, install: Self.installTag))
            events.append(.appleSpeechInstallEnded(outcome, install: Self.installTag))
        }
        for outcome in probeOutcomes { events.append(.startProbeResult(tag: 7, outcome: outcome)) }

        /// Quit's ends issue no read on purpose (the app is going away): its own server stop
        /// (`shutdownServers`, supervised or native) and the Apple Speech install it cancelled.
        func isQuitEnd(_ event: LifecycleEvent, _ before: LifecycleState) -> Bool {
            switch event {
            case .shutdownServers: true
            case .appleSpeechInstallEnded: before.shuttingDown
            default: false
            }
        }

        var checked = 0
        for (label, start) in starts where start.hasLiveWork && !start.phase.isExternal {
            for event in events {
                var s = start
                let effects = ServiceLifecycle.reduce(&s, event)
                guard !s.hasLiveWork, !isQuitEnd(event, start) else { continue }
                checked += 1
                let reads = effects.contains { if case .refresh = $0 { true } else { false } }
                var failed = false
                if case .failed = s.phase { failed = true }
                #expect(
                    reads || failed,
                    "\(label) \(event.kind): live work ended with no read and no failure: \(s.phase) \(effects)")
            }
        }
        #expect(checked > 0, "no transition out of live work was exercised")
    }

    /// The events the driver used to send without running their effects: from every phase, with
    /// the owner current or stale, with or without an install and a read in flight, they return
    /// none. (Install and External exclude each other, so that pair is not a reachable state.)
    @Test func environmentReadInstallStageAndSupervisedErrorIssueNoEffect() {
        for phase in Self.phases {
            for installing in [false, true] where !(installing && phase.isExternal) {
                for reading in [false, true] {
                    for late in [false, true] {
                        let label = "\(phase) installing=\(installing) reading=\(reading) late=\(late)"
                        var start = Self.state(phase, installing: installing)
                        if reading { _ = Self.issueRead(&start) }
                        let events: [LifecycleEvent] = [
                            .environmentRead(.missing, epoch: late ? start.epoch - 1 : start.epoch),
                            .installStage(.packages, install: late ? Self.installTag - 1 : Self.installTag),
                            .supervisedError(late ? Self.stale : Self.current, SupervisedError(code: "X", message: nil)),
                        ]
                        for event in events {
                            var s = start
                            let effects = ServiceLifecycle.reduce(&s, event)
                            #expect(effects.isEmpty, "\(event) \(label): \(effects)")
                        }
                    }
                }
            }
        }
    }

    /// An owned phase is never moved, so a found can't drop `s.server` and leak the process.
    @Test func externalFoundInOwnedPhasesChangesNothing() {
        let owned: [ServicePhase] = [.installing(.model), .starting, .running, .stopping, .removing, .needsModel, .unavailable("x")]
        for phase in owned {
            for withServer in [false, true] {
                var s = Self.state(phase, server: withServer ? Self.current : nil)
                s.externalEpoch = 3
                let before = s
                let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
                #expect(s == before && effects.isEmpty, "\(phase) server=\(withServer)")
            }
        }
        // A server of ours in any phase keeps the phase, even one that would accept a found.
        for phase in Self.discoverable {
            var s = Self.state(phase, server: Self.current)
            s.externalEpoch = 3
            let before = s
            #expect(ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo)).isEmpty)
            #expect(s == before && s.server == Self.current, "\(phase)")
        }
    }

    @Test func externalFoundDuringShutdownChangesNothing() {
        for phase in Self.discoverable {
            var s = Self.state(phase, server: nil, shuttingDown: true)
            s.externalEpoch = 3
            let before = s
            #expect(ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo)).isEmpty)
            #expect(s == before, "\(phase)")
        }
    }

    @Test func externalFoundInCheckingClearsTheStartAfterRead() {
        var s = Self.state(.checking, server: nil)
        s.startAfterRead = true
        s.externalEpoch = 3
        let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
        #expect(s.phase == Self.external && !s.startAfterRead)
        #expect(!effects.contains(.start) && !effects.contains(.launch(port: 8665)))
        // The read that was meant to start it lands on an External service and starts nothing.
        let landed = ServiceLifecycle.reduce(&s, .refreshed(.installed, epoch: s.epoch))
        #expect(s.phase == Self.external && !landed.contains(.start))
    }

    @Test func externalFoundOnAnExternalServiceRefreshesTheInfoAndResetsTheCount() {
        var s = Self.externalState(failures: 2)
        let newer = ExternalInfo(backendName: "tone", model: nil, rate: 16000, protocolVersion: "0.1")
        let effects = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: newer))
        #expect(s.phase == .external(8665, newer) && s.externalFailures == 0)
        #expect(s.externalEpoch == 3, "External to External is not a transition")
        #expect(effects.allSatisfy(Self.allowedForExternal))
    }

    @Test func externalLostIsIgnoredOutsideExternal() {
        for phase in Self.phases where !phase.isExternal {
            for reason in [ExternalLostReason.refused, .timeout, .mismatch] {
                var s = Self.state(phase, server: nil)
                s.externalEpoch = 3
                let before = s
                let effects = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: reason))
                #expect(s == before && effects.isEmpty, "\(phase) \(reason)")
            }
        }
    }

    /// Refused and timeout each count one; the Nth moves the service to checking and re-reads it.
    @Test(arguments: [
        [ExternalLostReason.refused, .refused, .refused],
        [.timeout, .timeout, .timeout],
        [.refused, .timeout, .refused],
    ])
    func theNthFailedProbeMovesToChecking(reasons: [ExternalLostReason]) {
        #expect(reasons.count == ServiceLifecycle.externalFailureThreshold)
        var s = Self.externalState()
        for reason in reasons.dropLast() {
            let before = s
            let effects = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: reason))
            #expect(effects.isEmpty && s.phase == Self.external, "\(reason)")
            #expect(s.externalEpoch == 3 && s.epoch == before.epoch, "a below-threshold loss leaves both epochs alone")
            #expect(s.externalFailures == before.externalFailures + 1)
        }
        let effects = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: reasons.last!))
        #expect(s.phase == .checking && s.externalFailures == 0)
        #expect(s.externalEpoch == 4, "leaving External advances the epoch")
        #expect(Self.isLossReread(effects, epoch: s.epoch), "\(effects)")
        #expect(s.server == nil && s.native == nil)
    }

    /// The count is of consecutive failures: a found in between starts over.
    @Test func aFoundResetsTheFailureCount() {
        var s = Self.externalState()
        for _ in 0..<(ServiceLifecycle.externalFailureThreshold - 1) {
            _ = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: .refused))
        }
        _ = ServiceLifecycle.reduce(&s, .externalFound(epoch: 3, info: Self.externalInfo))
        #expect(s.externalFailures == 0)
        for _ in 0..<(ServiceLifecycle.externalFailureThreshold - 1) {
            _ = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: .timeout))
        }
        #expect(s.phase == Self.external, "the count did not start over")
    }

    /// A count-only loss is the one owning kind that changes no phase: `epoch` stays.
    @Test func externalLostBelowTheThresholdLeavesTheEpoch() {
        var s = Self.externalState()
        s.epoch = 12
        let before = s
        let effects = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: .refused))
        #expect(effects.isEmpty)
        #expect(s.epoch == 12 && s.externalEpoch == before.externalEpoch && s.phase == before.phase)
        #expect(s.externalFailures == 1)
    }

    @Test func aMismatchMovesToCheckingAtOnce() {
        for failures in 0..<ServiceLifecycle.externalFailureThreshold {
            var s = Self.externalState(failures: failures)
            let effects = ServiceLifecycle.reduce(&s, .externalLost(epoch: 3, reason: .mismatch))
            #expect(s.phase == .checking && s.externalFailures == 0, "failures=\(failures)")
            #expect(Self.isLossReread(effects, epoch: s.epoch), "\(effects)")
        }
    }

    /// Discovery events carry the `externalEpoch` the probe started under; one behind is dropped.
    @Test func aStaleDiscoveryEventChangesNothing() {
        let events: [LifecycleEvent] = [
            .externalFound(epoch: 2, info: Self.externalInfo), .externalLost(epoch: 2, reason: .mismatch),
            .externalLost(epoch: 4, reason: .refused),
        ]
        for phase in Self.phases {
            for event in events {
                var s = Self.state(phase, server: phase.isExternal ? nil : Self.current)
                s.externalEpoch = 3
                let before = s
                #expect(ServiceLifecycle.reduce(&s, event).isEmpty)
                #expect(s == before, "\(phase) \(event)")
            }
        }
    }

    /// A probe that started before Stop, Delete or quit can't resurrect or demote the service.
    @Test func stopDeleteAndQuitAdvanceTheExternalEpoch() {
        // Stop while the Start-path probe runs.
        var stopped = Self.state(.installed, server: nil)
        let discoveryEpoch = stopped.externalEpoch
        _ = ServiceLifecycle.reduce(&stopped, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        _ = ServiceLifecycle.reduce(&stopped, .stopRequested)
        #expect(stopped.externalEpoch > discoveryEpoch)
        let afterStop = stopped
        #expect(ServiceLifecycle.reduce(&stopped, .externalFound(epoch: discoveryEpoch, info: Self.externalInfo)).isEmpty)
        #expect(stopped == afterStop && !stopped.phase.isExternal)

        // Delete.
        var deleted = Self.state(.installed, server: nil)
        _ = ServiceLifecycle.reduce(&deleted, .removeRequested(deleteModel: true, managerAvailable: true))
        #expect(deleted.externalEpoch > discoveryEpoch)
        #expect(ServiceLifecycle.reduce(&deleted, .externalFound(epoch: discoveryEpoch, info: Self.externalInfo)).isEmpty)
        #expect(deleted.phase == .removing)

        // Quit stops a server of ours.
        var quit = Self.state(.running)
        _ = ServiceLifecycle.reduce(&quit, .shutdownServers)
        #expect(quit.externalEpoch > discoveryEpoch)
        #expect(ServiceLifecycle.reduce(&quit, .externalFound(epoch: discoveryEpoch, info: Self.externalInfo)).isEmpty)
        #expect(!quit.phase.isExternal)

        // Quit that cancels an Apple Speech install.
        var apple = Self.state(.installing(.model), info: Service.appleSpeech.info, server: nil, installing: true)
        _ = ServiceLifecycle.reduce(&apple, .shutdownRequested)
        #expect(apple.externalEpoch > discoveryEpoch)
    }

    /// {every event kind} x {every phase}: `externalEpoch` moves only on a transition into or out
    /// of External, or on Start, Install, Stop, Delete and quit; no other event touches it.
    @Test func theExternalEpochSurvivesEveryNonTransitionEvent() {
        let advancing: Set<LifecycleEvent.Kind> = [
            .startRequested, .installRequested, .stopRequested, .shutdownRequested, .shutdownServers, .removeRequested,
        ]
        for kind in LifecycleEvent.Kind.allCases {
            for phase in Self.phases where (kind != .portOwnerFound && kind != .startProbeResult) || phase == .starting {
                var s = Self.tagged(phase, for: kind)
                let before = s
                _ = ServiceLifecycle.reduce(&s, Self.sample(kind, stale: false))
                let label = "\(kind) \(phase)"
                if s.phase.isExternal != before.phase.isExternal {
                    #expect(s.externalEpoch == before.externalEpoch + 1, "transition: \(label)")
                } else if advancing.contains(kind) {
                    #expect([before.externalEpoch, before.externalEpoch + 1].contains(s.externalEpoch), "\(label)")
                } else {
                    #expect(s.externalEpoch == before.externalEpoch, "\(label)")
                }
            }
        }
    }

    // MARK: External: the ownership invariant

    /// An External service is never started, installed, removed or signalled.
    @Test func externalRefusesEveryOwnedIntent() {
        let intents: [LifecycleEvent] = [
            .startRequested(appAvailable: true, managerAvailable: true, portFree: true),
            .startRequested(appAvailable: true, managerAvailable: true, portFree: false),
            .installRequested(managerAvailable: true), .installRequested(managerAvailable: false),
            .cancelInstallRequested, .removeRequested(deleteModel: true, managerAvailable: true),
            .removeRequested(deleteModel: false, managerAvailable: true), .stopRequested, .shutdownRequested,
            .shutdownServers, .dismissFailure,
            .launched(ServerID(3)), .launchFailed("x"), .nativeLaunched(ServerID(3)),
        ]
        for info in [Service.tone.info, Service.whisper.info] {
            for event in intents {
                var s = Self.state(Self.external, info: info, server: nil)
                let before = s
                let effects = ServiceLifecycle.reduce(&s, event)
                #expect(s == before && effects.isEmpty, "\(info.service) \(event): \(effects)")
            }
        }
    }

    /// Reset is app-wide and gated by `blocksReset`; an External service neither blocks it nor is changed by it.
    @Test func resetNeitherBlocksNorChangesAnExternalService() {
        var s = Self.externalState()
        #expect(!s.blocksReset)
        #expect(AppPhase.ready.allowsReset(servicesBusy: s.blocksReset))
        // The re-read Reset leads to, and a sibling's environment change, never overwrite External.
        let read = Self.issueRead(&s)
        #expect(ServiceLifecycle.reduce(&s, .refreshed(.notInstalled, environment: .missing, requested: false, epoch: read)).isEmpty)
        #expect(s.phase == Self.external)
        #expect(ServiceLifecycle.reduce(&s, .environmentChanged(.missing)).isEmpty)
        #expect(s.phase == Self.external && s.environment == .missing)
    }

    @Test func tryItRequestedOpensOnlyOnAnExternalService() {
        for phase in Self.phases {
            var s = Self.state(phase, server: nil)
            let before = s
            let effects = ServiceLifecycle.reduce(&s, .tryItRequested)
            #expect(s == before, "non-owning: \(phase)")
            #expect(effects == (phase.isExternal ? [.openTryIt(port: 8665)] : []), "\(phase)")
        }
        // A server of ours in a running phase still opens through `becameReady` only.
        var running = Self.state(.running)
        #expect(ServiceLifecycle.reduce(&running, .tryItRequested).isEmpty)
    }

    /// The allow-list: whatever happens to an External service, only these effects come out and
    /// no server or native process ever appears. {every event kind} x {stale, current} x {quit under way}.
    ///
    /// `nativeBound` is the one kind left out: a bind that names no native server of ours is answered
    /// with `.discardNative` (it stops the process that bind belongs to, never an External one), by
    /// the reducer's first guard whatever the phase. It is asserted on its own below.
    @Test func anExternalServiceOnlyEverGetsAllowListedEffects() {
        for info in [Service.tone.info, Service.whisper.info] {
            for kind in LifecycleEvent.Kind.allCases where kind != .nativeBound {
                for stale in [false, true] {
                    for quitting in [false, true] {
                        for failures in [0, ServiceLifecycle.externalFailureThreshold - 1] {
                            var s = Self.state(Self.external, info: info, server: nil, shuttingDown: quitting)
                            s.epoch = Self.epochTag
                            s.externalEpoch = Self.externalTag
                            s.externalFailures = failures
                            let event = Self.sample(kind, stale: stale)
                            let effects = ServiceLifecycle.reduce(&s, event)
                            let label = "\(info.service) \(kind) stale=\(stale) quit=\(quitting) failures=\(failures)"
                            #expect(effects.allSatisfy(Self.allowedForExternal), "\(label): \(effects)")
                            #expect(s.server == nil && s.native == nil, "\(label)")
                            #expect(s.stopRequested == false, "\(label)")
                        }
                    }
                }
            }
        }
        var s = Self.externalState()
        let effects = ServiceLifecycle.reduce(&s, Self.sample(.nativeBound, stale: true))
        #expect(effects == [.discardNative(Self.stale)] && s == Self.externalState())
    }

    // MARK: External: the Start path

    static func busyStart(info: ServiceInfo = Service.tone.info) -> (state: LifecycleState, probe: Int) {
        var s = state(.installed, info: info, server: nil)
        let effects = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        guard case .probeExternal(_, let probe)? = effects.last else {
            Issue.record("no hello probe: \(effects)")
            return (s, -1)
        }
        return (s, probe)
    }

    @Test func aBusyPortStartIssuesOneHelloProbeAndStaysStarting() {
        var s = Self.state(.installed, server: nil)
        let effects = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        #expect(s.phase == .starting && s.probe == s.epoch)
        #expect(effects == [.startDetail("Checking port 8665…"), .probeExternal(port: 8665, probe: s.epoch)])
        // A free port launches at once, with no probe.
        var free = Self.state(.installed, server: nil)
        let launch = ServiceLifecycle.reduce(
            &free, .startRequested(appAvailable: true, managerAvailable: true, portFree: true))
        #expect(launch == [.launch(port: 8665)] && free.probe == nil)
    }

    @Test func appleSpeechOnABusyPortLooksUpTheOwnerOnly() {
        var s = Self.state(.installed, info: Service.appleSpeech.info, server: nil)
        let effects = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        #expect(effects.last == .probePortOwner(port: 9465, probe: s.epoch))
        #expect(!effects.contains { if case .probeExternal = $0 { true } else { false } })
    }

    /// A discovery probe that began before Start answers about an older moment than the Start
    /// path's own probe. Once Start has settled (here: the port is another server's), the late
    /// discovery answer must not turn the failure into an adoption.
    @Test func aDiscoveryResultFromBeforeStartIsStaleOnceStartHasSettled() {
        var s = Self.state(.installed, server: nil)
        let discoveryEpoch = s.externalEpoch
        let start = ServiceLifecycle.reduce(
            &s, .startRequested(appAvailable: true, managerAvailable: true, portFree: false))
        guard case .probeExternal(_, let probe)? = start.last else {
            Issue.record("\(start)")
            return
        }
        #expect(s.externalEpoch > discoveryEpoch)
        let owner = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: .mismatch(Self.kokoroHello)))
        guard case .probePortOwner(_, let ownerProbe)? = owner.last else {
            Issue.record("\(owner)")
            return
        }
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(), probe: ownerProbe))
        guard case .failed = s.phase else {
            Issue.record("\(s.phase)")
            return
        }
        let late = ServiceLifecycle.reduce(&s, .externalFound(epoch: discoveryEpoch, info: Self.externalInfo))
        #expect(late.isEmpty)
        guard case .failed = s.phase else {
            Issue.record("a stale discovery result adopted: \(s.phase)")
            return
        }
    }

    @Test func installingMakesAnEarlierDiscoveryResultStale() {
        var s = Self.state(.notInstalled, server: nil)
        s.environment = .missing
        let discoveryEpoch = s.externalEpoch
        _ = ServiceLifecycle.reduce(&s, .installRequested(managerAvailable: true))
        #expect(s.externalEpoch > discoveryEpoch)
        #expect(ServiceLifecycle.reduce(&s, .externalFound(epoch: discoveryEpoch, info: Self.externalInfo)).isEmpty)
        #expect(!s.phase.isExternal)
    }

    /// Apple Speech runs in the app and has no port to adopt: not even a direct event can make it External.
    @Test func appleSpeechIsNeverExternal() {
        for phase in Self.phases {
            var s = Self.state(phase, info: Service.appleSpeech.info, server: nil)
            let before = s
            let effects = ServiceLifecycle.reduce(
                &s, .externalFound(epoch: s.externalEpoch, info: Self.externalInfo))
            #expect(effects.isEmpty && s == before, "\(phase)")
        }
    }

    @Test func startProbeAdoptGoesExternal() {
        var (s, probe) = Self.busyStart()
        let effects = ServiceLifecycle.reduce(
            &s, .startProbeResult(tag: probe, outcome: .adopt(Service.tone.info, Self.toneHello)))
        #expect(s.phase == .external(8665, ExternalInfo(hello: Self.toneHello)))
        #expect(s.probe == nil && s.server == nil && s.native == nil)
        #expect(effects.allSatisfy(Self.allowedForExternal), "\(effects)")
        #expect(!effects.contains(.launch(port: 8665)))
    }

    @Test func startProbeMismatchChainsTheOwnerLookupBeforeTheBusyFailure() {
        var (s, probe) = Self.busyStart()
        let effects = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: .mismatch(Self.kokoroHello)))
        guard case .probePortOwner(8665, let ownerProbe)? = effects.last, effects.count == 1 else {
            Issue.record("\(effects)")
            return
        }
        #expect(s.phase == .starting && s.probe == ownerProbe)
        let owner = PortProbe.Owner(pid: 77, command: "python")
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(owner, probe: ownerProbe))
        guard case .failed(let failure) = s.phase,
            case .portBusy(let found, found: .server(let backend, _)) = failure.kind
        else {
            Issue.record("\(s.phase)")
            return
        }
        #expect(found == owner && backend == "kokoro")
        #expect(failure.message.contains("kokoro"), "\(failure.message)")
    }

    @Test(arguments: [
        (ExternalProbe.Outcome.needsToken, "token"), (.silent, "identified itself"), (.timeout, "answered"),
    ])
    func startProbeNeedsTokenSilentAndTimeoutFailBusyWithTheirMessage(outcome: ExternalProbe.Outcome, word: String) {
        var (s, probe) = Self.busyStart()
        let effects = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: outcome))
        #expect(effects.isEmpty, "\(effects)")
        guard case .failed(let failure) = s.phase, case .portBusy = failure.kind else {
            Issue.record("\(s.phase)")
            return
        }
        #expect(failure.title == "Port 8665 is busy")
        #expect(failure.message.contains(word), "\(failure.message)")
        #expect(s.probe == nil && s.server == nil)
    }

    @Test func startProbeUnreachableLaunchesTheAppsOwnServer() {
        var (s, probe) = Self.busyStart()
        let effects = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: .unreachable))
        #expect(effects == [.launch(port: 8665)])
        #expect(s.phase == .starting)
    }

    static let outcomes: [ExternalProbe.Outcome] = [
        .adopt(Service.tone.info, toneHello), .mismatch(kokoroHello), .needsToken, .silent, .timeout, .unreachable,
    ]

    @Test func aStaleStartProbeResultChangesNothing() {
        for outcome in Self.outcomes {
            var (s, probe) = Self.busyStart()
            let before = s
            #expect(ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe - 1, outcome: outcome)).isEmpty)
            #expect(s == before, "\(outcome)")
            // Stop ended the probe: the late answer can't resurrect or launch anything.
            _ = ServiceLifecycle.reduce(&s, .stopRequested)
            let stopped = s
            #expect(ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: outcome)).isEmpty)
            #expect(s == stopped && !s.phase.isExternal, "\(outcome)")
        }
    }

    /// Outside `.starting` an outcome adopts, launches and fails nothing.
    @Test func aStartProbeResultOutsideStartingDoesNothing() {
        for phase in Self.phases where phase != .starting {
            for outcome in Self.outcomes {
                var s = Self.state(phase, server: nil)
                s.probe = 7
                let before = s
                let effects = ServiceLifecycle.reduce(&s, .startProbeResult(tag: 7, outcome: outcome))
                #expect(s.phase == before.phase, "\(phase) \(outcome)")
                #expect(!effects.contains(.launch(port: 8665)), "\(phase) \(outcome)")
                #expect(!effects.contains { if case .probePortOwner = $0 { true } else { false } }, "\(phase) \(outcome)")
            }
        }
        // A launched server (the probe's slot is gone): nothing to adopt over it.
        var s = Self.state(.starting)
        s.probe = 7
        let before = s.phase
        _ = ServiceLifecycle.reduce(&s, .startProbeResult(tag: 7, outcome: .adopt(Service.tone.info, Self.toneHello)))
        #expect(s.phase == before && s.server == Self.current)
    }

    // MARK: External: EADDRINUSE after a launch

    /// The launched server loses the bind race; the reducer chains one hello probe.
    static func lostTheBindRace() -> (state: LifecycleState, probe: Int) {
        var s = state(.starting)
        _ = ServiceLifecycle.reduce(&s, .supervisedError(current, SupervisedError(code: "EADDRINUSE", message: nil)))
        let effects = ServiceLifecycle.reduce(&s, .exited(current, status: 1, logTail: []))
        guard case .probeExternal(8665, let probe)? = effects.last else {
            Issue.record("\(effects)")
            return (s, -1)
        }
        return (s, probe)
    }

    @Test func eaddrinuseAfterLaunchAdoptsTheKeepAliveRestartThatWonThePort() {
        var (s, probe) = Self.lostTheBindRace()
        #expect(s.phase == .starting && s.server == nil && s.probeAfterBind)
        let effects = ServiceLifecycle.reduce(
            &s, .startProbeResult(tag: probe, outcome: .adopt(Service.tone.info, Self.toneHello)))
        #expect(s.phase == .external(8665, ExternalInfo(hello: Self.toneHello)))
        #expect(!s.probeAfterBind && s.probe == nil)
        #expect(effects.allSatisfy(Self.allowedForExternal), "\(effects)")
    }

    @Test(arguments: [
        ExternalProbe.Outcome.mismatch(ServiceLifecycleTests.kokoroHello), .needsToken, .silent, .timeout, .unreachable,
    ])
    func eaddrinuseAfterLaunchStaysBusyForAnythingButAnAdopt(outcome: ExternalProbe.Outcome) {
        var (s, probe) = Self.lostTheBindRace()
        let effects = ServiceLifecycle.reduce(&s, .startProbeResult(tag: probe, outcome: outcome))
        #expect(!effects.contains(.launch(port: 8665)), "\(outcome): the app's own server just lost the port")
        guard case .probePortOwner(_, let ownerProbe)? = effects.last else {
            Issue.record("\(outcome): \(effects)")
            return
        }
        _ = ServiceLifecycle.reduce(&s, .portOwnerFound(PortProbe.Owner(pid: 5), probe: ownerProbe))
        guard case .failed(let failure) = s.phase, case .portBusy = failure.kind else {
            Issue.record("\(outcome): \(s.phase)")
            return
        }
        #expect(!s.phase.isExternal)
    }

    // MARK: External: the policy's directives against the reducer

    /// A LaunchAgent restart: refused (one failed probe, still External), then found again.
    @Test func externalLostThenFoundAfterALaunchAgentRestart() {
        var s = Self.state(.installed, server: nil)
        func apply(_ outcome: ExternalProbe.Outcome) {
            let snapshot = ExternalDiscoveryPolicy.Snapshot(service: .tone, epoch: s.externalEpoch, phase: s.phase)
            let directives = ExternalDiscoveryPolicy.events(
                for: [.init(snapshot: snapshot, outcome: outcome)])
            for directive in directives { _ = ServiceLifecycle.reduce(&s, directive.event) }
        }
        apply(.adopt(Service.tone.info, Self.toneHello))
        #expect(s.phase.isExternal)
        apply(.unreachable)
        apply(.unreachable)
        #expect(s.phase.isExternal && s.externalFailures == 2, "not responding, still External")
        apply(.adopt(Service.tone.info, Self.toneHello))
        #expect(s.phase.isExternal && s.externalFailures == 0)
        // A restart that outlasts the threshold: back to checking, then adopted again.
        for _ in 0..<ServiceLifecycle.externalFailureThreshold { apply(.unreachable) }
        #expect(s.phase == .checking)
        apply(.adopt(Service.tone.info, Self.toneHello))
        #expect(s.phase.isExternal)
    }

    /// Silent, needs-token and mismatch re-probes all mean something else holds the port.
    @Test(arguments: [ExternalProbe.Outcome.silent, .needsToken, .mismatch(ServiceLifecycleTests.kokoroHello)])
    func aReProbeThatFindsSomethingElseMovesToCheckingAtOnce(outcome: ExternalProbe.Outcome) {
        var s = Self.externalState()
        let snapshot = ExternalDiscoveryPolicy.Snapshot(service: .tone, epoch: s.externalEpoch, phase: s.phase)
        let directives = ExternalDiscoveryPolicy.events(for: [.init(snapshot: snapshot, outcome: outcome)])
        #expect(directives.count == 1)
        for directive in directives { _ = ServiceLifecycle.reduce(&s, directive.event) }
        #expect(s.phase == .checking, "\(outcome)")
    }
}
