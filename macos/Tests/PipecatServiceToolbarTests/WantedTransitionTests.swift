import Foundation
import Testing

@testable import PipecatToolbarCore

/// `WantedTransition.next` (how the wanted flag moves with each lifecycle event): pure, written
/// out per case, then folded through the real reducer in sequences.
@Suite struct WantedTransitionTests {
    // MARK: - WantedTransition: one row per Kind

    /// What the flag does for each event kind before quit and after, written independently of
    /// `WantedTransition.rule` (only its `Effect` vocabulary is shared). The switch is exhaustive: a
    /// new `LifecycleEvent.Kind` fails to compile until both of its effects are decided here.
    static func expected(_ kind: LifecycleEvent.Kind) -> (normal: WantedTransition.Effect, quitting: WantedTransition.Effect) {
        switch kind {
        case .stopRequested, .removeRequested: (.clear, .clear)
        case .ready, .nativeBound: (.setWhenNewlyRunning, .keep)
        case .refreshRequested, .environmentRead, .refreshed, .environmentChanged, .installRequested,
            .cancelInstallRequested, .installStage, .installEnded, .appleSpeechInstallEnded, .startRequested,
            .portOwnerFound, .launched, .launchFailed, .nativeLaunched, .nativeFailed, .supervisedError,
            .readyTimedOut, .exited, .shutdownRequested, .shutdownServers, .removalResumed, .removalFailed,
            .removalFinished, .dismissFailure, .externalFound, .externalLost, .startProbeResult, .tryItRequested:
            (.keep, .keep)
        }
    }

    static let failed = ServicePhase.failed(ServiceLifecycleTests.failure)

    @Test func everyKindHasARowAgainstEveryPhaseChange() {
        #expect(LifecycleEvent.Kind.allCases.count == 32)
        for kind in LifecycleEvent.Kind.allCases {
            for before in ServiceLifecycleTests.phases {
                for after in ServiceLifecycleTests.phases {
                    for wanted in [true, false] {
                        for quitting in [false, true] {
                            let label = "\(kind) \(before) -> \(after) wanted=\(wanted) quitting=\(quitting)"
                            let got = WantedTransition.next(
                                wanted: wanted, kind: kind, before: before, after: after, quitting: quitting)
                            let entersFailed = !Self.isFailed(before) && Self.isFailed(after)
                            let entersRunning = before != .running && after == .running
                            let want: Bool
                            if !quitting, entersFailed {
                                want = false  // before quit, any route into .failed clears
                            } else {
                                // After quit began the failure rule is off and only Stop or Delete clears.
                                switch quitting ? Self.expected(kind).quitting : Self.expected(kind).normal {
                                case .clear: want = false
                                case .setWhenNewlyRunning: want = entersRunning ? true : wanted
                                case .keep: want = wanted
                                }
                            }
                            #expect(got == want, "\(label)")
                        }
                    }
                }
            }
        }
    }

    /// Each kind's two effects, as `WantedTransition.rule` states them.
    @Test func everyKindChoosesItsEffectBeforeAndAfterQuit() {
        for kind in LifecycleEvent.Kind.allCases {
            let want = Self.expected(kind)
            #expect(WantedTransition.rule(kind) == .init(normal: want.normal, quitting: want.quitting), "\(kind)")
        }
    }

    static func isFailed(_ phase: ServicePhase) -> Bool {
        if case .failed = phase { return true }
        return false
    }

    @Test func aPhaseThatWasAlreadyFailedDoesNotClearByItself() {
        // Precedence (1) is the change into .failed; a failed-to-failed event falls to the kind rules.
        #expect(WantedTransition.next(wanted: true, kind: .dismissFailure, before: Self.failed, after: Self.failed, quitting: false))
        #expect(!WantedTransition.next(wanted: true, kind: .stopRequested, before: Self.failed, after: Self.failed, quitting: false))
    }

    @Test func readyOrNativeBoundSetsOnlyOnANewRunningPhase() {
        for kind in [LifecycleEvent.Kind.ready, .nativeBound] {
            #expect(WantedTransition.next(wanted: false, kind: kind, before: .starting, after: .running, quitting: false), "\(kind)")
            #expect(!WantedTransition.next(wanted: false, kind: kind, before: .running, after: .running, quitting: false), "\(kind) stale")
            #expect(!WantedTransition.next(wanted: false, kind: kind, before: .stopping, after: .stopping, quitting: false), "\(kind) stale")
            #expect(!WantedTransition.next(wanted: false, kind: kind, before: .starting, after: .running, quitting: true), "\(kind) during quit")
        }
    }

    // MARK: - WantedTransition: sequences through the real reducer

