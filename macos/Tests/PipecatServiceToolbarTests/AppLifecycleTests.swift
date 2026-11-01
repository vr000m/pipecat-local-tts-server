import Testing

@testable import PipecatToolbarCore

/// `AppLifecycle.reduce`: the app-wide bootstrap / Reset / quit machine
/// (`AppModel` is its adapter).
@Suite struct AppLifecycleTests {
    /// One test-side name per `AppPhase` case. `kind(of:)` and `sample(_:)` switch
    /// with no default, so a new phase fails to compile here until it is named,
    /// sampled and given its row in `expected`.
    enum PhaseKind: CaseIterable { case idle, bootstrapping, resetting, ready, failed, shuttingDown }

    static func kind(of phase: AppPhase) -> PhaseKind {
        switch phase {
        case .idle: .idle
        case .bootstrapping: .bootstrapping
        case .resetting: .resetting
        case .ready: .ready
        case .failed: .failed
        case .shuttingDown: .shuttingDown
        }
    }

    static func sample(_ kind: PhaseKind) -> AppPhase {
        switch kind {
        case .idle: .idle
        case .bootstrapping: .bootstrapping
        case .resetting: .resetting
        case .ready: .ready
        case .failed: .failed("x")
        case .shuttingDown: .shuttingDown
        }
    }

    /// Every event of a kind (Reset with and without live work), no default either.
    static func samples(_ kind: AppEvent.Kind) -> [AppEvent] {
        switch kind {
        case .bootstrap: [.bootstrap]
        case .retry: [.retry]
        case .reset: [.reset(servicesBusy: false), .reset(servicesBusy: true)]
        case .quit: [.quit]
        case .bootstrapDone: [.bootstrapDone]
        case .bootstrapFailed: [.bootstrapFailed("e")]
        case .resetDone: [.resetDone]
        }
    }

    static let phases: [AppPhase] = PhaseKind.allCases.map(sample)
    static let events: [AppEvent] = AppEvent.Kind.allCases.flatMap(samples)

    /// The accepted transitions, written per event kind and then per phase
    /// (not the reducer's order), every pair named: nil is refused (no phase
    /// change, no effect).
    static func expected(_ phase: AppPhase, _ event: AppEvent) -> (AppPhase, [AppEffect])? {
        let p = kind(of: phase)
        switch event {
        case .quit:
            switch p {
            case .idle, .bootstrapping, .resetting, .ready, .failed: return (.shuttingDown, [.shutdown])
            case .shuttingDown: return nil
            }
        case .bootstrap:
            switch p {
            case .idle: return (.bootstrapping, [.runBootstrap])
            case .bootstrapping, .resetting, .ready, .failed, .shuttingDown: return nil
            }
        case .retry:
            switch p {
            case .failed: return (.bootstrapping, [.runBootstrap])
            case .idle, .bootstrapping, .resetting, .ready, .shuttingDown: return nil
            }
        case .reset(let busy):
            switch p {
            case .ready, .failed: return busy ? nil : (.resetting, [.clearPersistedServiceState, .runReset])
            case .idle, .bootstrapping, .resetting, .shuttingDown: return nil
            }
        case .bootstrapDone:
            switch p {
            case .bootstrapping: return (.ready, [])
            case .idle, .resetting, .ready, .failed, .shuttingDown: return nil
            }
        case .bootstrapFailed(let message):
            switch p {
            case .bootstrapping: return (.failed(message), [])
            case .idle, .resetting, .ready, .failed, .shuttingDown: return nil
            }
        case .resetDone:
            switch p {
            case .resetting: return (.bootstrapping, [.runBootstrap])
            case .idle, .bootstrapping, .ready, .failed, .shuttingDown: return nil
            }
        }
    }

