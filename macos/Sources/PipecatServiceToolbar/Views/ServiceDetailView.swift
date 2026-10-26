import PipecatToolbarCore
import SwiftUI

struct ServiceDetailView: View {
    @Environment(AppModel.self) private var app
    let model: ServiceModel

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider().opacity(0.5)
            ScrollView {
                VStack(spacing: 12) {
                    hero
                    primaryAction
                        .disabled(!model.acceptsActions)
                    if case .installing(let stage) = model.phase {
                        InstallProgressCard(model: model, stage: stage)
                    }
                    if case .failed(let failure) = model.phase {
                        FailureCard(model: model, failure: failure)
                    }
                    if let warning = model.warning {
                        Label(warning, systemImage: "exclamationmark.circle")
                            .font(.system(size: 11.5))
                            .legibleTint(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if model.isRunning, let tryIt = model.ttsTryIt {
                        TryItCard(session: tryIt)
                    }
                    if model.isRunning, let tryIt = model.sttTryIt {
                        STTTryItCard(session: tryIt)
                    }
                    ConnectionCard(model: model)
                    DetailsCard(model: model)
                    if !model.log.isEmpty {
                        LogCard(model: model)
                    }
                    if model.canDeleteModel, !model.isBusy {
                        RemoveSection(model: model)
                            .disabled(!model.acceptsActions)
                    }
                }
                .padding(14)
            }
            .scrollIndicators(.never)
            .frame(maxHeight: .infinity)
            Divider().opacity(0.5)
            FooterBar()
        }
    }

    private var topBar: some View {
        let fromCatalog: Bool = {
            if case .detail(_, let origin) = app.page { return origin == .catalog }
            return false
        }()
        return TopBar(title: model.info.kind.title, backTitle: fromCatalog ? "Add Models" : "Running") {
            app.back()
        }
    }

    private var hero: some View {
        HStack(alignment: .center, spacing: 12) {
            ProviderTile(info: model.info, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.info.displayName).font(.system(size: 17, weight: .semibold))
                Text(model.info.tagline)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    StatusBadge(model: model)
                    LicenceBadge(licence: model.info.licence)
                }
                .padding(.top, 1)
            }
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch model.phase {
        case .notInstalled:
            wideButton(downloadTitle, systemImage: "arrow.down.circle.fill", tint: .accentColor) { model.install() }
        case .needsModel:
            wideButton("Resume Download", systemImage: "arrow.down.circle.fill", tint: .orange) { model.install() }
        case .installed:
            wideButton("Start Server", systemImage: "play.fill", tint: .green) { model.start() }
        case .running:
            wideButton("Stop Server", systemImage: "stop.fill", tint: .secondary) { model.stop() }
        case .external:
            // No Stop, Delete, Get or Install: the app did not start this server and leaves it running.
            Label(
                model.externalFailures > 0
                    ? "Not responding right now. Running outside the app (\(model.externalSource)); Quit leaves it running."
                    : "Running outside the app (\(model.externalSource)). Quit leaves it running.",
                systemImage: "network"
            )
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(10)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            if model.externalActions?.tryIt == true, model.ttsTryIt == nil, model.sttTryIt == nil {
                wideButton("Open Try It", systemImage: "play.circle", tint: .accentColor) { model.requestTryIt() }
            }
        case .starting:
            busyRow(model.startDetail.isEmpty ? "Starting…" : model.startDetail) {
                Button("Cancel") { model.stop() }.buttonStyle(.borderless).font(.system(size: 12))
            }
        case .stopping:
            busyRow("Stopping…") { EmptyView() }
        case .removing:
            busyRow("Removing…") { EmptyView() }
        case .checking:
            busyRow("Checking…") { EmptyView() }
        case .unavailable(let why):
            Label(why, systemImage: "info.circle")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        case .installing, .failed:
            EmptyView()
        }
    }

    private var downloadTitle: String {
        if let bytes = model.approxDownloadBytes { return "Download · \(Format.bytes(bytes))" }
        return model.info.runtime == .appleSpeech ? "Download Speech Model" : (model.info.needsModelDownload ? "Download" : "Install")
    }

    private func wideButton(_ title: String, systemImage: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: systemImage)
        }
        .buttonStyle(WideButtonStyle(tint: tint))
    }

    private func busyRow<Trailing: View>(_ text: String, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .frame(minHeight: 36)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}

