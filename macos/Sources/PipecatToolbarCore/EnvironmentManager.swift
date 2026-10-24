import Foundation

public enum InstallStage: String, Sendable, Equatable {
    case queued, python, environment, packages, model, converting

    public var title: String {
        switch self {
        case .queued: "Waiting for another install"
        case .python: "Installing Python 3.12"
        case .environment: "Creating environment"
        case .packages: "Installing packages"
        case .model: "Downloading model"
        case .converting: "Optimizing model"
        }
    }
}

/// What an install run does.
public enum InstallMode: Sendable, Equatable {
    /// Python, a fresh venv, packages, then model weights.
    case full
    /// Reinstall the server package into the existing venv (after an app update).
    case packages
    /// Download (or resume) model weights only.
    case model
}

public enum InstallEvent: Sendable, Equatable {
    case stage(InstallStage)
    case log(String)
    case download(DownloadProgress)
    case warning(String)
}

public struct InstallError: LocalizedError, Sendable, Equatable {
    public var stage: InstallStage
    public var message: String
    public var logTail: [String]

    public var errorDescription: String? { message }
}

/// The state of one backend's environment on disk.
public enum EnvironmentStatus: Sendable, Equatable {
    case missing
    /// Installed from the current wheel.
    case ready(EnvironmentMarker)
    /// Installed from an older wheel; reinstall the package before starting.
    case outdated(EnvironmentMarker)
}

public struct ModelCacheStatus: Sendable, Equatable {
    public var cached: Bool
    public var sizeBytes: Int64
    /// Hugging Face cache repo folders (`.../hub/models--org--name`) holding the weights.
    public var repoFolders: [URL]
    /// Weights the server derived for this variant alone (Phonon's quantized copies).
    public var derivedFolders: [URL]

    public init(cached: Bool, sizeBytes: Int64, repoFolders: [URL], derivedFolders: [URL] = []) {
        self.cached = cached
        self.sizeBytes = sizeBytes
        self.repoFolders = repoFolders
        self.derivedFolders = derivedFolders
    }
}

