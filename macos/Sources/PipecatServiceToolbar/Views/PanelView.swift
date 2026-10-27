import AppKit
import PipecatToolbarCore
import SwiftUI

/// The menu bar panel: running services, the model catalog, or one service's page.
///
/// Every page has the same size. A `MenuBarExtra` window grows with its content
/// but doesn't reliably shrink back, so a page that changed the panel's height
/// would leave the next, shorter page floating in an oversized window.
struct PanelView: View {
    @Environment(AppModel.self) private var app

    static let width: CGFloat = 360
    static let height: CGFloat = 540

    var body: some View {
        ZStack {
            switch app.page {
            case .running:
                RunningView()
                    .transition(.asymmetric(insertion: .move(edge: .leading), removal: .move(edge: .leading)))
            case .catalog:
                CatalogView()
                    .transition(.move(edge: .trailing))
            case .detail(let service, _):
                ServiceDetailView(model: app.model(service))
                    .transition(.move(edge: .trailing))
            }
        }
        .frame(width: Self.width, height: Self.height)
        // Opaque, not the menu's translucent material: text contrast then
        // depends only on light/dark mode, never on the wallpaper behind it.
        .background(Color(nsColor: .windowBackgroundColor))
        .clipped()
        .animation(.snappy(duration: 0.28), value: app.page)
        // Discovery re-probes only while the panel is visible. UNVERIFIED: that a
        // `MenuBarExtra(.window)` content view gets both on every open and close
        // (a person must confirm; Phase 3 re-checks by hand).
        .onAppear { app.panelVisibilityChanged(true) }
        .onDisappear { app.panelVisibilityChanged(false) }
    }
}

// MARK: - Running services

