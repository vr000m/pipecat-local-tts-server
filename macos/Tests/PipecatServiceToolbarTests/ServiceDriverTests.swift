import Foundation
import Testing

@testable import PipecatToolbarCore

/// `ServiceDriver` running the lifecycle's effects through fakes: a server
/// process the test drives, an environment, and Apple Speech's install.
@MainActor @Suite struct ServiceDriverTests {
    /// A server process whose output and exit the test controls.
    final class FakeProcess: ServerProcess, @unchecked Sendable {
        let pid: Int32 = 4242
        let stdout: AsyncStream<String>
        let stderr: AsyncStream<String>
        private let out: AsyncStream<String>.Continuation
        private let err: AsyncStream<String>.Continuation
        private let lock = NSLock()
        private var exitWaiters: [CheckedContinuation<Int32, Never>] = []
        private var status: Int32?
        private(set) var stops = 0
        /// False: `stop()` only records the request; the test calls `exit`.
        var exitsOnStop = true
        /// A descendant holds the pipes: they stay open after `exit`, and the
        /// exit is reported without waiting for them (the drain limit).
        var keepsPipesOpen = false

        init() {
            (stdout, out) = AsyncStream.makeStream()
            (stderr, err) = AsyncStream.makeStream()
        }

        func run() throws {}
        func emit(_ line: String) { out.yield(line) }
        func emitError(_ line: String) { err.yield(line) }

        func exit(_ code: Int32) {
            if !keepsPipesOpen {
                out.finish()
                err.finish()
            }
            let waiters: [CheckedContinuation<Int32, Never>] = lock.withLock {
                status = code
                defer { exitWaiters = [] }
                return exitWaiters
            }
            for waiter in waiters { waiter.resume(returning: code) }
        }

        func stop(grace: Duration) async -> Int32 {
            lock.withLock { stops += 1 }
            if exitsOnStop { exit(15) }
            return 15
        }

