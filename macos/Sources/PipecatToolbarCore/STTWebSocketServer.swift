import Foundation
import Network

/// A loopback WebSocket server speaking the stt wire protocol of
/// `pipecat-local-stt-server` (docs/protocol.md there), around any transcriber.
///
/// The app runs Apple's SpeechAnalyzer through this, so a Pipecat bot's
/// `LocalWebSocketSTTService` can use it exactly like the Python engines.
/// Commit-oriented like the reference server: binary (or base64) pcm16 at
/// 16 kHz mono accumulates until `input_audio_buffer.commit`, then one delta and
/// one completed event carry the transcript. Requests with an `Origin` header
/// are refused, as in the Python servers.
public final class STTWebSocketServer: @unchecked Sendable {
    public typealias Transcriber = @Sendable (_ pcm16: Data, _ language: String?) async throws -> String

    public struct Identity: Sendable {
        public var name: String
        public var model: String?
        public init(name: String, model: String?) {
            self.name = name
            self.model = model
        }
    }

    public enum StartError: LocalizedError, Sendable {
        case addressInUse(Int), failed(String)

        public var errorDescription: String? {
            switch self {
            case .addressInUse(let port): "Port \(port) is already in use."
            case .failed(let message): message
            }
        }
    }

    static let maxBufferBytes = 300 * 16000 * 2  // 300 s, as in the reference server

    let identity: Identity
    let transcriber: Transcriber
    let queue = DispatchQueue(label: "ai.pipecat.toolbar.stt-server")
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: STTServerConnection] = [:]
    /// Called on the server queue with human-readable log lines.
    public var onLog: (@Sendable (String) -> Void)?

    public init(identity: Identity, transcriber: @escaping Transcriber) {
        self.identity = identity
        self.transcriber = transcriber
    }

    /// Binds 127.0.0.1:`port` (0 = any free port) and returns the bound port.
    public func start(port: Int) async throws -> Int {
        let params = NWParameters.tcp
        let ws = NWProtocolWebSocket.Options()
        ws.autoReplyPing = true
        ws.maximumMessageSize = 4 * 1024 * 1024
        ws.setClientRequestHandler(queue) { _, headers in
            let browser = headers.contains { $0.name.caseInsensitiveCompare("Origin") == .orderedSame }
            return NWProtocolWebSocket.Response(status: browser ? .reject : .accept, subprotocol: nil)
        }
        params.defaultProtocolStack.applicationProtocols.insert(ws, at: 0)
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let session = STTServerConnection(connection: connection, server: self)
            self.connections[ObjectIdentifier(session)] = session
            session.start()
        }
        let once = OnceFlag()
        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    if once.claim() {
                        let bound = Int(listener.port?.rawValue ?? UInt16(port))
                        self?.onLog?("listening on \(ServiceCatalog.host):\(bound)")
                        continuation.resume(returning: bound)
                    }
                case .failed(let error):
                    listener.cancel()
                    if once.claim() {
                        if case .posix(let code) = error, code == .EADDRINUSE {
                            continuation.resume(throwing: StartError.addressInUse(port))
                        } else {
                            continuation.resume(throwing: StartError.failed(error.localizedDescription))
                        }
                    }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            listener?.cancel()
            listener = nil
            for session in connections.values { session.close() }
            connections.removeAll()
        }
    }

    func remove(_ session: STTServerConnection) {
        connections[ObjectIdentifier(session)] = nil
    }
}

private final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool {
        lock.withLock {
            defer { claimed = true }
            return !claimed
        }
    }
}

/// One client session. All state is confined to the server's queue.
final class STTServerConnection: @unchecked Sendable {
    private let connection: NWConnection
    unowned let server: STTWebSocketServer
    private let sessionID = "sess_" + STTServerConnection.hex()
    private var buffer = Data()
    private var language: String?
    private var decode: Task<Void, Never>?
    private var closed = false
    private let started = Date()