struct StatusBadge: View {
    let model: ServiceModel
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let (text, color) = descriptor
        HStack(spacing: 4) {
            StatusDot(color: color, pulsing: model.phase == .running)
            Text(text).font(.system(size: 10.5, weight: .semibold)).foregroundStyle(color.legible(in: scheme))
        }
    }

    private var descriptor: (String, Color) {
        switch model.phase {
        case .checking: ("Checking", .secondary)
        case .unavailable: ("Unavailable", .secondary)
        case .notInstalled: ("Not installed", .secondary)
        case .needsModel: ("Model missing", .orange)
        case .installing: ("Installing", .blue)
        case .installed: ("Ready", .secondary)
        case .starting: ("Starting", .orange)
        case .running: ("Running", .green)
        case .external: ("External", .blue)
        case .stopping: ("Stopping", .orange)
        case .removing: ("Deleting", .orange)
        case .failed: ("Error", .red)
        }
    }
}

struct InstallProgressCard: View {
    let model: ServiceModel
    let stage: InstallStage

    private let stages: [InstallStage] = [.python, .environment, .packages, .model]

    var body: some View {
        Card {
            HStack {
                Text(stage.title).font(.system(size: 12.5, weight: .medium))
                Spacer()
                Button("Cancel") { model.cancelInstall() }
                    .buttonStyle(.borderless)
                    .font(.system(size: 12))
            }
            if stage == .model, let fraction = model.installFraction {
                ProgressView(value: fraction).progressViewStyle(.linear)
            } else {
                ProgressView().progressViewStyle(.linear)
            }
            HStack {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .monospacedDigit()
                Spacer()
                if stage != .converting {
                    StageDots(stages: visibleStages, current: stage)
                }
            }
        }
    }

    private var visibleStages: [InstallStage] {
        if model.info.runtime == .appleSpeech { return [.model] }
        return model.info.needsModelDownload ? stages : stages.filter { $0 != .model }
    }

    private var detail: String {
        if model.info.runtime == .appleSpeech {
            return "Apple's on-device model for \(AppleSpeech.localeDescription)" + (model.assetProgress.map { " · \(Int($0 * 100))%" } ?? "")
        }
        if stage == .model, let d = model.download {
            if d.totalBytes > 0 {
                return "\(Format.bytes(d.downloadedBytes)) of \(Format.bytes(d.totalBytes))"
                    + (d.filesTotal > 0 ? " · \(d.filesDone)/\(d.filesTotal) files" : "")
            }
            return d.repo
        }
        if stage == .converting { return "Quantizing weights (one time)" }
        return model.installDetail.isEmpty ? "This can take a few minutes." : model.installDetail
    }
}

struct StageDots: View {
    let stages: [InstallStage]
    let current: InstallStage

    var body: some View {
        let index = stages.firstIndex(of: current) ?? 0
        HStack(spacing: 4) {
            ForEach(Array(stages.enumerated()), id: \.offset) { i, _ in
                Capsule()
                    .fill(i <= index ? Color.accentColor : Color.primary.opacity(0.15))
                    .frame(width: i == index ? 12 : 5, height: 5)
            }
        }
        .animation(.snappy, value: index)
    }
}

struct FailureCard: View {
    let model: ServiceModel
    let failure: ServiceModel.Failure
    @State private var showLog = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(failure.title, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12.5, weight: .semibold))
                .legibleTint(.red)
            Text(failure.message)
                .font(.system(size: 12))
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if case .portBusy(let owner, _) = failure.kind, let label = owner.launchdLabel {
                HStack {
                    Text(verbatim: "launchctl bootout gui/$UID/\(label)")
                        .font(.system(size: 11, design: .monospaced))
                        .lineLimit(2)
                        .textSelection(.enabled)
                    Spacer()
                    CopyButton(text: "launchctl bootout gui/$(id -u)/\(label)", help: "Copy command")
                }
                .padding(6)
                .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
            }
            if !failure.logTail.isEmpty {
                DisclosureGroup(isExpanded: $showLog) {
                    LogLines(lines: failure.logTail)
                } label: {
                    Text("Details").font(.system(size: 11.5))
                }
            }
            HStack {
                Spacer()
                Button("Dismiss") { model.dismissFailure() }
                    .buttonStyle(PillButtonStyle(tint: .secondary))
                Button(retryTitle) { retry() }
                    .buttonStyle(PillButtonStyle(tint: .red, prominent: true))
                    .disabled(!model.acceptsActions)
            }
        }
        .padding(12)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.2), lineWidth: 0.5))
    }

    private var retryTitle: String {
        switch failure.kind {
        case .install, .download: "Retry"
        case .crashed: "Restart"
        case .portBusy, .startup: "Try Again"
        }
    }

    private func retry() {
        switch failure.kind {
        case .install, .download: model.install()
        case .crashed, .portBusy, .startup: model.start()
        }
    }
}

struct TryItCard: View {
    @Bindable var session: TryItSession
    @FocusState private var focused: Bool

