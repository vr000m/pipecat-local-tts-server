import Foundation
import Observation
import os

// Runs `ServiceLifecycle`'s effects against injectable seams: the environment
// manager, server processes, the port probe, Apple Speech and the clock. It
// owns the per-service progress state the UI reads (download, log tail, ...).

/// What the driver needs from `EnvironmentManager`.
public protocol ServiceEnvironment: Sendable {
    func environmentStatus(_ backend: Service) -> EnvironmentStatus
    func isRequested(_ service: Service) -> Bool
    func modelCacheStatus(_ backend: Service, includeOutdated: Bool) async -> ModelCacheStatus?
    func install(_ backend: Service, mode: InstallMode) -> AsyncThrowingStream<InstallEvent, Error>
    /// `known`: what the last check saw, for when the environment can no longer report it.
    func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus?) async throws
    func serveArguments(for info: ServiceInfo, port: Int) -> [String]?
}

extension EnvironmentManager: ServiceEnvironment {}

/// A supervised server process (`Subprocess`).
public protocol ServerProcess: AnyObject, Sendable {
    var pid: Int32 { get }
    var stdout: AsyncStream<String> { get }
    var stderr: AsyncStream<String> { get }
    func run() throws
    func stop(grace: Duration) async -> Int32
    func waitForExit(after reader: Task<Void, Never>, drainLimit: Duration) async -> Int32
}

extension Subprocess: ServerProcess {}

/// The in-process stt-protocol server (`STTWebSocketServer`).
public protocol NativeSpeechServer: AnyObject, Sendable {
    var onLog: (@Sendable (String) -> Void)? { get set }
    func start(port: Int) async throws -> Int
    func stop()
}

extension STTWebSocketServer: NativeSpeechServer {}

/// The app-side pieces of a service: where it lives and what it shows.
@MainActor
public protocol ServiceHost: AnyObject {
    /// The environment manager, once the tools are found.
    var serviceEnvironment: (any ServiceEnvironment)? { get }
    var servicePaths: AppPaths? { get }
    /// Lets the service's siblings re-read the environment it changed.
    func familyChanged() async
    func openTryIt(port: Int)
    /// One hello probe of a loopback catalog port (`ExternalProbe`), for the Start path
    /// and the `EADDRINUSE` chain. A cancelled probe's outcome is not to be trusted
    /// (the driver drops it by tag).
    func probeExternal(port: Int) async -> ExternalProbe.Outcome
    /// Stops Try it's audio (the server is going down).
    func detachTryIt()
    /// Drops the Try it session.
    func closeTryIt()
}

/// The driver's process, port, clock and Apple Speech seams; the process and port defaults are the
/// real ones, the Apple Speech defaults are inert stubs the app replaces. The hello probe
/// is the one seam on `ServiceHost` instead (`probeExternal`: the app's shared prober).
public struct ServiceDependencies: Sendable {
    public var isPortFree: @Sendable (Int) -> Bool = { PortProbe.isFree($0) }
    public var portOwner: @Sendable (Int, Service) async -> PortProbe.Owner = { await PortProbe.owner(of: $0, backend: $1) }
    public var makeProcess: @Sendable (Subprocess.Spec) -> any ServerProcess = { Subprocess($0) }
    /// Apple Speech's phase (installed, needs a download, unavailable).
    public var appleSpeechPhase: @MainActor @Sendable () async -> ServicePhase = { .unavailable("Apple Speech is unavailable.") }
    /// Downloads the Apple Speech model, reporting 0...1.
    public var appleSpeechInstall: @MainActor @Sendable (@escaping @MainActor (Double) -> Void) async throws -> Void = { _ in }
    public var makeNativeServer: @MainActor @Sendable () -> (any NativeSpeechServer)? = { nil }
    public var sleep: @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
    public var now: @Sendable () -> Date = { Date() }
    /// How long `start()` waits for the ready line.
    public var readyTimeout: Duration = .seconds(600)
    /// How long app quit waits for a cancelled Apple Speech install to unwind.
    public var installDrain: Duration = .seconds(5)
    /// SIGTERM to SIGKILL for a stopped server.
    public var stopGrace: Duration = .seconds(10)
    /// How long an exit waits for stdout to drain.
    public var drainLimit: Duration = .seconds(2)
    /// The persisted "wanted running" set (`WantedTransition`); the default keeps nothing.
    public var wanted: any WantedServiceStore = NoopWantedServiceStore()