struct RunningView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 0) {
            header
            if let banner = app.setupError {
                SetupBanner(message: banner)
            } else if app.staleLayout {
                StaleLayoutBanner()
            }
            Divider().opacity(0.5)
            Group {
                if app.anyActive {
                    // Something started: running services only.
                    serviceList { app.active($0) } row: { RunningRow(model: $0) }
                } else if app.anyStartable {
                    // Nothing running yet: the installed models, ready to start.
                    VStack(spacing: 0) {
                        Text("Start a model to serve it on its local port.")
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 16)
                            .padding(.top, 10)
                        serviceList { app.startable($0) } row: { CatalogRow(model: $0) }
                    }
                } else if app.bootstrapping {
                    ProgressView().controlSize(.small)
                } else {
                    EmptyRunningState()
                }
            }
            .frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterBar()
        }
    }

    /// Services grouped under Text to Speech / Speech to Text headers.
    private func serviceList<Row: View>(
        _ models: @escaping (ServiceKind) -> [ServiceModel], @ViewBuilder row: @escaping (ServiceModel) -> Row
    ) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(ServiceKind.allCases) { kind in
                    let group = models(kind)
                    if !group.isEmpty {
                        SectionHeader(kind: kind)
                        ForEach(group) { row($0) }
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)
            .padding(.bottom, 8)
        }
        .scrollIndicators(.never)
    }

    private var header: some View {
        HStack(spacing: 10) {
            AppGlyph()
            VStack(alignment: .leading, spacing: 1) {
                Text("Pipecat Service Toolbar").font(.system(size: 13.5, weight: .semibold)).lineLimit(1)
                Text(app.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            if app.bootstrapping {
                ProgressView().controlSize(.small)
            } else if app.anyInstalling {
                Button {
                    app.page = .catalog
                } label: {
                    Image(systemName: "arrow.down.circle.dotted")
                        .font(.system(size: 15))
                        .legibleTint(.blue)
                        .symbolEffect(.pulse)
                }
                .buttonStyle(.plain)
                .help("A model is downloading. Click to see it in Add Models.")
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 12)
        .padding(.bottom, 10)
    }
}

struct SectionHeader: View {
    let kind: ServiceKind

    var body: some View {
        Label(kind.title, systemImage: kind == .tts ? "speaker.wave.2.fill" : "mic.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

struct EmptyRunningState: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        VStack(spacing: 10) {
            PipecatMark()
                .fill(.quaternary)
                .frame(width: 72, height: 42)
            Text("No models installed")
                .font(.system(size: 13, weight: .semibold))
            Text("Download a speech model to serve it on a local port for your Pipecat apps.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 30)
            Button {
                app.page = .catalog
            } label: {
                Label("Add Models", systemImage: "plus")
            }
            .buttonStyle(PillButtonStyle(tint: .accentColor, prominent: true))
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity)
        .padding(.bottom, 24)
    }
}

/// A started service: endpoint, quick copy, stop.
struct RunningRow: View {
    @Environment(AppModel.self) private var app
    let model: ServiceModel

    var body: some View {
        HStack(spacing: 10) {
            ProviderTile(info: model.info, size: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.info.displayName).font(.system(size: 13, weight: .medium))
                status
            }
            Spacer(minLength: 6)
            trailing
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { app.show(model.service) }
        .contextMenu { ServiceMenuItems(model: model) }
    }

    @ViewBuilder private var status: some View {
        HStack(spacing: 5) {
            switch model.phase {
            case .running:
                StatusDot(color: .green)
                Text(verbatim: "127.0.0.1:\(model.port)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .external:
                StatusDot(color: model.isExternalNotResponding ? .orange : .green)
                Text(verbatim: model.externalStatusLine)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            case .starting:
                StatusDot(color: .orange)
                Text(model.info.needsModelDownload ? "Loading model…" : "Starting…")
                    .foregroundStyle(.secondary)
            case .stopping:
                StatusDot(color: .orange)
                Text("Stopping…").foregroundStyle(.secondary)
            case .failed(let failure):
                Image(systemName: "exclamationmark.triangle.fill").legibleTint(.red).imageScale(.small)
                Text(failure.title).legibleTint(.red)
            default:
                EmptyView()
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    @ViewBuilder private var trailing: some View {
        switch model.phase {
        case .running:
            HStack(spacing: 2) {
                CopyButton(text: "ws://\(ServiceCatalog.host):\(model.port)/", help: "Copy URL")
                IconButton(systemImage: "stop.fill", help: "Stop") { model.stop() }
            }
        case .external(let port, _):
            // Observe and copy only (`ExternalPresentation.Actions`): the app never stops a server it did not start.
            let actions = model.externalActions
            HStack(spacing: 2) {
                if actions?.copyURL == true {
                    CopyButton(text: "ws://\(ServiceCatalog.host):\(port)/", help: "Copy URL")
                }
                if actions?.stop == true {
                    IconButton(systemImage: "stop.fill", help: "Stop") { model.stop() }
                }
            }
        case .starting, .stopping:
            ProgressView().controlSize(.small).frame(width: 44)
        case .failed:
            Button("Retry") { model.start() }.buttonStyle(PillButtonStyle(tint: .red))
                .disabled(!model.acceptsActions)
        default:
            EmptyView()
        }
    }
}

// MARK: - Catalog ("Add Models")

struct CatalogView: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        @Bindable var app = app
        VStack(spacing: 0) {
            TopBar(title: "Add Models", backTitle: "Running") { app.page = .running }
            Picker("Type", selection: $app.catalogKind) {
                ForEach(ServiceKind.allCases) { kind in
                    Text(kind.title).tag(kind)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
            Divider().opacity(0.5)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    let active = app.active(app.catalogKind)
                    if !active.isEmpty { group("Running", active) }
                    group("Installed", app.installed(app.catalogKind))
                    availableGroup(app.available(app.catalogKind))
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterBar(showsAddModels: false)
        }
    }

    @ViewBuilder
    private func group(_ title: String, _ models: [ServiceModel]) -> some View {
        if !models.isEmpty {
            groupTitle(title)
            ForEach(models) { CatalogRow(model: $0) }
        }
    }

    /// Not yet installed: a family of variants shares one row that expands to list them.
    @ViewBuilder
    private func availableGroup(_ models: [ServiceModel]) -> some View {
        if !models.isEmpty {
            groupTitle("Available")
            ForEach(CatalogEntry.grouping(models)) { entry in
                switch entry {
                case .single(let model): CatalogRow(model: model)
                case .family(let variants): FamilyRow(variants: variants)
                }
            }
        }
    }

    private func groupTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
            .padding(.top, 8)
            .padding(.bottom, 2)
    }
}

/// One row of the catalog's Available group.
enum CatalogEntry: Identifiable {
    case single(ServiceModel)
    /// Two or more variants of one family (Phonon full precision, 8-bit, 4-bit).
    case family([ServiceModel])

    var id: Service {
        switch self {
        case .single(let model): model.id
        case .family(let variants): variants[0].id.family
        }
    }

    /// Groups variants by family, in catalog order.
    static func grouping(_ models: [ServiceModel]) -> [CatalogEntry] {
        var seen = Set<Service>()
        return models.compactMap { model in
            guard seen.insert(model.info.family).inserted else { return nil }
            let variants = models.filter { $0.info.family == model.info.family }
            return variants.count > 1 ? .family(variants) : .single(model)
        }
    }
}

/// A family of weights variants. It expands to list each variant as its own
/// entry: each installs separately and serves on its own port, so siblings
/// can run side by side.
struct FamilyRow: View {
    @Environment(AppModel.self) private var app
    let variants: [ServiceModel]

    private var family: ServiceInfo { variants[0].info.family.info }
    /// A variant that's downloading or failed keeps the family open.
    private var pinnedOpen: Bool {
        variants.contains { model in
            if case .failed = model.phase { return true }
            return model.isBusy
        }
    }
    private var expanded: Bool { pinnedOpen || app.expandedFamilies.contains(family.service) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                ProviderTile(info: family)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 5) {
                        Text(family.displayName).font(.system(size: 13, weight: .medium))
                        if family.licence.isRestrictive {
                            LicenceBadge(licence: family.licence)
                        }
                    }
                    Text("\(variants.count) options · \(family.tagline)")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 6)
                if !pinnedOpen {
                    if expanded {
                        IconButton(systemImage: "chevron.up", help: "Hide options") { toggle() }
                            .frame(width: 54)
                    } else {
                        Button(action: toggle) {
                            HStack(spacing: 3) {
                                Text("Get")
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold))
                            }
                        }
                        .buttonStyle(PillButtonStyle())
                        .help("Choose which \(family.displayName) weights to download")
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .contentShape(Rectangle())
            .hoverHighlight()
            .onTapGesture { toggle() }

            if expanded {
                VStack(spacing: 0) {
                    ForEach(variants) { VariantRow(model: $0) }
                }
                // Under the family's name, with a rule down from its tile.
                .padding(.leading, 44)
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.12))
                        .frame(width: 2)
                        .padding(.vertical, 6)
                        .padding(.leading, 24)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.snappy(duration: 0.22), value: expanded)
    }

    private func toggle() {
        guard !pinnedOpen else { return }
        if app.expandedFamilies.contains(family.service) {
            app.expandedFamilies.remove(family.service)
        } else {
            app.expandedFamilies.insert(family.service)
        }
    }
}

/// One variant in an expanded `FamilyRow`: it installs, and later runs, on its own.
struct VariantRow: View {
    @Environment(AppModel.self) private var app
    let model: ServiceModel

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.info.variantLabel ?? model.info.displayName)
                    .font(.system(size: 12.5, weight: .medium))
                CatalogSubtitle(model: model, note: model.info.variantDetail)
            }
            Spacer(minLength: 6)
            CatalogAction(model: model)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { app.show(model.service) }
        .contextMenu { ServiceMenuItems(model: model) }
        .help("\(model.info.displayName), served on port \(model.info.port)")
    }
}

