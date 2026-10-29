import Testing

@testable import PipecatToolbarCore

/// `ServiceCounts`: the menu's counting as a pure function of the services' lifecycle states.
/// An External server counts as running; only servers the app started count toward the Quit title.
@Suite struct ServiceCountsTests {
    static func state(_ phase: ServicePhase, requested: Bool = true, environment: EnvironmentStatus? = nil) -> LifecycleState {
        var s = ServiceLifecycleTests.state(phase, server: nil)
        s.requested = requested
        if let environment { s.environment = environment }
        return s
    }

    static let external = state(ServiceLifecycleTests.external)
    /// A server of ours: the reducer sets `server` on launch, and Quit stops what holds one.
    static let running = ServiceLifecycleTests.state(.running)
    static let starting = ServiceLifecycleTests.state(.starting)
    static let installed = state(.installed)
    static let notInstalled = state(.notInstalled, requested: false, environment: .missing)

    @Test func noServicesCountForNothing() {
        let counts = ServiceCounts([])
        #expect(counts.running == 0 && counts.owned == 0 && counts.active == 0 && counts.startable == 0)
        #expect(counts.installed == 0 && counts.installing == 0 && !counts.blocksReset)
        #expect(counts.badge == .none && counts.quitTitle == "Quit")
        #expect(counts.summary(bootstrapping: false) == "Add a model to get started")
    }

    @Test func anExternalServiceCountsAsRunningAndActiveButNotAsOwned() {
        let counts = ServiceCounts([Self.external])
        #expect(counts.running == 1 && counts.active == 1)
        #expect(counts.owned == 0)
        #expect(counts.startable == 0, "an External server is not offered a Start")
        #expect(!counts.blocksReset, "an External server does not block Reset")
        #expect(counts.badge == .running)
        #expect(counts.summary(bootstrapping: false) == "1 service running")
        #expect(ServiceCounts.isRunning(Self.external))
    }

    @Test func isRunningIsTrueForRunningAndExternalOnly() {
        for phase in ServiceLifecycleTests.phases {
            let expected = phase == .running || phase.isExternal
            #expect(ServiceCounts.isRunning(Self.state(phase)) == expected, "\(phase)")
        }
    }

    @Test func quitTitleCountsOwnedServersOnly() {
        #expect(ServiceCounts([Self.external]).quitTitle == "Quit")
        #expect(ServiceCounts([Self.external, Self.installed, Self.notInstalled]).quitTitle == "Quit")
        #expect(ServiceCounts([Self.running]).quitTitle == "Stop All & Quit")
        #expect(ServiceCounts([Self.external, Self.running]).quitTitle == "Stop All & Quit")
        let counts = ServiceCounts([Self.external, Self.running])
        #expect(counts.running == 2 && counts.owned == 1)
        #expect(counts.summary(bootstrapping: false) == "2 services running")
    }

    /// Quit stops a server that is still loading or winding down, so the title says so.
    @Test func aStartingOrStoppingServerOfOursIsOwned() {
        #expect(ServiceCounts([Self.starting]).owned == 1)
        #expect(ServiceCounts([Self.starting]).quitTitle == "Stop All & Quit")
        let stopping = ServiceLifecycleTests.state(.stopping)
        #expect(ServiceCounts([stopping]).quitTitle == "Stop All & Quit")
        // A starting service that only holds a probe (a busy port, no server of ours) is not.
        var probing = ServiceLifecycleTests.state(.starting, server: nil)
        probing.probe = 3
        #expect(ServiceCounts([probing]).owned == 0 && ServiceCounts([probing]).quitTitle == "Quit")
    }

    @Test func installedFollowsTheAppsOwnEnvironmentForAnExternalService() {
        #expect(ServiceCounts([Self.external]).installed == 1)
        let withoutEnvironment = Self.state(ServiceLifecycleTests.external, requested: false, environment: .missing)
        let counts = ServiceCounts([withoutEnvironment])
        #expect(counts.installed == 0)
        #expect(counts.running == 1 && counts.active == 1, "still running, just not installed here")
    }

    /// An External variant whose sibling built the shared environment was never installed by the
    /// user (`requested` false): it is not installed here, so Delete is not offered and a sibling's
    /// removal does not list it among those that stay.
    @Test func anUnrequestedExternalVariantIsNotInstalledEvenWithTheSharedEnvironment() {
        let sharedOnly = Self.state(ServiceLifecycleTests.external, requested: false)
        #expect(sharedOnly.environment != .missing)
        #expect(!sharedOnly.isInstalled)
        #expect(ServiceCounts([sharedOnly]).installed == 0)
        #expect(Self.external.isInstalled, "requested and the environment exists")
        var noEnvironment = Self.external
        noEnvironment.environment = .missing
        #expect(!noEnvironment.isInstalled, "requested, but the environment is gone")
    }

