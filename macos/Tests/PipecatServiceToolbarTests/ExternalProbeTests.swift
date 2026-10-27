import CryptoKit
import Darwin
import Foundation
import Network
import Testing

@testable import PipecatToolbarCore

/// A loopback fake of a Pipecat speech server's WebSocket endpoint, with a scripted
/// answer to the upgrade and an injectable hello delay. It speaks the handshake and one
/// unmasked text frame by hand so a test can also script what a real server does badly:
/// answer 401/403, close without a hello, hold the upgrade, or send the hello late.
/// It records the headers of every request, so a test can assert what the probe sent.
final class FakeHelloServer: @unchecked Sendable {
    enum Behavior: Sendable {
        /// Upgrade, then send `json` as the first text frame after `delay` seconds.
        case hello(String, delay: TimeInterval = 0)
        /// Answer the upgrade with this HTTP status (401 and 403 are the token cases).
        case reject(status: Int)
        /// Upgrade, then close the socket without sending any frame.
        case closeWithoutHello
        /// Upgrade and keep the socket open forever (a listener that never says hello).
        case upgradeAndStaySilent
        /// Accept the TCP connection and never answer the request.
        case holdWithoutUpgrade
    }

    struct BindError: Error, CustomStringConvertible {
        let port: Int
        let reason: String
        var description: String { "could not bind 127.0.0.1:\(port): \(reason)" }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func claim() -> Bool { lock.withLock { defer { done = true }; return !done } }
    }

    let behavior: Behavior
    private let queue = DispatchQueue(label: "ai.pipecat.toolbar.tests.fake-hello")
    private let lock = NSLock()
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var requests: [[String: String]] = []
    private var _port = 0

    var port: Int { lock.withLock { _port } }

    /// Every request received, as lowercased header name to value (the request line is
    /// under `":request"`).
    var receivedRequests: [[String: String]] { lock.withLock { requests } }

    init(_ behavior: Behavior) { self.behavior = behavior }

    /// Binds 127.0.0.1:`port` (0 = any free port). Throws `BindError` when it is taken.
    static func start(_ behavior: Behavior, port: Int = 0) async throws -> FakeHelloServer {
        let server = FakeHelloServer(behavior)
        try await server.listen(port: port)
        return server
    }

    /// A loopback TCP port with nothing listening on it.
    static func closedPort() -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) }
        }
        var bound = sockaddr_in()
        var length = size
        _ = withUnsafeMutablePointer(to: &bound) { p in
            p.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        return Int(UInt16(bigEndian: bound.sin_port))
    }

    func stop() {
        let (listener, connections) = lock.withLock { () -> (NWListener?, [NWConnection]) in
            defer { self.listener = nil; self.connections = [] }
            return (self.listener, self.connections)
        }
        listener?.cancel()
        for connection in connections { connection.cancel() }
    }

    // MARK: Listening

    private func listen(port: Int) async throws {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(
            host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: UInt16(port)) ?? .any)
        let listener = try NWListener(using: params)
        lock.withLock { self.listener = listener }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            self.accept(connection)
        }
        let once = Once()
        let bound: Int = try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    if once.claim() { continuation.resume(returning: Int(listener.port?.rawValue ?? UInt16(port))) }
                case .failed(let error):
                    listener.cancel()
                    if once.claim() {
                        continuation.resume(throwing: BindError(port: port, reason: "\(error)"))
                    }
                case .cancelled:
                    if once.claim() { continuation.resume(throwing: CancellationError()) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
        lock.withLock { _port = bound }
    }

    private func accept(_ connection: NWConnection) {
        lock.withLock { connections.append(connection) }
        connection.start(queue: queue)
        if case .holdWithoutUpgrade = behavior { return }
        readRequest(connection, buffer: Data())
    }

    private func readRequest(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }
            if let end = buffer.range(of: Data("\r\n\r\n".utf8)) {
                self.handle(String(decoding: buffer[..<end.lowerBound], as: UTF8.self), on: connection)
            } else if error != nil || isComplete {
                connection.cancel()
            } else {
                self.readRequest(connection, buffer: buffer)
            }
        }
    }

    private func handle(_ head: String, on connection: NWConnection) {
        var headers: [String: String] = [:]
        let lines = head.components(separatedBy: "\r\n")
        headers[":request"] = lines.first ?? ""
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].lowercased()
            headers[name] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        lock.withLock { requests.append(headers) }

        switch behavior {
        case .reject(let status):
            let reason = status == 401 ? "Unauthorized" : "Forbidden"
            let response = "HTTP/1.1 \(status) \(reason)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            send(Data(response.utf8), on: connection) { connection.cancel() }
        case .closeWithoutHello:
            upgrade(connection, headers) { connection.cancel() }
        case .upgradeAndStaySilent:
            upgrade(connection, headers) {}
        case .hello(let json, let delay):
            upgrade(connection, headers) { [queue] in
                let frame = Self.textFrame(json)
                if delay <= 0 {
                    self.send(frame, on: connection) {}
                } else {
                    queue.asyncAfter(deadline: .now() + delay) { self.send(frame, on: connection) {} }
                }
            }
        case .holdWithoutUpgrade:
            break
        }
    }

    private func upgrade(_ connection: NWConnection, _ headers: [String: String], then next: @escaping @Sendable () -> Void) {
        guard let key = headers["sec-websocket-key"] else { return connection.cancel() }
        let digest = Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))
        let accept = Data(digest).base64EncodedString()
        let response =
            "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        send(Data(response.utf8), on: connection, then: next)
    }

    private func send(_ data: Data, on connection: NWConnection, then next: @escaping @Sendable () -> Void) {
        connection.send(content: data, completion: .contentProcessed { _ in next() })
    }

    /// One unmasked server-to-client text frame (RFC 6455 section 5.2).
    static func textFrame(_ text: String) -> Data {
        let payload = Data(text.utf8)
        var frame = Data([0x81])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else {
            precondition(payload.count <= 0xFFFF, "fixture hello too large")
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        }
        return frame + payload
    }
}