/// Builds, checks and removes the per-family Python environments with `uv`.
///
/// Layout: one venv per family under `envs/<family>`, all sharing one
/// uv-managed CPython (`python/`) and uv cache, so a second backend reuses the
/// interpreter and most wheels. A family's variants (Phonon 8-bit, Whisper
/// Small) share its venv; `envs/<family>/.variants/` records which ones the
/// user installed. Work on one family's venv is serialized.
public actor EnvironmentManager {
    public static let pythonVersion = "3.12"

    public let paths: AppPaths
    public let tools: Tools
    private var running: [Service: Subprocess] = [:]
    private var busyFamilies: Set<Service> = []
    private var familyWaiters: [Service: [CheckedContinuation<Void, Never>]] = [:]

    public init(paths: AppPaths, tools: Tools) {
        self.paths = paths
        self.tools = tools
    }

    // MARK: - Status

    public nonisolated func environmentStatus(_ backend: Service) -> EnvironmentStatus {
        guard FileManager.default.isExecutableFile(atPath: paths.python(backend).path),
            let marker = EnvironmentMarker.read(paths.marker(backend))
        else { return .missing }
        return marker.fingerprint == tools.fingerprint(for: backend.info) ? .ready(marker) : .outdated(marker)
    }

    /// Whether the user installed this variant in its family's environment.
    /// Environments from before variants name their one service in the marker.
    public nonisolated func isRequested(_ service: Service) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: paths.variantsDir(service).path) {
            return fm.fileExists(atPath: paths.variantMarker(service).path)
        }
        return EnvironmentMarker.read(paths.marker(service))?.service == service.rawValue
    }

    // MARK: - Commands

    /// What `uv pip install` gets for a service, and whether the TTS lockfile pins apply.
    public nonisolated func requirements(for info: ServiceInfo) -> (specs: [String], constrained: Bool) {
        switch info.runtime {
        case .ttsServer(let extra):
            var spec = "pipecat-local-tts-server"
            if let extra { spec += "[\(extra)]" }
            return (["\(spec) @ \(tools.wheel.absoluteString)"], true)
        case .sttHelper(_, let requirements):
            return (requirements, false)
        case .appleSpeech:
            return ([], false)
        }
    }

    /// `prefetch` (or its offline `--check`) as run inside the service's environment.
    public nonisolated func prefetchArguments(for info: ServiceInfo, check: Bool) -> [String]? {
        var args: [String]
        switch info.runtime {
        case .ttsServer:
            args = ["-m", "tts_server", "prefetch", "--backend", info.family.rawValue, "--json"]
            if let model = info.modelArgument { args += ["--model", model] }
        case .sttHelper:
            guard let helper = tools.helper, let repo = info.modelRepo else { return nil }
            args = [helper.path, "prefetch", "--repo", repo, "--state-dir", paths.envDir(info.service).path, "--json"]
        case .appleSpeech:
            return nil
        }
        if check { args.append("--check") }
        return args
    }

    /// The supervised server command (run with the environment's python).
    public nonisolated func serveArguments(for info: ServiceInfo, port: Int) -> [String]? {
        switch info.runtime {
        case .ttsServer:
            var args = ["-m", "tts_server", "serve", "--backend", info.family.rawValue]
            if let model = info.modelArgument { args += ["--model", model] }
            return args + [
                "--host", ServiceCatalog.host, "--port", String(port), "--supervised", "--log-level", "INFO",
            ]
        case .sttHelper(let engine, _):
            guard let helper = tools.helper else { return nil }
            var args = [helper.path, "serve-stt", "--engine", engine, "--host", ServiceCatalog.host, "--port", String(port)]
            if let repo = info.modelRepo { args += ["--model", repo] }
            return args
        case .appleSpeech:
            return nil
        }
    }

    /// Offline probe (`prefetch --check --json`); never touches the network.
    public func modelCacheStatus(_ backend: Service) async -> ModelCacheStatus? {
        guard backend.info.needsModelDownload else {
            return ModelCacheStatus(cached: true, sizeBytes: 0, repoFolders: [])
        }
        guard case .ready = environmentStatus(backend),
            let args = prefetchArguments(for: backend.info, check: true)
        else { return nil }
        let sub = Subprocess(
            .init(executable: paths.python(backend), arguments: args, environment: ProcessEnvironment.base()))
        guard let result = try? await sub.collect() else { return nil }
        return Self.cacheStatus(checkOutput: result.stdout)
    }

    /// Reads `prefetch --check --json` output.
    static func cacheStatus(checkOutput lines: [String]) -> ModelCacheStatus? {
        let events = lines.compactMap(ServerCLIEvent.parse)
        guard let summary = events.last(where: { $0.event == "summary" }) else { return nil }
        // TTS reports one `check` row per snapshot; the STT helper reports the path on the summary.
        let paths = events.filter { $0.event == "check" }.compactMap(\.path) + [summary.path].compactMap { $0 }
        // A quantized Phonon variant also needs its converted copy of the weights.
        let derived = summary.quantized == true ? [summary.quantizedPath].compactMap { $0.map { URL(filePath: $0) } } : []
        return ModelCacheStatus(
            cached: (summary.cached ?? false) && summary.quantized != false, sizeBytes: summary.sizeBytes ?? 0,
            repoFolders: Array(Set(paths.compactMap(Self.repoFolder(fromSnapshot:)))), derivedFolders: derived)
    }

    /// `.../hub/models--org--name/snapshots/<sha>` -> `.../hub/models--org--name`, if it looks like one.
    static func repoFolder(fromSnapshot path: String) -> URL? {
        let snapshot = URL(filePath: path)
        let repo = snapshot.deletingLastPathComponent().deletingLastPathComponent()
        guard snapshot.deletingLastPathComponent().lastPathComponent == "snapshots",
            repo.lastPathComponent.hasPrefix("models--")
        else { return nil }
        return repo
    }

    /// `org/name` -> `models--org--name`, the repo's folder in the Hugging Face cache.
    static func cacheFolderName(repo: String) -> String {
        "models--" + repo.replacingOccurrences(of: "/", with: "--")
    }

    /// Only Hugging Face repo folders and the TTS server's own derived weights
    /// (`.../pipecat-tts-server/<backend>/<key>`) are ever deleted.
    static func isDeletableModelPath(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix("models--")
            || url.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent == "pipecat-tts-server"
    }

    /// The folders in `own` that no sibling uses, judged by repo id and by the
    /// folders siblings reported (Phonon's variants share one Hugging Face repo).
    static func unshared(_ own: [URL], siblingRepos: [String], siblingFolders: [URL]) -> [URL] {
        let shared = Set(siblingRepos.map(cacheFolderName(repo:)) + siblingFolders.map(\.lastPathComponent))
        return own.filter { !shared.contains($0.lastPathComponent) }
    }

    // MARK: - Family lock

    /// Waits for exclusive use of a family's environment (sibling installs, removal).
    private func lockFamily(_ family: Service, onWait: () -> Void = {}) async {
        guard busyFamilies.contains(family) else {
            busyFamilies.insert(family)
            return
        }
        onWait()
        await withCheckedContinuation { familyWaiters[family, default: []].append($0) }
    }

    private func unlockFamily(_ family: Service) {
        if let next = familyWaiters[family]?.first {
            familyWaiters[family]?.removeFirst()
            next.resume()  // the lock passes straight to the next waiter
        } else {
            busyFamilies.remove(family)
        }
    }

    /// Records `service` as installed. The first variant record in an environment
    /// from before variants also records the service that built it.
    func recordVariant(_ service: Service, installed: Bool) throws {
        let fm = FileManager.default
        let dir = paths.variantsDir(service)
        if !fm.fileExists(atPath: dir.path) {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if let builder = EnvironmentMarker.read(paths.marker(service)).flatMap({ Service(rawValue: $0.service) }),
                builder.family == service.family
            {
                fm.createFile(atPath: paths.variantMarker(builder).path, contents: nil)
            }
        }
        if installed {
            fm.createFile(atPath: paths.variantMarker(service).path, contents: nil)
        } else {
            try? fm.removeItem(at: paths.variantMarker(service))
        }
    }

    // MARK: - Install

    /// Installs (or repairs) `backend`: Python, venv, packages, then model weights.
    public nonisolated func install(_ backend: Service, mode: InstallMode = .full) -> AsyncThrowingStream<InstallEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    try await self.runInstall(backend, mode: mode) { continuation.yield($0) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func runInstall(
        _ backend: Service, mode: InstallMode, emit: @escaping @Sendable (InstallEvent) -> Void
    ) async throws {
        let info = backend.info
        await lockFamily(info.family) { emit(.stage(.queued)) }
        defer { unlockFamily(info.family) }
        let env = ProcessEnvironment.uv(paths: paths)
        let envDir = paths.envDir(backend)
        try paths.prepare()

        // A sibling variant may have built the environment already: build only
        // what's missing, and never rebuild one that works.
        let status = environmentStatus(backend)
        let buildsEnvironment = status == .missing
        var installsPackages = buildsEnvironment || mode == .packages
        if mode == .full, case .outdated = status { installsPackages = true }

        if buildsEnvironment {
            emit(.stage(.python))
            try await step(backend, .python, emit: emit) {
                Subprocess(
                    .init(
                        executable: self.tools.uv,
                        arguments: ["python", "install", Self.pythonVersion], environment: env))
            }

            emit(.stage(.environment))
            // A half-built env from an interrupted install is never trusted.
            try? FileManager.default.removeItem(at: envDir)
            try await step(backend, .environment, emit: emit) {
                Subprocess(
                    .init(
                        executable: self.tools.uv,
                        arguments: ["venv", "--python", Self.pythonVersion, envDir.path],
                        environment: env))
            }
        }

        if installsPackages {
            try await installPackages(backend, env: env, emit: emit)
        }
        try recordVariant(backend, installed: true)

        guard info.needsModelDownload, mode != .packages else { return }
        emit(.stage(.model))
        try await prefetch(backend, emit: emit)
    }

    /// `uv pip install` the service's requirements into its environment, then marks it built.
    private func installPackages(
        _ backend: Service, env: [String: String], emit: @escaping @Sendable (InstallEvent) -> Void
    ) async throws {
        let info = backend.info
        emit(.stage(.packages))
        let (specs, constrained) = requirements(for: info)
        var args = ["pip", "install", "--python", paths.python(backend).path]
        if case .ttsServer = info.runtime { args += ["--reinstall-package", "pipecat-local-tts-server"] }
        // uv splits a `--constraint` path at spaces (and the app bundle name has
        // them), so run from the file's directory and pass the bare name.
        var workingDir: URL?
        if constrained, let constraints = tools.constraints {
            args += ["--constraint", constraints.lastPathComponent]
            workingDir = constraints.deletingLastPathComponent()
        }
        args += specs
        try await step(backend, .packages, emit: emit) {
            Subprocess(.init(executable: self.tools.uv, arguments: args, environment: env, currentDirectory: workingDir))
        }

        let pythonVersion = (try? await Subprocess(
            .init(executable: paths.python(backend), arguments: ["-c", "import platform; print(platform.python_version())"],
                  environment: ProcessEnvironment.base())).collect().stdout.first) ?? Self.pythonVersion
        try EnvironmentMarker(
            service: backend.rawValue, fingerprint: tools.fingerprint(for: info),
            python: pythonVersion, createdAt: Date()
        ).write(paths.marker(backend))
    }

    /// Runs one uv step; a non-zero exit becomes an `InstallError` with the log tail.
    private func step(
        _ backend: Service, _ stage: InstallStage, emit: @escaping @Sendable (InstallEvent) -> Void,
        make: () -> Subprocess
    ) async throws {
        try Task.checkCancellation()
        let sub = make()
        running[backend] = sub
        defer { running[backend] = nil }
        try sub.run()
        let tail = LogTail(limit: 12)
        let out = Task {
            for await line in sub.stdout { tail.append(line); emit(.log(line)) }
        }
        let err = Task {
            for await line in sub.stderr { tail.append(line); emit(.log(line)) }
        }
        let status = await withTaskCancellationHandler {
            await sub.waitForExit()
        } onCancel: {
            sub.terminate()
        }
        _ = await (out.value, err.value)
        try Task.checkCancellation()
        guard status == 0 else {
            let lines = tail.lines
            let reason = lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? "exit status \(status)"
            throw InstallError(stage: stage, message: "\(stage.title) failed: \(reason)", logTail: lines)
        }
    }

    private func prefetch(_ backend: Service, emit: @escaping @Sendable (InstallEvent) -> Void) async throws {
        try Task.checkCancellation()
        guard let args = prefetchArguments(for: backend.info, check: false) else {
            throw InstallError(stage: .model, message: "The STT helper script is missing from this build.", logTail: [])
        }
        let sub = Subprocess(.init(executable: paths.python(backend), arguments: args, environment: ProcessEnvironment.base()))
        running[backend] = sub
        defer { running[backend] = nil }
        try sub.run()

        let tail = LogTail(limit: 12)
        let err = Task {
            for await line in sub.stderr { tail.append(line); emit(.log(line)) }
        }
        let outcome = Task { () -> ServerCLIEvent? in
            var failure: ServerCLIEvent?
            var progress = DownloadProgress(repo: backend.info.modelRepo ?? "")
            for await line in sub.stdout {
                guard let event = ServerCLIEvent.parse(line) else {
                    emit(.log(line))
                    continue
                }
                switch event.event {
                case "start":
                    progress = DownloadProgress(repo: event.repo ?? progress.repo)
                    emit(.download(progress))
                case "progress":
                    progress.downloadedBytes = event.downloadedBytes ?? progress.downloadedBytes
                    progress.totalBytes = event.totalBytes ?? progress.totalBytes
                    progress.filesDone = event.filesDone ?? progress.filesDone
                    progress.filesTotal = event.filesTotal ?? progress.filesTotal
                    emit(.download(progress))
                case "convert" where event.state == "start":
                    emit(.stage(.converting))
                case "warning":
                    emit(.warning(event.message ?? "A model file could not be downloaded."))
                case "error":
                    failure = event
                default:
                    break
                }
            }
            return failure
        }
        let status = await withTaskCancellationHandler {
            await sub.waitForExit()
        } onCancel: {
            sub.terminate()
        }
        let failure = await outcome.value
        _ = await err.value
        try Task.checkCancellation()
        guard status == 0 else {
            let message = failure?.message ?? tail.lines.last ?? "exit status \(status)"
            throw InstallError(stage: .model, message: "Model download failed: \(message)", logTail: tail.lines)
        }
    }

    public func cancel(_ backend: Service) {
        running[backend]?.terminate()
    }

    // MARK: - Remove

    /// Uninstalls a variant. With `deleteModel`, also deletes its model files
    /// that no installed sibling uses (`knownFolders` when the environment can't
    /// report them). The family environment goes with its last variant.
    public func remove(_ backend: Service, deleteModel: Bool, knownFolders: [URL] = []) async throws {
        cancel(backend)
        await lockFamily(backend.family)
        defer { unlockFamily(backend.family) }
        let fm = FileManager.default
        let siblings = backend.variants.filter { $0 != backend && isRequested($0) }
        var doomed: [URL] = []
        if deleteModel {
            let own = await modelCacheStatus(backend).map { $0.repoFolders + $0.derivedFolders } ?? knownFolders
            var shared: [URL] = []
            for sibling in siblings {
                shared += await modelCacheStatus(sibling)?.repoFolders ?? []
            }
            doomed = Self.unshared(own, siblingRepos: siblings.compactMap(\.info.modelRepo), siblingFolders: shared)
        }
        if siblings.isEmpty {
            if fm.fileExists(atPath: paths.envDir(backend).path) {
                try fm.removeItem(at: paths.envDir(backend))
            }
        } else {
            try recordVariant(backend, installed: false)
        }
        for folder in doomed where Self.isDeletableModelPath(folder) {
            try? fm.removeItem(at: folder)
        }
    }
}

/// A bounded, thread-safe ring of recent log lines.
public final class LogTail: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer: [String] = []
    private let limit: Int

    public init(limit: Int) { self.limit = limit }

    public func append(_ line: String) {
        lock.withLock {
            buffer.append(line)
            if buffer.count > limit { buffer.removeFirst(buffer.count - limit) }
        }
    }

    public var lines: [String] { lock.withLock { buffer } }
}
