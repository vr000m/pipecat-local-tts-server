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
    /// Restore the services in the persisted wanted set after each launch's bootstrap
    /// (`RestorePolicy`). Default on when unset, see `RestorePreference`.
    /// Stored, so the gear menu's checkmark follows a click.
    var restoreOnLaunch: Bool {
        didSet { RestorePreference.set(restoreOnLaunch, in: preferences) }
    }
    /// The catalog's TTS / STT tab (remembered between launches).
    var catalogKind: ServiceKind = ServiceKind(rawValue: UserDefaults.standard.string(forKey: "catalogKind") ?? "") ?? .tts {
        didSet { UserDefaults.standard.set(catalogKind.rawValue, forKey: "catalogKind") }
    }

    /// `preferences` holds the restore preference and the wanted set
    /// (`PreferencesDomain`: the standard domain, or the suite a smoke run names).
    init(
        paths: AppPaths = .standard(), prober: any HelloProber = ExternalProbe(),
        preferences: UserDefaults = PreferencesDomain.defaults()
    ) {
        self.paths = paths
        self.prober = prober
        self.preferences = preferences
        restoreOnLaunch = RestorePreference.isOn(preferences)
        let wantedStore = UserDefaultsWantedServiceStore(defaults: preferences)
        self.wantedStore = wantedStore
        let lastUsedStore = UserDefaultsLastUsedStore(defaults: preferences)
        self.lastUsedStore = lastUsedStore
        services = Service.allCases.map {
            ServiceModel(info: $0.info, prober: prober, wanted: wantedStore, lastUsed: lastUsedStore)
        }
        for model in services { model.app = self }
    }

    /// The persisted "wanted running" set, shared by every service's driver.
    @ObservationIgnored private let wantedStore: any WantedServiceStore
    /// The model last started per category, shared by every service's driver (Reset clears it).
    @ObservationIgnored private let lastUsedStore: any LastUsedStore
    @ObservationIgnored private let preferences: UserDefaults
    /// The one restore this process may run, and the one gate for the Running panel's suggestion
    /// row (`suggestionsEnabled`). Observed, so the first render with it true already sees the
    /// restored services occupying their categories. Written in `restoreWantedServices()` after
    /// its start loop, and by `finishPreviewBootstrap()`; it stays false after a failed bootstrap.
    private var restoredThisProcess = false
    var suggestionsEnabled: Bool { restoredThisProcess }

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
    /// Ports of the services the app started (server or native), keyed by service: what the
    /// quit guard counts clients on. External servers are not the app's to protect.
    var ownedPorts: [Service: Int] { ServiceCounts.ownedPorts(states) }
    /// Each service's lifecycle state, keyed by service (the quit guard's and the restore's input).
    private var states: [Service: LifecycleState] {
        Dictionary(uniqueKeysWithValues: services.map { ($0.service, $0.driver.state) })
    }

    var anyActive: Bool { counts.active > 0 }

    /// The Running panel's active branch per kind: the active services plus the suggestion for an
    /// idle category (`SuggestionPolicy.panelListing`), mapped to models. The last-used read is
    /// untracked; the row refreshes because each write coincides with an observed state change.
    func panelEntries(_ kind: ServiceKind) -> [(entry: PanelEntry, model: ServiceModel)] {
        let lastUsed = Dictionary(
            uniqueKeysWithValues: ServiceKind.allCases.compactMap { k in
                lastUsedStore.lastUsed(k).map { (k, $0) }
            })
        let listing = SuggestionPolicy.panelListing(states: states, lastUsed: lastUsed, ready: suggestionsEnabled)
        return (listing[kind] ?? []).map { entry in
            switch entry {
            case .active(let service), .suggested(let service): (entry, model(service))
            }
        }
    }

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
            case .clearWantedServices:
                wantedStore.removeAll()
                lastUsedStore.removeAll()
            case .runReset:
                staleLayout = false
                let old = manager
                manager = nil
                job = Task { await runReset(old: old) }
            case .shutdown:
                // In this turn, before the shutdown task runs: a probe or read continuation
                // already queued on the main actor must not launch a server after Quit, nor a
                // queued ready, failure or exit move the wanted set (`WantedTransition`).
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
        // `RestorePolicy.shouldRun` owns the restore's phase gate (a bootstrap quit overtook
        // restores nothing); only a bootstrap that ended the job looks up sizes.
        restoreWantedServices()
        guard phase == .ready else { return }
        sizes = Task { await loadDownloadSizes() }
    }

    /// Starts the services the last session left running (`RestorePolicy`), once per process.
    private func restoreWantedServices() {
        guard RestorePolicy.shouldRun(alreadyRan: restoredThisProcess, phase: phase) else { return }
        let plan = RestorePolicy.plan(wanted: wantedStore.read(), states: states, preferenceOn: restoreOnLaunch)
        for model in services {
            switch plan[model.service] {
            case .start:
                Log.app.info("restore: starting \(model.service.rawValue, privacy: .public)")
                model.start(origin: .restore)
            case .skip(let reason) where reason != .notWanted:
                Log.app.info("restore: skipping \(model.service.rawValue, privacy: .public): \(String(describing: reason), privacy: .public)")
            default:
                break
            }
        }
        // After the loop, in the same main-actor turn: the first render with the gate true
        // already sees the restored services occupying their categories.
        restoredThisProcess = true
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

    /// App quit (and power-off), the synchronous half: the phase moves to `shuttingDown`, every
    /// driver's `quitting` is set and the shutdown task starts, all in the caller's turn. The
    /// delegate calls it in the main-actor turn that accepts the quit, so a ready, failure or exit
    /// callback already queued on the main actor runs with `quitting` set and can't move the
    /// wanted set. A second call does nothing (`AppLifecycle`: no event moves `shuttingDown`).
    func beginShutdown() { send(.quit) }

    /// App quit (and power-off): stops every running server (SIGTERM, 10 s
    /// grace, then SIGKILL), the bootstrap's subprocesses and the manager's
    /// (installs, cache probes), waits for busy families to drain
    /// (`EnvironmentManager.shutdown`), then for the bootstrap or Reset in
    /// flight. Begins the quit if `beginShutdown()` has not; every call waits
    /// for the same shutdown.
    func shutdownAll() async {
        beginShutdown()
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
        func finishPreviewBootstrap() {
            phase = .ready
            restoredThisProcess = true
        }
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
