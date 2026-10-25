import Darwin
import Foundation

/// One Hugging Face snapshot an install downloads (a Python `SnapshotSpec`).
public struct HubSnapshot: Sendable, Equatable {
    public enum Kind: String, Sendable { case model, codec, voice }

    /// Which of the repo's files the download takes.
    public enum Files: Sendable, Equatable {
        /// `fnmatch` patterns, as `snapshot_download(allow_patterns=)` matches them
        /// (`*` also crosses `/`).
        case patterns([String])
        /// The STT helper's filter: every file but top-level dotfiles, `*.md` and `.gitattributes`.
        case allButDocs

        /// `mlx_audio.utils.DEFAULT_ALLOW_PATTERNS` (`tts_server.prefetch.DEFAULT_ALLOW_PATTERNS`).
        public static let mlxAudioDefault = Files.patterns([
            "*.json", "*.safetensors", "*.py", "*.model", "*.tiktoken", "*.txt", "*.jinja", "*.jsonl", "*.yaml",
            "*.npz", "*.pth",
        ])

        public func includes(_ path: String) -> Bool {
            switch self {
            case .patterns(let patterns):
                return patterns.contains { fnmatch($0, path, 0) == 0 }
            case .allButDocs:
                let lower = path.lowercased()
                return !path.hasPrefix(".") && !lower.hasSuffix(".md") && !lower.hasSuffix(".gitattributes")
            }
        }
    }

    public var repo: String
    /// A commit pin; nil is the repo's `main`.
    public var revision: String?
    public var files: Files
    public var kind: Kind
    /// False when the server also starts without it (optional voice files).
    public var required: Bool

    public init(
        repo: String, revision: String? = nil, files: Files = .mlxAudioDefault, kind: Kind = .model, required: Bool = true
    ) {
        self.repo = repo
        self.revision = revision
        self.files = files
        self.kind = kind
        self.required = required
    }
}

/// Approximate download size of a service, from the public Hugging Face tree API.
///
/// Sums every snapshot of `ServiceCatalog.snapshots(for:)` at its pinned revision,
/// counting only the files that snapshot's filter takes, so the figure matches
/// what the install's `prefetch` fetches.
public enum HubSizes {
    public static func downloadSize(of service: Service, session: URLSession = .shared) async -> Int64? {
        let snapshots = ServiceCatalog.snapshots(for: service)
        guard !snapshots.isEmpty else { return nil }
        var total: Int64 = 0
        for snapshot in snapshots {
            guard let bytes = await downloadSize(of: snapshot, session: session) else { return nil }
            total += bytes
        }
        return total
    }

    public static func downloadSize(of snapshot: HubSnapshot, session: URLSession = .shared) async -> Int64? {
        guard let url = treeURL(snapshot) else { return nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return size(fromTreeJSON: data, files: snapshot.files)
    }

    static func treeURL(_ snapshot: HubSnapshot) -> URL? {
        URL(string: "https://huggingface.co/api/models/\(snapshot.repo)/tree/\(snapshot.revision ?? "main")?recursive=true")
    }

    static func size(fromTreeJSON data: Data, files: HubSnapshot.Files) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var total: Int64 = 0
        for entry in entries where (entry["type"] as? String) == "file" {
            guard let path = entry["path"] as? String, files.includes(path) else { continue }
            let lfs = entry["lfs"] as? [String: Any]
            let bytes = (lfs?["size"] as? NSNumber) ?? (entry["size"] as? NSNumber)
            total += bytes?.int64Value ?? 0
        }
        return total
    }
}
