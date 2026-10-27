import AppKit
import Foundation
import Observation
import PipecatToolbarCore

/// UI state for one service: publishes its `ServiceDriver` (Core's lifecycle
/// state machine and effect runner) and forwards the user's intents to it.
///
/// It adds only what needs the app target: the Try it sessions, Apple Speech
/// (Speech framework), the derived flags the views read, and Finder.
@MainActor
@Observable
final class ServiceModel: Identifiable {
    typealias Phase = ServicePhase
    typealias Failure = ServiceFailure
    typealias RunningInfo = ServiceRunningInfo

    let info: ServiceInfo
    let driver: ServiceDriver
    nonisolated var id: Service { info.service }
    var service: Service { info.service }
    var kind: ServiceKind { info.kind }

    var phase: Phase { driver.state.phase }
    var download: DownloadProgress? { driver.download }
    /// Apple Speech model install progress (0...1).
    var assetProgress: Double? { driver.assetProgress }
    var installDetail: String { driver.installDetail }
    var environment: EnvironmentStatus { driver.state.environment }
    /// Installed by the user (a variant's family environment can exist without it).
    var requested: Bool { driver.state.requested }
    var cache: ModelCacheStatus? { driver.cache }
    var running: RunningInfo? { driver.state.running }
    var startDetail: String { driver.startDetail }
    var log: [String] { driver.log }
    var warning: String? { driver.warning }
    var approxDownloadBytes: Int64?
    private(set) var ttsTryIt: TryItSession?
    private(set) var sttTryIt: STTTryItSession?

    @ObservationIgnored weak var app: AppModel?

    init(info: ServiceInfo) {
        self.info = info
        var dependencies = ServiceDependencies()
        dependencies.appleSpeechPhase = {
            switch await AppleSpeech.status() {
            case .installed: .installed
            case .needsDownload: .notInstalled
            case .downloading: .installing(.model)
            case .unavailable(let why): .unavailable(why)
            }
        }
        dependencies.appleSpeechInstall = { progress in try await AppleSpeech.install(progress: progress) }
        dependencies.makeNativeServer = {
            STTWebSocketServer(identity: .init(name: "apple_speech", model: "SpeechTranscriber")) { pcm, language in
                try await AppleSpeech.transcribe(pcm16: pcm, language: language)
            }
        }
        driver = ServiceDriver(info: info, dependencies: dependencies)
        driver.host = self
    }

    // MARK: - Derived

    /// A server answers: the app's own, or an External one (`ServiceCounts`).
    var isRunning: Bool { ServiceCounts.isRunning(driver.state) }
    /// Consecutive failed re-probes of an External server ("not responding" while below the threshold).
    var externalFailures: Int { driver.state.externalFailures }
    /// The External server missed a re-probe (`ExternalPresentation.isNotResponding`, Core).
    var isExternalNotResponding: Bool { ExternalPresentation.isNotResponding(failures: externalFailures) }
    /// The LaunchAgent label `PortProbe.owner` confirmed holds the External server's port
    /// (pid matched); nil until looked up or when unconfirmed. Reset when the service leaves External.
    private(set) var externalLaunchdLabel: String?
    /// The row's status line for an External service (`ExternalPresentation`, Core).
    var externalStatusLine: String {
        guard case .external(let port, _) = phase else { return "" }
        return ExternalPresentation.statusLine(
            port: port, launchdLabel: externalLaunchdLabel, hasLaunchdFamily: info.launchdLabel != nil,
            failures: externalFailures)
    }
    /// The source alone (label or `127.0.0.1:<port>`), for the detail view.
    var externalSource: String {
        guard case .external(let port, _) = phase else { return "" }
        return ExternalPresentation.source(
            port: port, launchdLabel: externalLaunchdLabel, hasLaunchdFamily: info.launchdLabel != nil)
    }
    /// The External row's actions, nil when the service is not External.
    var externalActions: ExternalPresentation.Actions? { ExternalPresentation.Actions.forPhase(phase) }

    /// Looks up, on every discovery pass, who holds an External server's port, to confirm the
    /// LaunchAgent label. Read-only: `lsof` and `launchctl print`, never a signal. It runs
    /// every pass (not once per adoption) so that a different holder answering the same hello,
    /// or an agent that restarted under a new pid, never keeps the previous holder's label; an
    /// unconfirmed lookup clears it. A cancelled lookup (Quit) changes nothing. When to look
    /// up and whether the answer lands is `ExternalPresentation.OwnerLookup` (Core, tested).
    func refreshExternalOwner() async {
        typealias Lookup = ExternalPresentation.OwnerLookup
        switch Lookup.step(for: driver.state, hasLaunchdFamily: info.launchdLabel != nil) {
        case .clear:
            externalLaunchdLabel = nil
        case .lookUp(let port, let epoch):
            // The driver's injected seam (default `PortProbe.owner`), as the Start-path lookup uses.
            let portOwner = driver.dependencies.portOwner
            let owner = await portOwner(port, service)
            externalLaunchdLabel = Lookup.settle(
                found: owner.launchdLabel, startedAt: epoch, cancelled: Task.isCancelled,
                current: externalLaunchdLabel, in: driver.state)
        }
    }
    // The lifecycle's own reading of its state (Core, tested with the reducer).
    /// Started by the user: shown in the main menu.
    var isActive: Bool { driver.state.isActive }
    var isInstalled: Bool { driver.state.isInstalled }
    var isInstalling: Bool { driver.state.isInstalling }
    var isBusy: Bool { driver.state.isBusy }

