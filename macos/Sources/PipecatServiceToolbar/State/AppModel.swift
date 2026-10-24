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
    private(set) var bootstrapping = true
    private(set) var setupError: String?
    private(set) var staleLayout = false
    var page: Page = .running
    /// Families of variants opened in the catalog's Available group.
    var expandedFamilies: Set<Service> = []
    /// The catalog's TTS / STT tab (remembered between launches).
    var catalogKind: ServiceKind = ServiceKind(rawValue: UserDefaults.standard.string(forKey: "catalogKind") ?? "") ?? .tts {
        didSet { UserDefaults.standard.set(catalogKind.rawValue, forKey: "catalogKind") }
    }

    init(paths: AppPaths = .standard()) {
        self.paths = paths
        services = Service.allCases.map { ServiceModel(info: $0.info) }
        for model in services { model.app = self }
    }

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
    var anyActive: Bool { services.contains(where: \.isActive) }

    /// Installed (or downloading) services that aren't running: what the main
    /// menu offers to start when nothing is running.
    func startable(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && !$0.isActive && ($0.isInstalled || $0.isInstalling) }
    }
    var anyStartable: Bool { ServiceKind.allCases.contains { !startable($0).isEmpty } }
    var running: [ServiceModel] { services.filter(\.isRunning) }

    func installed(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && $0.isInstalled && !$0.isActive }
    }

    func available(_ kind: ServiceKind) -> [ServiceModel] {
        services.filter { $0.kind == kind && !$0.isInstalled && !$0.isActive }
    }

    var anyInstalling: Bool {
        services.contains { if case .installing = $0.phase { true } else { false } }
    }

    var summary: String {
        if bootstrapping { return "Checking services…" }
        let runningCount = running.count
        let installedCount = services.filter(\.isInstalled).count
        switch (runningCount, installedCount) {
        case (0, 0): return "Add a model to get started"
        case (0, _): return "Nothing running · \(installedCount) installed"
        case (1, _): return "1 service running"
        default: return "\(runningCount) services running"
        }
    }

    var menuBarBadge: MenuBarArt.Badge {
        if anyInstalling { return .installing }
        return running.isEmpty ? .none : .running
    }

    // MARK: - Lifecycle

    func bootstrap() async {
        bootstrapping = true
        defer { bootstrapping = false }
        do {
            staleLayout = !(try paths.prepare())
        } catch {
            setupError = "Couldn't create \(paths.supportDir.path): \(error.localizedDescription)"
            return
        }
        do {
            let tools = try await ToolLocator.locate(paths: paths)
            self.tools = tools
            manager = EnvironmentManager(paths: paths, tools: tools)
            setupError = nil
            Log.app.info("tools from \(tools.source.rawValue, privacy: .public): uv=\(tools.uv.path, privacy: .public) wheel=\(tools.wheelName, privacy: .public) constraints=\(tools.constraints != nil)")
        } catch {
            setupError = error.localizedDescription
            Log.app.error("tool lookup failed: \(error.localizedDescription, privacy: .public)")
            for model in services { await model.refresh() }
            return
        }
        await withTaskGroup(of: Void.self) { group in
            for model in services {
                group.addTask { await model.refresh() }
            }
        }
        for model in services {
            Log.app.info("\(model.service.rawValue, privacy: .public): \(String(describing: model.phase), privacy: .public)")
        }
        Task { await loadDownloadSizes() }
    }

    /// Approximate sizes for providers that aren't installed, cached for a week.
    private func loadDownloadSizes() async {
        let defaults = UserDefaults.standard
        for model in services {
            guard let repo = model.info.modelRepo else { continue }
            let key = "hubSize.\(repo)"
            let stamp = defaults.double(forKey: key + ".at")
            if stamp > 0, Date().timeIntervalSince1970 - stamp < 7 * 86_400 {
                let cached = defaults.object(forKey: key) as? Int64
                model.approxDownloadBytes = cached
                continue
            }
            if let size = await HubSizes.downloadSize(repo: repo), size > 0 {
                model.approxDownloadBytes = size
                defaults.set(size, forKey: key)
                defaults.set(Date().timeIntervalSince1970, forKey: key + ".at")
            }
        }
    }

    /// Stops every running server (SIGTERM, 10 s grace, then SIGKILL).
    func shutdownAll() async {
        await withTaskGroup(of: Void.self) { group in
            for model in services {
                group.addTask { await model.shutdown() }
            }
        }
    }

    /// Deletes per-service environments left by an incompatible older layout.
    func resetLayout() {
        try? FileManager.default.removeItem(at: paths.envsDir)
        try? FileManager.default.removeItem(at: paths.layoutFile)
        staleLayout = false
        Task { await bootstrap() }
    }

    #if DEBUG
        func finishPreviewBootstrap() { bootstrapping = false }
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
        let env = ProcessInfo.processInfo.environment
        let hub: URL
        if let cache = env["HF_HUB_CACHE"] {
            hub = URL(filePath: cache)
        } else if let home = env["HF_HOME"] {
            hub = URL(filePath: home).appending(path: "hub")
        } else {
            hub = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".cache/huggingface/hub")
        }
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