    public init() {}
}

@MainActor
@Observable
public final class ServiceDriver {
    public let info: ServiceInfo
    public var service: Service { info.service }

    public private(set) var state: LifecycleState
    public private(set) var download: DownloadProgress?
    /// Apple Speech model install progress (0...1).
    public private(set) var assetProgress: Double?
    public private(set) var installDetail: String = ""
    /// The last cache probe a current read reported.
    public var cache: ModelCacheStatus? { state.cache }
    public private(set) var startDetail: String = ""
    public private(set) var log: [String] = []
    public private(set) var warning: String?

    @ObservationIgnored public weak var host: (any ServiceHost)?
    @ObservationIgnored public var dependencies: ServiceDependencies
    @ObservationIgnored private var installTask: Task<Void, Never>?
    @ObservationIgnored private var cancelledInstall: Task<Void, Never>?
    @ObservationIgnored private var server: (any ServerProcess)?
    @ObservationIgnored private var nativeServer: (any NativeSpeechServer)?
    @ObservationIgnored private var logSink: LogSink?
    @ObservationIgnored private var nextID = 0
    /// The output readers of each launched server, cancelled at its exit.
    @ObservationIgnored private var readers: [ServerID: [Task<Void, Never>]] = [:]
    /// The port-owner probes still running, by probe tag (a cancelled one stays
    /// until its `lsof` has exited, so quit can wait for it).
    @ObservationIgnored private var probes: [Int: Task<Void, Never>] = [:]
    /// App quit began (`quit()`): no read is issued or lands, and no intent
    /// starts work, so a late refresh (the bootstrap's, an install unwinding)
    /// can't start what the shutdown already passed (an Apple Speech attach).
    @ObservationIgnored public private(set) var quitting = false

    public init(info: ServiceInfo, dependencies: ServiceDependencies = ServiceDependencies()) {
        self.info = info
        self.dependencies = dependencies
        state = LifecycleState(info: info)
    }

    private var environment: (any ServiceEnvironment)? { host?.serviceEnvironment }

    // MARK: - Events

    /// The one rule for every event: it reaches the reducer only through `dispatch` or
    /// `dispatchAwaiting`, and the effects the reducer returns always run, in order (none is
    /// dropped because an event's effects are empty "by reasoning"). `dispatch` runs the
    /// leading immediate effects now and the rest in a task; `dispatchAwaiting` runs them all
    /// before it returns, for callers that must order what follows after them. Both return the
    /// effects (already running) for a caller that also inspects them.
    @discardableResult
    private func dispatch(_ event: LifecycleEvent) -> [LifecycleEffect] {
        let effects = reduce(event)
        execute(effects)
        return effects
    }

    private func dispatchAwaiting(_ event: LifecycleEvent) async {
        await run(reduce(event))
    }

    /// The one place an event reaches the reducer: the service's persisted wanted flag follows
    /// `WantedTransition` from the event, the phase before and after and `quitting` (after quit
    /// began only a Stop moves it: `remove()` and the other intents are refused here, and
    /// `WantedTransition.rule` keeps every other kind), and is written only when it changes, through the
    /// store's per-service operations (other services' flags are never touched).
    private func reduce(_ event: LifecycleEvent) -> [LifecycleEffect] {
        let before = state.phase
        let effects = ServiceLifecycle.reduce(&state, event)
        let store = dependencies.wanted
        let was = store.contains(service)
        let now = WantedTransition.next(
            wanted: was, kind: event.kind, before: before, after: state.phase, quitting: quitting)
        if now != was { store.setWanted(now, for: service) }
        return effects
    }

