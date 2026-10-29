import Foundation
import Testing

@testable import PipecatToolbarCore

/// `RestorePolicy.plan` (which wanted services start on launch) and `WantedTransition.next`
/// (how the wanted flag moves with each lifecycle event): both pure, both written out per case.
@Suite struct RestorePolicyTests {
    // MARK: - RestorePolicy

    static func state(_ phase: ServicePhase, requested: Bool = true) -> LifecycleState {
        ServiceCountsTests.state(phase, requested: requested)
    }

    /// The decision for one service (`tone`) alone, so each row stays about one state.
    static func decision(
        _ s: LifecycleState, wanted: Bool, preferenceOn: Bool, service: Service = .tone
    ) -> RestoreDecision? {
        RestorePolicy.plan(wanted: wanted ? [service] : [], states: [service: s], preferenceOn: preferenceOn)[service]
    }

    /// Written per phase, not derived from the policy's own predicates. wanted + preference on:
    /// the reason the phase is skipped, or `nil` for a start. An installed service with an
    /// outdated environment is still `.installed`: the reducer turns the start into a packages refresh.
    static let table: [(ServicePhase, SkipReason?)] = [
        (.checking, .notInstalled), (.unavailable("old"), .notInstalled), (.notInstalled, .notInstalled),
        (.needsModel, .modelNotCached), (.installing(.model), .notInstalled), (.installed, nil),
        (.starting, .alreadyActive), (.running, .alreadyActive), (.stopping, .alreadyActive),
        (.removing, .notInstalled), (.failed(ServiceLifecycleTests.failure), .notInstalled),
        (ServiceLifecycleTests.external, .external),
    ]

    @Test func theTableCoversEveryPhase() {
        #expect(Self.table.count == ServiceLifecycleTests.phases.count, "a new phase needs a row here")
    }

    @Test func aWantedServiceWithThePreferenceOnFollowsThePhaseTable() {
        for (phase, skip) in Self.table {
            let got = Self.decision(Self.state(phase), wanted: true, preferenceOn: true)
            #expect(got == (skip.map { .skip($0) } ?? .start), "\(phase)")
        }
    }

    @Test func aServiceThatIsNotWantedIsNeverStarted() {
        for (phase, _) in Self.table {
            for preferenceOn in [true, false] {
                let got = Self.decision(Self.state(phase), wanted: false, preferenceOn: preferenceOn)
                #expect(got == .skip(.notWanted), "\(phase) preferenceOn=\(preferenceOn)")
            }
        }
    }

    @Test func thePreferenceOffSkipsEveryWantedPhase() {
        for (phase, _) in Self.table {
            let got = Self.decision(Self.state(phase), wanted: true, preferenceOn: false)
            #expect(got == .skip(.preferenceOff), "\(phase)")
        }
    }

    @Test func anExternalServerIsNeverStartedEvenWhenWanted() {
        let s = Self.state(ServiceLifecycleTests.external)
        #expect(Self.decision(s, wanted: true, preferenceOn: true) == .skip(.external))
    }

    /// A failure of a server that ran (busy port, crash) is active-like: shown to the user, not retried.
    @Test func aRuntimeFailureIsNotRetried() {
        let crash = ServiceFailure(kind: .crashed(status: 1), title: "Server stopped unexpectedly", message: "x")
        #expect(Self.decision(Self.state(.failed(crash)), wanted: true, preferenceOn: true) == .skip(.alreadyActive))
    }

    @Test func anInstalledServiceWithoutItsWeightsIsSkippedAndWithThemStarted() {
        func cache(_ cached: Bool) -> ModelCacheStatus {
            ModelCacheStatus(cached: cached, sizeBytes: 0, repoFolders: [], derivedFolders: [], repoIDs: [])
        }
        var s = Self.state(.installed)
        s.cache = cache(false)
        #expect(Self.decision(s, wanted: true, preferenceOn: true) == .skip(.modelNotCached))
        s.cache = cache(true)
        #expect(Self.decision(s, wanted: true, preferenceOn: true) == .start)
        s.cache = nil
        #expect(Self.decision(s, wanted: true, preferenceOn: true) == .start, "not probed yet: start")
    }