        func waitForExit(after reader: Task<Void, Never>, drainLimit: Duration) async -> Int32 {
            let code = await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                let done: Int32? = lock.withLock {
                    if let status { return status }
                    exitWaiters.append(c)
                    return nil
                }
                if let done { c.resume(returning: done) }
            }
            if !keepsPipesOpen { await reader.value }
            return code
        }
    }

    struct FakeEnvironment: ServiceEnvironment {
        func environmentStatus(_ backend: Service) -> EnvironmentStatus {
            .ready(EnvironmentMarker(service: backend.rawValue, fingerprint: "w", python: "3.12", createdAt: Date()))
        }
        func isRequested(_ service: Service) -> Bool { true }
        func modelCacheStatus(_ backend: Service, includeOutdated: Bool) async -> ModelCacheStatus? { nil }
        func install(_ backend: Service, mode: InstallMode) -> AsyncThrowingStream<InstallEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus?) async throws {}
        func serveArguments(for info: ServiceInfo, port: Int) -> [String]? { ["serve"] }
    }

    /// An environment whose cache probe waits until the test opens the gate.
    final class SlowEnvironment: ServiceEnvironment, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        func environmentStatus(_ backend: Service) -> EnvironmentStatus { FakeEnvironment().environmentStatus(backend) }
        func isRequested(_ service: Service) -> Bool { true }
        func modelCacheStatus(_ backend: Service, includeOutdated: Bool) async -> ModelCacheStatus? {
            await withCheckedContinuation { c in
                let now: Bool = lock.withLock {
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if now { c.resume() }
            }
            return ModelCacheStatus(cached: true, sizeBytes: 1, repoFolders: [])
        }
        func release() {
            let all: [CheckedContinuation<Void, Never>] = lock.withLock {
                open = true
                defer { waiters = [] }
                return waiters
            }
            for c in all { c.resume() }
        }
        func install(_ backend: Service, mode: InstallMode) -> AsyncThrowingStream<InstallEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus?) async throws {}
        func serveArguments(for info: ServiceInfo, port: Int) -> [String]? { ["serve"] }
    }

    /// An environment the test scripts: an outdated env that its install
    /// brings up to date, a cache probe that waits for `release()`, a removal.
    final class ScriptedEnvironment: ServiceEnvironment, @unchecked Sendable {
        private let lock = NSLock()
        private var waiters: [CheckedContinuation<Void, Never>] = []
        private var open = false
        private var status: EnvironmentStatus
        private var requested = true
        static let marker = EnvironmentMarker(service: "tone", fingerprint: "w", python: "3.12", createdAt: Date())

        init(_ status: EnvironmentStatus) { self.status = status }
        func environmentStatus(_ backend: Service) -> EnvironmentStatus { lock.withLock { status } }
        func isRequested(_ service: Service) -> Bool { lock.withLock { requested } }
        func modelCacheStatus(_ backend: Service, includeOutdated: Bool) async -> ModelCacheStatus? {
            await withCheckedContinuation { c in
                let now: Bool = lock.withLock {
                    if open { return true }
                    waiters.append(c)
                    return false
                }
                if now { c.resume() }
            }
            return ModelCacheStatus(cached: true, sizeBytes: 1, repoFolders: [])
        }
        func release() {
            let all: [CheckedContinuation<Void, Never>] = lock.withLock {
                open = true
                defer { waiters = [] }
                return waiters
            }
            for c in all { c.resume() }
        }
        var probing: Bool { lock.withLock { !waiters.isEmpty } }
        func install(_ backend: Service, mode: InstallMode) -> AsyncThrowingStream<InstallEvent, Error> {
            lock.withLock { status = .ready(Self.marker) }
            return AsyncThrowingStream { $0.finish() }
        }
        func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus?) async throws {
            lock.withLock {
                status = .missing
                requested = false
            }
        }
        func serveArguments(for info: ServiceInfo, port: Int) -> [String]? { ["serve"] }
    }

    /// Hands out the test's processes in order and counts the launches.
    final class Processes: @unchecked Sendable {
        private let lock = NSLock()
        private var queue: [FakeProcess]
        private(set) var launches = 0
        init(_ queue: [FakeProcess]) { self.queue = queue }
        func next() -> FakeProcess {
            lock.withLock {
                launches += 1
                return queue.isEmpty ? FakeProcess() : queue.removeFirst()
            }
        }
    }

    @MainActor final class FakeHost: ServiceHost {
        let serviceEnvironment: (any ServiceEnvironment)?
        let servicePaths: AppPaths?
        var tryIt: [String] = []
        /// Every port `probeExternal` was asked about.
        var externalProbes: [Int] = []
        /// What the hello probe answers: by default a server that is not ours (kokoro on a tone port),
        /// so a busy-port Start ends in the owner lookup and the busy failure as before.
        var externalOutcome: ExternalProbe.Outcome = .mismatch(
            try! HelloFixtures.frame(HelloFixtures.json(for: .kokoro)))
        /// Replaces `externalOutcome` with a probe the test controls.
        var externalHandler: (@MainActor (Int) async -> ExternalProbe.Outcome)?

        init(environment: any ServiceEnvironment = FakeEnvironment()) {
            serviceEnvironment = environment
            let root = FileManager.default.temporaryDirectory.appending(path: "driver-tests-\(UUID().uuidString)")
            servicePaths = AppPaths(supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"))
        }
        func familyChanged() async {}
        func openTryIt(port: Int) { tryIt.append("open \(port)") }
        func probeExternal(port: Int) async -> ExternalProbe.Outcome {
            externalProbes.append(port)
            if let externalHandler { return await externalHandler(port) }
            return externalOutcome
        }
        func detachTryIt() { tryIt.append("detach") }
        func closeTryIt() { tryIt.append("close") }
    }

    @MainActor final class Flag { var value = false }

    /// Polls (on the main actor) until `condition` holds or 2 s pass.
    func until(_ condition: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while !condition(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
    }

    func makeDriver(_ process: FakeProcess, host: FakeHost, configure: (inout ServiceDependencies) -> Void = { _ in })
        -> ServiceDriver
    {
        var deps = ServiceDependencies()
        deps.isPortFree = { _ in true }
        deps.makeProcess = { _ in process }
        configure(&deps)
        let driver = ServiceDriver(info: Service.tone.info, dependencies: deps)
        driver.host = host
        return driver
    }

    // MARK: - Ported from the app-target ServiceModelTests

    /// App quit cancels an Apple Speech model install and waits for it to unwind.
    @Test func shutdownCancelsAndAwaitsAnAppleSpeechInstall() async {
        var deps = ServiceDependencies()
        let ended = Flag()
        deps.appleSpeechPhase = { .notInstalled }
        deps.appleSpeechInstall = { _ in
            defer { ended.value = true }
            try await Task.sleep(for: .seconds(30))
        }
        let driver = ServiceDriver(info: Service.appleSpeech.info, dependencies: deps)
        driver.install()
        await Task.yield()
        let clock = ContinuousClock()
        let start = clock.now
        await driver.shutdown()
        #expect(ended.value, "shutdown returned with the install still running")
        #expect(clock.now - start < .seconds(2))
        #expect(driver.state.phase == .installing(.model), "a cancel during quit shows nothing")
    }

    /// An install that ignores cancellation holds quit for at most `installDrain`.
    @Test func shutdownWaitsForAStuckInstallOnlySoLong() async {
        var deps = ServiceDependencies()
        deps.installDrain = .milliseconds(200)
        deps.appleSpeechInstall = { _ in
            // Ignores cancellation without spinning: a cancelled task's own sleep throws at once,
            // which would busy-loop and starve a small runner's task pool (and the drain timer).
            let deadline = ContinuousClock.now + .seconds(3)
            while ContinuousClock.now < deadline {
                await Task.detached { try? await Task.sleep(for: .milliseconds(20)) }.value
            }
        }
        let driver = ServiceDriver(info: Service.appleSpeech.info, dependencies: deps)
        driver.install()
        let clock = ContinuousClock()
        let start = clock.now
        await driver.shutdown()
        #expect(clock.now - start < .seconds(2))
    }

    // MARK: - Server lifecycle through the driver

    @Test func startReadyStop() async {
        let process = FakeProcess()
        let host = FakeHost()
        let driver = makeDriver(process, host: host)
        await driver.refresh()
        #expect(driver.state.phase == .installed)
        driver.start()
        #expect(driver.state.phase == .starting)
        #expect(driver.startDetail == "Loading model…")
        process.emit(#"{"event":"ready","port":8665,"rate":24000,"pid":77}"#)
        await until { driver.state.phase == .running }
        #expect(driver.state.running?.pid == 77)
        #expect(host.tryIt == ["open 8665"])
        driver.stop()
        #expect(driver.state.phase == .stopping)
        await until { driver.state.phase == .installed }
        #expect(driver.state.phase == .installed)
        #expect(host.tryIt == ["open 8665", "detach", "close"])
        #expect(driver.state.server == nil)
    }

    /// A ready line that lands after Stop must not flip the phase back to running.
    @Test func aReadyAfterStopIsIgnored() async {
        let process = FakeProcess()
        let host = FakeHost()
        process.exitsOnStop = false
        let driver = makeDriver(process, host: host)
        driver.start()
        driver.stop()
        #expect(driver.state.phase == .stopping)
        process.emit(#"{"event":"ready","port":8665}"#)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(driver.state.phase == .stopping, "the late ready flipped the phase")
        process.exit(15)
        await until { driver.state.server == nil }
        #expect(driver.state.phase == .installed)
        #expect(!host.tryIt.contains("open 8665"))
    }

    /// The ready timeout stops a server that never reports ready and fails the start.
    @Test func aServerThatNeverGetsReadyTimesOut() async {
        let process = FakeProcess()
        let host = FakeHost()  // the driver holds its host weakly
        let driver = makeDriver(process, host: host) { $0.readyTimeout = .milliseconds(50) }
        driver.start()
        await until { driver.state.server == nil }
        #expect(process.stops == 1)
        guard case .failed(let failure) = driver.state.phase else {
            Issue.record("\(driver.state.phase)")
            return
        }
        #expect(failure.kind == .startup(code: "Timeout"))
    }

    // MARK: - Late async results (generation and liveness guards)

    /// A slow cache probe that lands after Start + ready must not hide the server.
    @Test func aSlowRefreshDoesNotHideAServerStartedMeanwhile() async {
        let process = FakeProcess()
        let slow = SlowEnvironment()
        let host = FakeHost(environment: slow)
        let driver = makeDriver(process, host: host)
        let refresh = Task { await driver.refresh() }
        await until { driver.state.environment != .missing }
        driver.start()
        process.emit(#"{"event":"ready","port":8665,"rate":24000,"pid":77}"#)
        await until { driver.state.phase == .running }
        slow.release()
        await refresh.value
        #expect(driver.state.phase == .running, "the stale refresh hid the running server")
        // A fresh refresh (Reset / Try Again) leaves the running server alone too.
        await driver.refresh()
        #expect(driver.state.phase == .running)
    }

    /// Cancel during the busy-port probe ends it; the late answer is dropped.
    @Test func cancelDuringThePortProbe() async {
        let process = FakeProcess()
        let host = FakeHost()
        let answered = Flag()
        let began = Flag()
        let driver = makeDriver(process, host: host) {
            $0.isPortFree = { _ in false }
            $0.portOwner = { _, _ in
                await MainActor.run { began.value = true }
                try? await Task.sleep(for: .milliseconds(100))
                await MainActor.run { answered.value = true }
                return PortProbe.Owner(pid: 1)
            }
        }
        await driver.refresh()
        driver.start()
        #expect(driver.state.phase == .starting)
        await until { began.value }  // the hello probe answered; the owner lookup is the one stopped
        #expect(began.value)
        driver.stop()
        await until { answered.value }
        await until { driver.state.phase == .installed }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(driver.state.phase == .installed, "\(driver.state.phase)")
    }

    /// A port probe that would run for 30 s: records that it started, and how it ended.
    @MainActor final class SlowProbe {
        var started = false
        var ended = false
        var cancelled = false
        func run() async -> PortProbe.Owner {
            started = true
            try? await Task.sleep(for: .seconds(30))
            cancelled = Task.isCancelled
            ended = true
            return PortProbe.Owner(pid: 1)
        }
    }

    /// Stop while the busy-port probe runs cancels it (its `lsof` is stopped),
    /// and the cancelled probe's answer never reaches the reducer.
    @Test func stopCancelsThePortProbe() async {
        let probe = SlowProbe()
        let host = FakeHost()  // the driver holds its host weakly
        let driver = makeDriver(FakeProcess(), host: host) {
            $0.isPortFree = { _ in false }
            $0.portOwner = { _, _ in await probe.run() }
        }
        await driver.refresh()
        driver.start()
        await until { probe.started }
        #expect(probe.started)
        driver.stop()
        await until { probe.ended }
        #expect(probe.ended && probe.cancelled, "Stop left the port probe running")
        await until { driver.state.phase == .installed }
        #expect(driver.state.phase == .installed, "\(driver.state.phase)")
    }

    /// Quit while the busy-port probe runs: `shutdown()` cancels it and returns
    /// only once it has ended (its subprocess can't outlive the app).
    @Test func quitWaitsForThePortProbe() async {
        let probe = SlowProbe()
        let host = FakeHost()  // the driver holds its host weakly
        let driver = makeDriver(FakeProcess(), host: host) {
            $0.isPortFree = { _ in false }
            $0.portOwner = { _, _ in await probe.run() }
        }
        await driver.refresh()
        driver.start()
        await until { probe.started }
        #expect(probe.started)
        await driver.shutdown()
        #expect(probe.ended && probe.cancelled, "shutdown returned with the port probe still running")
        #expect(driver.state.phase == .starting, "a cancelled probe's answer failed the service: \(driver.state.phase)")
    }

    /// An environment whose cache probe answers at once until `arm()`, then waits for `release()`.
    final class ArmableEnvironment: ServiceEnvironment, @unchecked Sendable {
        let slow = SlowEnvironment()
        private let lock = NSLock()
        private var armed = false
        func arm() { lock.withLock { armed = true } }
        func environmentStatus(_ backend: Service) -> EnvironmentStatus { slow.environmentStatus(backend) }
        func isRequested(_ service: Service) -> Bool { true }
        func modelCacheStatus(_ backend: Service, includeOutdated: Bool) async -> ModelCacheStatus? {
            guard lock.withLock({ armed }) else { return ModelCacheStatus(cached: true, sizeBytes: 1, repoFolders: []) }
            return await slow.modelCacheStatus(backend, includeOutdated: includeOutdated)
        }
        func install(_ backend: Service, mode: InstallMode) -> AsyncThrowingStream<InstallEvent, Error> {
            AsyncThrowingStream { $0.finish() }
        }
        func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus?) async throws {}
        func serveArguments(for info: ServiceInfo, port: Int) -> [String]? { ["serve"] }
    }

    /// Stop during the port probe cancels it before the re-read Stop issues:
    /// a slow cache probe can't keep `lsof` running.
    @Test func stopCancelsTheProbeBeforeItsRefresh() async {
        let probe = SlowProbe()
        let environment = ArmableEnvironment()
        let host = FakeHost(environment: environment)  // the driver holds its host weakly
        let driver = makeDriver(FakeProcess(), host: host) {
            $0.isPortFree = { _ in false }
            $0.portOwner = { _, _ in await probe.run() }
        }
        await driver.refresh()
        driver.start()
        await until { probe.started }
        #expect(probe.started)
        environment.arm()
        driver.stop()
        await until { probe.ended }
        #expect(probe.ended && probe.cancelled, "the probe waited behind Stop's refresh")
        environment.slow.release()
        await until { driver.state.phase == .installed }
        #expect(driver.state.phase == .installed, "\(driver.state.phase)")
    }

    /// Quit began, then a late refresh (the bootstrap's) sees the system
    /// downloading the Apple Speech model: it attaches nothing, whether it was
    /// issued after quit or was in flight when quit began.
    @Test func aRefreshAfterQuitAttachesNoAppleSpeechInstall() async {
        let gate = SlowEnvironment()
        let attached = Flag()
        let asked = Flag()
        var deps = ServiceDependencies()
        deps.appleSpeechPhase = {
            asked.value = true
            _ = await gate.modelCacheStatus(.appleSpeech, includeOutdated: false)
            return .installing(.model)
        }
        deps.appleSpeechInstall = { _ in
            attached.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let driver = ServiceDriver(info: Service.appleSpeech.info, dependencies: deps)
        let inFlight = Task { await driver.refresh() }
        await until { asked.value }
        #expect(asked.value, "the first refresh never asked for the phase")
        await driver.quit()
        gate.release()
        await inFlight.value
        await driver.refresh()
        for _ in 0..<20 { await Task.yield() }
        #expect(!attached.value, "a refresh after quit attached an install")
        #expect(!driver.state.installing, "\(driver.state)")
    }

    /// Apple Speech already downloading (no install of ours): the refresh attaches
    /// an install task, so progress and Cancel act on it.
    @Test func aSystemAppleSpeechDownloadIsAttached() async {
        var deps = ServiceDependencies()
        let installs = Flag()
        deps.appleSpeechPhase = { installs.value ? .installed : .installing(.model) }
        deps.appleSpeechInstall = { _ in
            installs.value = true
            try await Task.sleep(for: .seconds(30))
        }
        let driver = ServiceDriver(info: Service.appleSpeech.info, dependencies: deps)
        await driver.refresh()
        #expect(driver.state.installing && driver.state.phase == .installing(.model))
        await until { installs.value }
        #expect(installs.value, "no install task attached to the download")
        driver.cancelInstall()
        await until { !driver.state.installing }
        await until { driver.state.phase == .installed }
        #expect(driver.state.phase == .installed)
    }

    /// An `error` line is judged with the exit that follows it.
    @Test func aSupervisedErrorFailsTheStart() async {
        let process = FakeProcess()
        let host = FakeHost()
        let driver = makeDriver(process, host: host)
        driver.start()
        process.emit(#"{"event":"error","code":"ConfigError","message":"bad voice"}"#)
        process.exit(1)
        await until { driver.state.server == nil }
        #expect(driver.state.phase == .failed(ServiceFailure(kind: .startup(code: "ConfigError"), title: "Couldn't start", message: "bad voice")))
    }

    // MARK: - The reported sequences, through the driver

    /// A descendant keeps the crashed server's pipes open: its late output must
    /// not reach the next launch's log or start detail.
    @Test func aStaleReaderLineNeverReachesTheNextLaunch() async {
        let old = FakeProcess()
        old.keepsPipesOpen = true
        let new = FakeProcess()
        let processes = Processes([old, new])
        let host = FakeHost()
        var deps = ServiceDependencies()
        deps.isPortFree = { _ in true }
        deps.makeProcess = { _ in processes.next() }
        let driver = ServiceDriver(info: Service.tone.info, dependencies: deps)
        driver.host = host
        driver.start()
        old.emit(#"{"event":"ready","port":8665,"rate":24000,"pid":77}"#)
        await until { driver.state.phase == .running }
        old.exit(1)
        await until { driver.state.server == nil }
        guard case .failed = driver.state.phase else {
            Issue.record("\(driver.state.phase)")
            return
        }
        driver.start()
        #expect(processes.launches == 2 && driver.state.phase == .starting)
        let late = "2026-10-23 09:31:34,650 INFO tts_server: late line from the old server"
        old.emitError(late)
        old.emit(#"{"event":"ready","port":8665,"rate":24000,"pid":77}"#)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!driver.log.contains(late), "the old server's reader wrote into the new launch's log")
        #expect(driver.startDetail == "Loading model…", "\(driver.startDetail)")
        #expect(driver.state.phase == .starting)
        new.emit(#"{"event":"ready","port":8665,"rate":24000,"pid":78}"#)
        await until { driver.state.phase == .running }
        #expect(driver.state.running?.pid == 78)
    }

    /// Start on an outdated environment refreshes its packages, then reads the
    /// phase before starting. Delete while that read's cache probe runs: the
    /// read lands stale, so nothing is launched.
    @Test func deleteDuringRefreshThenStartLaunchesNothing() async {
        let env = ScriptedEnvironment(.outdated(ScriptedEnvironment.marker))
        let processes = Processes([])
        let host = FakeHost(environment: env)
        var deps = ServiceDependencies()
        deps.isPortFree = { _ in true }
        deps.makeProcess = { _ in processes.next() }
        let driver = ServiceDriver(info: Service.tone.info, dependencies: deps)
        driver.host = host
        await driver.refresh()
        #expect(driver.state.phase == .installed)
        driver.start()
        await until { env.probing }
        #expect(env.probing, "the package refresh's read never reached the cache probe")
        #expect(driver.state.startAfterRead)
        driver.remove(deleteModel: false)
        await until { driver.state.phase == .notInstalled }
        #expect(driver.state.phase == .notInstalled)
        env.release()
        try? await Task.sleep(for: .milliseconds(100))
        #expect(processes.launches == 0, "the deleted service was started")
        #expect(driver.state.phase == .notInstalled && driver.state.server == nil)
    }

    /// The system keeps downloading after the user cancelled the attached
    /// install: the follow-up refresh does not attach again.
    @Test func aCancelledSystemDownloadStaysCancelled() async {
        var deps = ServiceDependencies()
        let attaches = Counter()
        deps.appleSpeechPhase = { .installing(.model) }
        deps.appleSpeechInstall = { _ in
            attaches.value += 1
            try await Task.sleep(for: .seconds(30))
        }
        let driver = ServiceDriver(info: Service.appleSpeech.info, dependencies: deps)
        await driver.refresh()
        await until { attaches.value == 1 }
        driver.cancelInstall()
        await until { driver.state.phase == .notInstalled }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(driver.state.phase == .notInstalled && !driver.state.installing, "\(driver.state.phase)")
        #expect(attaches.value == 1, "Cancel re-attached to the system download")
    }

    @MainActor final class Counter { var value = 0 }

    // MARK: - External: discovery entry points and the Start-path probe

    static let toneHello = try! HelloFixtures.frame(HelloFixtures.json(for: .tone))
    static let toneInfo = ExternalInfo(hello: toneHello)

    /// A hello probe that waits 30 s and, if it ever finished, would adopt: records how it ended.
    @MainActor final class SlowHello {
        var started = false
        var ended = false
        var cancelled = false
        func run() async -> ExternalProbe.Outcome {
            started = true
            try? await Task.sleep(for: .seconds(30))
            cancelled = Task.isCancelled
            ended = true
            return .adopt(Service.tone.info, ServiceDriverTests.toneHello)
        }
    }

    /// A tone driver on a busy port: the Start-path probe asks the host.
    func busyDriver(_ host: FakeHost, processes: Processes = Processes([])) -> ServiceDriver {
        var deps = ServiceDependencies()
        deps.isPortFree = { _ in false }
        deps.portOwner = { _, _ in PortProbe.Owner(pid: 1, command: "other") }
        deps.makeProcess = { _ in processes.next() }
        let driver = ServiceDriver(info: Service.tone.info, dependencies: deps)
        driver.host = host
        return driver
    }

    @Test func discoveryAdoptsAnExternalServerAndOpensNoTryItUntilAsked() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        driver.externalFound(epoch: driver.state.externalEpoch, info: Self.toneInfo)
        #expect(driver.state.phase == .external(8665, Self.toneInfo))
        #expect(driver.state.server == nil && driver.state.native == nil)
        #expect(host.tryIt.isEmpty, "Try it opens on demand, not at adoption")
        driver.tryItRequested()
        #expect(host.tryIt == ["open 8665"])
    }

    @Test func tryItRequestedDoesNothingOutsideExternal() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        driver.tryItRequested()
        #expect(host.tryIt.isEmpty && driver.state.phase == .installed)
    }

    @Test func aLateFoundBehindTheEpochDoesNotResurrectTheService() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        let epoch = driver.state.externalEpoch
        driver.remove(deleteModel: false)  // Delete during the probe
        driver.externalFound(epoch: epoch, info: Self.toneInfo)
        #expect(!driver.state.phase.isExternal)
    }

    @Test func threeFailedProbesTearDownTheSessionAndReReadTheService() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        driver.externalFound(epoch: driver.state.externalEpoch, info: Self.toneInfo)
        driver.tryItRequested()
        let epoch = driver.state.externalEpoch
        driver.externalLost(epoch: epoch, reason: .refused)
        driver.externalLost(epoch: epoch, reason: .timeout)
        #expect(driver.state.phase.isExternal && host.tryIt == ["open 8665"])
        driver.externalLost(epoch: epoch, reason: .refused)
        await until { driver.state.phase == .installed }
        #expect(driver.state.phase == .installed, "\(driver.state.phase)")
        #expect(host.tryIt == ["open 8665", "close"], "the Try it session was not torn down: \(host.tryIt)")
    }

    /// After quit began, every discovery entry point refuses, like the other intents.
    @Test func discoveryEntryPointsRefuseWhenQuitting() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        driver.externalFound(epoch: driver.state.externalEpoch, info: Self.toneInfo)
        let epoch = driver.state.externalEpoch
        await driver.quit()
        let before = driver.state
        // Each event below is still current after quit, so only the quit guard refuses it.
        let lost = LifecycleEvent.externalLost(epoch: epoch, reason: .mismatch)
        #expect(ServiceLifecycle.isCurrent(lost, in: before) && ServiceLifecycle.isCurrent(.tryItRequested, in: before))
        driver.externalLost(epoch: epoch, reason: .mismatch)
        driver.discovered(.lost(.tone, epoch: epoch, reason: .mismatch))
        driver.tryItRequested()
        #expect(driver.state == before && driver.state.phase.isExternal)
        #expect(host.tryIt.isEmpty)

        let fresh = makeDriver(FakeProcess(), host: host)
        await fresh.refresh()
        let idle = fresh.state
        await fresh.quit()
        #expect(ServiceLifecycle.isCurrent(.externalFound(epoch: fresh.state.externalEpoch, info: Self.toneInfo), in: fresh.state))
        fresh.externalFound(epoch: fresh.state.externalEpoch, info: Self.toneInfo)
        fresh.discovered(.found(.tone, epoch: fresh.state.externalEpoch, info: Self.toneInfo))
        #expect(fresh.state.phase == idle.phase, "an External adoption landed after quit began")
    }

    /// A Start-path probe still in flight when quit begins: its tag stays current (quit leaves a
    /// `.starting` service with no server alone), so only the quit guard keeps its result out.
    @Test func startProbeResultRefusesWhenQuitting() async {
        let host = FakeHost()
        host.externalHandler = { _ in
            try? await Task.sleep(for: .seconds(30))  // cancelled by quit
            return .unreachable
        }
        let processes = Processes([])
        let driver = busyDriver(host, processes: processes)
        await driver.refresh()
        driver.start()
        await until { !host.externalProbes.isEmpty }
        await driver.quit()
        let before = driver.state
        guard let tag = before.probe else {
            Issue.record("no Start-path probe in flight: \(before.phase)")
            return
        }
        #expect(before.phase == .starting)
        #expect(ServiceLifecycle.isCurrent(.startProbeResult(tag: tag, outcome: .unreachable), in: before))
        driver.startProbeResult(tag: tag, outcome: .unreachable)
        #expect(driver.state == before, "a Start-path probe result landed after quit began")
        #expect(processes.launches == 0, "quit must not launch a server")
    }

    /// Discovery has one path into the reducer (`discovered`), the same `Directive.event` the
    /// policy tests reduce; a directive for another service is refused.
    @Test func discoveredSendsTheDirectivesEventToItsOwnServiceOnly() async {
        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        let idle = driver.state
        driver.discovered(.found(.kokoro, epoch: idle.externalEpoch, info: Self.toneInfo))
        #expect(driver.state == idle, "another service's directive changed this one")
        let directive = ExternalDiscoveryPolicy.Directive.found(.tone, epoch: idle.externalEpoch, info: Self.toneInfo)
        var expected = idle
        _ = ServiceLifecycle.reduce(&expected, directive.event)
        driver.discovered(directive)
        #expect(driver.state == expected && driver.state.phase.isExternal)
    }

    // MARK: Start path through the driver

    @Test func startOnABusyPortAdoptsTheServerThatAnswers() async {
        let host = FakeHost()
        host.externalOutcome = .adopt(Service.tone.info, Self.toneHello)
        let processes = Processes([])
        let driver = busyDriver(host, processes: processes)
        await driver.refresh()
        driver.start()
        #expect(driver.state.phase == .starting)
        await until { driver.state.phase.isExternal }
        #expect(driver.state.phase == .external(8665, Self.toneInfo))
        #expect(host.externalProbes == [8665])
        #expect(processes.launches == 0, "the app launched a server next to the one it adopted")
        #expect(driver.state.probe == nil)
    }

    @Test func startOnABusyPortWithNothingListeningLaunchesTheAppsServer() async {
        let host = FakeHost()
        host.externalOutcome = .unreachable
        let process = FakeProcess()
        let processes = Processes([process])
        let driver = busyDriver(host, processes: processes)
        await driver.refresh()
        driver.start()
        await until { driver.state.server != nil }
        #expect(processes.launches == 1 && driver.state.phase == .starting)
    }

    @Test func startOnABusyPortHeldByAnotherServerFailsBusyNamingIt() async {
        let host = FakeHost()  // answers kokoro on the tone port by default
        let processes = Processes([])
        let driver = busyDriver(host, processes: processes)
        await driver.refresh()
        driver.start()
        await until { if case .failed = driver.state.phase { true } else { false } }
        guard case .failed(let failure) = driver.state.phase, case .portBusy(let owner, let found) = failure.kind else {
            Issue.record("\(driver.state.phase)")
            return
        }
        #expect(owner.pid == 1)
        #expect(found == .server(backend: "kokoro", model: "mlx-community/Kokoro-82M-bf16"))
        #expect(failure.message.contains("kokoro"))
        #expect(processes.launches == 0)
    }

    @Test func stopCancelsTheHelloProbeAndItsAdoptNeverLands() async {
        let hello = SlowHello()
        let host = FakeHost()
        host.externalHandler = { _ in await hello.run() }
        let driver = busyDriver(host)
        await driver.refresh()
        driver.start()
        await until { hello.started }
        #expect(hello.started)
        driver.stop()
        await until { hello.ended }
        #expect(hello.ended && hello.cancelled, "Stop left the hello probe running")
        await until { driver.state.phase == .installed }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(driver.state.phase == .installed, "\(driver.state.phase)")
    }

    @Test func deleteCancelsTheHelloProbeAndItsAdoptNeverLands() async {
        let hello = SlowHello()
        let host = FakeHost()
        host.externalHandler = { _ in await hello.run() }
        let driver = busyDriver(host)
        await driver.refresh()
        driver.start()
        await until { hello.started }
        driver.remove(deleteModel: false)
        await until { hello.ended }
        #expect(hello.ended && hello.cancelled, "Delete left the hello probe running")
        await until { driver.state.phase == .notInstalled }
        try? await Task.sleep(for: .milliseconds(20))
        #expect(!driver.state.phase.isExternal, "\(driver.state.phase)")
    }

    /// Quit cancels the hello probe and returns only once it has ended; its adopt is dropped.
    @Test func quitCancelsAndWaitsForTheHelloProbe() async {
        let hello = SlowHello()
        let host = FakeHost()
        host.externalHandler = { _ in await hello.run() }
        let driver = busyDriver(host)
        await driver.refresh()
        driver.start()
        await until { hello.started }
        await driver.shutdown()
        #expect(hello.ended && hello.cancelled, "shutdown returned with the hello probe still running")
        #expect(!driver.state.phase.isExternal && driver.state.server == nil, "\(driver.state.phase)")
    }

    // MARK: Quit leaves External services alone

    /// An External service next to one the app started: Quit stops only ours.
    @Test func quitStopsTheOwnedServerAndLeavesTheExternalOne() async {
        let externalHost = FakeHost()
        let external = makeDriver(FakeProcess(), host: externalHost)
        await external.refresh()
        external.externalFound(epoch: external.state.externalEpoch, info: Self.toneInfo)
        external.tryItRequested()

        let process = FakeProcess()
        let ownedHost = FakeHost()
        var deps = ServiceDependencies()
        deps.isPortFree = { _ in true }
        deps.makeProcess = { _ in process }
        let owned = ServiceDriver(info: Service.kokoro.info, dependencies: deps)
        owned.host = ownedHost
        await owned.refresh()
        owned.start()
        process.emit(#"{"event":"ready","port":9265,"rate":24000,"pid":77}"#)
        await until { owned.state.phase == .running }
        #expect(owned.state.phase == .running)

        await external.quit()
        await owned.quit()
        #expect(process.stops == 1, "Quit did not stop the server the app started")
        #expect(external.state.phase == .external(8665, Self.toneInfo) && external.state.server == nil)
        #expect(externalHost.tryIt == ["open 8665"], "Quit tore down or detached the External row's session")
        #expect(external.state.externalFailures == 0)
    }

    /// Live: adopts a real tone server (on its own ephemeral port, never the catalog's) and asserts
    /// Quit leaves it running and answering.
    @Test(.enabled(if: TTSRequestDriverLiveTests.enabled))
    func quitLeavesAnAdoptedLiveToneServerRunning() async throws {
        let (server, port) = try await TTSRequestDriverLiveTests.startTone()
        defer { server.kill() }
        let hello = try await HelloFixtures.liveHello(port: port)
        // The hello of a real tone server maps to the tone entry on the tone port.
        #expect(HelloFixtures.entry(for: hello, port: Service.tone.info.port)?.service == .tone)

        let host = FakeHost()
        let driver = makeDriver(FakeProcess(), host: host)
        await driver.refresh()
        driver.externalFound(epoch: driver.state.externalEpoch, info: ExternalInfo(hello: hello))
        guard case .external = driver.state.phase else {
            Issue.record("\(driver.state.phase)")
            return
        }
        #expect(driver.state.server == nil && driver.state.native == nil)

        await driver.quit()
        #expect(driver.state.phase.isExternal)
        try await Task.sleep(for: .milliseconds(200))
        #expect(server.isRunning, "Quit signalled a server the app did not start")
        let again = try await HelloFixtures.liveHello(port: port)
        #expect(again.backendName == "tone")
    }
}