/// `ExternalProbe`: one loopback port, one `server.hello`, one of six outcomes.
///
/// The fakes bind loopback ephemeral ports, which belong to no catalog entry: every hello
/// there is a `mismatch` (the port check), and that is what the timing and the HTTP
/// cases assert. An `adopt` needs the hello to arrive on the entry's own port, so those
/// tests bind a catalog port that nothing on the machine is serving (the services below
/// are the ones a developer rarely runs as LaunchAgents) and return early when none is free.
@Suite(.serialized) struct ExternalProbeTests {
    /// Short enough to wait out in a test, long enough that a local hello beats it.
    static let shortTimeout: TimeInterval = 0.1
    static let patientTimeout: TimeInterval = 5

    static let adoptCandidates: [Service] = [.dia, .fishTTS, .qwen3TTS, .voxtralTTS, .phononQ8, .phononQ4]

    /// A fake on the first free catalog port of `adoptCandidates`, behaving as `behavior`
    /// says for that service; nil when every candidate port is taken.
    static func onCatalogPort(
        _ behavior: (Service) -> FakeHelloServer.Behavior
    ) async -> (server: FakeHelloServer, service: Service)? {
        for service in adoptCandidates {
            if let server = try? await FakeHelloServer.start(behavior(service), port: service.info.port) {
                return (server, service)
            }
        }
        print("ExternalProbeTests: every candidate catalog port is busy; skipping the adopt-path assertion")
        return nil
    }

    static func probe(_ port: Int, timeout: TimeInterval = patientTimeout) async -> ExternalProbe.Outcome {
        await ExternalProbe(helloTimeout: timeout).probe(port: port)
    }

    // MARK: Constant

    @Test func defaultHelloTimeoutStaysBelowTheReprobePeriod() {
        // A discovery pass probes each port once per period and skips a port still in flight.
        #expect(ExternalProbe.helloTimeout > 0)
        #expect(Duration.milliseconds(Int(ExternalProbe.helloTimeout * 1000)) < ExternalDiscoveryPolicy.period)
        #expect(ExternalProbe().helloTimeout == ExternalProbe.helloTimeout)
    }

    // MARK: Outcomes

    @Test func closedPortIsUnreachable() async throws {
        let outcome = await Self.probe(FakeHelloServer.closedPort())
        #expect(outcome == .unreachable)
    }

    @Test func matchingHelloOnTheEntrysPortIsAdopted() async throws {
        guard
            let (server, service) = await Self.onCatalogPort({ s in
                .hello(HelloFixtures.json(for: s))
            })
        else { return }
        defer { server.stop() }
        guard case .adopt(let info, let frame) = await Self.probe(server.port) else {
            Issue.record("expected adopt")
            return
        }
        let reported = HelloFixtures.reported(service)
        #expect(info.service == service)
        #expect(frame.backendName == reported.name && frame.model == reported.model)
        #expect(frame.protocolVersion == "0.1")
        #expect(frame.rate == reported.rate)
    }

