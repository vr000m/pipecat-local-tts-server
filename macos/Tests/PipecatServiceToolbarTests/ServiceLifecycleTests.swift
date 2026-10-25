import Foundation
import Testing

@testable import PipecatToolbarCore

/// `ServiceLifecycle.reduce`, the pure state machine behind every service:
/// late ready/exit/timeout events, Stop, Delete and quit against every phase.
@Suite struct ServiceLifecycleTests {
    static let failure = ServiceFailure(kind: .install, title: "Couldn't remove", message: "no")
    static let phases: [ServicePhase] = [
        .checking, .unavailable("old"), .notInstalled, .needsModel, .installing(.model), .installed,
        .starting, .running, .stopping, .removing, .failed(failure),
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
        s.server = server
        s.stopRequested = stopRequested
        s.shuttingDown = shuttingDown
        s.install = installing ? installTag : nil
        return s
    }

    // MARK: - Ported from the app-target ServiceModelTests

    /// {phase} x {requested exit, crash} x {the exiting server is current, or
    /// already replaced}. A requested exit only completes a Stop; in particular
    /// one reported after a removal finished (`.notInstalled`) or failed keeps
    /// that phase. A crash of the current server fails it; a replaced server's
    /// exit changes nothing.
    @Test func everyExitAgainstEveryPhase() {
        for phase in Self.phases {
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
                        if late {
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
                        #expect(startIdle == (phase == .removing ? [] : [.launch(port: 8665)]), "start \(label)")

                        // Stop moves the current server to `.stopping` from any phase.
                        let stop = run(.stopRequested)
                        #expect(stop.after.phase == .stopping && stop.after.stopRequested, "stop \(label)")

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
                        if phase == .removing {
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

    static func expectedNonOwning(_ kind: LifecycleEvent.Kind) -> Bool {
        switch kind {
        case .cancelInstallRequested, .environmentRead, .supervisedError: true
        case .refreshRequested, .refreshed, .environmentChanged, .installRequested, .installStage, .installEnded,
            .appleSpeechInstallEnded, .startRequested, .portOwnerFound, .launched, .launchFailed, .nativeLaunched,
            .nativeBound, .nativeFailed, .ready, .readyTimedOut, .exited, .stopRequested, .shutdownRequested,
            .shutdownServers, .removeRequested, .removalResumed, .removalFailed, .removalFinished, .dismissFailure:
            false
        }
    }

    /// The tags `tagged(_:)` gives each owner slot.
    static let epochTag = 5, probeTag = 4, removalTag = 2

    /// A state whose owner slots hold the tags `sample` names (the server or
    /// native one only for the events that name it, the probe only where it can live).
    static func tagged(_ phase: ServicePhase, for kind: LifecycleEvent.Kind) -> LifecycleState {
        let owner = expectedOwner(kind)
        var s = state(phase, info: owner == .native ? Service.appleSpeech.info : Service.tone.info,
                      server: owner == .server ? current : nil, installing: owner == .install)
        s.epoch = epochTag
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
        case .refresh, .runInstall, .runAppleSpeechInstall, .probePortOwner, .launch, .launchNative, .resumeRemoval,
            .removeEnvironment, .start:
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
        #expect(LifecycleEvent.Kind.allCases.count == 28)
        for kind in LifecycleEvent.Kind.allCases {
            #expect(kind.owner == Self.expectedOwner(kind), "\(kind) owner")
            #expect(kind.isNonOwning == Self.expectedNonOwning(kind), "\(kind) non-owning")
            #expect(Self.sample(kind, stale: false).kind == kind, "\(kind) sample")
            // A probe lives only in `.starting`.
            for phase in Self.phases where kind != .portOwnerFound || phase == .starting {
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
                    #expect(s.epoch == before.epoch + (kind.isNonOwning || rejected ? 0 : 1), "epoch: \(label)")
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
                            .probePortOwner(_, let tag):
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
        return [.starting, .running, .stopping, .removing].contains(s.phase)
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
                            #expect(s.phase == before.phase && s.requested == before.requested, "\(label)")
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
        guard case .probePortOwner(_, let probe) = busy.last else {
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
            if s.probe != probe, kind != .portOwnerFound {
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
        #expect(effects.last == .probePortOwner(port: 8665, probe: probe))
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
                let expected = [.server, .stoppedServer, .native, .install, .removal].contains(owner)
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
        #expect(ServiceLifecycle.reduce(&s, .stopRequested) == [.stopNative, .tearDown(note: "stopped")])
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
                == .probePortOwner(port: 8665, probe: busy.epoch))
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
}
