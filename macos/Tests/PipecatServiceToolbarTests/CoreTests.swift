import Foundation
import Testing

@testable import PipecatToolbarCore

@Suite struct LineSplitterTests {
    @Test func splitsOnNewlinesAndCarriageReturns() {
        var splitter = LineSplitter()
        #expect(splitter.feed(Data("a\nb\rc".utf8)) == ["a", "b"])
        #expect(splitter.feed(Data("d\r\n\ne".utf8)) == ["cd"])
        #expect(splitter.flush() == "e")
        #expect(splitter.flush() == nil)
    }

    @Test func handlesMultibyteSplitAcrossChunks() {
        var splitter = LineSplitter()
        let bytes = Array("héllo\n".utf8)
        #expect(splitter.feed(Data(bytes[0..<2])) == [])
        #expect(splitter.feed(Data(bytes[2...])) == ["héllo"])
    }
}

@Suite struct CatalogTests {
    /// TTS ports must match the tts repo's `justfile` `_resolve` table.
    @Test func canonicalPorts() {
        let expected: [Service: Int] = [
            .tone: 8665, .kokoro: 8765, .voxtralTTS: 8865, .pocketTTS: 8965,
            .dia: 9065, .qwen3TTS: 9165, .fishTTS: 9265, .phonon: 9365,
            .appleSpeech: 9465, .whisper: 9565, .kyutai: 9665,
            // Variants: the family's port + 1, 2, ...
            .phononQ8: 9366, .phononQ4: 9367,
            .whisperLargeV3: 9566, .whisperMedium: 9567, .whisperSmall: 9568, .whisperBase: 9569, .whisperTiny: 9570,
            .kyutai2B: 9666,
        ]
        for service in Service.allCases {
            #expect(service.info.port == expected[service], "\(service)")
        }
        #expect(Set(ServiceCatalog.all.map(\.port)).count == Service.allCases.count)
    }

    @Test func ttsFamilyNamesMatchServerBackendNames() {
        let families = ServiceCatalog.services(of: .tts).filter { $0.family == $0 }
        #expect(families.map(\.rawValue).sorted() == [
            "dia", "fish_tts", "kokoro", "phonon", "pocket_tts", "qwen3_tts", "tone", "voxtral_tts",
        ])
        #expect(ServiceCatalog.services(of: .stt).filter { $0.family == $0 } == [.appleSpeech, .whisper, .kyutai])
    }

    @Test func runtimes() {
        for service in ServiceCatalog.services(of: .tts) where service != .tone {
            #expect(service.info.runtime == .ttsServer(extra: service.family.rawValue))
            #expect(service.info.needsModelDownload)
        }
        #expect(Service.tone.info.runtime == .ttsServer(extra: nil))
        #expect(Service.appleSpeech.info.runtime == .appleSpeech)
        #expect(!Service.appleSpeech.info.runtime.usesPython)
        guard case .sttHelper(let engine, let reqs) = Service.kyutai.info.runtime else {
            Issue.record("kyutai runtime")
            return
        }
        #expect(engine == "kyutai" && reqs.contains("moshi_mlx==0.3.0"))
    }

    @Test func copyStrings() {
        #expect(Service.kokoro.info.endpoint == "ws://127.0.0.1:8765/")
        #expect(Service.kokoro.info.pipecatService() == #"LocalTTSService(host="127.0.0.1", port=8765)"#)
        #expect(Service.whisper.info.pipecatService() == #"LocalWebSocketSTTService(host="127.0.0.1", port=9565)"#)
        #expect(Service.whisper.info.environment() == "STT_WS_HOST=127.0.0.1 STT_WS_PORT=9565")
        #expect(Service.phonon.info.environment(port: 1234) == "TTS_WS_HOST=127.0.0.1 TTS_WS_PORT=1234")
    }

    @Test func restrictiveLicences() {
        #expect(Service.voxtralTTS.info.licence.isRestrictive)
        #expect(Service.fishTTS.info.licence.isRestrictive)
        #expect(!Service.kokoro.info.licence.isRestrictive)
        #expect(!Service.kyutai.info.licence.isRestrictive)
    }
}