struct CatalogRow: View {
    @Environment(AppModel.self) private var app
    let model: ServiceModel

    var body: some View {
        HStack(spacing: 10) {
            ProviderTile(info: model.info)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(model.info.displayName).font(.system(size: 13, weight: .medium))
                    if model.info.isDefault {
                        Badge(text: "Default", color: .accentColor)
                    }
                    if model.info.licence.isRestrictive {
                        LicenceBadge(licence: model.info.licence)
                    }
                }
                // A variant's name already says which family it's from.
                CatalogSubtitle(model: model, note: model.info.family != model.service ? model.info.variantDetail : nil)
            }
            Spacer(minLength: 6)
            CatalogAction(model: model)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .hoverHighlight()
        .onTapGesture { app.show(model.service) }
        .contextMenu { ServiceMenuItems(model: model) }
    }
}

struct CatalogSubtitle: View {
    let model: ServiceModel
    /// Replaces the tagline beside the download size.
    var note: String? = nil

    var body: some View {
        HStack(spacing: 4) {
            switch model.phase {
            case .checking:
                Text("Checking…").foregroundStyle(.secondary)
            case .unavailable(let why):
                Text(why).foregroundStyle(.secondary)
            case .notInstalled:
                Text(availableText).foregroundStyle(.secondary)
            case .needsModel:
                Text("Model not downloaded").legibleTint(.orange)
            case .installing(let stage):
                Text(installingText(stage)).foregroundStyle(.secondary).monospacedDigit()
            case .installed:
                Text(readyText).foregroundStyle(.secondary)
            case .starting:
                Text("Starting…").foregroundStyle(.secondary)
            case .running:
                StatusDot(color: .green)
                Text(verbatim: "Running on :\(model.port)").foregroundStyle(.secondary)
            case .external:
                StatusDot(color: model.isExternalNotResponding ? .orange : .green)
                Text(verbatim: model.externalStatusLine).foregroundStyle(.secondary)
            case .stopping:
                Text("Stopping…").foregroundStyle(.secondary)
            case .removing:
                Text("Deleting…").foregroundStyle(.secondary)
            case .failed(let failure):
                Image(systemName: "exclamationmark.triangle.fill").legibleTint(.red).imageScale(.small)
                Text(failure.title).legibleTint(.red)
            }
        }
        .font(.system(size: 11))
        .lineLimit(1)
    }