    /// The Python services own an environment and model files that can be deleted.
    /// An External row follows `ExternalPresentation.Actions.delete` (never: the server is not ours).
    var canDeleteModel: Bool {
        info.runtime.usesPython && isInstalled && phase != .removing && (externalActions?.delete ?? true)
    }

    var installFraction: Double? { info.runtime == .appleSpeech ? assetProgress : download?.fraction }
    var diskBytes: Int64? { cache.map(\.sizeBytes).flatMap { $0 > 0 ? $0 : nil } }
    var logURL: URL? { app?.paths.appLog(service) }
    var port: Int { running?.port ?? info.port }

    // MARK: - Intents

    func refresh() async { await driver.refresh() }
    /// After a sibling variant changed the shared environment: re-read it, but
    /// leave a phase that work in progress (or a failure on screen) owns.
    func environmentChanged() async { await driver.environmentChanged() }
    /// Get / Start / Delete can run now (`AppModel.acceptsActions`); the views
    /// disable them otherwise, and the intents refuse them too.
    var acceptsActions: Bool { app?.acceptsActions(self) ?? false }

    func install() {
        guard acceptsActions else { return }
        driver.install()
    }
    func cancelInstall() { driver.cancelInstall() }
    func start() {
        guard acceptsActions else { return }
        driver.start()
    }
    func stop() { driver.stop() }
    /// App quit: nothing new starts from here on; stop and wait.
    func shutdown() async { await driver.quit() }
    func dismissFailure() { driver.dismissFailure() }
    func remove(deleteModel: Bool) {
        guard acceptsActions else { return }
        driver.remove(deleteModel: deleteModel)
    }

    static func logMessage(_ line: String) -> String? { ServiceDriver.logMessage(line) }

    func revealLog() {
        guard let url = logURL, FileManager.default.fileExists(atPath: url.path) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

extension ServiceModel: ServiceHost {
    var serviceEnvironment: (any ServiceEnvironment)? { app?.manager }
    var servicePaths: AppPaths? { app?.paths }

    func familyChanged() async { await app?.familyChanged(by: self) }

    func openTryIt(port: Int) {
        switch kind {
        case .tts: ttsTryIt = TryItSession(backend: service, port: port)
        // An External server gets the test clip but never live microphone audio (`Actions.microphone`).
        case .stt: sttTryIt = STTTryItSession(port: port, allowsMicrophone: externalActions?.microphone ?? true)
        }
    }

    func detachTryIt() { ttsTryIt?.detach() }

    /// Opens Try it on an External row on demand (it opens at adoption for no one).
    /// A no-op while a session exists or the service is not External.
    func requestTryIt() {
        guard phase.isExternal, ttsTryIt == nil, sttTryIt == nil else { return }
        driver.tryItRequested()
    }

    /// The menu's "Test Voice" / "Test Transcription": runs the Try it check on this service.
    func runTest() async {
        requestTryIt()
        switch kind {
        case .tts: await ttsTryIt?.speakTest(TryItSession.testLine(for: info))
        case .stt: await sttTryIt?.transcribeSample()
        }
    }

    func probeExternal(port: Int) async -> ExternalProbe.Outcome {
        await ExternalProbe().probe(port: port)
    }

    func closeTryIt() {
        ttsTryIt?.detach()
        ttsTryIt = nil
        sttTryIt?.cancel()
        sttTryIt = nil
    }
}

#if DEBUG
    extension ServiceModel {
        /// Puts the model into a given state for `--snapshot` rendering (debug builds only).
        func setPreviewState(
            phase: Phase, download: DownloadProgress? = nil, running: RunningInfo? = nil,
            environment: EnvironmentStatus = .missing, requested: Bool? = nil, diskBytes: Int64? = nil,
            log: [String] = [], startDetail: String = "", installDetail: String = ""
        ) {
            var state = LifecycleState(info: info)
            state.phase = phase
            state.running = running
            state.environment = environment
            state.requested = requested ?? (environment != .missing)
            driver.setPreviewState(
                state, download: download, cache: diskBytes.map { ModelCacheStatus(cached: true, sizeBytes: $0, repoFolders: []) },
                log: log, startDetail: startDetail, installDetail: installDetail)
            if let running { openTryIt(port: running.port) }
        }
    }
#endif
