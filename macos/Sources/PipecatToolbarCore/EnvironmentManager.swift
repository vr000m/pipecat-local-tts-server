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

extension AsyncThrowingStream where Failure == any Error {
    /// `for try await` over the stream, except that cancelling the consuming task
    /// throws `CancellationError`. A cancelled `for try await` just ends, exactly
    /// as if the stream had finished, so a cancelled install would read as done.
    /// No element is handed to `body` once the task is cancelled.
    public func consume(
        isolation: isolated (any Actor)? = #isolation, _ body: (Element) throws -> Void
    ) async throws {
        for try await element in self {
            try Task.checkCancellation()
            try body(element)
        }
        try Task.checkCancellation()
    }
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
    /// Every repo the check named, cached or not (a partial download still has a folder).
    public var repoIDs: [String]

    public init(cached: Bool, sizeBytes: Int64, repoFolders: [URL], derivedFolders: [URL] = [], repoIDs: [String] = []) {
        self.cached = cached
        self.sizeBytes = sizeBytes
        self.repoFolders = repoFolders
        self.derivedFolders = derivedFolders
        self.repoIDs = repoIDs
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
    /// Short offline probes in flight (`prefetch --check`, the Python version).
    private var probes: [ObjectIdentifier: Subprocess] = [:]
    private var busyFamilies: Set<Service> = []
    private var familyWaiters: [Service: [(id: UUID, resume: CheckedContinuation<Bool, Never>)]] = [:]
    /// Set by `shutdown()` on app quit: no new subprocess starts after it.
    private var shuttingDown = false
    /// How long a cancelled install step gets to exit after SIGTERM before SIGKILL.
    public let cancelGrace: Duration
    /// How long a step's output may stay open after the step exited.
    public let drainLimit: Duration

    public init(paths: AppPaths, tools: Tools, cancelGrace: Duration = .seconds(5), drainLimit: Duration = .seconds(2)) {
        self.paths = paths
        self.tools = tools
        self.cancelGrace = cancelGrace
        self.drainLimit = drainLimit
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

    /// What `uv pip install` gets for a service, and whether pins apply: the TTS
    /// lockfile export, or the STT engine's hash-pinned constraints.
    public nonisolated func requirements(for info: ServiceInfo) -> (specs: [String], constrained: Bool) {
        switch info.runtime {
        case .ttsServer(let extra):
            var spec = "pipecat-local-tts-server"
            if let extra { spec += "[\(extra)]" }
            return (["\(spec) @ \(tools.wheel.absoluteString)"], true)
        case .sttHelper(_, let requirements):
            return (requirements, true)
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
    /// `includeOutdated` also probes an environment from an older wheel, which
    /// still locates the weights (removal needs that; a start does not).
    public func modelCacheStatus(_ backend: Service, includeOutdated: Bool = false) async -> ModelCacheStatus? {
        guard backend.info.needsModelDownload else {
            return ModelCacheStatus(cached: true, sizeBytes: 0, repoFolders: [])
        }
        switch environmentStatus(backend) {
        case .ready: break
        case .outdated where includeOutdated: break
        default: return nil
        }
        guard let args = prefetchArguments(for: backend.info, check: true),
            let stdout = await probe(.init(executable: paths.python(backend), arguments: args, environment: ProcessEnvironment.base()))
        else { return nil }
        return Self.cacheStatus(checkOutput: stdout)
    }

    /// Runs a short offline probe to completion and returns its stdout. None
    /// starts once the app is quitting, and `shutdown()` stops one in flight.
    private func probe(_ spec: Subprocess.Spec) async -> [String]? {
        guard !shuttingDown else { return nil }
        let sub = Subprocess(spec)
        probes[ObjectIdentifier(sub)] = sub
        defer { probes[ObjectIdentifier(sub)] = nil }
        return try? await sub.collect().stdout
    }

    /// Reads `prefetch --check --json` output: one `check` row per snapshot, then
    /// a `summary`. The TTS server and the STT helper write the same events
    /// (`docs/supervised-contract.json`, enforced by `tests/test_supervised_contract.py`).
    static func cacheStatus(checkOutput lines: [String]) -> ModelCacheStatus? {
        let events = lines.compactMap(ServerCLIEvent.parse)
        guard let summary = events.last(where: { $0.event == "summary" }) else { return nil }
        let checks = events.filter { $0.event == "check" }
        let paths = checks.compactMap(\.path)
        let repos = Array(Set(checks.compactMap(\.repo))).sorted()
        // A quantized Phonon variant also needs its converted copy of the weights.
        let derived = summary.quantized == true ? [summary.quantizedPath].compactMap { $0.map { URL(filePath: $0) } } : []
        return ModelCacheStatus(
            cached: (summary.cached ?? false) && summary.quantized != false, sizeBytes: summary.sizeBytes ?? 0,
            repoFolders: Array(Set(paths.compactMap(Self.repoFolder(fromSnapshot:)))), derivedFolders: derived, repoIDs: repos)
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

    /// Only a Hugging Face repo folder directly in the hub cache
    /// (`<hub>/models--org--name`) and the TTS server's own derived weights
    /// (`<derived>/<backend>/<key>`) are ever deleted. The candidates come from
    /// subprocess output, so a look-alike name anywhere else (or a `..` path
    /// that resolves outside those roots) is refused.
    ///
    /// Invariant: every component above the folder resolves, with symlinks
    /// resolved, to exactly `<hub>` or `<derived>/<backend>`, so a symlinked
    /// backend directory can't carry the deletion outside the root. The folder
    /// itself is not followed (deleting a link removes the link). `..` is
    /// resolved lexically first, and that lexical path is what is deleted.
    static func deletionTarget(_ url: URL, hub: URL, derived: URL) -> URL? {
        let folder = url.standardizedFileURL
        let name = folder.lastPathComponent
        guard !name.isEmpty, name != "/", name != ".", name != ".." else { return nil }
        let parent = canonicalPath(folder.deletingLastPathComponent())
        if name.hasPrefix("models--"), name.count > "models--".count, parent == canonicalPath(hub) { return folder }
        let backend = folder.deletingLastPathComponent().lastPathComponent
        guard !backend.isEmpty, backend != "/", backend != "..", !backend.hasPrefix(".") else { return nil }
        // The backend directory, resolved, must be the root's own `<backend>`, not a link out of it.
        let root = canonicalPath(derived)
        return parent == (root == "/" ? "" : root) + "/" + backend ? folder : nil
    }

    /// Whether anything (a folder, a file or a link, even a dangling one) is at `url`.
    static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.standardizedFileURL.path)) != nil
    }

    static func isDeletableModelPath(_ url: URL, hub: URL, derived: URL) -> Bool {
        deletionTarget(url, hub: hub, derived: derived) != nil
    }

    private static func canonicalPath(_ url: URL) -> String {
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path(percentEncoded: false)
        return path.count > 1 && path.hasSuffix("/") ? String(path.dropLast()) : path
    }

    /// The folders in `own` that no sibling uses, judged by repo id and by the
    /// folders siblings reported (Phonon's variants share one Hugging Face repo).
    static func unshared(_ own: [URL], siblingRepos: [String], siblingFolders: [URL]) -> [URL] {
        let shared = Set(siblingRepos.map(cacheFolderName(repo:)) + siblingFolders.map(\.lastPathComponent))
        return own.filter { !shared.contains($0.lastPathComponent) }
    }

    // MARK: - Family lock

    /// Waits for exclusive use of a family's environment (sibling installs, removal).
    /// Cancelling the waiting task leaves the queue at once and throws
    /// `CancellationError`, without the lock: only a caller that got it unlocks.
    private func lockFamily(_ family: Service, onWait: () -> Void = {}) async throws {
        try Task.checkCancellation()
        guard busyFamilies.contains(family) else {
            busyFamilies.insert(family)
            return
        }
        onWait()
        let id = UUID()
        let granted = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
                familyWaiters[family, default: []].append((id, continuation))
            }
        } onCancel: {
            Task { await self.leaveQueue(family, id) }
        }
        guard granted else { throw CancellationError() }
    }

