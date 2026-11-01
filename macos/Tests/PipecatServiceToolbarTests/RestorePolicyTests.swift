import Foundation
import Testing

@testable import PipecatToolbarCore

/// `RestorePolicy.plan` (which wanted services start on launch) and the launch restore gate:
/// pure, written out per case. `WantedTransition` has its own suite (`WantedTransitionTests`).
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

    /// `RestorePolicy`'s `.installed` arm is `isReadyToStart`: one definition for restore and suggestion.
    @Test func restoreStartsExactlyWhenTheStateIsReadyToStart() {
        let refused = ModelCacheStatus(cached: false, sizeBytes: 0, repoFolders: [], derivedFolders: [], repoIDs: [])
        for phase in ServiceLifecycleTests.phases {
            for cache in [nil, refused] {
                var s = Self.state(phase)
                s.cache = cache
                let got = Self.decision(s, wanted: true, preferenceOn: true)
                if s.isReadyToStart { #expect(got == .start, "\(phase)") } else { #expect(got != .start, "\(phase)") }
            }
        }
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

    // MARK: - The launch restore gate

    /// Every `AppPhase` x already ran: only the first call in `ready` runs the restore.
    @Test func theRestoreRunsOnceAndOnlyFromReady() {
        for kind in AppLifecycleTests.PhaseKind.allCases {
            for alreadyRan in [false, true] {
                let phase = AppLifecycleTests.sample(kind)
                let want: Bool
                switch kind {
                case .ready: want = !alreadyRan
                case .idle, .bootstrapping, .resetting, .failed, .shuttingDown: want = false
                }
                #expect(RestorePolicy.shouldRun(alreadyRan: alreadyRan, phase: phase) == want, "\(kind) ran=\(alreadyRan)")
            }
        }
    }
}