    /// The count reads `ServiceCounts.isStartable`, the predicate `AppModel.startable` (the rows)
    /// also calls; the app target has no test target, so the shared predicate is pinned here.
    @Test func startableCountsExactlyTheStatesIsStartableAccepts() {
        // Written out per phase, not derived from the predicate's own formula, so a change to
        // `isStartable`, `isActive` or `isInstalled` has to change this table as well.
        // (phase, startable when requested, startable when not requested)
        let table: [(ServicePhase, Bool, Bool)] = [
            (.checking, false, false), (.unavailable("old"), false, false), (.notInstalled, false, false),
            (.needsModel, true, true), (.installing(.model), true, true), (.installed, true, true),
            (.starting, false, false), (.running, false, false), (.stopping, false, false),
            (.removing, true, false), (.failed(ServiceLifecycleTests.failure), true, false),
            (ServiceLifecycleTests.external, false, false),
        ]
        #expect(table.count == ServiceLifecycleTests.phases.count, "a new phase needs a row here")
        for (phase, whenRequested, whenNotRequested) in table {
            for requested in [true, false] {
                let s = Self.state(phase, requested: requested)
                let expected = requested ? whenRequested : whenNotRequested
                #expect(ServiceCounts.isStartable(s) == expected, "\(phase) requested=\(requested)")
                #expect(ServiceCounts([s]).startable == (expected ? 1 : 0), "\(phase) requested=\(requested)")
            }
        }
    }

    @Test func startableIsInstalledAndNotActive() {
        #expect(ServiceCounts([Self.installed, Self.notInstalled, Self.external, Self.running]).startable == 1)
        let downloading = Self.state(.installing(.model))
        let counts = ServiceCounts([downloading])
        #expect(counts.installing == 1 && counts.startable == 1)
        #expect(counts.badge == .installing)
    }

    @Test func blocksResetWhenAnyOwnedWorkRunsButNotForExternalOnes() {
        #expect(!ServiceCounts([Self.external, Self.installed]).blocksReset)
        #expect(ServiceCounts([Self.external, Self.running]).blocksReset)
        #expect(ServiceCounts([Self.state(.removing)]).blocksReset)
        #expect(ServiceCounts([Self.state(.installing(.model))]).blocksReset)
        var withServer = Self.state(.installed)
        withServer.server = ServiceLifecycleTests.current
        #expect(ServiceCounts([withServer]).blocksReset)
    }

    @Test func theInstallingBadgeWinsOverRunning() {
        let counts = ServiceCounts([Self.external, Self.state(.installing(.model))])
        #expect(counts.badge == .installing)
    }

    @Test func theSummaryReadsFromRunningThenInstalled() {
        #expect(ServiceCounts([Self.installed, Self.installed]).summary(bootstrapping: false) == "Nothing running · 2 installed")
        #expect(ServiceCounts([Self.running, Self.installed]).summary(bootstrapping: false) == "1 service running")
        #expect(ServiceCounts([Self.running, Self.external, Self.installed]).summary(bootstrapping: false) == "2 services running")
        #expect(ServiceCounts([Self.running]).summary(bootstrapping: true) == "Checking services…")
        #expect(ServiceCounts([]).summary(bootstrapping: true) == "Checking services…")
    }

    /// The quit guard's ownership rule, per case: owned iff a subprocess (`server`) or an
    /// in-process (`native`) server is set; an External server and an idle service are not.
    @Test func ownershipAndOwnedPortsTable() {
        func state(_ info: ServiceInfo, server: Bool = false, native: Bool = false, external: Bool = false)
            -> LifecycleState
        {
            var s = ServiceLifecycleTests.state(external ? ServiceLifecycleTests.external : .running, info: info, server: nil)
            if server { s.server = ServiceLifecycleTests.current }
            if native { s.native = ServiceLifecycleTests.current }
            return s
        }
        let tone = Service.tone.info
        let apple = Service.appleSpeech
        let cases: [(String, LifecycleState, Bool)] = [
            ("subprocess server", state(tone, server: true), true),
            ("native server", state(apple.info, native: true), true),
            ("both set", state(tone, server: true, native: true), true),
            ("neither (idle)", state(tone), false),
            ("External", state(tone, external: true), false),
        ]
        for (name, s, owned) in cases {
            #expect(ServiceCounts.isOwned(s) == owned, "\(name)")
            #expect(ServiceCounts([s]).owned == (owned ? 1 : 0), "\(name): isOwned and owned agree")
        }
        let states: [Service: LifecycleState] = [
            .tone: state(tone, server: true), apple: state(apple.info, native: true),
            .whisper: state(Service.whisper.info, external: true), .kokoro: state(Service.kokoro.info),
        ]
        let ports = ServiceCounts.ownedPorts(states)
        #expect(Set(ports.keys) == [.tone, apple])
        #expect(ports[.tone] == Service.tone.info.port && ports[apple] == apple.info.port)
        #expect(ServiceCounts.ownedPorts([:]).isEmpty)
    }
}