    var body: some View {
        Card(title: "Try it", systemImage: "play.circle") {
            TextField("Type something to say…", text: $session.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .lineLimit(3...6)
                .focused($focused)
                .padding(8)
                .background(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color(nsColor: .textBackgroundColor).opacity(0.6))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .strokeBorder(focused ? Color.accentColor.opacity(0.6) : Color.primary.opacity(0.1), lineWidth: focused ? 1.5 : 0.5)
                )
                .onSubmit { Task { await session.speak() } }

            HStack(spacing: 8) {
                if !session.voices.isEmpty {
                    Picker("Voice", selection: $session.voice) {
                        Text("Default voice").tag(String?.none)
                        Divider()
                        ForEach(session.voices, id: \.self) { voice in
                            Text(voice).tag(String?.some(voice))
                        }
                    }
                    .labelsHidden()
                    .controlSize(.small)
                    .frame(maxWidth: 150)
                }
                if session.overLimit {
                    Text("Too long for one request")
                        .font(.system(size: 11))
                        .legibleTint(.orange)
                }
                Spacer()
                Image(systemName: "waveform")
                    .legibleTint(.accentColor)
                    .symbolEffect(.variableColor.iterative, isActive: session.phase == .speaking)
                    .opacity(session.phase == .speaking ? 1 : 0)
                if session.phase == .connecting {
                    ProgressView().controlSize(.small)
                } else if session.isSpeaking {
                    Button {
                        Task { await session.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: .secondary))
                } else {
                    Button {
                        Task { await session.speak() }
                    } label: {
                        Label("Speak", systemImage: "play.fill")
                    }
                    .buttonStyle(PillButtonStyle(tint: .accentColor, prominent: true))
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || session.overLimit)
                }
            }
            if case .failed(let message) = session.phase {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5))
                    .legibleTint(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task { await session.prepare() }
    }
}

struct ConnectionCard: View {
    let model: ServiceModel

    var body: some View {
        let info = model.info
        Card(title: "Connect", systemImage: "point.3.connected.trianglepath.dotted") {
            CopyRow(label: "URL", value: "ws://\(ServiceCatalog.host):\(model.port)/")
            CopyRow(label: "Pipecat service", value: info.pipecatService(port: model.port))
            CopyRow(label: "Environment", value: info.environment(port: model.port))
            Text(footnote)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footnote: String {
        let adapter = model.kind == .tts
            ? "LocalTTSService is in pipecat-local-tts-server's examples/pipecat_tts_service.py."
            : "LocalWebSocketSTTService is in stt_server.examples.pipecat_stt_service."
        return model.isRunning ? adapter : "Available once the server is running. " + adapter
    }
}

/// A labelled, selectable monospaced value with a copy button.
struct CopyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 1) {
                Text(label)
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(verbatim: value)
                    .font(.system(size: 10.5, design: .monospaced))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            CopyButton(text: value, help: "Copy \(label)")
        }
    }
}

struct DetailsCard: View {
    let model: ServiceModel