    private var availableText: String {
        let text = note ?? model.info.tagline
        if let bytes = model.approxDownloadBytes { return "\(Format.bytes(bytes)) · \(text)" }
        return text
    }

    private var readyText: String {
        if let bytes = model.diskBytes { return "Ready · \(Format.bytes(bytes))" }
        return "Ready"
    }

    private func installingText(_ stage: InstallStage) -> String {
        if stage == .model, let d = model.download, d.totalBytes > 0 {
            return "\(Format.bytes(d.downloadedBytes)) of \(Format.bytes(d.totalBytes))"
        }
        if stage == .model, let fraction = model.assetProgress {
            return "Downloading model · \(Int(fraction * 100))%"
        }
        return stage.title + "…"
    }
}

struct CatalogAction: View {
    let model: ServiceModel

    /// Disabled while the app can't run them (`AppPhase.acceptsServiceActions`).
    var body: some View {
        action.disabled(!model.acceptsActions)
    }

    @ViewBuilder private var action: some View {
        switch model.phase {
        case .checking, .starting, .stopping, .removing:
            ProgressView().controlSize(.small).frame(width: 54)
        case .unavailable:
            EmptyView()
        case .notInstalled:
            Button("Get") { model.install() }.buttonStyle(PillButtonStyle())
        case .needsModel:
            Button("Resume") { model.install() }.buttonStyle(PillButtonStyle(tint: .orange))
        case .installing(let stage):
            ProgressRing(fraction: stage == .model ? model.installFraction : nil) { model.cancelInstall() }
                .frame(width: 54)
        case .installed:
            Button("Start") { model.start() }.buttonStyle(PillButtonStyle(tint: .green, prominent: true))
        case .running:
            Button("Stop") { model.stop() }.buttonStyle(PillButtonStyle(tint: .secondary))
        case .external:
            // `ExternalPresentation.Actions`: no Get or Install for a server the app did not start.
            if model.externalActions?.get == true || model.externalActions?.install == true {
                Button("Get") { model.install() }.buttonStyle(PillButtonStyle())
            }
        case .failed(let failure):
            switch failure.kind {
            case .install, .download:
                Button("Retry") { model.install() }.buttonStyle(PillButtonStyle(tint: .red))
            case .crashed, .startup, .portBusy:
                Button("Retry") { model.start() }.buttonStyle(PillButtonStyle(tint: .orange))
            }
        }
    }
}

// MARK: - Shared pieces

/// The right-click menu for a service, wherever it appears.
struct ServiceMenuItems: View {
    @Environment(AppModel.self) private var app
    let model: ServiceModel