    /// Runs the leading effects that need no suspension now, the rest in a task.
    private func execute(_ effects: [LifecycleEffect]) {
        var rest = effects[...]
        while let effect = rest.first, effect.isImmediate {
            rest.removeFirst()
            performImmediate(effect)
        }
        guard !rest.isEmpty else { return }
        let remaining = Array(rest)
        Task { await self.run(remaining) }
    }

    private func run(_ effects: [LifecycleEffect]) async {
        for effect in effects {
            if effect.isImmediate { performImmediate(effect) } else { await performAsync(effect) }
        }
    }

    // MARK: - Intents

    /// Re-reads the phase (the reducer tags the read with a fresh epoch, so a
    /// newer read, or anything else that moved the epoch, makes this one stale).
    public func refresh() async {
        guard !quitting else { return }
        await dispatchAwaiting(.refreshRequested)
    }

    /// The read issued under `epoch`: every result carries it. After quit
    /// began, none starts and none lands. One already stale when it runs (a later event
    /// moved the epoch: Start right after a completed Stop) does not start its slow cache
    /// probe; its results would be dropped anyway (`ServiceLifecycle.isCurrent`).
    private func read(epoch: Int) async {
        guard !quitting, epoch == state.epoch else { return }
        if info.runtime == .appleSpeech {
            let phase = await dependencies.appleSpeechPhase()
            guard !quitting else { return }
            dispatch(.refreshed(phase, epoch: epoch))
            return
        }
        guard let environment else { return }
        let status = environment.environmentStatus(service)
        let requested = status != .missing && environment.isRequested(service)
        guard requested, case .ready = status else {
            dispatch(
                .refreshed(
                    ServiceLifecycle.installedPhase(environment: status, requested: requested, cached: nil),
                    environment: status, requested: requested, cache: requested ? .none : .some(nil), epoch: epoch))
            return
        }
        // The environment is current while the (slow) cache probe runs.
        dispatch(.environmentRead(status, epoch: epoch))
        let cache = await environment.modelCacheStatus(service, includeOutdated: false)
        guard !quitting else { return }
        dispatch(
            .refreshed(
                ServiceLifecycle.installedPhase(environment: status, requested: requested, cached: cache?.cached),
                environment: status, requested: requested, cache: .some(cache), epoch: epoch))
    }

    public func environmentChanged() async {
        await dispatchAwaiting(.environmentChanged(environment?.environmentStatus(service)))
    }

    public func install() {
        guard !quitting else { return }
        dispatch(.installRequested(managerAvailable: environment != nil))
    }
    public func cancelInstall() { dispatch(.cancelInstallRequested) }

    public func start() {
        guard !quitting else { return }
        dispatch(
            .startRequested(
                appAvailable: host != nil, managerAvailable: environment != nil,
                portFree: dependencies.isPortFree(info.port)))
    }

    public func stop() { dispatch(.stopRequested) }

    // MARK: - External discovery

    /// The one path from discovery into the reducer (`externalFound` / `externalLost`): sends
    /// `directive.event`, the same event the policy's tests reduce. Each directive carries the
    /// `state.externalEpoch` read when its probe started; the reducer drops it if that moved.
    /// Refused after quit began, and for another service's directive.
    public func discovered(_ directive: ExternalDiscoveryPolicy.Directive) {
        guard !quitting, directive.service == service else { return }
        dispatch(directive.event)
    }

    /// The Start-path probe `tag` finished (the `.probeExternal` effect calls this).
    public func startProbeResult(tag: Int, outcome: ExternalProbe.Outcome) {
        guard !quitting else { return }
        dispatch(.startProbeResult(tag: tag, outcome: outcome))
    }

