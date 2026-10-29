import AppKit
import Foundation
import Observation
import PipecatToolbarCore
import ServiceManagement

/// Root state: locates the tools, owns every `ServiceModel`, drives panel
/// navigation, and tears servers down when the app quits.
@MainActor
@Observable
final class AppModel {
    /// The panel's pages: running services, the model catalog, one service's detail.
    enum Page: Equatable {
        case running
        case catalog
        case detail(Service, from: Page.Origin)

        enum Origin: Equatable { case running, catalog }
    }

    let paths: AppPaths
    let services: [ServiceModel]
    private(set) var tools: Tools?
    private(set) var manager: EnvironmentManager?
    /// The app-wide phase (`AppLifecycle`): bootstrap, Reset and quit.
    private(set) var phase: AppPhase = .idle
    private(set) var staleLayout = false
    /// The bootstrap's own subprocesses (the repository wheel build), stopped on quit.
    @ObservationIgnored private var bootstrapProcesses = ProcessRegistry()
    /// The one bootstrap or Reset in flight (`AppPhase.hasJob`), awaited by quit.
    @ObservationIgnored private var job: Task<Void, Never>?
    /// The download-size lookup a finished bootstrap starts, cancelled by quit.
    @ObservationIgnored private var sizes: Task<Void, Never>?
    /// The quit shutdown, shared by every quit request.
    @ObservationIgnored private var shutdownTask: Task<Void, Never>?
    /// Finds servers already running on the catalog ports (one pass at bootstrap, on panel open and every 15 s).
    @ObservationIgnored private(set) lazy var discovery = ExternalDiscovery(app: self, prober: prober)
    /// The one hello prober: discovery's passes and every service's Start-path probe use it.
    @ObservationIgnored let prober: any HelloProber
    var page: Page = .running
    /// Families of variants opened in the catalog's Available group.
    var expandedFamilies: Set<Service> = []
    /// The catalog's TTS / STT tab (remembered between launches).
    var catalogKind: ServiceKind = ServiceKind(rawValue: UserDefaults.standard.string(forKey: "catalogKind") ?? "") ?? .tts {
        didSet { UserDefaults.standard.set(catalogKind.rawValue, forKey: "catalogKind") }
    }

    init(paths: AppPaths = .standard(), prober: any HelloProber = ExternalProbe()) {
        self.paths = paths
        self.prober = prober
        services = Service.allCases.map { ServiceModel(info: $0.info, prober: prober) }
        for model in services {
            model.app = self
            model.driver.dependencies.wanted = wantedStore
        }
    }

    /// The persisted "wanted running" set, shared by every service's driver.
    @ObservationIgnored let wantedStore: any WantedServiceStore = UserDefaultsWantedServiceStore()
    /// The one restore this process may run.
    @ObservationIgnored private var restoredThisProcess = false

    func model(_ service: Service) -> ServiceModel {
        services.first { $0.service == service }!
    }

    /// The other variants that share `model`'s environment.
    func siblings(of model: ServiceModel) -> [ServiceModel] {
        services.filter { $0.info.family == model.info.family && $0 !== model }
    }

    /// Lets a model's siblings re-read the environment it just built, updated or removed.
    func familyChanged(by model: ServiceModel) async {
        for sibling in siblings(of: model) { await sibling.environmentChanged() }
    }

    func show(_ service: Service) {
        page = .detail(service, from: page == .catalog ? .catalog : .running)
    }

    func back() {
        if case .detail(_, let origin) = page {
            page = origin == .catalog ? .catalog : .running
        } else {
            page = .running
        }
    }

    /// Services the user started (running, starting, stopping or failed at runtime).
    func active(_ kind: ServiceKind) -> [ServiceModel] { services.filter { $0.kind == kind && $0.isActive } }
    /// The menu's counting (`ServiceCounts`, Core): External services count as running.
    var counts: ServiceCounts { ServiceCounts(services.map { $0.driver.state }) }
    var anyActive: Bool { counts.active > 0 }