    init(connection: NWConnection, server: STTWebSocketServer) {
        self.connection = connection
        self.server = server
    }

    static func hex() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16).description }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.sendHello()
                self.receive()
            case .failed, .cancelled:
                self.teardown()
            default:
                break
            }
        }
        connection.start(queue: server.queue)
    }

    func close() {
        guard !closed else { return }
        closed = true
        decode?.cancel()
        connection.cancel()
    }

    private func teardown() {
        closed = true
        decode?.cancel()
        server.remove(self)
    }

    // MARK: Receive

    private func receive() {
        connection.receiveMessage { [weak self] data, context, _, error in
            guard let self, !self.closed else { return }
            if error != nil {
                self.close()
                return
            }
            let meta = context?.protocolMetadata(definition: NWProtocolWebSocket.definition) as? NWProtocolWebSocket.Metadata
            switch meta?.opcode {
            case .binary:
                self.appendAudio(data ?? Data())
            case .text:
                self.handleText(data ?? Data())
            case .close:
                self.close()
                return
            default:
                break
            }
            self.receive()
        }
    }

    private func appendAudio(_ chunk: Data) {
        if decode != nil {
            return sendError("invalid_event", "audio append while previous decode in flight")
        }
        if buffer.count + chunk.count > STTWebSocketServer.maxBufferBytes {
            return sendError("buffer_overflow", "uncommitted audio exceeds 300 s")
        }
        buffer.append(chunk)
    }

    private func handleText(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return sendError("invalid_json", "message is not a JSON object")
        }
        let clientEventID = obj["event_id"] as? String
        switch obj["type"] as? String {
        case "session.update", "transcription_session.update":
            let session = obj["session"] as? [String: Any] ?? obj
            if let td = session["turn_detection"], !(td is NSNull) {
                return sendError("invalid_config", "server VAD is not implemented; use turn_detection: null", clientEventID)
            }
            let transcription = session["input_audio_transcription"] as? [String: Any]
            if let lang = (transcription?["language"] ?? session["language"]) as? String {
                language = lang.isEmpty || lang == "auto" ? nil : lang
            }
            for type in ["session.updated", "transcription_session.updated"] {
                send(["type": type, "event_id": event(), "session": snapshot()])
            }
        case "input_audio_buffer.append":
            guard let b64 = obj["audio"] as? String, let pcm = Data(base64Encoded: b64) else {
                return sendError("invalid_event", "append needs base64 'audio'", clientEventID)
            }
            appendAudio(pcm)
        case "input_audio_buffer.commit":
            commit(clientEventID)
        case "input_audio_buffer.clear":
            if decode != nil { return sendError("invalid_event", "clear while decode in flight", clientEventID) }
            buffer.removeAll()
            send(["type": "input_audio_buffer.cleared", "event_id": event()])
        case "server.status":
            send([
                "type": "server.status", "event_id": event(), "session_id": sessionID,
                "backend": backendObject(), "audio": audioObject(),
                "queue_depth": decode == nil ? 0 : 1, "uncommitted_bytes": buffer.count,
                "uptime_seconds": Date().timeIntervalSince(started),
                "pid": Int(ProcessInfo.processInfo.processIdentifier),
            ])
        case "session.close":
            finishSession(reason: "client_close", waitForDecode: true)
        case "session.cancel":
            decode?.cancel()
            finishSession(reason: "client_cancel", waitForDecode: false)
        default:
            sendError("unsupported_event", "unknown event: \(obj["type"] ?? "nil")", clientEventID)
        }
    }

    private func commit(_ clientEventID: String?) {
        guard !buffer.isEmpty else { return sendError("buffer_empty", "commit on empty buffer", clientEventID) }
        guard decode == nil else { return sendError("invalid_event", "commit while previous decode in flight", clientEventID) }
        let audio = buffer
        buffer.removeAll()
        let item = "item_" + Self.hex()
        var committed: [String: Any] = ["type": "input_audio_buffer.committed", "event_id": event(), "item_id": item]
        if let clientEventID { committed["previous_event_id"] = clientEventID }
        send(committed)
        let transcriber = server.transcriber
        let language = language
        let queue = server.queue
        let log = server.onLog
        let session = self
        decode = Task {
            let started = Date()
            let result: Result<String, Error>
            do { result = .success(try await transcriber(audio, language)) } catch { result = .failure(error) }
            let cancelled = Task.isCancelled
            queue.async {
                let `self` = session
                self.decode = nil
                guard !cancelled, !self.closed else { return }
                switch result {
                case .success(let text):
                    log?(String(format: "transcribed %.1f s of audio in %.2f s", Double(audio.count) / 32000, Date().timeIntervalSince(started)))
                    self.send(["type": "conversation.item.input_audio_transcription.delta", "event_id": self.event(), "item_id": item, "content_index": 0, "delta": text])
                    self.send(["type": "conversation.item.input_audio_transcription.completed", "event_id": self.event(), "item_id": item, "content_index": 0, "transcript": text])
                case .failure(let error):
                    log?("transcription failed: \(error.localizedDescription)")
                    self.send([
                        "type": "conversation.item.input_audio_transcription.failed", "event_id": self.event(),
                        "item_id": item, "content_index": 0,
                        "error": ["type": "server_error", "code": "backend_error", "message": "backend decode failed"],
                    ])
                }
                if let pending = self.pendingClose { self.pendingClose = nil; self.finishSession(reason: pending, waitForDecode: false) }
            }
        }
    }

    private var pendingClose: String?

    private func finishSession(reason: String, waitForDecode: Bool) {
        if waitForDecode, decode != nil {
            pendingClose = reason
            return
        }
        send(["type": "session.closed", "event_id": event(), "session_id": sessionID, "reason": reason])
        let session = self
        connection.send(
            content: nil,
            contentContext: NWConnection.ContentContext(identifier: "close", metadata: [NWProtocolWebSocket.Metadata(opcode: .close)]),
            isComplete: true, completion: .contentProcessed { _ in session.server.queue.async { session.close() } })
    }

    // MARK: Send

    private func sendHello() {
        send([
            "type": "server.hello", "event_id": event(), "protocol_version": "0.1",
            "capabilities": ["binary_audio": true, "base64_audio_append": true, "server_vad": false],
            "audio": audioObject(), "backend": backendObject(),
        ])
        for type in ["session.created", "transcription_session.created"] {
            send(["type": type, "event_id": event(), "session": snapshot()])
        }
    }

    private func sendError(_ code: String, _ message: String, _ clientEventID: String? = nil) {
        var err: [String: Any] = ["type": "invalid_request_error", "code": code, "message": message]
        if let clientEventID { err["event_id"] = clientEventID }
        send(["type": "error", "event_id": event(), "error": err])
    }

    private func send(_ object: [String: Any]) {
        guard !closed, let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        let context = NWConnection.ContentContext(identifier: "text", metadata: [NWProtocolWebSocket.Metadata(opcode: .text)])
        connection.send(content: data, contentContext: context, isComplete: true, completion: .contentProcessed { _ in })
    }

    private func event() -> String { "evt_" + Self.hex() }

    /// A JSON value for an optional string (`null` when absent).
    static func json(_ value: String?) -> Any { value.map { $0 as Any } ?? NSNull() }

    private func backendObject() -> [String: Any] {
        ["name": server.identity.name, "model": Self.json(server.identity.model)]
    }

    private func audioObject() -> [String: Any] { ["format": "pcm16", "rate": 16000, "channels": 1] }

    private func snapshot() -> [String: Any] {
        [
            "id": sessionID, "object": "realtime.transcription_session", "type": "transcription",
            "input_audio_format": "pcm16", "turn_detection": NSNull(),
            "input_audio_transcription": ["language": Self.json(language)],
        ]
    }
}
