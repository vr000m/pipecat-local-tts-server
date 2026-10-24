import Foundation

/// Approximate download size of a model repo, from the public Hugging Face tree API.
///
/// Counts only the files mlx-audio downloads (its default allow patterns), so the
/// figure matches what `prefetch` will fetch for the main model repo.
public enum HubSizes {
    static let patterns = [
        ".json", ".safetensors", ".py", ".model", ".tiktoken", ".txt", ".jinja", ".jsonl", ".yaml", ".npz", ".pth",
    ]

    public static func downloadSize(repo: String, session: URLSession = .shared) async -> Int64? {
        guard let url = URL(string: "https://huggingface.co/api/models/\(repo)/tree/main?recursive=true") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        guard let (data, response) = try? await session.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }
        return size(fromTreeJSON: data)
    }

    static func size(fromTreeJSON data: Data) -> Int64? {
        guard let entries = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return nil }
        var total: Int64 = 0
        for entry in entries where (entry["type"] as? String) == "file" {
            guard let path = entry["path"] as? String, patterns.contains(where: { path.hasSuffix($0) }) else {
                continue
            }
            let lfs = entry["lfs"] as? [String: Any]
            let bytes = (lfs?["size"] as? NSNumber) ?? (entry["size"] as? NSNumber)
            total += bytes?.int64Value ?? 0
        }
        return total
    }
}