@Suite struct VariantTests {
    @Test func families() {
        #expect(Service.phonon.variants == [.phonon, .phononQ8, .phononQ4])
        #expect(Service.whisperSmall.variants.first == .whisper)
        #expect(Service.kyutai2B.family == .kyutai)
        #expect(Service.kokoro.variants == [.kokoro])
        for service in Service.allCases {
            let info = service.info
            // Siblings share a runtime (one environment) and each has a label.
            #expect(info.runtime == service.family.info.runtime, "\(service)")
            #expect(info.kind == service.family.info.kind)
            #expect((info.variantLabel != nil) == (service.variants.count > 1), "\(service)")
        }
        #expect(Service.phononQ8.info.displayName == "Phonon 8-bit")
        #expect(Service.phonon.info.launchdLabel == "pipecat.tts-server.phonon")
        #expect(Service.phononQ8.info.launchdLabel == nil)
    }

    static func manager() throws -> (EnvironmentManager, AppPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-variants-\(UUID().uuidString.prefix(8))")
        let paths = AppPaths(supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"))
        try paths.prepare()
        let tools = Tools(
            uv: URL(filePath: "/usr/bin/true"), wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"),
            constraints: nil, helper: URL(filePath: "/tmp/helper.py"), source: .override)
        return (EnvironmentManager(paths: paths, tools: tools), paths)
    }

    @Test func commands() throws {
        let (manager, paths) = try Self.manager()
        let serve = try #require(manager.serveArguments(for: Service.phononQ8.info, port: 9366))
        #expect(Array(serve.prefix(7)) == ["-m", "tts_server", "serve", "--backend", "phonon", "--model", "phonon-q8"])
        #expect(manager.serveArguments(for: Service.phonon.info, port: 9365)?.contains("--model") == false)
        let prefetch = try #require(manager.prefetchArguments(for: Service.phononQ4.info, check: true))
        #expect(prefetch == ["-m", "tts_server", "prefetch", "--backend", "phonon", "--json", "--model", "phonon-q4", "--check"])

        let stt = try #require(manager.serveArguments(for: Service.whisperSmall.info, port: 9568))
        #expect(stt.suffix(2) == ["--model", "mlx-community/whisper-small-mlx"])
        let sttPrefetch = try #require(manager.prefetchArguments(for: Service.whisperSmall.info, check: false))
        #expect(sttPrefetch.contains("mlx-community/whisper-small-mlx"))
        #expect(sttPrefetch.contains(paths.envDir(.whisper).path))

        // One environment per family; logs per variant.
        #expect(paths.envDir(.whisperTiny) == paths.envDir(.whisper))
        #expect(paths.python(.phononQ8) == paths.python(.phonon))
        #expect(paths.appLog(.phononQ8) != paths.appLog(.phonon))
    }

    /// A built environment as `install` leaves it: an executable python and the marker.
    static func fakeEnvironment(_ service: Service, _ manager: EnvironmentManager, _ paths: AppPaths) async throws {
        try FileManager.default.createDirectory(
            at: paths.python(service).deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(
            atPath: paths.python(service).path, contents: Data("#!/bin/sh\n".utf8), attributes: [.posixPermissions: 0o755])
        try EnvironmentMarker(
            service: service.rawValue, fingerprint: await manager.tools.fingerprint(for: service.info), python: "3.12.0",
            createdAt: Date()
        ).write(paths.marker(service))
    }

    @Test func siblingsShareAnEnvironment() async throws {
        let (manager, paths) = try Self.manager()
        try await Self.fakeEnvironment(.phonon, manager, paths)
        // Built before variants existed: the marker names the one service.
        #expect(manager.isRequested(.phonon))
        #expect(!manager.isRequested(.phononQ8))
        guard case .ready = manager.environmentStatus(.phononQ8) else {
            Issue.record("a sibling sees the family environment")
            return
        }

        try await manager.recordVariant(.phononQ8, installed: true)
        #expect(manager.isRequested(.phonon) && manager.isRequested(.phononQ8))
        #expect(!manager.isRequested(.phononQ4))

        // Removing one variant keeps the environment for the other...
        try await manager.remove(.phonon, deleteModel: false)
        #expect(!manager.isRequested(.phonon) && manager.isRequested(.phononQ8))
        #expect(manager.environmentStatus(.phononQ8) != .missing)
        // ...and the last one takes it with it.
        try await manager.remove(.phononQ8, deleteModel: false)
        #expect(manager.environmentStatus(.phonon) == .missing)
        #expect(!FileManager.default.fileExists(atPath: paths.envDir(.phonon).path))
    }

    @Test func deletesOnlyUnsharedModelFiles() {
        let hub = URL(filePath: "/Users/x/.cache/huggingface/hub")
        let repo = hub.appending(path: "models--gradium--phonon-31m-en")
        let voices = hub.appending(path: "models--gradium--phonon-voices")
        let q8 = URL(filePath: "/Users/x/.cache/pipecat-tts-server/phonon/52433c46975b-q8-g32-mlxaudio0.6.1")
        // Phonon full precision is still installed: it keeps the repo and voices.
        #expect(
            EnvironmentManager.unshared(
                [repo, voices, q8], siblingRepos: ["gradium/phonon-31m-en"], siblingFolders: [voices]) == [q8])
        #expect(EnvironmentManager.unshared([repo], siblingRepos: [], siblingFolders: []) == [repo])

        #expect(EnvironmentManager.isDeletableModelPath(repo))
        #expect(EnvironmentManager.isDeletableModelPath(q8))
        #expect(!EnvironmentManager.isDeletableModelPath(URL(filePath: "/Users/x/Documents")))
        #expect(!EnvironmentManager.isDeletableModelPath(URL(filePath: "/Users/x/.cache/pipecat-tts-server")))
    }

    @Test func quantizedVariantNeedsItsConvertedWeights() throws {
        let check = #"{"event":"check","repo":"gradium/phonon-31m-en","cached":true,"path":"/h/hub/models--gradium--phonon-31m-en/snapshots/abc","size_bytes":10}"#
        let path = "/c/pipecat-tts-server/phonon/abc-q8"
        let notYet = try #require(
            EnvironmentManager.cacheStatus(checkOutput: [
                check,
                #"{"event":"summary","cached":true,"size_bytes":10,"quantized":false,"quantized_path":"\#(path)"}"#,
            ]))
        #expect(!notYet.cached && notYet.derivedFolders.isEmpty)
        #expect(notYet.repoFolders.map(\.lastPathComponent) == ["models--gradium--phonon-31m-en"])
        let converted = try #require(
            EnvironmentManager.cacheStatus(checkOutput: [
                check, #"{"event":"summary","cached":true,"size_bytes":10,"quantized":true,"quantized_path":"\#(path)"}"#,
            ]))
        #expect(converted.cached && converted.derivedFolders == [URL(filePath: path)])
        // Unquantized backends report no `quantized` field.
        #expect(
            EnvironmentManager.cacheStatus(checkOutput: [check, #"{"event":"summary","cached":true,"size_bytes":10}"#])?
                .cached == true)
    }
}