    private func leaveQueue(_ family: Service, _ id: UUID) {
        guard let index = familyWaiters[family]?.firstIndex(where: { $0.id == id }) else { return }  // already granted
        familyWaiters[family]?.remove(at: index).resume.resume(returning: false)
    }

    private func unlockFamily(_ family: Service) {
        if let next = familyWaiters[family]?.first {
            familyWaiters[family]?.removeFirst()
            next.resume.resume(returning: true)  // the lock passes straight to the next waiter
        } else {
            busyFamilies.remove(family)
        }
    }

    /// Moves an environment from before variants (its marker names the one
    /// service that built it, there is no `.variants/`) to variant records,
    /// before anything in it changes: `.variants/` appears in one rename,
    /// already holding its builder, so the builder stays installed whatever
    /// a later step (a sibling's marker write, a Cancel) does. A no-op for an
    /// environment that has records, or for no environment at all.
    func adoptVariants(_ service: Service) throws {
        let fm = FileManager.default
        let dir = paths.variantsDir(service)
        guard !Self.exists(dir), fm.fileExists(atPath: paths.envDir(service).path) else { return }
        let staging = paths.envDir(service).appending(path: ".variants-\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: false)
        do {
            if let builder = EnvironmentMarker.read(paths.marker(service)).flatMap({ Service(rawValue: $0.service) }),
                builder.family == service.family
            {
                try Self.createEmptyFile(staging.appending(path: builder.rawValue))
            }
            try fm.moveItem(at: staging, to: dir)
        } catch {
            try? fm.removeItem(at: staging)
            throw error
        }
    }

    /// Records `service` as installed (or not) in its family's environment.
    /// Every failure is thrown: a record that silently didn't change makes the
    /// next refresh report the wrong variants.
    func recordVariant(_ service: Service, installed: Bool) throws {
        try adoptVariants(service)
        let fm = FileManager.default
        let marker = paths.variantMarker(service)
        if installed {
            try fm.createDirectory(at: paths.variantsDir(service), withIntermediateDirectories: true)
            try Self.createEmptyFile(marker)
        } else if Self.exists(marker) {
            try fm.removeItem(at: marker)
        }
    }

    private static func createEmptyFile(_ url: URL) throws {
        guard FileManager.default.createFile(atPath: url.path, contents: nil) else {
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
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
        try await lockFamily(info.family) { emit(.stage(.queued)) }
        defer { unlockFamily(info.family) }
        // Cancelled once the lock came (it may have been granted as Cancel landed): nothing ran, nothing is recorded.
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
        let env = ProcessEnvironment.uv(paths: paths)
        let envDir = paths.envDir(backend)
        try paths.prepare()

        // A sibling variant may have built the environment already: build only
        // what's missing, and never rebuild one that works.
        let status = environmentStatus(backend)
        let buildsEnvironment = status == .missing
        // An existing environment from before variants records its builder
        // first: a sibling's install below rewrites the marker, and a Cancel
        // after that must leave the builder installed and the sibling not.
        if !buildsEnvironment { try adoptVariants(backend) }
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
            // A new environment records its variants from the start, so it never
            // falls back to the pre-variant marker: until the commit point below
            // writes this variant, a cancelled build reads as not installed.
            try FileManager.default.createDirectory(at: paths.variantsDir(backend), withIntermediateDirectories: true)
        }

        if installsPackages {
            try await installPackages(backend, env: env, emit: emit)
        }
        // The variant marker is the install's commit point: a Cancel that landed
        // during the steps above (the version probe ignores it) records nothing.
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
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
        let pins: URL?
        do {
            pins = constrained ? try tools.constraints(for: info) : nil
        } catch {
            // A bundled build never installs an STT engine without its hash pins.
            throw InstallError(stage: .packages, message: error.localizedDescription, logTail: [])
        }
        if let constraints = pins {
            args += ["--constraint", constraints.lastPathComponent]
            workingDir = constraints.deletingLastPathComponent()
            // The STT constraints carry a sha256 for every wheel (the uv.lock export does not).
            if case .sttHelper = info.runtime { args.append("--require-hashes") }
        }
        args += specs
        try await step(backend, .packages, emit: emit) {
            Subprocess(.init(executable: self.tools.uv, arguments: args, environment: env, currentDirectory: workingDir))
        }

        let pythonVersion = await probe(
            .init(executable: paths.python(backend), arguments: ["-c", "import platform; print(platform.python_version())"],
                  environment: ProcessEnvironment.base()))?.first ?? Self.pythonVersion
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
        if shuttingDown { throw CancellationError() }
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
        let status = await waitForExit(sub, readers: [out, err])
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
        guard status == 0 else {
            let lines = tail.lines
            let reason = lines.last(where: { $0.lowercased().contains("error") }) ?? lines.last ?? "exit status \(status)"
            throw InstallError(stage: stage, message: "\(stage.title) failed: \(reason)", logTail: lines)
        }
    }

    private func prefetch(_ backend: Service, emit: @escaping @Sendable (InstallEvent) -> Void) async throws {
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
        guard let args = prefetchArguments(for: backend.info, check: false) else {
            throw InstallError(stage: .model, message: "The STT helper script is missing from this build.", logTail: [])
        }
        let sub = Subprocess(.init(executable: paths.python(backend), arguments: args, environment: ProcessEnvironment.huggingFace()))
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
        let status = await waitForExit(sub, readers: [Task { _ = await outcome.value }, err])
        // The pipes closed, or the drain limit passed: a cancelled reader ends at once.
        outcome.cancel()
        let failure = await outcome.value
        try Task.checkCancellation()
        if shuttingDown { throw CancellationError() }
        guard status == 0 else {
            let message = failure?.message ?? tail.lines.last ?? "exit status \(status)"
            throw InstallError(stage: .model, message: "Model download failed: \(message)", logTail: tail.lines)
        }
    }

    /// The step's exit status, once its output `readers` finished or `drainLimit`
    /// after the exit, whichever comes first: a grandchild that inherited the
    /// pipes (a build backend surviving uv's SIGKILL) can't keep the install, and
    /// so the family lock, waiting. Readers still going then are cancelled.
    /// Cancelling the caller stops the child: SIGTERM, then SIGKILL.
    private func waitForExit(_ sub: Subprocess, readers: [Task<Void, Never>]) async -> Int32 {
        let grace = cancelGrace
        let drained = Task { for reader in readers { await reader.value } }
        let status = await withTaskCancellationHandler {
            await sub.waitForExit(after: drained, drainLimit: drainLimit)
        } onCancel: {
            // SIGTERM, then SIGKILL: a child that ignores SIGTERM can't hold the family lock.
            Task { _ = await sub.stop(grace: grace) }
        }
        for reader in readers { reader.cancel() }
        // Stopped (cancel, removal, quit): the step, and so the family lock, ends
        // only once the child's descendants are gone too (at most `grace`).
        if Task.isCancelled || sub.stopRequested { _ = await sub.stop(grace: grace) }
        return status
    }

    /// Stops `backend`'s running install step: SIGTERM, then SIGKILL after `cancelGrace`.
    public func cancel(_ backend: Service) {
        guard let sub = running[backend] else { return }
        let grace = cancelGrace
        Task { _ = await sub.stop(grace: grace) }
    }

    /// App quit: abort every install/prefetch, stop its subprocess (SIGTERM, then
    /// SIGKILL after `grace`), and wait for family work (an unwinding install, a
    /// removal) to drain, so no installer outlives the app or races a relaunch.
    public func shutdown(grace: Duration = .seconds(5), drain: Duration = .seconds(20)) async {
        shuttingDown = true  // nothing new can register in `running` after this
        let subs = Array(running.values) + Array(probes.values)
        await withTaskGroup(of: Void.self) { group in
            for sub in subs { group.addTask { _ = await sub.stop(grace: grace) } }
        }
        let deadline = ContinuousClock.now + drain
        while !busyFamilies.isEmpty, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(25))
        }
    }

    // MARK: - Remove

    /// Uninstalls a variant. With `deleteModel`, also deletes its model files
    /// that no installed sibling uses (`known`, the last check the app saw,
    /// when the environment can't report them). The repo-to-folder mapping
    /// lives here. The family environment goes with its last variant.
    ///
    /// Invariant: a folder is deleted only when every installed sibling's check
    /// answered, in full, and named none of it. A sibling whose check gave no
    /// answer (it failed, or quit stopped it) keeps every candidate folder, and
    /// the kept ones are reported like any other leftover.
    public func remove(_ backend: Service, deleteModel: Bool, known: ModelCacheStatus? = nil) async throws {
        cancel(backend)
        try await lockFamily(backend.family)
        defer { unlockFamily(backend.family) }
        let fm = FileManager.default
        let siblings = backend.variants.filter { $0 != backend && isRequested($0) }
        var doomed: [URL] = []
        // Model folders kept because a sibling's use of them is unknown (reported).
        var kept: [URL] = []
        if deleteModel {
            // An outdated environment (after an app update) still reports where its
            // weights are; only fall back to the cached/derived folders if it can't.
            // Every repo the check names counts, cached or partial, and so does the
            // service's model repo: a partial download is still gigabytes on disk.
            let status = await modelCacheStatus(backend, includeOutdated: true) ?? known
            let repos = (status?.repoIDs ?? []) + [backend.info.modelRepo].compactMap { $0 }
            let own = (status.map { $0.repoFolders + $0.derivedFolders } ?? [])
                + repos.map { paths.hubDir.appending(path: Self.cacheFolderName(repo: $0)) }
            var shared: [URL] = []
            var sharedRepos = siblings.compactMap(\.info.modelRepo)
            var siblingsKnown = true
            for sibling in siblings {
                // nil is "unknown" (a failed probe, or one quit stopped), never
                // "uses nothing": a sibling's other repos (Phonon's voices) are
                // known only from its check.
                guard let siblingStatus = await modelCacheStatus(sibling, includeOutdated: true) else {
                    siblingsKnown = false
                    continue
                }
                shared += siblingStatus.repoFolders
                sharedRepos += siblingStatus.repoIDs
            }
            var seen = Set<String>()
            let candidates = Self.unshared(own, siblingRepos: sharedRepos, siblingFolders: shared)
                .filter { seen.insert($0.standardizedFileURL.path).inserted }
            // Quit began during the siblings' checks: don't judge sharing from them.
            if siblings.isEmpty || (siblingsKnown && !shuttingDown) {
                doomed = candidates
            } else {
                kept = candidates.filter(Self.exists)
            }
        }
        if siblings.isEmpty {
            if fm.fileExists(atPath: paths.envDir(backend).path) {
                try fm.removeItem(at: paths.envDir(backend))
            }
        } else {
            try recordVariant(backend, installed: false)
        }
        // Try every folder, then report the ones that stayed: a silent leftover
        // is multiple gigabytes the user thinks are gone.
        // A folder the deletion guard refuses is reported too, never skipped.
        var failures = kept.map { "\($0.path): kept, another installed variant may use it" }
        for candidate in doomed {
            guard let folder = Self.deletionTarget(candidate, hub: paths.hubDir, derived: paths.derivedModelsDir) else {
                if Self.exists(candidate) { failures.append("\(candidate.path): outside the model caches, not deleted") }
                continue
            }
            guard Self.exists(folder) else { continue }
            do { try fm.removeItem(at: folder) } catch { failures.append("\(folder.path): \(error.localizedDescription)") }
        }
        if !failures.isEmpty {
            throw RemovalError(message: "The environment was removed, but model files remain: " + failures.joined(separator: "; "))
        }
    }
}

public struct RemovalError: LocalizedError, Sendable, Equatable {
    public var message: String
    public var errorDescription: String? { message }
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
