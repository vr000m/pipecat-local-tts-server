import Foundation
import Testing

@testable import PipecatToolbarCore

/// `PortProbe.clientCounts` against real sockets and the real `lsof`. Opt-in like `EndToEndTests`:
///
///     PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter ConnectionCountLiveTests
///
/// The Apple Speech shape: the server is in this process (its rows are owned by the app pid), a
/// client in another process (`nc`) is counted, one in this process (the app's own) is not.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PIPECAT_TOOLBAR_E2E"] == "1"))
struct ConnectionCountLiveTests {
    static let appPid = ProcessInfo.processInfo.processIdentifier
    static let repoRoot = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// An out-of-process client: `nc` connected to `port`, held open by an unclosed stdin pipe.
    final class NCClient {
        let process = Process()
        let stdin = Pipe()

        init(port: Int) throws {
            process.executableURL = URL(filePath: "/usr/bin/nc")
            process.arguments = ["127.0.0.1", "\(port)"]
            process.standardInput = stdin
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
        }

        func stop() {
            try? stdin.fileHandleForWriting.close()
            process.terminate()
            process.waitUntilExit()
        }
    }

    /// Polls until the count for `port` is `expected` (a socket takes a moment to show), or gives up
    /// and returns the last answer.
    static func count(port: Int, expected: Int, within seconds: Double = 5) async -> ClientCount? {
        var last: ClientCount?
        let deadline = Date().addingTimeInterval(seconds)
        repeat {
            last = PortProbe.clientCounts(ports: [port], appPid: appPid, timeout: 2)[port]
            if last == .known(expected) { break }
            try? await Task.sleep(for: .milliseconds(100))
        } while Date() < deadline
        return last
    }

    static func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func anIdleServerHasNoClients() async throws {
        let server = STTWebSocketServer(identity: .init(name: "fake", model: nil)) { _, _ in "" }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        #expect(await Self.count(port: port, expected: 0) == .known(0))
    }

    @Test func aPortWithNothingListeningIsZeroNotUnknown() {
        let counts = PortProbe.clientCounts(ports: [1], appPid: Self.appPid, timeout: 2)
        #expect(counts[1] == .known(0))
    }

    @Test func anEmptyPortListAsksNothing() {
        #expect(PortProbe.clientCounts(ports: [], appPid: Self.appPid, timeout: 2).isEmpty)
    }

    /// Apple Speech shape, out-of-process client: the server rows are the app's own, the client is not.
    @Test func anOutOfProcessClientOfTheInProcessServerCountsOne() async throws {
        let server = STTWebSocketServer(identity: .init(name: "fake", model: nil)) { _, _ in "" }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let client = try NCClient(port: port)
        defer { client.stop() }
        #expect(await Self.count(port: port, expected: 1) == .known(1))
    }

    /// Apple Speech shape, in-process client: the app's own socket is not a client.
    @Test func anInProcessClientOfTheInProcessServerCountsZero() async throws {
        let server = STTWebSocketServer(identity: .init(name: "fake", model: nil)) { _, _ in "" }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let client = STTClient(port: port)
        _ = try await client.connect()
        defer { Task { await client.close() } }
        await Self.settle()
        #expect(PortProbe.clientCounts(ports: [port], appPid: Self.appPid, timeout: 2)[port] == .known(0))
    }

    /// Control for the test above: with an app pid that owns nothing, the in-process client's socket
    /// is counted, so lsof does list it under the app pid and the exclusion is what yields 0.
    @Test func anInProcessClientCountsOneWhenTheAppPidOwnsNothing() async throws {
        let server = STTWebSocketServer(identity: .init(name: "fake", model: nil)) { _, _ in "" }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let client = STTClient(port: port)
        _ = try await client.connect()
        defer { Task { await client.close() } }
        await Self.settle()
        for foreignPid: Int32 in [0, 1] {
            #expect(PortProbe.clientCounts(ports: [port], appPid: foreignPid, timeout: 2)[port] == .known(1))
        }
    }

    @Test func bothKindsOfClientTogetherCountOnlyTheOutsideOne() async throws {
        let server = STTWebSocketServer(identity: .init(name: "fake", model: nil)) { _, _ in "" }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let inside = STTClient(port: port)
        _ = try await inside.connect()
        defer { Task { await inside.close() } }
        let outside = try NCClient(port: port)
        defer { outside.stop() }
        #expect(await Self.count(port: port, expected: 1) == .known(1))
    }

    /// A tone TTS server (a subprocess, like the app's) over loopback with one outside client.
    @Test func aToneServerWithOneClientCountsOne() async throws {
        let python = Self.repoRoot.appending(path: ".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            Issue.record("needs the repo .venv (uv sync --extra client) for a tone server")
            return
        }
        let server = Subprocess(
            .init(
                executable: python,
                arguments: ["-m", "tts_server", "serve", "--backend", "tone", "--supervised", "--host", "127.0.0.1", "--port", "0"],
                environment: ProcessEnvironment.base(), currentDirectory: Self.repoRoot, holdStdin: true))
        try server.run()
        defer { server.kill() }
        var port: Int?
        for await line in server.stdout {
            guard let event = ServerCLIEvent.parse(line) else { continue }
            if event.event == "ready", let p = event.port {
                port = p
                break
            }
            if event.event == "error" { break }
        }
        let bound = try #require(port, "the tone server did not report ready")
        #expect(await Self.count(port: bound, expected: 0) == .known(0))
        let client = try NCClient(port: bound)
        defer { client.stop() }
        #expect(await Self.count(port: bound, expected: 1) == .known(1))
    }
}
