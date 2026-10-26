import Foundation
import Testing

@testable import PipecatToolbarCore

/// `ExternalDiscoveryPolicy`: the pure rules `ExternalDiscovery` (the app target's timer shell)
/// applies to probe outcomes. Nothing here touches a catalog port: outcomes are injected through
/// `HelloProber`, or the real `ExternalProbe` is pointed at a fake server on an ephemeral port.
@Suite struct ExternalDiscoveryPolicyTests {
    typealias Policy = ExternalDiscoveryPolicy
    typealias Snapshot = ExternalDiscoveryPolicy.Snapshot

    static let toneHello = try! HelloFixtures.frame(HelloFixtures.json(for: .tone))
    static let kokoroHello = try! HelloFixtures.frame(HelloFixtures.json(for: .kokoro))
    static let info = ExternalInfo(hello: toneHello)
    static let external = ServicePhase.external(8665, info)
    static let failure = ServiceFailure(kind: .install, title: "x", message: "y")

    /// Phases where discovery probes and can send an event.
    static let probed: [ServicePhase] = [.notInstalled, .installed, .failed(failure), .checking, external]
    /// Owned (or not-yet-readable) phases, which discovery never probes.
    static let skipped: [ServicePhase] = [
        .unavailable("x"), .needsModel, .installing(.model), .starting, .running, .stopping, .removing,
    ]

    static func snap(_ service: Service, _ phase: ServicePhase, epoch: Int = 4) -> Snapshot {
        Snapshot(service: service, epoch: epoch, phase: phase)
    }

    static func events(_ snapshot: Snapshot, _ outcome: ExternalProbe.Outcome) -> [Policy.Directive] {
        Policy.events(for: [.init(snapshot: snapshot, outcome: outcome)])
    }

    /// A prober that answers from a table and records every port it was asked.
    final class TableProber: HelloProber, @unchecked Sendable {
        private let lock = NSLock()
        private var asked: [Int] = []
        let outcomes: [Int: ExternalProbe.Outcome]
        let fallback: ExternalProbe.Outcome
        init(_ outcomes: [Int: ExternalProbe.Outcome] = [:], fallback: ExternalProbe.Outcome = .unreachable) {
            self.outcomes = outcomes
            self.fallback = fallback
        }
        var calls: [Int] { lock.withLock { asked } }
        func probe(port: Int) async -> ExternalProbe.Outcome {
            lock.withLock { asked.append(port) }
            return outcomes[port] ?? fallback
        }
    }

    /// The real probe, with a catalog port redirected to a fake server's ephemeral port.
    struct RedirectedProber: HelloProber {
        let redirects: [Int: Int]
        let real: ExternalProbe
        func probe(port: Int) async -> ExternalProbe.Outcome { await real.probe(port: redirects[port] ?? port) }
    }

    // MARK: Which services are probed

    @Test func onlyAcceptingPhasesAreProbedAndAppleSpeechNever() {
        for service in Service.allCases {
            for phase in Self.probed + Self.skipped {
                let expected = service != .appleSpeech && Self.probed.contains(phase)
                #expect(Policy.probes(service, in: phase) == expected, "\(service) \(phase)")
            }
        }
    }

    @Test func anOwnedServiceGetsNoEventWhateverTheOutcome() {
        let outcomes: [ExternalProbe.Outcome] = [
            .adopt(Service.tone.info, Self.toneHello), .mismatch(Self.kokoroHello), .needsToken, .silent, .timeout,
            .unreachable,
        ]
        for phase in Self.skipped {
            for outcome in outcomes {
                #expect(Self.events(Self.snap(.tone, phase), outcome).isEmpty, "\(phase) \(outcome)")
            }
        }
    }

    // MARK: Outcome to event

    @Test func anAdoptIsAFoundCarryingTheSnapshotsEpochAndTheHello() {
        for phase in Self.probed {
            let directives = Self.events(Self.snap(.tone, phase, epoch: 7), .adopt(Service.tone.info, Self.toneHello))
            #expect(directives == [.found(.tone, epoch: 7, info: Self.info)], "\(phase)")
            #expect(directives.first?.event == .externalFound(epoch: 7, info: Self.info))
        }
    }

