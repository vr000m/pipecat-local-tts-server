import Foundation

/// Asks a loopback port who is listening: one WebSocket connect, one `server.hello`.
///
/// The only prober. Discovery and the Start path both call it, and both read the
/// hello through `ServiceInfo.entry(for:port:)`, so every caller decides the same way.
/// It speaks WebSocket (a raw connect fails the handshake) and sends no `Origin`
/// header (the TTS server answers 403 to any request that carries one), then closes
/// the connection as soon as the hello is read.
public struct ExternalProbe: Sendable {
    /// What answered on the port.
    public enum Outcome: Sendable, Equatable {
        /// A server of this catalog entry, with the hello it sent.
        case adopt(ServiceInfo, ServerHelloFrame)
        /// A server that sent a hello, but not one of the entry on this port
        /// (another backend or model, no or wrong `protocol_version`).
        case mismatch(ServerHelloFrame)
        /// The handshake failed with HTTP 401 or 403: a token is required.
        case needsToken
        /// Something accepted the connection and closed it, or sent no `server.hello`.
        case silent
        /// The connection was accepted, but no hello came before the deadline.
        case timeout
        /// Nothing listens on the port (connection refused).
        case unreachable
    }

    /// Longest wait for the hello. Below the 15 s re-probe period, so a pass never queues probes.
    // provisional: set from the Phase 1 measurement
    public static let helloTimeout: TimeInterval = 5.0

    public let helloTimeout: TimeInterval
    public let host: String

    public init(helloTimeout: TimeInterval = ExternalProbe.helloTimeout, host: String = "127.0.0.1") {
        self.helloTimeout = helloTimeout
        self.host = host
    }

    /// Connects to `port`, reads the first frame and classifies it. Never throws; a
    /// cancelled caller gets whatever outcome the cancelled connection produced
    /// (callers discard it).
    public func probe(port: Int) async -> Outcome {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        var request = URLRequest(url: URL(string: "ws://\(host):\(port)/")!)
        request.timeoutInterval = helloTimeout
        let task = session.webSocketTask(with: request)
        task.maximumMessageSize = 4 * 1024 * 1024
        let outcome = await withTaskCancellationHandler {
            await readHello(task: task, port: port)
        } onCancel: {
            task.cancel(with: .goingAway, reason: nil)
        }
        task.cancel(with: .normalClosure, reason: nil)
        session.invalidateAndCancel()
        return outcome
    }

    /// Races the first frame against the deadline.
    private func readHello(task: URLSessionWebSocketTask, port: Int) async -> Outcome {
        task.resume()
        let deadline = helloTimeout
        return await withTaskGroup(of: Outcome.self) { group in
            group.addTask { await Self.firstFrame(of: task, port: port) }
            group.addTask {
                try? await Task.sleep(for: .seconds(deadline))
                return .timeout
            }
            let first = await group.next() ?? .timeout
            // Closing the socket unblocks a `receive()` that is still waiting.
            task.cancel(with: .normalClosure, reason: nil)
            group.cancelAll()
            return first
        }
    }

    private static func firstFrame(of task: URLSessionWebSocketTask, port: Int) async -> Outcome {
        do {
            let message = try await task.receive()
            let text: String?
            switch message {
            case .string(let s): text = s
            case .data(let d): text = String(data: d, encoding: .utf8)
            @unknown default: text = nil
            }
            // The hello is the first frame on every connection; anything else did not identify itself.
            guard let text, let hello = ServerHelloFrame.decode(text) else { return .silent }
            if let entry = ServiceInfo.entry(for: hello, port: port) { return .adopt(entry, hello) }
            return .mismatch(hello)
        } catch {
            return outcome(for: error, httpStatus: (task.response as? HTTPURLResponse)?.statusCode)
        }
    }

    /// The error mapping: refused (-1004) is `unreachable`; -1001 is `timeout`; a socket that
    /// closes without a hello (-1005) is `silent`; a failed upgrade (-1011) carrying HTTP
    /// 401/403 is `needsToken`. Any other failure is `silent`: something answered, and
    /// nothing identified itself.
    static func outcome(for error: Error, httpStatus: Int?) -> Outcome {
        if httpStatus == 401 || httpStatus == 403 { return .needsToken }
        switch (error as? URLError)?.code {
        case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed: return .unreachable
        case .timedOut: return .timeout
        default: return .silent
        }
    }
}

extension ExternalProbe.Outcome {
    /// The one test of "this `adopt` is the server of the service on `port`": the entry
    /// `ServiceInfo.entry(for:port:)` matched is the one that owns `port`. Discovery
    /// (`ExternalDiscoveryPolicy`) and the Start path (`ServiceLifecycle`) both ask it.
    /// Nil for every other outcome.
    public func adoptedInfo(onPort port: Int) -> ExternalInfo? {
        guard case .adopt(let entry, let hello) = self, entry.port == port else { return nil }
        return ExternalInfo(hello: hello)
    }
}