@Suite struct EventDecodingTests {
    @Test func prefetchProgress() throws {
        let line = #"{"event":"progress","repo":"r","downloaded_bytes":10,"total_bytes":40,"files_done":1,"files_total":5}"#
        let event = try #require(ServerCLIEvent.parse(line))
        #expect(event.event == "progress")
        #expect(event.downloadedBytes == 10 && event.totalBytes == 40)
        #expect(event.filesDone == 1 && event.filesTotal == 5)
    }

    @Test func readyLine() throws {
        let line = #"{"event":"ready","backend":"tone","model":null,"host":"127.0.0.1","port":8665,"socket_path":null,"rate":24000,"pid":42}"#
        let event = try #require(ServerCLIEvent.parse(line))
        #expect(event.port == 8665 && event.rate == 24000 && event.pid == 42)
    }

    @Test func nonJSONIsIgnored() {
        #expect(ServerCLIEvent.parse("Fetching 5 files: 100%") == nil)
    }

    @Test func downloadFraction() {
        #expect(DownloadProgress(repo: "r").fraction == nil)
        #expect(DownloadProgress(repo: "r", filesDone: 1, filesTotal: 4).fraction == 0.25)
        #expect(DownloadProgress(repo: "r", downloadedBytes: 50, totalBytes: 100, filesDone: 4, filesTotal: 4).fraction == 0.5)
    }