    var body: some View {
        Card(title: "Details", systemImage: "info.circle") {
            if let repo = model.info.modelRepo {
                InfoRow(label: "Model") {
                    Link(destination: URL(string: "https://huggingface.co/\(repo)")!) {
                        Text(repo).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.system(size: 12))
                    .help(repo)
                }
            }
            if let variant = model.info.variantLabel {
                InfoRow(label: "Variant") { Text(variant) }
            }
            InfoRow(label: "Licence") {
                Text(model.info.licence.label).legibleTint(model.info.licence.isRestrictive ? .orange : .primary)
            }
            if model.info.licence != .none, model.info.licence != .system {
                Text(model.info.licence.detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            InfoRow(label: "Streaming") { Text(model.info.streaming ? "Yes" : "No") }
            if model.info.runtime == .appleSpeech {
                InfoRow(label: "Language") { Text(AppleSpeech.localeDescription) }
            }
            if case .external(_, let info) = model.phase {
                InfoRow(label: "Reports") { Text(info.model.map { "\(info.backendName) · \($0)" } ?? info.backendName).lineLimit(1).truncationMode(.middle) }
                if let rate = info.rate { InfoRow(label: "Sample rate") { Text("\(rate) Hz").monospacedDigit() } }
            }
            if let running = model.running {
                InfoRow(label: "Sample rate") { Text("\(running.rate) Hz").monospacedDigit() }
                InfoRow(label: "Process") { Text(verbatim: "pid \(running.pid)").monospacedDigit() }
                InfoRow(label: "Up since") { Text(running.since, style: .time) }
            }
            if let bytes = model.diskBytes {
                InfoRow(label: "On disk") { Text(Format.bytes(bytes)) }
            } else if !model.isInstalled, let bytes = model.approxDownloadBytes {
                InfoRow(label: "Download") { Text("≈ \(Format.bytes(bytes))") }
            }
        }
    }
}

struct LogCard: View {
    let model: ServiceModel

    var body: some View {
        Card(title: "Log", systemImage: "text.alignleft") {
            LogLines(lines: Array(model.log.suffix(8)))
            if model.logURL.map({ FileManager.default.fileExists(atPath: $0.path) }) == true {
                Button("Show Log File") { model.revealLog() }
                    .buttonStyle(.link)
                    .font(.system(size: 11.5))
            }
        }
    }
}

struct LogLines: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: ServiceModel.logMessage(line) ?? line)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct RemoveSection: View {
    let model: ServiceModel
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if confirming {
                Text("Delete \(model.info.displayName)?")
                    .font(.system(size: 12.5, weight: .semibold))
                Text("The Python environment is deleted. Model files live in the shared Hugging Face cache; delete them too to free \(model.diskBytes.map(Format.bytes) ?? "their space").")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Cancel") { withAnimation(.snappy) { confirming = false } }
                        .buttonStyle(PillButtonStyle(tint: .secondary))
                    Spacer()
                    Button("Keep Model Files") { model.remove(deleteModel: false) }
                        .buttonStyle(PillButtonStyle(tint: .red))
                    if model.info.needsModelDownload {
                        Button("Delete Everything") { model.remove(deleteModel: true) }
                            .buttonStyle(PillButtonStyle(tint: .red, prominent: true))
                    }
                }
            } else {
                Button(role: .destructive) {
                    withAnimation(.snappy) { confirming = true }
                } label: {
                    Label("Delete…", systemImage: "trash").font(.system(size: 12))
                }
                .buttonStyle(.borderless)
                .legibleTint(.red)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.top, 2)
    }
}

/// "Try it" for speech to text: record, or transcribe a fixed spoken test clip.
struct STTTryItCard: View {
    let session: STTTryItSession

    var body: some View {
        Card(title: "Try it", systemImage: "mic.circle") {
            HStack(spacing: 8) {
                // No Record for an External server (`ExternalPresentation.Actions.microphone`).
                if session.allowsMicrophone {
                    Button {
                        Task { await session.toggleRecording() }
                    } label: {
                        Label(session.phase == .recording ? "Stop & Transcribe" : "Record", systemImage: session.phase == .recording ? "stop.fill" : "record.circle")
                    }
                    .buttonStyle(PillButtonStyle(tint: .red, prominent: session.phase == .recording))
                    .disabled(session.isBusy && session.phase != .recording)
                }

                Button {
                    Task { await session.transcribeSample() }
                } label: {
                    Label("Test Clip", systemImage: "text.bubble")
                }
                .buttonStyle(PillButtonStyle(tint: .accentColor))
                .disabled(session.isBusy)
                .help("Transcribe a fixed spoken clip and check the result (no microphone)")

                Spacer()
                if session.phase == .recording {
                    LevelMeter(level: session.level)
                } else if session.phase == .transcribing {
                    ProgressView().controlSize(.small)
                }
            }

            if let transcript = session.transcript {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .top) {
                        Text(transcript)
                            .font(.system(size: 13))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 4)
                        CopyButton(text: transcript, help: "Copy transcript")
                    }
                    HStack(spacing: 6) {
                        if let source = session.lastSource {
                            Text(source).lineLimit(1).truncationMode(.tail)
                        }
                        if let latency = session.latency {
                            Text(latency.formatted(.units(allowed: [.seconds, .milliseconds], width: .narrow)))
                                .monospacedDigit()
                        }
                    }
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    if let match = session.sampleMatch {
                        Label(
                            match ? "Matches the clip" : "Doesn't match the clip",
                            systemImage: match ? "checkmark.circle.fill" : "xmark.circle.fill"
                        )
                        .font(.system(size: 11.5, weight: .medium))
                        .legibleTint(match ? .green : .red)
                    }
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor).opacity(0.6)))
            } else if session.phase == .recording {
                Text("Listening… speak, then press Stop & Transcribe.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
            }

            if case .failed(let message) = session.phase {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11.5))
                    .legibleTint(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Five bars that follow the microphone level.
struct LevelMeter: View {
    let level: Float

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<5) { i in
                Capsule()
                    .fill(Float(i) / 5 < level ? Color.red : Color.primary.opacity(0.15))
                    .frame(width: 3, height: 6 + CGFloat(i) * 2)
            }
        }
        .animation(.easeOut(duration: 0.1), value: level)
    }
}