    @Test func eachServiceIsDecidedOnItsOwn() {
        let states: [Service: LifecycleState] = [
            .tone: Self.state(.installed), .kokoro: Self.state(.installed), .whisper: Self.state(.running),
            .parakeet: Self.state(.notInstalled, requested: false), .dia: Self.state(.needsModel),
        ]
        let plan = RestorePolicy.plan(wanted: [.tone, .whisper, .parakeet, .dia], states: states, preferenceOn: true)
        #expect(plan[.tone] == .start)
        #expect(plan[.kokoro] == .skip(.notWanted))
        #expect(plan[.whisper] == .skip(.alreadyActive))
        #expect(plan[.parakeet] == .skip(.notInstalled))
        #expect(plan[.dia] == .skip(.modelNotCached))
    }

    // MARK: - WantedTransition: one row per Kind

    /// What the flag does for each event kind, written independently of `WantedTransition`.
    /// The switch is exhaustive: a new `LifecycleEvent.Kind` fails to compile until it is decided here.
    enum Effect { case keep, clear, setOnNewlyRunning }

    static func expected(_ kind: LifecycleEvent.Kind) -> Effect {
        switch kind {
        case .stopRequested, .removeRequested: .clear
        case .ready, .nativeBound: .setOnNewlyRunning
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .installRequested,
            .cancelInstallRequested, .installStage, .installEnded, .appleSpeechInstallEnded, .startRequested,
            .portOwnerFound, .launched, .launchFailed, .nativeLaunched, .nativeFailed, .supervisedError,
            .readyTimedOut, .exited, .shutdownRequested, .shutdownServers, .removalResumed, .removalFailed,
            .removalFinished, .dismissFailure, .externalFound, .externalLost, .startProbeResult, .tryItRequested:
            .keep
        }
    }

    static let failed = ServicePhase.failed(ServiceLifecycleTests.failure)

    @Test func everyKindHasARowAgainstEveryPhaseChange() {
        #expect(LifecycleEvent.Kind.allCases.count == 32)
        for kind in LifecycleEvent.Kind.allCases {
            for before in ServiceLifecycleTests.phases {
                for after in ServiceLifecycleTests.phases {
                    for wanted in [true, false] {
                        let label = "\(kind) \(before) -> \(after) wanted=\(wanted)"
                        let got = WantedTransition.next(wanted: wanted, kind: kind, before: before, after: after)
                        let entersFailed = !Self.isFailed(before) && Self.isFailed(after)
                        let entersRunning = before != .running && after == .running
                        let want: Bool
                        if entersFailed {
                            want = false  // (1) any route into .failed clears
                        } else {
                            switch Self.expected(kind) {
                            case .clear: want = false  // (2), (3)
                            case .setOnNewlyRunning: want = entersRunning ? true : wanted  // (4)
                            case .keep: want = wanted  // (5)
                            }
                        }
                        #expect(got == want, "\(label)")
                    }
                }
            }
        }
    }