    @Test func helloAndAudio() throws {
        let hello = #"{"type":"server.hello","backend":{"name":"tone","model":null},"audio":{"format":"pcm16","rate":24000,"channels":1},"capabilities":{"streaming":false,"voice_count":0,"max_text_chars":4096}}"#
        guard case .hello(let h)? = TTSEvent.decode(hello) else { Issue.record("not hello"); return }
        #expect(h.rate == 24000 && h.backend == "tone" && h.maxTextChars == 4096)

        let pcm = Data([0x00, 0x80, 0xFF, 0x7F])  // -32768, 32767
        let delta = #"{"type":"response.audio.delta","response_id":"r1","seq":3,"audio":"\#(pcm.base64EncodedString())"}"#
        guard case .audio(let rid, let seq, let data)? = TTSEvent.decode(delta) else {
            Issue.record("not audio")
            return
        }
        #expect(rid == "r1" && seq == 3 && data == pcm)
    }

    @Test func pcmConversionExtremes() {
        let floats = PCM16.floats(from: Data([0x00, 0x80, 0xFF, 0x7F, 0x00, 0x00]))
        #expect(floats[0] == -1.0)
        #expect(abs(floats[1] - 0.99997) < 0.0001)
        #expect(floats[2] == 0)
    }

    @Test func snapshotToRepoFolder() {
        let folder = EnvironmentManager.repoFolder(
            fromSnapshot: "/u/.cache/huggingface/hub/models--gradium--phonon-31m-en/snapshots/abc")
        #expect(folder?.lastPathComponent == "models--gradium--phonon-31m-en")
        #expect(EnvironmentManager.repoFolder(fromSnapshot: "/tmp/some/dir") == nil)
    }
}

@Suite struct SubprocessTests {
    @Test func collectsLinesAndStatus() async throws {
        let sub = Subprocess(
            .init(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", "printf 'one\\ntwo'; echo err >&2; exit 3"],
                environment: ProcessEnvironment.base()))
        let result = try await sub.collect()
        #expect(result.status == 3)
        #expect(result.stdout == ["one", "two"])
        #expect(result.stderr == ["err"])
    }

    @Test func heldStdinEOFEndsChild() async throws {
        // `cat` exits when its stdin closes: the same contract as `serve --supervised`.
        let sub = Subprocess(
            .init(
                executable: URL(filePath: "/bin/cat"), arguments: [],
                environment: ProcessEnvironment.base(), holdStdin: true))
        try sub.run()
        try await Task.sleep(for: .milliseconds(200))
        #expect(sub.isRunning)
        sub.closeStdin()
        #expect(await sub.waitForExit() == 0)
    }

    @Test func stopEscalatesToKill() async throws {
        let sub = Subprocess(
            .init(
                executable: URL(filePath: "/bin/sh"), arguments: ["-c", "trap '' TERM; sleep 30"],
                environment: ProcessEnvironment.base()))
        try sub.run()
        try await Task.sleep(for: .milliseconds(200))
        let clock = ContinuousClock()
        let start = clock.now
        _ = await sub.stop(grace: .milliseconds(500))
        #expect(!sub.isRunning)
        #expect(clock.now - start < .seconds(5))
    }
}

