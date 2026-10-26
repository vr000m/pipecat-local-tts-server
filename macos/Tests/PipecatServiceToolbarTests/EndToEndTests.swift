import Foundation
import Testing

@testable import PipecatToolbarCore

/// The app's real install -> serve -> use -> remove path, through `uv`, the TTS
/// server wheel and the upstream `stt_server` CLI, into a throwaway support directory. Opt-in
/// because it downloads Python, packages and model weights (phonon ~100 MB,
/// Whisper Tiny ~75 MB, Kyutai ~2.4 GB, Parakeet and Nemotron ~1 to 2.5 GB; weights are shared with the Hugging Face cache):
///
///     PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter EndToEnd
///
/// Uses the built bundle's tools when `macos/build/Pipecat Service Toolbar.app`
/// exists (exactly what the app ships), else builds them from the repo.
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PIPECAT_TOOLBAR_E2E"] == "1"))
struct EndToEndTests {
    static let macosDir = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()

    static func makeManager() async throws -> (EnvironmentManager, AppPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "pipecat-toolbar-e2e-\(UUID().uuidString.prefix(8))")
        let real = AppPaths.standard()
        // Fresh support dir; the real uv cache so repeat runs are fast.
        let paths = AppPaths(supportDir: root.appending(path: "support"), cacheDir: real.cacheDir, logsDir: root.appending(path: "logs"))
        try paths.prepare()
        let bundleResources = macosDir.appending(path: "build/Pipecat Service Toolbar.app/Contents/Resources")
        let tools: Tools
        if let bundle = Bundle(url: macosDir.appending(path: "build/Pipecat Service Toolbar.app")),
            FileManager.default.fileExists(atPath: bundleResources.appending(path: "bin/uv").path)
        {
            tools = try await ToolLocator.locate(bundle: bundle, paths: paths)
            #expect(tools.source == .bundle)
        } else {
            tools = try await ToolLocator.locate(paths: paths)
        }
        return (EnvironmentManager(paths: paths, tools: tools), paths)
    }

    func install(_ backend: Service, _ manager: EnvironmentManager) async throws -> [InstallEvent] {
        var events: [InstallEvent] = []
        for try await event in manager.install(backend) { events.append(event) }
        return events
    }

    /// Starts `service` via the manager's supervised serve command on a free port.
    func startServer(_ service: Service, _ manager: EnvironmentManager, paths: AppPaths) async throws -> (Subprocess, Int) {
        let (server, ready) = try await startServerReady(service, manager, paths: paths)
        return (server, try #require(ready.port))
    }

    /// As `startServer`, keeping the `ready` line (always on an ephemeral port: never a
    /// catalog port, so a LaunchAgent on 9565 to 9865 is never touched).
    func startServerReady(_ service: Service, _ manager: EnvironmentManager, paths: AppPaths) async throws -> (Subprocess, ServerCLIEvent) {
        let args = try #require(manager.serveArguments(for: service.info, port: 0))
        let server = Subprocess(
            .init(executable: paths.python(service), arguments: args, environment: ProcessEnvironment.serve(service), holdStdin: true))
        try server.run()
        for await line in server.stdout {
            guard let event = ServerCLIEvent.parse(line) else { continue }
            if event.event == "ready", event.port != nil { return (server, event) }
            if event.event == "error" { break }
        }
        server.kill()
        throw TTSClientError.closed
    }

    /// The live hello of a server the test started maps back to the service it started: the
    /// shared decoder reads it and `entry(for:port:)` picks the same catalog entry (the
    /// server is on an ephemeral port, so the match is made on the service's own port).
    func expectHelloMapsBack(_ service: Service, port: Int) async throws {
        let live = try await HelloFixtures.liveHello(port: port)
        #expect(live.protocolVersion == "0.1", "\(service): protocol_version \(String(describing: live.protocolVersion))")
        let matched = HelloFixtures.entry(for: live, port: service.info.port)
        #expect(matched?.service == service, "\(service): hello \(live) matched \(String(describing: matched?.service))")
    }

    func serveAndSpeak(_ backend: Service, _ manager: EnvironmentManager, paths: AppPaths) async throws -> Int {
        let (server, port) = try await startServer(backend, manager, paths: paths)
        defer { server.kill() }
        let client = TTSClient(port: port)
        let hello = try await client.connect()
        #expect(hello.backend == backend.family.rawValue)
        try await expectHelloMapsBack(backend, port: port)
        for frame in TTSClientFrame.request(TTSRequest(id: "tryit-1", text: "Testing the menu bar app.", voice: nil)) {
            try await client.send(frame)
        }
        var bytes = 0
        while let event = try await client.next() {
            if case .audio(_, _, let pcm) = event { bytes += pcm.count }
            if case .done = event { break }
            if case .failed(_, _, let message) = event { Issue.record("failed: \(message)"); break }
        }
        await client.close()
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        return bytes
    }

    @Test func toneInstallServeRemove() async throws {
        let (manager, paths) = try await Self.makeManager()
        let events = try await install(.tone, manager)
        #expect(events.contains(.stage(.packages)))
        #expect(!events.contains(.stage(.model)))
        guard case .ready(let marker) = manager.environmentStatus(.tone) else {
            Issue.record("tone env not ready")
            return
        }
        #expect(marker.python.hasPrefix("3.12"))
        #expect(try await serveAndSpeak(.tone, manager, paths: paths) > 0)
        try await manager.remove(.tone, deleteModel: false)
        #expect(manager.environmentStatus(.tone) == .missing)
    }

    @Test func phononInstallDownloadServe() async throws {
        let (manager, paths) = try await Self.makeManager()
        let events = try await install(.phonon, manager)
        #expect(events.contains(.stage(.model)))
        let cache = try #require(await manager.modelCacheStatus(.phonon))
        #expect(cache.cached && cache.sizeBytes > 50_000_000)
        #expect(cache.repoFolders.first?.lastPathComponent == "models--gradium--phonon-31m-en")
        // 24 kHz pcm16: a short sentence is well over 1 s of audio.
        #expect(try await serveAndSpeak(.phonon, manager, paths: paths) > 48_000)
        try await manager.remove(.phonon, deleteModel: false)  // keeps the shared HF weights
    }

    /// Phonon 8-bit installs into Phonon's environment (weights + conversion only)
    /// and both serve at once, each on its own port.
    @Test func phononVariantsRunSideBySide() async throws {
        let (manager, paths) = try await Self.makeManager()
        _ = try await install(.phonon, manager)
        let events = try await install(.phononQ8, manager)
        #expect(events.contains(.stage(.model)))
        #expect(!events.contains(.stage(.python)) && !events.contains(.stage(.packages)))
        let cache = try #require(await manager.modelCacheStatus(.phononQ8))
        #expect(cache.cached && cache.derivedFolders.count == 1)

        let (full, fullPort) = try await startServer(.phonon, manager, paths: paths)
        defer { full.kill() }
        try await expectHelloMapsBack(.phonon, port: fullPort)
        #expect(try await serveAndSpeak(.phononQ8, manager, paths: paths) > 48_000)
        #expect(fullPort > 0)
        full.closeStdin()
        #expect(await full.waitForExit() == 0)

        try await manager.remove(.phononQ8, deleteModel: false)
        #expect(manager.isRequested(.phonon) && !manager.isRequested(.phononQ8))
        #expect(manager.environmentStatus(.phonon) != .missing)
        try await manager.remove(.phonon, deleteModel: false)
        #expect(manager.environmentStatus(.phonon) == .missing)
    }

    /// A spoken clip from the system voice, as pcm16 16 kHz mono.
    static func spokenClip(_ text: String) throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appending(path: "toolbar-clip-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let aiff = dir.appending(path: "clip.aiff"), wav = dir.appending(path: "clip.wav")
        for (tool, args) in [("/usr/bin/say", ["-o", aiff.path, text]), ("/usr/bin/afconvert", ["-f", "WAVE", "-d", "LEI16@16000", "-c", "1", aiff.path, wav.path])] {
            let p = Process()
            p.executableURL = URL(filePath: tool)
            p.arguments = args
            try p.run()
            p.waitUntilExit()
        }
        let data = try Data(contentsOf: wav)
        return data.subdata(in: 44..<data.count)  // canonical 44-byte WAV header
    }

    /// Whisper Tiny is its own entry: Whisper's environment, its own model and port.
    @Test func whisperTinyVariant() async throws {
        let (manager, paths) = try await Self.makeManager()
        _ = try await install(.whisperTiny, manager)
        #expect(manager.isRequested(.whisperTiny) && !manager.isRequested(.whisper))
        let cache = try #require(await manager.modelCacheStatus(.whisperTiny))
        #expect(cache.cached)
        #expect(cache.repoFolders.first?.lastPathComponent == "models--mlx-community--whisper-tiny-mlx")
        let (server, port) = try await startServer(.whisperTiny, manager, paths: paths)
        defer { server.kill() }
        let client = STTClient(port: port)
        #expect(try await client.connect().model == "mlx-community/whisper-tiny-mlx")
        try await expectHelloMapsBack(.whisperTiny, port: port)
        let text = try await client.transcribe(try Self.spokenClip("The weather today is sunny and warm."))
        #expect(text.lowercased().contains("weather"))
        await client.close()
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        try await manager.remove(.whisperTiny, deleteModel: false)
        #expect(manager.environmentStatus(.whisper) == .missing)
    }

    @Test func kyutaiInstallServeTranscribe() async throws {
        let (manager, paths) = try await Self.makeManager()
        let events = try await install(.kyutai, manager)
        #expect(events.contains(.stage(.model)))
        let cache = try #require(await manager.modelCacheStatus(.kyutai))
        #expect(cache.cached && cache.sizeBytes > 2_000_000_000)
        #expect(cache.repoFolders.first?.lastPathComponent == "models--kyutai--stt-1b-en_fr-mlx")
        let (server, port) = try await startServer(.kyutai, manager, paths: paths)
        defer { server.kill() }
        let client = STTClient(port: port)
        #expect(try await client.connect().backend == "kyutai")
        try await expectHelloMapsBack(.kyutai, port: port)
        let text = try await client.transcribe(try Self.spokenClip("The weather today is sunny and warm."))
        #expect(text.lowercased().contains("weather"))
        await client.close()
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        try await manager.remove(.kyutai, deleteModel: false)
    }

    /// A dropped long request must free the model: the next client is served at
    /// about its own speed, not after the abandoned decode finishes.
    @Test func kyutaiAbandonedRequestReleasesTheBackend() async throws {
        let (manager, paths) = try await Self.makeManager()
        _ = try await install(.kyutai, manager)
        let (server, port) = try await startServer(.kyutai, manager, paths: paths)
        defer { server.kill() }
        let short = try Self.spokenClip("The weather today is sunny and warm.")
        let long = try Self.spokenClip(String(repeating: "The weather today is sunny and warm. ", count: 60))

        func timedShortRequest() async throws -> (String, Double) {
            let client = STTClient(port: port)
            _ = try await client.connect()
            let began = ContinuousClock.now
            let text = try await client.transcribe(short)
            let elapsed = (ContinuousClock.now - began).seconds
            await client.close()
            return (text, elapsed)
        }
        let (warmText, baseline) = try await timedShortRequest()
        #expect(warmText.lowercased().contains("weather"))

        // Start a minutes-long decode, then drop the connection mid-way.
        let abandoned = STTClient(port: port)
        _ = try await abandoned.connect()
        let drop = Task { _ = try? await abandoned.transcribe(long) }
        try await Task.sleep(for: .seconds(3))
        drop.cancel()
        await abandoned.close()

        let (text, latency) = try await timedShortRequest()
        print("kyutai: baseline \(baseline) s; after an abandoned \(long.count / 32000) s clip \(latency) s")
        #expect(text.lowercased().contains("weather"))
        // KNOWN ISSUE against pipecat-local-stt-server 0.4.0: its Kyutai backend never checks
        // for cancellation mid-decode, so a dropped request holds the model until the
        // utterance finishes (the retired app helper cancelled cooperatively). The STT repo
        // is adding a per-frame cancel for its next release; when the pin moves to it this
        // starts passing, `withKnownIssue` then fails, and this wrapper is the thing to delete.
        withKnownIssue("0.4.0 Kyutai has no mid-decode cancel") {
            #expect(latency < baseline + 8, "the abandoned request kept the backend busy for \(latency) s")
        }

        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        try await manager.remove(.kyutai, deleteModel: false)
    }

    /// Parakeet through the upstream CLI: install, serve on an ephemeral port, transcribe.
    /// The live `ready` line has the shape of the recorded 0.4.0 fixture.
    @Test func parakeetInstallServeTranscribe() async throws {
        let (manager, paths) = try await Self.makeManager()
        let events = try await install(.parakeet, manager)
        #expect(events.contains(.stage(.model)))
        let cache = try #require(await manager.modelCacheStatus(.parakeet))
        #expect(cache.cached)
        #expect(cache.repoFolders.first?.lastPathComponent == "models--mlx-community--parakeet-tdt-0.6b-v3")
        let (server, ready) = try await startServerReady(.parakeet, manager, paths: paths)
        defer { server.kill() }
        let port = try #require(ready.port)
        #expect(port != Service.parakeet.info.port)
        #expect(ready.backend == "parakeet" && ready.host == "127.0.0.1" && ready.rate == 16000 && ready.pid != nil)
        let client = STTClient(port: port)
        #expect(try await client.connect().backend == "parakeet")
        try await expectHelloMapsBack(.parakeet, port: port)
        let text = try await client.transcribe(try Self.spokenClip("The weather today is sunny and warm."))
        #expect(text.lowercased().contains("weather"))
        await client.close()
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        try await manager.remove(.parakeet, deleteModel: false)
        #expect(manager.environmentStatus(.parakeet) == .missing)
    }

    /// Nemotron through the upstream CLI, in the same style. Its own environment: removing
    /// it leaves Parakeet's alone. (The try-it flow against the 9865 LaunchAgent is manual.)
    @Test func nemotronInstallServeTranscribe() async throws {
        let (manager, paths) = try await Self.makeManager()
        let events = try await install(.nemotron, manager)
        #expect(events.contains(.stage(.model)))
        let cache = try #require(await manager.modelCacheStatus(.nemotron))
        #expect(cache.cached)
        #expect(cache.repoFolders.first?.lastPathComponent == "models--mlx-community--nemotron-3.5-asr-streaming-0.6b")
        let (server, ready) = try await startServerReady(.nemotron, manager, paths: paths)
        defer { server.kill() }
        let port = try #require(ready.port)
        #expect(port != Service.nemotron.info.port)
        #expect(ready.backend == "nemotron" && ready.host == "127.0.0.1" && ready.rate == 16000 && ready.pid != nil)
        let client = STTClient(port: port)
        #expect(try await client.connect().backend == "nemotron")
        try await expectHelloMapsBack(.nemotron, port: port)
        let text = try await client.transcribe(try Self.spokenClip("The weather today is sunny and warm."))
        #expect(text.lowercased().contains("weather"))
        await client.close()
        server.closeStdin()
        #expect(await server.waitForExit() == 0)
        try await manager.remove(.nemotron, deleteModel: false)
        #expect(manager.environmentStatus(.nemotron) == .missing)
    }
}


private extension Duration {
    var seconds: Double { Double(components.seconds) + Double(components.attoseconds) / 1e18 }
}