    /// {every phase} x {every event}: the table above, and the one rule: a job
    /// (bootstrap or Reset) starts only when none runs, and only through a
    /// phase that names it; quit runs the shutdown from every phase but
    /// `shuttingDown`, which nothing leaves.
    @Test func wholeSpace() {
        #expect(Set(Self.events.map(\.kind)).count == AppEvent.Kind.allCases.count)
        for phase in Self.phases {
            for event in Self.events {
                var p = phase
                let effects = AppLifecycle.reduce(&p, event)
                let label = "\(phase) + \(event)"
                if let (next, work) = Self.expected(phase, event) {
                    #expect(p == next && effects == work, "\(label): \(p) \(effects)")
                } else {
                    #expect(p == phase && effects.isEmpty, "refused: \(label): \(p) \(effects)")
                }
                if effects.contains(.runBootstrap) || effects.contains(.runReset) {
                    #expect(!phase.hasJob || event == .resetDone, "a second job started: \(label)")
                    #expect(p.hasJob, "a job started without a phase naming it: \(label)")
                }
                if phase == .shuttingDown { #expect(p == .shuttingDown && effects.isEmpty, "\(label)") }
            }
        }
    }

    /// The Reset button reads the reducer's own rule: it is enabled exactly
    /// when the reducer would accept the Reset.
    @Test func theResetButtonMatchesTheReducer() {
        for phase in Self.phases {
            for busy in [false, true] {
                var p = phase
                let accepted = AppLifecycle.reduce(&p, .reset(servicesBusy: busy)) == [.clearPersistedServiceState, .runReset]
                #expect(phase.allowsReset(servicesBusy: busy) == accepted, "\(phase) busy=\(busy)")
            }
        }
    }

    /// Get / Start / Delete: a Python service needs the manager and no job in
    /// flight (Reset took the manager away; its rows are stale until the
    /// re-read); Apple Speech needs neither; nothing starts after quit.
    @Test func serviceActionsWaitForTheManagerAndTheJob() {
        for phase in Self.phases {
            for manager in [false, true] {
                let quit = phase == .shuttingDown
                #expect(
                    phase.acceptsServiceActions(usesPython: true, managerInstalled: manager)
                        == (!quit && manager && !phase.hasJob), "python \(phase) manager=\(manager)")
                #expect(
                    phase.acceptsServiceActions(usesPython: false, managerInstalled: manager) == !quit,
                    "apple \(phase) manager=\(manager)")
            }
        }
    }

    /// The derived flags come from the phase alone.
    @Test func derivedFlags() {
        for phase in Self.phases {
            let failed = if case .failed = phase { true } else { false }
            #expect(phase.canRetryBootstrap == failed, "\(phase)")
            #expect(phase.canReset == (phase == .ready || failed), "\(phase)")
            #expect(phase.hasJob == (phase == .bootstrapping || phase == .resetting), "\(phase)")
            #expect(phase.isChecking == (phase == .idle || phase.hasJob), "\(phase)")
            #expect(phase.setupError == (failed ? "x" : nil), "\(phase)")
        }
    }

    /// Runs `events` from `phase`, returning the phase and every effect issued.
    static func run(_ phase: AppPhase, _ events: [AppEvent]) -> (AppPhase, [AppEffect]) {
        var p = phase
        var all: [AppEffect] = []
        for event in events { all += AppLifecycle.reduce(&p, event) }
        return (p, all)
    }

    @Test func tryAgainTwiceStartsOneBootstrap() {
        let (p, effects) = Self.run(.failed("no uv"), [.retry, .retry])
        #expect(p == .bootstrapping && effects == [.runBootstrap])
    }

    /// Reset forgets the wanted set before deleting: the first effect, never on a refused Reset.
    @Test func resetClearsTheWantedSetFirstAndRefusedResetDoesNot() {
        var p = AppPhase.ready
        #expect(AppLifecycle.reduce(&p, .reset(servicesBusy: false)) == [.clearPersistedServiceState, .runReset])
        var busy = AppPhase.ready
        #expect(AppLifecycle.reduce(&busy, .reset(servicesBusy: true)).isEmpty)
    }

    @Test func resetTwiceStartsOneReset() {
        let (p, effects) = Self.run(.ready, [.reset(servicesBusy: false), .reset(servicesBusy: false)])
        #expect(p == .resetting && effects == [.clearPersistedServiceState, .runReset])
        // Its bootstrap is the same job's tail: a Reset during it is refused too.
        let (after, tail) = Self.run(p, [.resetDone, .reset(servicesBusy: false), .retry])
        #expect(after == .bootstrapping && tail == [.runBootstrap])
    }

    /// Quit during Reset's shutdown-and-delete window runs the shutdown (which
    /// waits for the Reset job), and the Reset's end starts no bootstrap after it.
    @Test func quitDuringResetWaitsAndStartsNothing() {
        let (p, effects) = Self.run(.ready, [.reset(servicesBusy: false), .quit, .resetDone])
        #expect(p == .shuttingDown && effects == [.clearPersistedServiceState, .runReset, .shutdown])
    }

    @Test func quitDuringBootstrap() {
        let (p, effects) = Self.run(.idle, [.bootstrap, .quit, .bootstrapDone, .quit, .bootstrapFailed("killed")])
        #expect(p == .shuttingDown && effects == [.runBootstrap, .shutdown])
    }

    /// A Try Again or a second launch while a bootstrap runs is refused, so the
    /// first one's end is the only one (it can't clear a flag another still needs).
    @Test func bootstrapFinishWhileAnotherRequested() {
        let (p, effects) = Self.run(.idle, [.bootstrap, .retry, .bootstrap, .bootstrapFailed("e"), .bootstrapDone])
        #expect(p == .failed("e") && effects == [.runBootstrap])
        let (again, more) = Self.run(p, [.retry, .retry, .bootstrapDone])
        #expect(again == .ready && more == [.runBootstrap])
    }

    /// Quit with nothing running still runs the shutdown: a cache probe (or the
    /// manager's other subprocesses) can be live while no service blocks quit.
    @Test func quitFromReadyRunsTheShutdown() {
        let (p, effects) = Self.run(.ready, [.quit])
        #expect(p == .shuttingDown && effects == [.shutdown])
    }

    /// Reset is refused while a service holds live work.
    @Test func resetRefusedUnderLiveWork() {
        let (p, effects) = Self.run(.ready, [.reset(servicesBusy: true)])
        #expect(p == .ready && effects.isEmpty)
    }
}