    /// Opens Try it on an External row (a no-op in every other phase).
    public func tryItRequested() {
        guard !quitting else { return }
        dispatch(.tryItRequested)
    }

    /// Before removal, and for app quit (through `quit()`): stop and wait. It also cancels an
    /// Apple Speech model install and waits (at most `installDrain`) for it to
    /// unwind; a Python install is the environment manager's to stop. A port
    /// probe in flight is cancelled and waited for (its `lsof` never outlives quit).
    public func shutdown() async {
        await dispatchAwaiting(.shutdownRequested)
        await dispatchAwaiting(.shutdownServers)
        let running = Array(probes.values)
        for probe in running { probe.cancel() }
        for probe in running { await probe.value }
    }

    /// App quit: from here on nothing new starts (see `quitting`), then `shutdown()`.
    public func quit() async {
        beginQuit()
        await shutdown()
    }

    /// Sets `quitting` now, before the asynchronous `quit()` runs: the app calls it in the same
    /// main-actor turn as Quit, so a probe or read continuation already queued can't start work.
    public func beginQuit() { quitting = true }

    public func dismissFailure() { dispatch(.dismissFailure) }

    /// Uninstalls the service and, with `deleteModel`, the model files no installed
    /// sibling shares. The family environment goes with its last installed variant.
    public func remove(deleteModel: Bool) {
        guard !quitting else { return }
        dispatch(.removeRequested(deleteModel: deleteModel, managerAvailable: environment != nil))
    }

    // MARK: - Effects

    private func performImmediate(_ effect: LifecycleEffect) {
        switch effect {
        case .runInstall(let mode, let then, let install): runInstall(mode: mode, then: then, install: install)
        case .runAppleSpeechInstall(let install): runAppleSpeechInstall(install: install)
        case .cancelInstall:
            cancelledInstall = installTask
            installTask?.cancel()
        case .probePortOwner(let port, let probe):
            let portOwner = dependencies.portOwner
            let service = self.service
            probes[probe] = Task {
                let owner = await portOwner(port, service)
                self.probes[probe] = nil
                // A cancelled probe (Stop, quit) reports nothing, nor one that ends after quit
                // began (as `startProbeResult`).
                guard !Task.isCancelled, !self.quitting else { return }
                self.dispatch(.portOwnerFound(owner, probe: probe))
            }
        case .probeExternal(let port, let probe):
            probes[probe] = Task {
                let outcome = await self.host?.probeExternal(port: port)
                self.probes[probe] = nil
                // A cancelled probe (Stop, quit) reports `.silent`/`.timeout`: drop it, never trust it.
                guard let outcome, !Task.isCancelled else { return }
                self.startProbeResult(tag: probe, outcome: outcome)
            }
        case .cancelProbe(let probe):
            probes[probe]?.cancel()
        case .launch(let port): launch(port: port)
        case .launchNative(let port): launchNative(port: port)
        case .stopNative:
            nativeServer?.stop()
            nativeServer = nil
        case .discardNative:
            break  // `launchNative` stops the instance it bound
        case .startReadyTimer(let id):
            let timeout = dependencies.readyTimeout
            let sleep = dependencies.sleep
            Task { [weak self] in
                try? await sleep(timeout)
                guard let self else { return }
                self.dispatch(.readyTimedOut(id))
            }
        case .openTryIt(let port):
            host?.openTryIt(port: port)
            ServiceLog.server.info("\(self.service.rawValue, privacy: .public): ready on port \(port)")
        case .detachTryIt: host?.detachTryIt()
        case .tearDown(let note):
            host?.closeTryIt()
            logSink?.write("---- \(note)")
            logSink?.close()
            logSink = nil
        case .stopServer(_, wait: false):
            guard let server else { return }
            let grace = dependencies.stopGrace
            Task { _ = await server.stop(grace: grace) }
        case .appendLog(let line): appendLog(line)
        case .startDetail(let text): startDetail = text
        case .clearLog: log = []
        case .start: start()
        case .refresh, .familyChanged, .awaitInstall, .stopServer, .resumeRemoval, .shutdown, .removeEnvironment:
            assertionFailure("\(effect) is not immediate")
        }
    }

