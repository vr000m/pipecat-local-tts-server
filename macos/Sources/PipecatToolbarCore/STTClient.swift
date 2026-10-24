import Foundation

/// A minimal client for the stt wire protocol (`pipecat-local-stt-server`):
/// binary pcm16 (16 kHz mono) frames, then `input_audio_buffer.commit`, then one
/// `...transcription.completed` (or `.failed`).
public actor STTClient {
    public struct Hello: Sendable, Equatable {
        public var backend: String
        public var model: String?
        public var rate: Int
    }

    public enum Failure: LocalizedError, Sendable {
        case handshake, server(String), closed

        public var errorDescription: String? {
            switch self {
            case .handshake: "The server did not send server.hello."
            case .server(let message): message
            case .closed: "The connection closed before a transcript arrived."
            }
        }
    }

    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(host: String = ServiceCatalog.host, port: Int) {
        session = URLSession(configuration: .ephemeral)
        var request = URLRequest(url: URL(string: "ws://\(host):\(port)/")!)
        request.timeoutInterval = 10
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    public func connect() async throws -> Hello {
        task.resume()
        while true {
            let obj = try await nextObject()
            if obj["type"] as? String == "server.hello" {
                let backend = obj["backend"] as? [String: Any] ?? [:]
                let audio = obj["audio"] as? [String: Any] ?? [:]
                return Hello(
                    backend: backend["name"] as? String ?? "", model: backend["model"] as? String,
                    rate: audio["rate"] as? Int ?? 16000)
            }
        }
    }

    /// Sends one utterance (pcm16 LE, 16 kHz mono) and returns its transcript.
    public func transcribe(_ pcm16: Data, chunkBytes: Int = 6400) async throws -> String {
        var offset = 0
        while offset < pcm16.count {
            let end = min(offset + chunkBytes, pcm16.count)
            try await task.send(.data(pcm16.subdata(in: offset..<end)))
            offset = end
        }
        try await sendJSON(["type": "input_audio_buffer.commit"])
        while true {
            let obj = try await nextObject()
            switch obj["type"] as? String {
            case "conversation.item.input_audio_transcription.completed":
                return (obj["transcript"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            case "conversation.item.input_audio_transcription.failed":
                let err = obj["error"] as? [String: Any]
                throw Failure.server(err?["message"] as? String ?? "Transcription failed.")
            case "error":
                let err = obj["error"] as? [String: Any]
                throw Failure.server(err?["message"] as? String ?? "Server error.")
            default:
                continue
            }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    private func sendJSON(_ object: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }

    private func nextObject() async throws -> [String: Any] {
        while true {
            let message = try await task.receive()
            let data: Data?
            switch message {
            case .string(let s): data = s.data(using: .utf8)
            case .data(let d): data = d
            @unknown default: data = nil
            }
            if let data, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return obj
            }
        }
    }
}