    static func isFailed(_ phase: ServicePhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    @Test func aPhaseThatWasAlreadyFailedDoesNotClearByItself() {
        // Precedence (1) is the change into .failed; a failed-to-failed event falls to the kind rules.
        #expect(WantedTransition.next(wanted: true, kind: .dismissFailure, before: Self.failed, after: Self.failed))
        #expect(!WantedTransition.next(wanted: true, kind: .stopRequested, before: Self.failed, after: Self.failed))
    }

    @Test func readyOrNativeBoundSetsOnlyOnANewRunningPhase() {
        for kind in [LifecycleEvent.Kind.ready, .nativeBound] {
            #expect(WantedTransition.next(wanted: false, kind: kind, before: .starting, after: .running), "\(kind)")
            #expect(!WantedTransition.next(wanted: false, kind: kind, before: .running, after: .running), "\(kind) stale")
            #expect(!WantedTransition.next(wanted: false, kind: kind, before: .stopping, after: .stopping), "\(kind) stale")
        }
    }

    // MARK: - WantedTransition: sequences through the real reducer

    /// Reduces `event` and folds the flag, as the driver's one reduce wrapper does.
    @discardableResult
    static func step(_ s: inout LifecycleState, _ wanted: inout Bool, _ event: LifecycleEvent) -> [LifecycleEffect] {
        let before = s.phase
        let effects = ServiceLifecycle.reduce(&s, event)
        wanted = WantedTransition.next(wanted: wanted, kind: event.kind, before: before, after: s.phase)
        return effects
    }

    static let ready = LifecycleEvent.ready(
        ServiceLifecycleTests.current, port: 8665, pid: 9, rate: 24000, model: nil, at: ServiceLifecycleTests.date)

    /// A state that has just launched a server: starting, with the current ServerID.
    static func starting() -> LifecycleState { ServiceLifecycleTests.state(.starting) }

    @Test func startThenQuitKeepsTheFlag() {
        var s = Self.starting()
        var wanted = false
        Self.step(&s, &wanted, Self.ready)
        #expect(s.phase == .running && wanted)
        Self.step(&s, &wanted, .shutdownRequested)
        Self.step(&s, &wanted, .shutdownServers)
        #expect(wanted, "Quit does not forget what was running")
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 0, logTail: []))
        #expect(wanted, "the exit after a requested stop keeps the flag")
    }

    @Test func startThenAStopClickClears() {
        var s = Self.starting()
        var wanted = false
        Self.step(&s, &wanted, Self.ready)
        #expect(wanted)
        Self.step(&s, &wanted, .stopRequested)
        #expect(!wanted)
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 0, logTail: []))
        #expect(!wanted, "the exit after the click does not set it again")
    }

    @Test func aStopClickWhileStartingClears() {
        var s = Self.starting()
        var wanted = true  // restored from the persisted set
        Self.step(&s, &wanted, .stopRequested)
        #expect(!wanted)
    }

    @Test func aStaleReadyAfterStopLeavesTheFlagUnchanged() {
        var s = ServiceLifecycleTests.state(.running)
        var wanted = true
        Self.step(&s, &wanted, .stopRequested)
        #expect(!wanted)
        let phase = s.phase
        Self.step(&s, &wanted, Self.ready)
        #expect(s.phase == phase, "the reducer drops a ready outside .starting")
        #expect(!wanted, "a stale ready never sets")
        // And a stale ready on a still-running service keeps a set flag set.
        var running = ServiceLifecycleTests.state(.running)
        var kept = true
        Self.step(&running, &kept, Self.ready)
        #expect(kept)
    }

    @Test func restoreThenABusyPortClears() {
        var s = ServiceLifecycleTests.state(.starting, server: nil)
        s.probe = ServiceLifecycleTests.probeTag
        var wanted = true
        Self.step(&s, &wanted, .portOwnerFound(PortProbe.Owner(pid: 42, command: "stranger"), probe: ServiceLifecycleTests.probeTag))
        #expect(Self.isFailed(s.phase))
        #expect(!wanted, "a stranger on the port clears the restored flag")
    }

    @Test func aPackagesRefreshThatFailsClears() {
        var s = ServiceLifecycleTests.state(.installing(.packages), server: nil, installing: true)
        var wanted = true
        Self.step(
            &s, &wanted,
            .installEnded(
                .failed(stage: .packages, message: "no network", logTail: []), then: .refreshThenStart,
                install: ServiceLifecycleTests.installTag))
        #expect(Self.isFailed(s.phase))
        #expect(!wanted)
    }

    @Test func aCrashWhileRunningClears() {
        var s = ServiceLifecycleTests.state(.running)
        var wanted = true
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 1, logTail: []))
        #expect(Self.isFailed(s.phase))
        #expect(!wanted, "a crashed server is not restarted on every launch")
    }

    @Test func removingAServiceClears() {
        var s = ServiceLifecycleTests.state(.installed)
        var wanted = true
        Self.step(&s, &wanted, .removeRequested(deleteModel: true, managerAvailable: true))
        #expect(!wanted)
    }

    @Test func adoptingAnExternalServerKeepsTheFlagAndLosingItDoesNotSet() {
        var s = ServiceLifecycleTests.state(.installed, server: nil)
        var wanted = true
        s.externalEpoch = 9
        Self.step(&s, &wanted, .externalFound(epoch: 9, info: ServiceLifecycleTests.externalInfo))
        #expect(s.phase.isExternal && wanted, "an adopted server keeps a restored flag")
        var notWanted = false
        var other = ServiceLifecycleTests.state(.installed, server: nil)
        other.externalEpoch = 9
        Self.step(&other, &notWanted, .externalFound(epoch: 9, info: ServiceLifecycleTests.externalInfo))
        #expect(other.phase.isExternal && !notWanted, "an adopted server is not ours: not set")
    }
}