    private func performAsync(_ effect: LifecycleEffect) async {
        switch effect {
        case .refresh(let epoch): await read(epoch: epoch)
        case .familyChanged: await host?.familyChanged()
        case .awaitInstall(let bounded):
            guard let install = cancelledInstall else { return }
            if bounded {
                await Self.wait(for: install, atMost: dependencies.installDrain, sleep: dependencies.sleep)
            } else {
                await install.value
            }
        case .stopServer(_, wait: true):
            guard let server else { return }
            _ = await server.stop(grace: dependencies.stopGrace)
        case .resumeRemoval(let deleteModel, let removal):
            await dispatchAwaiting(.removalResumed(deleteModel: deleteModel, removal: removal))
        case .shutdown: await shutdown()
        case .removeEnvironment(let deleteModel, let removal):
            guard let environment else { return }
            do {
                try await environment.remove(service, deleteModel: deleteModel, known: state.cache)
            } catch {
                await dispatchAwaiting(.removalFailed(error.localizedDescription, removal: removal))
                return
            }
            ServiceLog.install.info("\(self.service.rawValue, privacy: .public): removed (model files: \(deleteModel))")
            await dispatchAwaiting(.removalFinished(removal: removal))
        default:
            performImmediate(effect)
        }
    }

    // MARK: - Install

    private func runAppleSpeechInstall(install tag: Int) {
        warning = nil
        assetProgress = 0
        ServiceLog.install.info("apple_speech: installing speech model")
        let install = dependencies.appleSpeechInstall
        installTask = Task { [weak self] in
            do {
                try await install { fraction in self?.assetProgress = fraction }
                guard let self else { return }
                self.installTask = nil
                self.assetProgress = nil
                await self.dispatchAwaiting(.appleSpeechInstallEnded(.finished, install: tag))
            } catch {
                guard let self else { return }
                self.installTask = nil
                self.assetProgress = nil
                let outcome: InstallOutcome =
                    Task.isCancelled ? .cancelled : .failed(stage: .model, message: error.localizedDescription, logTail: [])
                await self.dispatchAwaiting(.appleSpeechInstallEnded(outcome, install: tag))
            }
        }
    }

    private func runInstall(mode: InstallMode, then: InstallContinuation, install tag: Int) {
        guard let environment else { return }
        warning = nil
        download = nil
        installDetail = ""
        let service = self.service
        ServiceLog.install.info("\(service.rawValue, privacy: .public): install (\(String(describing: mode), privacy: .public))")
        installTask = Task { [weak self] in
            var stage: InstallStage = .python
            do {
                // `consume` throws on Cancel; a plain `for try await` would end
                // normally and run `then` (which restarts a start()'s install).
                try await environment.install(service, mode: mode).consume { event in
                    guard let self else { return }
                    switch event {
                    case .stage(let s):
                        stage = s
                        self.dispatch(.installStage(s, install: tag))
                        self.installDetail = ""
                    case .log(let line):
                        self.installDetail = Self.summarize(uvLine: line) ?? self.installDetail
                        self.appendLog(line)
                    case .download(let progress):
                        self.download = progress
                    case .warning(let message):
                        self.warning = message
                    }
                }
                guard let self else { return }
                self.installTask = nil
                self.download = nil
                ServiceLog.install.info("\(service.rawValue, privacy: .public): install finished")
                await self.dispatchAwaiting(.installEnded(.finished, then: then, install: tag))
            } catch {
                guard let self else { return }
                self.installTask = nil
                self.download = nil
                let outcome: InstallOutcome
                if error is CancellationError || Task.isCancelled {
                    outcome = .cancelled
                } else {
                    let installError = error as? InstallError
                    outcome = .failed(
                        stage: installError?.stage ?? stage, message: Self.friendly(error.localizedDescription),
                        logTail: installError?.logTail ?? [])
                    if self.state.phase != .removing {
                        ServiceLog.install.error(
                            "\(service.rawValue, privacy: .public): install failed: \(error.localizedDescription, privacy: .public)")
                    }
                }
                await self.dispatchAwaiting(.installEnded(outcome, then: then, install: tag))
            }
        }
    }

