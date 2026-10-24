import Foundation

/// What the app needs to build and run environments: `uv`, the TTS server wheel
/// (with its `uv.lock` pins), and the helper script the STT engines run.
public struct Tools: Sendable, Equatable {
    public enum Source: String, Sendable { case bundle, override, repository }

    public let uv: URL
    public let wheel: URL
    /// Pins exported from `uv.lock` so TTS environments match what CI tests.
    public let constraints: URL?
    /// `pipecat_app_helper.py` (STT prefetch and supervised serving).
    public let helper: URL?
    public let source: Source

    public init(uv: URL, wheel: URL, constraints: URL?, helper: URL?, source: Source) {
        self.uv = uv.absoluteURL
        self.wheel = wheel.absoluteURL
        self.constraints = constraints?.absoluteURL
        self.helper = helper?.absoluteURL
        self.source = source
    }

    /// e.g. `pipecat_local_tts_server-0.7.0-py3-none-any.whl`
    public var wheelName: String { wheel.lastPathComponent }

    /// What a service's environment is built from; a change means "reinstall packages".
    public func fingerprint(for info: ServiceInfo) -> String {
        switch info.runtime {
        case .ttsServer: wheelName
        case .sttHelper(_, let requirements): requirements.joined(separator: " ")
        case .appleSpeech: "system"
        }
    }
}

public enum ToolLocatorError: LocalizedError, Sendable {
    case uvNotFound
    case wheelNotFound
    case buildFailed(String)

    public var errorDescription: String? {
        switch self {
        case .uvNotFound:
            "uv was not found. Install it (https://docs.astral.sh/uv/) or set PIPECAT_TOOLBAR_UV."
        case .wheelNotFound:
            "The server wheel was not found. Build the app with `just app-build`, or set PIPECAT_TOOLBAR_WHEEL."
        case .buildFailed(let detail):
            "Building the server wheel failed: \(detail)"
        }
    }
}

/// Finds the tools. Order: the app bundle, then environment overrides
/// (`PIPECAT_TOOLBAR_UV`, `_WHEEL`, `_CONSTRAINTS`, `_HELPER`), then, when running
/// unbundled from a checkout (`swift run`), a wheel built from the repo.
public enum ToolLocator {
    public static func locate(
        bundle: Bundle = .main,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        paths: AppPaths
    ) async throws -> Tools {
        let fm = FileManager.default

        if let resources = bundle.resourceURL {
            let uv = resources.appending(path: "bin/uv")
            let wheels = resources.appending(path: "wheels")
            if fm.isExecutableFile(atPath: uv.path),
                let name = try? String(contentsOf: wheels.appending(path: "MANIFEST"), encoding: .utf8)
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !name.isEmpty, fm.fileExists(atPath: wheels.appending(path: name).path)
            {
                let constraints = wheels.appending(path: "constraints.txt")
                let helper = resources.appending(path: "helper/pipecat_app_helper.py")
                return Tools(
                    uv: uv, wheel: wheels.appending(path: name),
                    constraints: fm.fileExists(atPath: constraints.path) ? constraints : nil,
                    helper: fm.fileExists(atPath: helper.path) ? helper : nil,
                    source: .bundle)
            }
        }

        guard let uv = findUV(environment: environment) else { throw ToolLocatorError.uvNotFound }

        let repo = findRepositoryRoot(environment: environment)
        let helper = environment["PIPECAT_TOOLBAR_HELPER"].map { URL(filePath: $0) }
            ?? repo.map { $0.appending(path: "macos/Helper/pipecat_app_helper.py") }

        if let wheelPath = environment["PIPECAT_TOOLBAR_WHEEL"], fm.fileExists(atPath: wheelPath) {
            let constraints = environment["PIPECAT_TOOLBAR_CONSTRAINTS"].map { URL(filePath: $0) }
            return Tools(uv: uv, wheel: URL(filePath: wheelPath), constraints: constraints, helper: helper, source: .override)
        }

        guard let repo else { throw ToolLocatorError.wheelNotFound }
        return try await buildFromRepository(repo, uv: uv, helper: helper, paths: paths)
    }

