import Foundation

/// `server.hello`: what the running server advertises.
public struct ServerHello: Sendable, Equatable {
    public var backend: String
    public var model: String?
    public var rate: Int
    public var channels: Int
    public var streaming: Bool
    public var voiceCount: Int
    public var maxTextChars: Int?
    public var languages: [String]
    /// `protocol_version`; defaults to nil so memberwise callers need not pass it.
    public var protocolVersion: String? = nil
}

/// A server -> client event, decoded from one JSON text frame (docs/protocol.md §5).
public enum TTSEvent: Sendable, Equatable {
    case hello(ServerHello)
    case status(voices: [String], queueDepth: Int?)
    /// `input_text.committed`: the commit whose `event_id` was `previousEventID` became `responseID`.
    case committed(responseID: String, previousEventID: String?)
    /// `input_text.cleared`, answering the clear whose `event_id` was `previousEventID`.
    case cleared(previousEventID: String?)
    case responseCreated(id: String)
    case audio(responseID: String, seq: Int, pcm: Data)
    case done(responseID: String, durationMs: Int?)
    case cancelled(responseID: String)
    case failed(responseID: String?, code: String, message: String)
    /// `previousEventID` is the `event_id` of the client frame the server refused, if it had one.
    case error(code: String, message: String, previousEventID: String?)
    case other(type: String)

    public static func decode(_ text: String) -> TTSEvent? {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let type = obj["type"] as? String
        else { return nil }
        let rid = obj["response_id"] as? String
        let previous = obj["previous_event_id"] as? String
        switch type {
        case "server.hello":
            let frame = ServerHelloFrame.decode(object: obj)
            let caps = obj["capabilities"] as? [String: Any] ?? [:]
            return .hello(
                ServerHello(
                    backend: frame?.backendName ?? "",
                    model: frame?.model,
                    rate: frame?.rate ?? 24000,
                    channels: (obj["audio"] as? [String: Any])?["channels"] as? Int ?? 1,
                    streaming: caps["streaming"] as? Bool ?? false,
                    voiceCount: caps["voice_count"] as? Int ?? 0,
                    maxTextChars: caps["max_text_chars"] as? Int,
                    languages: caps["languages"] as? [String] ?? [],
                    protocolVersion: frame?.protocolVersion))
        case "server.status":
            return .status(voices: obj["voices"] as? [String] ?? [], queueDepth: obj["queue_depth"] as? Int)
        case "input_text.committed":
            return .committed(responseID: rid ?? "", previousEventID: previous)
        case "input_text.cleared":
            return .cleared(previousEventID: previous)
        case "response.created":
            return .responseCreated(id: rid ?? "")
        case "response.audio.delta":
            guard let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) else {
                return .other(type: type)
            }
            return .audio(responseID: rid ?? "", seq: obj["seq"] as? Int ?? 0, pcm: pcm)
        case "response.audio.done":
            return .done(responseID: rid ?? "", durationMs: obj["duration_ms"] as? Int)
        case "response.cancelled":
            return .cancelled(responseID: rid ?? "")
        case "response.failed":
            let err = obj["error"] as? [String: Any]
            return .failed(
                responseID: rid, code: err?["code"] as? String ?? "backend_error",
                message: err?["message"] as? String ?? "Synthesis failed")
        case "error":
            // Nested, OpenAI-Realtime style: {type: "error", error: {type, code, message}} (docs/protocol.md §7).
            let err = obj["error"] as? [String: Any] ?? [:]
            return .error(
                code: err["code"] as? String ?? "error", message: err["message"] as? String ?? "",
                previousEventID: previous)
        default:
            return .other(type: type)
        }
    }
}

public enum TTSClientError: LocalizedError, Sendable {
    case unexpectedHandshake
    case closed

    public var errorDescription: String? {
        switch self {
        case .unexpectedHandshake: "The server did not send server.hello."
        case .closed: "The connection closed."
        }
    }
}

/// A minimal client for the local TTS server's WebSocket protocol.
///
/// `URLSessionWebSocketTask` sends no `Origin` header (the server rejects any
/// Origin with 403). One consumer calls `next()` in a loop while other tasks
/// call the send methods; actor reentrancy lets sends run while `next()` waits.
public actor TTSClient {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    public init(host: String = ServiceCatalog.host, port: Int) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 600
        session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "ws://\(host):\(port)/")!)
        request.timeoutInterval = 10
        task = session.webSocketTask(with: request)
        task.maximumMessageSize = 16 * 1024 * 1024
    }

    /// Opens the socket and waits for `server.hello`.
    public func connect() async throws -> ServerHello {
        task.resume()
        guard case .hello(let hello)? = try await next() else {
            throw TTSClientError.unexpectedHandshake
        }
        return hello
    }

    /// The next decodable server event (unknown frames are skipped).
    public func next() async throws -> TTSEvent? {
        while true {
            let message = try await task.receive()
            let text: String?
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8)
            @unknown default: text = nil
            }
            if let text, let event = TTSEvent.decode(text) { return event }
        }
    }

    public func close() {
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
    }

    /// Sends one client frame. Try it's frames come from `TTSRequestMachine`
    /// through `TTSRequestDriver`, which keeps them in order.
    public func send(_ frame: TTSClientFrame) async throws {
        try await send(frame.json)
    }

    public func send(_ object: [String: String]) async throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        try await task.send(.string(String(decoding: data, as: UTF8.self)))
    }
}

/// Little-endian pcm16 -> Float32 in [-1, 1), as the server documents its frames.
public enum PCM16 {
    public static func floats(from data: Data) -> [Float] {
        let count = data.count / 2
        var out = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                let lo = UInt16(raw[2 * i])
                let hi = UInt16(raw[2 * i + 1])
                out[i] = Float(Int16(bitPattern: lo | (hi << 8))) / 32768
            }
        }
        return out
    }
}