    @Test func helloForAnotherBackendIsAMismatch() async throws {
        // A kokoro hello on a port that is not kokoro's.
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .kokoro)))
        defer { server.stop() }
        guard case .mismatch(let frame) = await Self.probe(server.port) else {
            Issue.record("expected mismatch")
            return
        }
        #expect(frame.backendName == "kokoro")
        #expect(frame.model == "mlx-community/Kokoro-82M-bf16")
    }

    @Test func helloOnAnotherEntrysPortIsAMismatch() async throws {
        // Right backend, wrong port: a catalog entry is only adopted on its own port.
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone)))
        defer { server.stop() }
        guard case .mismatch(let frame) = await Self.probe(server.port) else {
            Issue.record("expected mismatch")
            return
        }
        #expect(frame.backendName == "tone")
    }

    @Test(arguments: [nil, "0.2", "1.0", ""] as [String?])
    func helloWithoutProtocolVersionZeroPointOneIsAMismatch(version: String?) async throws {
        // On the entry's own port, so only the protocol version can fail the match.
        guard
            let (server, _) = await Self.onCatalogPort({ s in
                .hello(HelloFixtures.json(for: s, protocolVersion: version))
            })
        else { return }
        defer { server.stop() }
        guard case .mismatch(let frame) = await Self.probe(server.port) else {
            Issue.record("expected mismatch for protocol_version \(String(describing: version))")
            return
        }
        #expect(frame.protocolVersion == version)
    }

    @Test(arguments: [401, 403])
    func httpAuthRejectionOnTheUpgradeNeedsAToken(status: Int) async throws {
        let server = try await FakeHelloServer.start(.reject(status: status))
        defer { server.stop() }
        #expect(await Self.probe(server.port) == .needsToken)
    }

    @Test func closingWithoutAHelloIsSilent() async throws {
        let server = try await FakeHelloServer.start(.closeWithoutHello)
        defer { server.stop() }
        #expect(await Self.probe(server.port) == .silent)
    }

    // MARK: Timing

    /// A hello that arrives after `helloTimeout` is a timeout, and the probe returns at the
    /// deadline rather than waiting for the hello.
    @Test func helloOverTheTimeoutIsATimeout() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone), delay: 3))
        defer { server.stop() }
        let clock = ContinuousClock()
        var outcome: ExternalProbe.Outcome?
        let elapsed = await clock.measure { outcome = await Self.probe(server.port, timeout: Self.shortTimeout) }
        #expect(outcome == .timeout)
        #expect(elapsed < .seconds(2), "the probe waited for the late hello (\(elapsed))")
    }

    @Test func listenerThatUpgradesButNeverSaysHelloTimesOut() async throws {
        let server = try await FakeHelloServer.start(.upgradeAndStaySilent)
        defer { server.stop() }
        let clock = ContinuousClock()
        var outcome: ExternalProbe.Outcome?
        let elapsed = await clock.measure { outcome = await Self.probe(server.port, timeout: Self.shortTimeout) }
        #expect(outcome == .timeout)
        #expect(elapsed < .seconds(2), "the probe waited past its deadline (\(elapsed))")
    }

    @Test func listenerThatNeverAnswersTheUpgradeTimesOut() async throws {
        let server = try await FakeHelloServer.start(.holdWithoutUpgrade)
        defer { server.stop() }
        let clock = ContinuousClock()
        var outcome: ExternalProbe.Outcome?
        let elapsed = await clock.measure { outcome = await Self.probe(server.port, timeout: Self.shortTimeout) }
        #expect(outcome == .timeout)
        #expect(elapsed < .seconds(2), "the probe waited past its deadline (\(elapsed))")
    }

    /// The other side of the deadline: a hello that is slow but inside `helloTimeout` is
    /// read, not demoted to a timeout (a busy TTS server can answer hello slowly).
    @Test func helloUnderTheTimeoutIsRead() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone), delay: 0.3))
        defer { server.stop() }
        guard case .mismatch(let frame) = await Self.probe(server.port, timeout: Self.patientTimeout) else {
            Issue.record("expected the late hello to be read")
            return
        }
        #expect(frame.backendName == "tone")
    }

    @Test func slowHelloUnderTheTimeoutIsStillAdopted() async throws {
        guard
            let (server, service) = await Self.onCatalogPort({ s in
                .hello(HelloFixtures.json(for: s), delay: 0.3)
            })
        else { return }
        defer { server.stop() }
        guard case .adopt(let info, _) = await Self.probe(server.port, timeout: Self.patientTimeout) else {
            Issue.record("expected adopt")
            return
        }
        #expect(info.service == service)
    }

    // MARK: What the probe sends

    /// The TTS server answers 403 to any handshake that carries an `Origin` header, so a
    /// probe that sent one would read every TTS server as `needsToken`.
    @Test func probeSendsOneUpgradeWithoutAnOriginHeader() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone)))
        defer { server.stop() }
        _ = await Self.probe(server.port)
        server.stop()
        let requests = server.receivedRequests
        #expect(requests.count == 1)
        let headers = try #require(requests.first)
        #expect(headers["origin"] == nil)
        #expect(headers["upgrade"]?.lowercased() == "websocket")
        #expect(headers[":request"]?.hasPrefix("GET ") == true)
    }

    @Test func probeUsesTheLoopbackHost() async throws {
        let server = try await FakeHelloServer.start(.hello(HelloFixtures.json(for: .tone)))
        defer { server.stop() }
        _ = await Self.probe(server.port)
        let host = try #require(server.receivedRequests.first?["host"])
        #expect(host.hasPrefix("127.0.0.1"))
    }
}
