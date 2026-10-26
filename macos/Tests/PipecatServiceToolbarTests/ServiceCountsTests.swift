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
    static let running = state(.running)
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

    @Test func installedFollowsTheAppsOwnEnvironmentForAnExternalService() {
        #expect(ServiceCounts([Self.external]).installed == 1)
        let withoutEnvironment = Self.state(ServiceLifecycleTests.external, requested: false, environment: .missing)
        let counts = ServiceCounts([withoutEnvironment])
        #expect(counts.installed == 0)
        #expect(counts.running == 1 && counts.active == 1, "still running, just not installed here")
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
}