    var body: some View {
        let info = model.info
        // An External row offers what `ExternalPresentation.Actions` allows; every other row all of them.
        let external = model.externalActions
        if external?.copyURL ?? true {
            Button("Copy URL") { Pasteboard.copy("ws://\(ServiceCatalog.host):\(model.port)/") }
        }
        if external?.copyPipecatService ?? true {
            Button("Copy Pipecat Service") { Pasteboard.copy(info.pipecatService(port: model.port)) }
        }
        if external?.copyEnvironment ?? true {
            Button("Copy Environment Variables") { Pasteboard.copy(info.environment(port: model.port)) }
        }
        Divider()
        // Disabled while the app can't run them (`AppPhase.acceptsServiceActions`).
        action.disabled(!model.acceptsActions)
        if model.isRunning, external?.tryIt ?? true {
            // Opens the detail view, which shows the result (playing, transcript, or error).
            Button(model.kind == .tts ? "Test Voice" : "Test Transcription") {
                app.show(model.service)
                Task { await model.runTest() }
            }
            .disabled(!model.acceptsActions)
        }
        Button("Show Details") { app.show(model.service) }
        if model.canDeleteModel {
            Divider()
            Button("Delete Model…", role: .destructive) { app.confirmDelete(model) }
                .disabled(!model.acceptsActions)
        }
    }

    @ViewBuilder private var action: some View {
        switch model.phase {
        case .running:
            Button("Stop") { model.stop() }
        case .external:
            if model.externalActions?.stop == true { Button("Stop") { model.stop() } }
        case .installed:
            Button("Start") { model.start() }
        case .notInstalled, .needsModel:
            Button("Download") { model.install() }
        case .failed(let failure):
            Button(failure.isRuntime ? "Start" : "Retry Download") {
                failure.isRuntime ? model.start() : model.install()
            }
        default:
            EmptyView()
        }
    }
}

struct TopBar: View {
    let title: String
    let backTitle: String
    let back: () -> Void

    var body: some View {
        ZStack {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack {
                Button(action: back) {
                    HStack(spacing: 3) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .semibold))
                        Text(backTitle).font(.system(size: 12.5))
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .keyboardShortcut(.escape, modifiers: [])
                Spacer()
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

struct FooterBar: View {
    @Environment(AppModel.self) private var app
    var showsAddModels = true

    var body: some View {
        HStack(spacing: 10) {
            if showsAddModels {
                Button {
                    app.page = .catalog
                } label: {
                    Label("Add Models", systemImage: "plus.circle")
                        .font(.system(size: 12))
                }
                .buttonStyle(.borderless)
            }
            Spacer()
            Menu {
                Button("Open Logs Folder") { app.openLogsFolder() }
                Button("Open Models Folder") { app.openModelsFolder() }
                Button("Open App Data Folder") { app.openDataFolder() }
                if app.canManageLoginItem {
                    Divider()
                    Toggle("Open at Login", isOn: Binding(get: { app.opensAtLogin }, set: { app.opensAtLogin = $0 }))
                }
                Divider()
                Button(quitTitle) { NSApp.terminate(nil) }
                    .keyboardShortcut("q")
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Settings and Quit")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        // ⌘Q while the panel is open, without the menu having to be open.
        .background {
            Button(quitTitle) { NSApp.terminate(nil) }
                .keyboardShortcut("q")
                .hidden()
        }
    }

    private var quitTitle: String { app.quitTitle }
}

struct SetupBanner: View {
    @Environment(AppModel.self) private var app
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").legibleTint(.orange)
            VStack(alignment: .leading, spacing: 4) {
                Text(message).font(.system(size: 11.5)).fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { app.retryBootstrap() }
                    .disabled(!app.canRetryBootstrap)
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}

struct StaleLayoutBanner: View {
    @Environment(AppModel.self) private var app

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.2.circlepath").legibleTint(.orange)
            Text("Environments from another app version were found.")
                .font(.system(size: 11.5))
            Spacer()
            Button("Reset") { app.resetLayout() }.buttonStyle(PillButtonStyle(tint: .orange))
                .disabled(!app.canReset)
        }
        .padding(10)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }
}
