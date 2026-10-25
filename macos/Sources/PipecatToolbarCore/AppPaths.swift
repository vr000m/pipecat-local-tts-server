import Foundation

/// Where the app keeps its managed Python, per-service environments, caches and logs.
///
/// Model weights are NOT here: the server uses the standard Hugging Face cache
/// (`~/.cache/huggingface`), so weights are shared with CLI and launchd use.
public struct AppPaths: Sendable {
    public static let layoutVersion = 1

    public static let folderName = "Pipecat Service Toolbar"

    /// `~/Library/Application Support/Pipecat Service Toolbar`
    public let supportDir: URL
    /// `~/Library/Caches/Pipecat Service Toolbar`
    public let cacheDir: URL
    /// `~/Library/Logs/Pipecat Service Toolbar`
    public let logsDir: URL
    /// The shared Hugging Face hub cache (`huggingFaceHub()`); the only place
    /// downloaded repo folders are deleted from.
    public let hubDir: URL
    /// The TTS server's derived weights (`ttsServerCache()`); the only other
    /// place model files are deleted from.
    public let derivedModelsDir: URL

    public init(
        supportDir: URL, cacheDir: URL, logsDir: URL,
        hubDir: URL = AppPaths.huggingFaceHub(), derivedModelsDir: URL = AppPaths.ttsServerCache()
    ) {
        self.supportDir = supportDir
        self.cacheDir = cacheDir
        self.logsDir = logsDir
        self.hubDir = hubDir
        self.derivedModelsDir = derivedModelsDir
    }

    public static func standard(supportOverride: URL? = nil) -> AppPaths {
        let fm = FileManager.default
        let library = fm.homeDirectoryForCurrentUser.appending(path: "Library")
        return AppPaths(
            supportDir: supportOverride ?? library.appending(path: "Application Support/\(folderName)"),
            cacheDir: library.appending(path: "Caches/\(folderName)"),
            logsDir: library.appending(path: "Logs/\(folderName)"))
    }

    /// The Hugging Face hub cache the servers use (`HF_HUB_CACHE`, `HF_HOME`, `XDG_CACHE_HOME`, else `~/.cache`).
    public static func huggingFaceHub(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let cache = environment["HF_HUB_CACHE"] { return URL(filePath: cache) }
        if let hf = environment["HF_HOME"] { return URL(filePath: hf).appending(path: "hub") }
        if let xdg = environment["XDG_CACHE_HOME"] { return URL(filePath: xdg).appending(path: "huggingface/hub") }
        return home.appending(path: ".cache/huggingface/hub")
    }

    /// Where the TTS server keeps weights it derives (Phonon's quantized copies):
    /// `$XDG_CACHE_HOME/pipecat-tts-server`, else `~/.cache/pipecat-tts-server`
    /// (`tts_server/backends/phonon.py` `_cache_root`).
    public static func ttsServerCache(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        let root = environment["XDG_CACHE_HOME"].map { URL(filePath: $0) } ?? home.appending(path: ".cache")
        return root.appending(path: "pipecat-tts-server")
    }

    /// uv-managed CPython installs (`UV_PYTHON_INSTALL_DIR`).
    public var pythonDir: URL { supportDir.appending(path: "python") }
    /// uv's package cache (`UV_CACHE_DIR`).
    public var uvCacheDir: URL { cacheDir.appending(path: "uv") }
    public var envsDir: URL { supportDir.appending(path: "envs") }
    public var layoutFile: URL { supportDir.appending(path: ".layout-version") }

    /// The environment a service runs in: its family's, shared by every variant.
    public func envDir(_ service: Service) -> URL { envsDir.appending(path: service.family.rawValue) }
    public func python(_ service: Service) -> URL { envDir(service).appending(path: "bin/python") }
    public func marker(_ service: Service) -> URL { envDir(service).appending(path: ".pipecat-toolbar.json") }
    /// `envs/<family>/.variants/`: one empty file per variant the user installed.
    public func variantsDir(_ service: Service) -> URL { envDir(service).appending(path: ".variants") }
    public func variantMarker(_ service: Service) -> URL { variantsDir(service).appending(path: service.rawValue) }
    public func appLog(_ service: Service) -> URL { logsDir.appending(path: "\(service.rawValue).app.log") }

    /// Creates the top-level directories and records the layout version.
    /// Returns false when an incompatible layout from another app version is present.
    @discardableResult
    public func prepare() throws -> Bool {
        let fm = FileManager.default
        for dir in [supportDir, cacheDir, logsDir, envsDir] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        if let text = try? String(contentsOf: layoutFile, encoding: .utf8),
            let found = Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            return found == Self.layoutVersion
        }
        try "\(Self.layoutVersion)\n".write(to: layoutFile, atomically: true, encoding: .utf8)
        return true
    }
}

/// Written into each environment after a successful install.
public struct EnvironmentMarker: Codable, Sendable, Equatable {
    public var service: String
    /// What the environment was built from (the wheel name for TTS, the pinned
    /// requirements for STT). A mismatch means the app was updated since.
    public var fingerprint: String
    public var python: String
    public var createdAt: Date

    public init(service: String, fingerprint: String, python: String, createdAt: Date) {
        self.service = service
        self.fingerprint = fingerprint
        self.python = python
        self.createdAt = createdAt
    }

    public static func read(_ url: URL) -> EnvironmentMarker? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(EnvironmentMarker.self, from: data)
    }

    public func write(_ url: URL) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