    /// Installed (or downloading) services that aren't running: what the main
    /// menu offers to start when nothing is running (`ServiceCounts.isStartable`, Core).
    func startable(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && ServiceCounts.isStartable($0.driver.state) }
    }
    var anyStartable: Bool { counts.startable > 0 }
    var running: [ServiceModel] { services.filter(\.isRunning) }

    func installed(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && $0.isInstalled && !$0.isActive }
    }

    func available(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && !$0.isInstalled && !$0.isActive }
    }

    var anyInstalling: Bool { counts.installing > 0 }

    /// Nothing known yet, or a bootstrap / Reset re-reads it.
    var bootstrapping: Bool { phase.isChecking }
    var setupError: String? { phase.setupError }
    var canRetryBootstrap: Bool { phase.canRetryBootstrap }

    var summary: String {
        counts.summary(bootstrapping: bootstrapping)
    }

    var menuBarBadge: MenuBarArt.Badge { counts.badge }

    /// The Stop-and-Quit title: only servers the app started are stopped.
    var quitTitle: String { counts.quitTitle }

    /// The panel opened or closed (`PanelView.onAppear` / `onDisappear`): discovery runs a
    /// pass now and every 15 s while it is open.
    func panelVisibilityChanged(_ visible: Bool) {
        guard phase != .shuttingDown else { return }
        Log.app.info("panel visible: \(visible, privacy: .public)")
        discovery.setPanelVisible(visible)
    }

    // MARK: - Lifecycle

    /// Applies `event` to the phase and runs what it asks for. The phase moves
    /// here, synchronously, before any job's task starts.
    private func send(_ event: AppEvent) {
        for effect in AppLifecycle.reduce(&phase, event) {
            switch effect {
            case .runBootstrap: job = Task { await runBootstrap() }
            case .clearWantedServices: wantedStore.removeAll()
            case .runReset:
                staleLayout = false
                let old = manager
                manager = nil
                job = Task { await runReset(old: old) }
            case .shutdown:
                // In this turn, before the shutdown task runs: a probe or read continuation
                // already queued on the main actor must not launch a server after Quit.
                for model in services { model.driver.beginQuit() }
                shutdownTask = Task { await runShutdown() }
            }
        }
    }

    /// App launch.
    func bootstrap() { send(.bootstrap) }

    /// Try Again (refused while a bootstrap runs).
    func retryBootstrap() { send(.retry) }

    private func runBootstrap() async {
        do {
            staleLayout = !(try paths.prepare())
        } catch {
            send(.bootstrapFailed("Couldn't create \(paths.supportDir.path): \(error.localizedDescription)"))
            return
        }
        do {
            let tools = try await ToolLocator.locate(paths: paths, processes: bootstrapProcesses)
            // Quit began: install no manager it would not shut down.
            guard phase == .bootstrapping else { return }
            self.tools = tools
            manager = EnvironmentManager(paths: paths, tools: tools)
            Log.app.info("tools from \(tools.source.rawValue, privacy: .public): uv=\(tools.uv.path, privacy: .public) wheel=\(tools.wheelName, privacy: .public) constraints=\(tools.constraints != nil)")
        } catch {
            Log.app.error("tool lookup failed: \(error.localizedDescription, privacy: .public)")
            for model in services { await model.refresh() }
            send(.bootstrapFailed(error.localizedDescription))
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for model in services {
                group.addTask { await model.refresh() }
            }
        }
        // The one discovery pass at launch (before the panel is ever opened), so the
        // phase lines below show a server that was already running as External.
        await discovery.runPass()
        for model in services {
            Log.app.info("\(model.service.rawValue, privacy: .public): \(String(describing: model.phase), privacy: .public)")
        }
        send(.bootstrapDone)
        // Only a bootstrap that ended the job (not one quit overtook) looks up sizes.
        guard phase == .ready else { return }
        restoreWantedServices()
        sizes = Task { await loadDownloadSizes() }
    }

    /// Starts the services the last session left running (`RestorePolicy`), once per process.
    private func restoreWantedServices() {
        guard !restoredThisProcess, phase == .ready else { return }
        restoredThisProcess = true
        let states = Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0.driver.state) })
        let plan = RestorePolicy.plan(wanted: wantedStore.read(), states: states, preferenceOn: restoreOnLaunch)
        for model in services {
            switch plan[model.service] {
            case .start:
                Log.app.info("restore: starting \(model.service.rawValue, privacy: .public)")
                model.start()
            case .skip(let reason) where reason != .notWanted:
                Log.app.info("restore: skipping \(model.service.rawValue, privacy: .public): \(String(describing: reason), privacy: .public)")
            default:
                break
            }
        }
    }

    /// Approximate sizes for providers that aren't installed, cached for a week.
    private func loadDownloadSizes() async {
        let defaults = UserDefaults.standard
        for model in services where !Task.isCancelled {
            guard model.info.modelRepo != nil else { continue }
            // Per service: a service's total spans several snapshots (the old `hubSize.<repo>` keys are left unread).
            let key = "hubSize.service.\(model.service.rawValue)"
            let stamp = defaults.double(forKey: key + ".at")
            if stamp > 0, Date().timeIntervalSince1970 - stamp < 7 * 86_400 {
                let cached = defaults.object(forKey: key) as? Int64
                model.approxDownloadBytes = cached
                continue
            }
            if let size = await HubSizes.downloadSize(of: model.service), size > 0 {
                model.approxDownloadBytes = size
                defaults.set(size, forKey: key)
                defaults.set(Date().timeIntervalSince1970, forKey: key + ".at")
            }
        }
    }

    /// App quit (and power-off): stops every running server (SIGTERM, 10 s
    /// grace, then SIGKILL), the bootstrap's subprocesses and the manager's
    /// (installs, cache probes), waits for busy families to drain
    /// (`EnvironmentManager.shutdown`), then for the bootstrap or Reset in
    /// flight. Every call waits for the same shutdown.
    func shutdownAll() async {
        send(.quit)
        await shutdownTask?.value
    }

    private func runShutdown() async {
        discovery.stop()
        sizes?.cancel()
        let manager = self.manager
        await withTaskGroup(of: Void.self) { group in
            for model in services {
                group.addTask { await model.shutdown() }
            }
            // The discovery pass `stop()` cancelled, with its probes and owner lookups.
            let discovery = self.discovery
            group.addTask { await discovery.drain() }
            let processes = bootstrapProcesses
            group.addTask { await processes.shutdown() }
            if let manager {
                group.addTask { await manager.shutdown() }
            }
        }
        // The job in flight unwinds (a Reset finishes its shutdown and deletion);
        // after quit it starts no other.
        await job?.value
    }

    /// Reset is offered only when the reducer would accept it
    /// (`AppPhase.allowsReset`): it deletes the environments and swaps the manager.
    var canReset: Bool { phase.allowsReset(servicesBusy: servicesBusy) }

    private var servicesBusy: Bool { counts.blocksReset }

    /// Whether `model`'s Get / Start / Delete can run now (`AppPhase.acceptsServiceActions`):
    /// the views disable them otherwise, so a Start during Reset can't fail on the missing manager.
    func acceptsActions(_ model: ServiceModel) -> Bool {
        phase.acceptsServiceActions(usesPython: model.info.runtime.usesPython, managerInstalled: manager != nil)
    }

    /// Deletes per-service environments left by an incompatible older layout.
    func resetLayout() { send(.reset(servicesBusy: servicesBusy)) }

    /// The old manager is shut down (its probes stopped) before the environments go.
    private func runReset(old: EnvironmentManager?) async {
        await old?.shutdown()
        try? FileManager.default.removeItem(at: paths.envsDir)
        try? FileManager.default.removeItem(at: paths.layoutFile)
        send(.resetDone)
    }

    #if DEBUG
        func finishPreviewBootstrap() { phase = .ready }
    #endif

    // MARK: - Settings

    var opensAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    /// Restore the services that were running at the last quit (default on when unset).
    var restoreOnLaunch: Bool {
        get { UserDefaults.standard.object(forKey: "restoreOnLaunch") == nil ? true : UserDefaults.standard.bool(forKey: "restoreOnLaunch") }
        set { UserDefaults.standard.set(newValue, forKey: "restoreOnLaunch") }
    }

    var canManageLoginItem: Bool { tools?.source == .bundle }

    func openLogsFolder() {
        try? FileManager.default.createDirectory(at: paths.logsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(paths.logsDir)
    }

    func openModelsFolder() {
        let hub = AppPaths.huggingFaceHub()
        NSWorkspace.shared.open(FileManager.default.fileExists(atPath: hub.path) ? hub : hub.deletingLastPathComponent())
    }

    func openDataFolder() {
        NSWorkspace.shared.open(paths.supportDir)
    }

    /// Asks before deleting a service's environment and downloaded model files.
    func confirmDelete(_ model: ServiceModel) {
        let alert = NSAlert()
        alert.messageText = "Delete \(model.info.displayName)?"
        let keeping = siblings(of: model).filter(\.isInstalled).map(\.info.displayName)
        var detail: String
        if keeping.isEmpty {
            detail = "This removes its Python environment"
            if model.info.needsModelDownload {
                detail += " and downloaded model files"
                if let bytes = model.diskBytes { detail += " (\(Format.bytes(bytes)))" }
            }
            detail += "."
        } else {
            detail = "This removes its model files. Files and the Python environment shared with "
                + "\(keeping.formatted(.list(type: .and))) stay."
        }
        if keeping.isEmpty, model.info.needsModelDownload {
            // The weights live in the shared Hugging Face cache, not in the app.
            detail += " The model files are in the shared Hugging Face cache, so a command-line or launchd "
                + "server using the same model will download them again."
        }
        alert.informativeText = detail + " You can download it again later."
        alert.alertStyle = .warning
        let delete = alert.addButton(withTitle: "Delete")
        delete.hasDestructiveAction = true
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            model.remove(deleteModel: true)
        }
    }
}
