import Foundation

/// Appends a server's stderr to `~/Library/Logs/pipecat-tts/<backend>.app.log`,
/// rotating once to `.1` past 20 MB.
@MainActor
final class LogSink {
    static let maxBytes: UInt64 = 20 * 1024 * 1024
    let url: URL
    private var handle: FileHandle?

    init(url: URL) {
        self.url = url
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? UInt64, size > Self.maxBytes {
            let rotated = url.appendingPathExtension("1")
            try? fm.removeItem(at: rotated)
            try? fm.moveItem(at: url, to: rotated)
        }
        if !fm.fileExists(atPath: url.path) { fm.createFile(atPath: url.path, contents: nil) }
        handle = try? FileHandle(forWritingTo: url)
        _ = try? handle?.seekToEnd()
    }

    func write(_ line: String) {
        guard let handle, let data = (line + "\n").data(using: .utf8) else { return }
        try? handle.write(contentsOf: data)
    }

    func close() {
        try? handle?.close()
        handle = nil
    }
}