    @Test func aNonExternalServiceIgnoresEveryFailedProbe() {
        for phase in Self.probed where !phase.isExternal {
            for outcome: ExternalProbe.Outcome in [.unreachable, .timeout, .silent, .needsToken, .mismatch(Self.kokoroHello)] {
                #expect(Self.events(Self.snap(.tone, phase), outcome).isEmpty, "\(phase) \(outcome)")
            }
        }
    }

    @Test func anExternalServiceMapsTheSixOutcomesToThreeReasons() {
        let external = Self.snap(.tone, Self.external, epoch: 6)
        let expected: [(ExternalProbe.Outcome, ExternalLostReason)] = [
            (.unreachable, .refused), (.timeout, .timeout), (.mismatch(Self.kokoroHello), .mismatch),
            (.needsToken, .mismatch), (.silent, .mismatch),
        ]
        for (outcome, reason) in expected {
            let directives = Self.events(external, outcome)
            #expect(directives == [.lost(.tone, epoch: 6, reason: reason)], "\(outcome)")
            #expect(directives.first?.event == .externalLost(epoch: 6, reason: reason))
        }
    }

    /// A second server for the same entry on another port is not adopted (only the entry that owns
    /// the port is), and it never keeps another port's External service alive.
    @Test func aSecondServerForTheSameEntryOnAnotherPortIsIgnored() {
        // The outcome on the Q8 port names the default Phonon entry: not this service.
        let hello = try! HelloFixtures.frame(HelloFixtures.json(for: .phonon))
        let other = ExternalProbe.Outcome.adopt(Service.phonon.info, hello)
        #expect(Self.events(Self.snap(.phononQ8, .installed), other).isEmpty)
        #expect(Self.events(Self.snap(.phononQ8, Self.external), other)
            == [.lost(.phononQ8, epoch: 4, reason: .mismatch)])
    }

    // MARK: A pass

    @Test func aPassProbesEachEligibleCatalogPortOnceAndNeverApplesOrOwnedOnes() async {
        var snapshots = Service.allCases.map { Self.snap($0, .running) }
        snapshots.append(Self.snap(.appleSpeech, .installed))
        // Re-point three to eligible phases (the last replaces the owned entry of the same service).
        func set(_ service: Service, _ phase: ServicePhase) {
            snapshots.removeAll { $0.service == service }
            snapshots.append(Self.snap(service, phase))
        }
        set(.tone, .installed)
        set(.kokoro, Self.external)
        set(.appleSpeech, Self.external)
        let prober = TableProber([Service.tone.info.port: .adopt(Service.tone.info, Self.toneHello)])
        let directives = await Policy.pass(snapshots: snapshots, prober: prober)
        #expect(prober.calls.sorted() == [Service.tone.info.port, Service.kokoro.info.port].sorted())
        #expect(!prober.calls.contains(Service.appleSpeech.info.port) && Service.appleSpeech.info.port == 9465)
        // Catalog order: tone, then kokoro (refused while External).
        #expect(directives == [
            .found(.tone, epoch: 4, info: Self.info), .lost(.kokoro, epoch: 4, reason: .refused),
        ])
    }

    @Test func aPassCarriesTheEpochItWasStartedWith() async {
        let prober = TableProber([8665: .adopt(Service.tone.info, Self.toneHello)])
        let directives = await Policy.pass(snapshots: [Self.snap(.tone, .installed, epoch: 41)], prober: prober)
        #expect(directives == [.found(.tone, epoch: 41, info: Self.info)])
    }

    @Test func aPassWithNothingEligibleProbesNothing() async {
        let prober = TableProber()
        let snapshots = Self.skipped.map { Self.snap(.tone, $0) } + [Self.snap(.appleSpeech, .notInstalled)]
        #expect(await Policy.pass(snapshots: snapshots, prober: prober).isEmpty)
        #expect(prober.calls.isEmpty)
    }

    /// A cancelled pass (quit, panel closed) returns nothing it could not trust.
    @Test func aCancelledPassReturnsNoEvents() async {
        final class Hang: HelloProber, @unchecked Sendable {
            func probe(port: Int) async -> ExternalProbe.Outcome {
                try? await Task.sleep(for: .seconds(30))
                return .silent
            }
        }
        let task = Task { await Policy.pass(snapshots: [Self.snap(.tone, Self.external)], prober: Hang()) }
        try? await Task.sleep(for: .milliseconds(50))
        task.cancel()
        #expect(await task.value.isEmpty, "a cancelled probe's outcome became an event")
    }

    // MARK: Against the real probe

    @Test func aSilentListenerOnAnExternalServicesPortMovesItToChecking() async throws {
        let server = try await FakeHelloServer.start(.closeWithoutHello)
        defer { server.stop() }
        let prober = RedirectedProber(redirects: [8665: server.port], real: ExternalProbe())
        let directives = await Policy.pass(snapshots: [Self.snap(.tone, Self.external)], prober: prober)
        #expect(directives == [.lost(.tone, epoch: 4, reason: .mismatch)])
    }

    @Test func aHelloMismatchOnAnExternalServicesPortMovesItToChecking() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .kokoro)))
        defer { server.stop() }
        let prober = RedirectedProber(redirects: [8665: server.port], real: ExternalProbe())
        let directives = await Policy.pass(snapshots: [Self.snap(.tone, Self.external)], prober: prober)
        #expect(directives == [.lost(.tone, epoch: 4, reason: .mismatch)])
    }

    @Test(arguments: [401, 403])
    func aNeedsTokenListenerOnAnExternalServicesPortMovesItToChecking(status: Int) async throws {
        let server = try await FakeHelloServer.start(.reject(status: status))
        defer { server.stop() }
        let prober = RedirectedProber(redirects: [8665: server.port], real: ExternalProbe())
        let directives = await Policy.pass(snapshots: [Self.snap(.tone, Self.external)], prober: prober)
        #expect(directives == [.lost(.tone, epoch: 4, reason: .mismatch)])
    }

    @Test func aSilentListenerOnAFreePortIsNotAdopted() async throws {
        let server = try await FakeHelloServer.start(.upgradeAndStaySilent)
        defer { server.stop() }
        let prober = RedirectedProber(redirects: [8665: server.port], real: ExternalProbe(helloTimeout: 0.2))
        #expect(await Policy.pass(snapshots: [Self.snap(.tone, .installed)], prober: prober).isEmpty)
    }

    /// A busy server's slow hello counts one failed probe and the service stays External.
    @Test func aSlowHelloIsOneFailedProbeAndTheServiceStaysExternal() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone), delay: 1.0))
        defer { server.stop() }
        let prober = RedirectedProber(redirects: [8665: server.port], real: ExternalProbe(helloTimeout: 0.2))
        let directives = await Policy.pass(snapshots: [Self.snap(.tone, Self.external)], prober: prober)
        #expect(directives == [.lost(.tone, epoch: 4, reason: .timeout)])

        var state = ServiceLifecycleTests.state(Self.external, server: nil)
        state.externalEpoch = 4
        for directive in directives { _ = ServiceLifecycle.reduce(&state, directive.event) }
        #expect(state.phase == Self.external && state.externalFailures == 1)
    }

    /// The one adopt test discovery and the Start path share: an `adopt` counts only on the
    /// matched entry's own port; every other outcome adopts nothing.
    @Test func adoptedInfoIsTheMatchedEntrysOwnPortOnly() {
        let adopt = ExternalProbe.Outcome.adopt(Service.tone.info, Self.toneHello)
        #expect(adopt.adoptedInfo(onPort: Service.tone.info.port) == Self.info)
        #expect(adopt.adoptedInfo(onPort: Service.kokoro.info.port) == nil)
        for other: ExternalProbe.Outcome in [.mismatch(Self.toneHello), .needsToken, .silent, .timeout, .unreachable] {
            #expect(other.adoptedInfo(onPort: Service.tone.info.port) == nil, "\(other)")
        }
    }
}