    /// Reduces `event` and folds the flag, as the driver's one reduce wrapper does.
    @discardableResult
    static func step(
        _ s: inout LifecycleState, _ wanted: inout Bool, _ event: LifecycleEvent, quitting: Bool
    ) -> [LifecycleEffect] {
        let before = s.phase
        let effects = ServiceLifecycle.reduce(&s, event)
        wanted = WantedTransition.next(wanted: wanted, kind: event.kind, before: before, after: s.phase, quitting: quitting)
        return effects
    }

    static let ready = LifecycleEvent.ready(
        ServiceLifecycleTests.current, port: 8665, pid: 9, rate: 24000, model: nil, at: ServiceLifecycleTests.date)

    /// A state that has just launched a server: starting, with the current ServerID.
    static func starting() -> LifecycleState { ServiceLifecycleTests.state(.starting) }

    @Test func startThenQuitKeepsTheFlag() {
        var s = Self.starting()
        var wanted = false
        Self.step(&s, &wanted, Self.ready, quitting: false)
        #expect(s.phase == .running && wanted)
        // `ServiceDriver.quit()` sets `quitting` before it dispatches the shutdown events.
        Self.step(&s, &wanted, .shutdownRequested, quitting: true)
        Self.step(&s, &wanted, .shutdownServers, quitting: true)
        #expect(wanted, "Quit does not forget what was running")
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 0, logTail: []), quitting: true)
        #expect(wanted, "the exit after a requested stop keeps the flag")
    }

    @Test func startThenAStopClickClears() {
        var s = Self.starting()
        var wanted = false
        Self.step(&s, &wanted, Self.ready, quitting: false)
        #expect(wanted)
        Self.step(&s, &wanted, .stopRequested, quitting: false)
        #expect(!wanted)
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 0, logTail: []), quitting: false)
        #expect(!wanted, "the exit after the click does not set it again")
    }

    @Test func aStopClickWhileStartingClears() {
        var s = Self.starting()
        var wanted = true  // restored from the persisted set
        Self.step(&s, &wanted, .stopRequested, quitting: false)
        #expect(!wanted)
    }

    @Test func aStaleReadyAfterStopLeavesTheFlagUnchanged() {
        var s = ServiceLifecycleTests.state(.running)
        var wanted = true
        Self.step(&s, &wanted, .stopRequested, quitting: false)
        #expect(!wanted)
        let phase = s.phase
        Self.step(&s, &wanted, Self.ready, quitting: false)
        #expect(s.phase == phase, "the reducer drops a ready outside .starting")
        #expect(!wanted, "a stale ready never sets")
        // And a stale ready on a still-running service keeps a set flag set.
        var running = ServiceLifecycleTests.state(.running)
        var kept = true
        Self.step(&running, &kept, Self.ready, quitting: false)
        #expect(kept)
    }

    @Test func restoreThenABusyPortClears() {
        var s = ServiceLifecycleTests.state(.starting, server: nil)
        s.probe = ServiceLifecycleTests.probeTag
        var wanted = true
        Self.step(&s, &wanted, .portOwnerFound(PortProbe.Owner(pid: 42, command: "stranger"), probe: ServiceLifecycleTests.probeTag), quitting: false)
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
                install: ServiceLifecycleTests.installTag), quitting: false)
        #expect(Self.isFailed(s.phase))
        #expect(!wanted)
    }

    @Test func aCrashWhileRunningClears() {
        var s = ServiceLifecycleTests.state(.running)
        var wanted = true
        Self.step(&s, &wanted, .exited(ServiceLifecycleTests.current, status: 1, logTail: []), quitting: false)
        #expect(Self.isFailed(s.phase))
        #expect(!wanted, "a crashed server is not restarted on every launch")
    }

    @Test func removingAServiceClears() {
        var s = ServiceLifecycleTests.state(.installed)
        var wanted = true
        Self.step(&s, &wanted, .removeRequested(deleteModel: true, managerAvailable: true), quitting: false)
        #expect(!wanted)
    }

    @Test func adoptingAnExternalServerKeepsTheFlagAndLosingItDoesNotSet() {
        var s = ServiceLifecycleTests.state(.installed, server: nil)
        var wanted = true
        s.externalEpoch = 9
        Self.step(&s, &wanted, .externalFound(epoch: 9, info: ServiceLifecycleTests.externalInfo), quitting: false)
        #expect(s.phase.isExternal && wanted, "an adopted server keeps a restored flag")
        var notWanted = false
        var other = ServiceLifecycleTests.state(.installed, server: nil)
        other.externalEpoch = 9
        Self.step(&other, &notWanted, .externalFound(epoch: 9, info: ServiceLifecycleTests.externalInfo), quitting: false)
        #expect(other.phase.isExternal && !notWanted, "an adopted server is not ours: not set")
    }
}