    static func findUV(environment: [String: String]) -> URL? {
        let fm = FileManager.default
        var candidates: [String] = []
        if let explicit = environment["PIPECAT_TOOLBAR_UV"] { candidates.append(explicit) }
        let home = fm.homeDirectoryForCurrentUser.path
        candidates += ["\(home)/.local/bin/uv", "\(home)/.cargo/bin/uv", "/opt/homebrew/bin/uv", "/usr/local/bin/uv"]
        for dir in (environment["PATH"] ?? "").split(separator: ":") {
            candidates.append("\(dir)/uv")
        }
        return candidates.first(where: fm.isExecutableFile(atPath:)).map { URL(filePath: $0) }
    }

    /// Walks up from the executable and the working directory to this repo's root.
    static func findRepositoryRoot(environment: [String: String]) -> URL? {
        var starts = [Bundle.main.executableURL?.deletingLastPathComponent()]
        starts.append(URL(filePath: FileManager.default.currentDirectoryPath))
        if let explicit = environment["PIPECAT_TOOLBAR_REPO"] { starts.insert(URL(filePath: explicit), at: 0) }
        for start in starts.compactMap({ $0 }) {
            var dir = start.standardizedFileURL
            while dir.path != "/" {
                let pyproject = dir.appending(path: "pyproject.toml")
                if let text = try? String(contentsOf: pyproject, encoding: .utf8),
                    text.contains("name = \"pipecat-local-tts-server\"")
                {
                    return dir
                }
                dir.deleteLastPathComponent()
            }
        }
        return nil
    }

    static func buildFromRepository(_ repo: URL, uv: URL, helper: URL?, paths: AppPaths) async throws -> Tools {
        let out = paths.cacheDir.appending(path: "dev-wheel")
        try? FileManager.default.removeItem(at: out)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let env = ProcessEnvironment.base()

        let build = Subprocess(
            .init(
                executable: uv, arguments: ["build", "--wheel", "--out-dir", out.path],
                environment: env, currentDirectory: repo))
        let built = try await build.collect()
        guard built.status == 0 else {
            throw ToolLocatorError.buildFailed((built.stderr.suffix(3)).joined(separator: "\n"))
        }
        let wheel = try FileManager.default.contentsOfDirectory(at: out, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasPrefix("pipecat_local_tts_server-") && $0.pathExtension == "whl" }
        guard let wheel else { throw ToolLocatorError.wheelNotFound }

        let constraints = out.appending(path: "constraints.txt")
        let export = Subprocess(
            .init(
                executable: uv,
                arguments: [
                    "export", "--all-extras", "--no-dev", "--no-hashes", "--no-emit-project",
                    "--format", "requirements.txt", "--output-file", constraints.path,
                ],
                environment: env, currentDirectory: repo))
        let exported = try await export.collect()
        return Tools(
            uv: uv, wheel: wheel, constraints: exported.status == 0 ? constraints : nil,
            helper: helper.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil },
            source: .repository)
    }
}

/// The minimal, explicit environment every child process starts from.
///
/// GUI apps inherit almost nothing from launchd, and `swift run` inherits a whole
/// developer shell; spelling it out gives both the same behaviour.
public enum ProcessEnvironment {
    public static func base() -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [
            "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
            "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
            "LANG": "en_US.UTF-8",
            "LC_ALL": "en_US.UTF-8",
            "PYTHONUNBUFFERED": "1",
            "PYTHONIOENCODING": "utf-8",
            "NO_COLOR": "1",
            "TERM": "dumb",
            "HF_HUB_DISABLE_TELEMETRY": "1",
            "DO_NOT_TRACK": "1",
        ]
        env["TMPDIR"] = inherited["TMPDIR"] ?? NSTemporaryDirectory()
        // Honour a user's own Hugging Face configuration (cache location, token).
        for key in ["HF_HOME", "HF_HUB_CACHE", "HF_TOKEN", "XDG_CACHE_HOME", "PIPECAT_TTS_PHONON_VOICES"] {
            if let value = inherited[key] { env[key] = value }
        }
        return env
    }

    /// `base()` plus the uv settings that keep the app's Python fully self-contained.
    public static func uv(paths: AppPaths) -> [String: String] {
        var env = base()
        env["UV_PYTHON_INSTALL_DIR"] = paths.pythonDir.path
        env["UV_CACHE_DIR"] = paths.uvCacheDir.path
        env["UV_PYTHON_PREFERENCE"] = "only-managed"
        env["UV_NO_CONFIG"] = "1"
        env["UV_NO_PROGRESS"] = "1"
        return env
    }
}