/// End to end against a real `serve --supervised` tone server, when the repo's
/// dev environment exists (`uv sync --extra client` at the repo root).
@Suite struct ToneServerIntegrationTests {
    static let repo = URL(filePath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent()
    static let python = repo.appending(path: ".venv/bin/python")

    @Test(.enabled(if: FileManager.default.isExecutableFile(atPath: python.path)))
    func supervisedToneServerSpeaks() async throws {
        let server = Subprocess(
            .init(
                executable: Self.python,
                arguments: ["-m", "tts_server", "serve", "--backend", "tone", "--host", "127.0.0.1", "--port", "0", "--supervised"],
                environment: ProcessEnvironment.base(), currentDirectory: Self.repo, holdStdin: true))
        try server.run()
        defer { server.kill() }

        var port: Int?
        for await line in server.stdout {
            if let event = ServerCLIEvent.parse(line), event.event == "ready" {
                port = event.port
                break
            }
        }
        let readyPort = try #require(port)

        // No 403: URLSession must not send an Origin header.
        let client = TTSClient(port: readyPort)
        let hello = try await client.connect()
        #expect(hello.backend == "tone" && hello.rate == 24000)

        try await client.speak("Hello there.", voice: nil)
        var frames = 0
        var finished = false
        while let event = try await client.next() {
            if case .audio = event { frames += 1 }
            if case .done = event { finished = true; break }
            if case .failed(_, let message) = event { Issue.record("failed: \(message)"); break }
        }
        #expect(finished && frames > 0)
        await client.close()

        server.closeStdin()
        #expect(await server.waitForExit() == 0)
    }
}

@Suite struct LogoTests {
    @Test func tokenizesImplicitSeparators() {
        #expect(SVGPath.tokenize("M45.7 0.76C50.4-0.99") == [
            .command("M"), .number(45.7), .number(0.76), .command("C"), .number(50.4), .number(-0.99),
        ])
    }

    @Test func markFillsItsViewBox() {
        let box = PipecatLogo.path.boundingBoxOfPath
        #expect(abs(box.minX) < 0.5 && abs(box.minY) < 0.5)
        #expect(abs(box.maxX - 332) < 0.5 && abs(box.maxY - 192) < 0.5)
    }

    @Test func fittingKeepsAspectAndCentres() {
        let fitted = PipecatLogo.path(fitting: CGRect(x: 0, y: 0, width: 100, height: 100)).boundingBoxOfPath
        #expect(abs(fitted.width - 100) < 0.5)
        #expect(abs(fitted.height - 100 * 192 / 332) < 0.5)
        #expect(abs(fitted.midY - 50) < 0.5)
    }
}


@Suite struct STTServerTests {
    static func fakeServer() -> STTWebSocketServer {
        STTWebSocketServer(identity: .init(name: "fake", model: nil)) { pcm, language in
            "heard \(pcm.count) bytes" + (language.map { " in \($0)" } ?? "")
        }
    }

    @Test func clientRoundTrip() async throws {
        let server = Self.fakeServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let client = STTClient(port: port)
        let hello = try await client.connect()
        #expect(hello.backend == "fake" && hello.rate == 16000)
        #expect(try await client.transcribe(Data(count: 32000)) == "heard 32000 bytes")
        // A second utterance on the same connection.
        #expect(try await client.transcribe(Data(count: 1000), chunkBytes: 300) == "heard 1000 bytes")
        await client.close()
    }

    @Test func busyPortFails() async throws {
        let first = Self.fakeServer()
        let port = try await first.start(port: 0)
        defer { first.stop() }
        await #expect(throws: STTWebSocketServer.StartError.self) {
            _ = try await Self.fakeServer().start(port: port)
        }
    }

    @Test func browserOriginRejected() async throws {
        let server = Self.fakeServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)/")!)
        request.setValue("https://evil.example", forHTTPHeaderField: "Origin")
        let task = URLSession(configuration: .ephemeral).webSocketTask(with: request)
        task.resume()
        await #expect(throws: (any Error).self) { _ = try await task.receive() }
    }
}