    // MARK: - Serve

    private func launchNative(port: Int) {
        guard let paths = host?.servicePaths, let native = dependencies.makeNativeServer() else {
            dispatch(.launchFailed("Apple Speech is unavailable."))
            return
        }
        let sink = LogSink(url: paths.appLog(service))
        sink.write("---- \(Date().formatted(.iso8601)) starting apple_speech on \(ServiceCatalog.host):\(port)")
        logSink = sink
        nextID += 1
        let id = ServerID(nextID)
        // A line from a server that was replaced never reaches the next one's log.
        native.onLog = { [weak self] line in
            Task { @MainActor in
                guard let self, self.state.native == id else { return }
                self.logSink?.write(line)
                self.appendLog(line)
            }
        }
        nativeServer = native
        dispatch(.nativeLaunched(id))
        let now = dependencies.now
        Task {
            do {
                let bound = try await native.start(port: port)
                let effects = self.dispatch(.nativeBound(id, port: bound, pid: ProcessInfo.processInfo.processIdentifier, at: now()))
                // `discardNative` runs as a no-op: the instance this launch bound is stopped here.
                if effects.contains(.discardNative(id)) { native.stop() }
            } catch {
                if self.state.native == id { self.nativeServer = nil }
                self.dispatch(.nativeFailed(id, error.localizedDescription))
            }
        }
    }

    private func launch(port: Int) {
        guard let paths = host?.servicePaths, let args = environment?.serveArguments(for: info, port: port) else {
            dispatch(.launchFailed("This service cannot be started by the app."))
            return
        }
        let sub = dependencies.makeProcess(
            .init(executable: paths.python(service), arguments: args, environment: ProcessEnvironment.serve(service), holdStdin: true))
        let sink = LogSink(url: paths.appLog(service))
        sink.write("---- \(Date().formatted(.iso8601)) starting \(service.rawValue) on \(ServiceCatalog.host):\(port)")
        do {
            try sub.run()
        } catch {
            sink.close()
            dispatch(.launchFailed(error.localizedDescription))
            return
        }
        nextID += 1
        let id = ServerID(nextID)
        server = sub
        logSink = sink
        ServiceLog.server.info("\(self.service.rawValue, privacy: .public): started pid \(sub.pid) on port \(port)")
        dispatch(.launched(id))
        watch(sub, id: id, port: port)
    }

    /// Reads a launched server's output and reports its ready line, errors and
    /// exit. The readers belong to server `id`: they stop at its exit (a
    /// descendant may hold the pipes open), and a line read once `id` is no
    /// longer the current server is dropped, so it can't reach the next launch.
    private func watch(_ sub: any ServerProcess, id: ServerID, port: Int) {
        let errors = Task { [weak self] in
            for await line in sub.stderr {
                guard let self, self.state.server == id else { return }
                self.logSink?.write(line)
                self.appendLog(line)
                if self.state.phase == .starting, let message = Self.logMessage(line) { self.startDetail = message }
            }
        }
        let now = dependencies.now
        let events = Task { [weak self] in
            for await line in sub.stdout {
                guard let self, self.state.server == id else { return }
                guard let event = ServerCLIEvent.parse(line) else { continue }
                if event.event == "ready" {
                    let rate = event.rate ?? (self.info.kind == .tts ? 24000 : STTWire.rate)
                    self.dispatch(.ready(id, port: event.port ?? port, pid: event.pid ?? sub.pid, rate: rate, model: event.model, at: now()))
                } else if event.event == "error" {
                    self.dispatch(.supervisedError(id, SupervisedError(code: event.code, message: event.message)))
                }
            }
        }
        readers[id] = [errors, events]
        let drain = dependencies.drainLimit
        Task { [weak self] in
            // The final `error` line is read before the exit is judged.
            let status = await sub.waitForExit(after: events, drainLimit: drain)
            self?.serverExited(id, status: status)
        }
    }

