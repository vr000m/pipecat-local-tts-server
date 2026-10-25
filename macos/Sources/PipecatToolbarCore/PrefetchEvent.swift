import Foundation

/// One JSON line from `python -m tts_server prefetch --json` (see the repo README,
/// "Prefetching models") or `serve --supervised`. Every field is optional because
/// each event type carries a different subset.
public struct ServerCLIEvent: Decodable, Sendable, Equatable {
    public var event: String
    public var repo: String?
    public var revision: String?
    public var kind: String?
    public var required: Bool?
    public var cached: Bool?
    public var path: String?
    public var sizeBytes: Int64?
    public var downloadedBytes: Int64?
    public var totalBytes: Int64?
    public var filesDone: Int?
    public var filesTotal: Int?
    public var state: String?
    public var bits: Int?
    public var code: String?
    public var message: String?
    public var quantized: Bool?
    public var quantizedPath: String?
    // serve --supervised "ready"
    public var backend: String?
    public var model: String?
    public var host: String?
    public var port: Int?
    public var rate: Int?
    public var pid: Int32?

    enum CodingKeys: String, CodingKey {
        case event, repo, revision, kind, required, cached, path, state, bits, code, message
        case quantized, backend, model, host, port, rate, pid
        case sizeBytes = "size_bytes"
        case downloadedBytes = "downloaded_bytes"
        case totalBytes = "total_bytes"
        case filesDone = "files_done"
        case filesTotal = "files_total"
        case quantizedPath = "quantized_path"
    }

    /// Parses one stdout line; non-JSON lines (stray native output) return nil.
    public static func parse(_ line: String) -> ServerCLIEvent? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ServerCLIEvent.self, from: data)
    }

    /// `code` of an `error` line, when it is one of the stable supervised codes.
    public var errorCode: SupervisedErrorCode? { code.flatMap(SupervisedErrorCode.init(rawValue:)) }
}

/// The stable `code` values of a supervised server's `{"event":"error"}` line:
/// `tts_server/supervise.py`'s `CODE_*` constants (the STT helper emits a subset).
/// `tests/test_macos_catalog_drift.py` keeps the two lists equal.
public enum SupervisedErrorCode: String, Sendable, CaseIterable {
    case moduleNotFound = "ModuleNotFoundError"
    case addressInUse = "EADDRINUSE"
    case accessDenied = "EACCES"
    case socketPathConflict = "SocketPathConflict"
    case modelDownload = "ModelDownloadError"
    case config = "ConfigError"
    case backendStart = "BackendStartError"
}

/// Download progress for the model step of an install.
public struct DownloadProgress: Sendable, Equatable {
    public var repo: String
    public var downloadedBytes: Int64
    public var totalBytes: Int64
    public var filesDone: Int
    public var filesTotal: Int

    public init(repo: String, downloadedBytes: Int64 = 0, totalBytes: Int64 = 0, filesDone: Int = 0, filesTotal: Int = 0) {
        self.repo = repo
        self.downloadedBytes = downloadedBytes
        self.totalBytes = totalBytes
        self.filesDone = filesDone
        self.filesTotal = filesTotal
    }

    /// 0...1 once the byte total is known. Small metadata files finish first, so
    /// the byte fraction is the honest one; the file count only fills the gap
    /// before any byte total is known.
    public var fraction: Double? {
        if totalBytes > 0 { return min(1, Double(downloadedBytes) / Double(totalBytes)) }
        if filesTotal > 0 { return Double(filesDone) / Double(filesTotal) }
        return nil
    }
}