    /// The server `id` exited (reported after its stdout drained).
    public func serverExited(_ id: ServerID, status: Int32) {
        for reader in readers.removeValue(forKey: id) ?? [] { reader.cancel() }
        if state.server == id {
            ServiceLog.server.info(
                "\(self.service.rawValue, privacy: .public): exited status \(status) (requested: \(self.state.stopRequested))")
            server = nil
        }
        dispatch(.exited(id, status: status, logTail: Array(log.suffix(8))))
    }

    /// Returns when `task` ends or `limit` passed, whichever is first (a task
    /// that ignores cancellation can't hold app quit).
    static func wait(
        for task: Task<Void, Never>, atMost limit: Duration, sleep: @escaping @Sendable (Duration) async throws -> Void
    ) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            var resumed = false
            let resume: @MainActor () -> Void = {
                guard !resumed else { return }
                resumed = true
                continuation.resume()
            }
            Task { @MainActor in
                await task.value
                resume()
            }
            Task { @MainActor in
                try? await sleep(limit)
                resume()
            }
        }
    }

    // MARK: - Logs

    private func appendLog(_ line: String) {
        log.append(line)
        if log.count > 300 { log.removeFirst(log.count - 300) }
    }

    /// Short progress text from uv's output.
    public static func summarize(uvLine line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        for prefix in ["Resolved", "Prepared", "Installed", "Downloading", "Uninstalled", "Using CPython", "Building"]
        where trimmed.hasPrefix(prefix) {
            return trimmed
        }
        return nil
    }

    public static func friendly(_ message: String) -> String {
        if message.contains("Failed to fetch") || message.contains("dns error") || message.contains("ConnectError")
            || message.contains("Network is unreachable")
        {
            return "Couldn't reach the network. Check your connection and try again."
        }
        return message
    }

    /// `2026-10-23 09:31:34,650 INFO tts_server: message` -> `message`
    public static func logMessage(_ line: String) -> String? {
        let parts = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: false)
        guard parts.count == 4, let colon = parts[3].range(of: ": ") else {
            return line.count < 120 && !line.contains("|") ? line : nil
        }
        var message = String(parts[3][colon.upperBound...])
        if message.hasPrefix("tts_server: ") { message.removeFirst("tts_server: ".count) }
        return message
    }

    // MARK: - Previews

    /// Puts the driver into a given state (the app's `--snapshot` renderer and tests).
    public func setPreviewState(
        _ state: LifecycleState, download: DownloadProgress? = nil, cache: ModelCacheStatus? = nil,
        log: [String] = [], startDetail: String = "", installDetail: String = ""
    ) {
        self.state = state
        self.state.cache = cache
        self.download = download
        self.log = log
        self.startDetail = startDetail
        self.installDetail = installDetail
    }
}

extension LifecycleEffect {
    /// Runs without suspending (anything slow it starts runs in its own task).
    var isImmediate: Bool {
        switch self {
        case .refresh, .familyChanged, .awaitInstall, .resumeRemoval, .shutdown, .removeEnvironment: false
        case .stopServer(_, let wait): !wait
        default: true
        }
    }
}

enum ServiceLog {
    static let install = Logger(subsystem: "ai.pipecat.ServiceToolbar", category: "install")
    static let server = Logger(subsystem: "ai.pipecat.ServiceToolbar", category: "server")
}
