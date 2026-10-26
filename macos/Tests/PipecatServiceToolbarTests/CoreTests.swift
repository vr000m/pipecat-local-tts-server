import AVFoundation
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
    /// TTS ports must match the tts repo's `justfile` `_resolve` table
    /// (`tests/test_macos_catalog_drift.py` checks the Swift source against it).
    @Test func canonicalPorts() {
        let expected: [Service: Int] = [
            .tone: 8665, .kokoro: 8765, .voxtralTTS: 8865, .pocketTTS: 8965,
            .dia: 9065, .qwen3TTS: 9165, .fishTTS: 9265, .phonon: 9365,
            .appleSpeech: 9465, .whisper: 9565, .kyutai: 9665,
            .parakeet: 9765, .nemotron: 9865,
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
        #expect(ServiceCatalog.services(of: .stt).filter { $0.family == $0 } == [.appleSpeech, .whisper, .kyutai, .parakeet, .nemotron])
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

    @Test func parakeetAndNemotronEntries() {
        let parakeet = Service.parakeet.info, nemotron = Service.nemotron.info
        #expect(parakeet.kind == .stt && nemotron.kind == .stt)
        #expect(parakeet.port == 9765 && nemotron.port == 9865)
        #expect(parakeet.modelRepo == "mlx-community/parakeet-tdt-0.6b-v3")
        #expect(nemotron.modelRepo == "mlx-community/nemotron-3.5-asr-streaming-0.6b")
        #expect(Service.parakeet.family == .parakeet && Service.nemotron.family == .nemotron)
        #expect(Service.parakeet.variants == [.parakeet] && Service.nemotron.variants == [.nemotron])
        #expect(parakeet.needsModelDownload && nemotron.needsModelDownload)
        #expect(parakeet.pipecatService() == #"LocalWebSocketSTTService(host="127.0.0.1", port=9765)"#)
        // Each engine has its own environment and its own constraints file.
        guard case .sttHelper(let pEngine, let pReqs) = parakeet.runtime,
              case .sttHelper(let nEngine, let nReqs) = nemotron.runtime
        else {
            Issue.record("parakeet and nemotron run the STT server")
            return
        }
        #expect(pEngine == "parakeet" && nEngine == "nemotron")
        #expect(pReqs.contains("pipecat-local-stt-server[parakeet]==0.4.0"))
        #expect(nReqs.contains("pipecat-local-stt-server[nemotron]==0.4.0"))
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-envs-\(UUID().uuidString.prefix(8))")
        let paths = AppPaths(
            supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"),
            hubDir: root.appending(path: "hub"), derivedModelsDir: root.appending(path: "derived"))
        let envs = Set([Service.whisper, .kyutai, .parakeet, .nemotron].map { paths.envDir($0).path })
        #expect(envs.count == 4)
    }

    @Test func everySTTEnvironmentPinsTheSameServerRelease() {
        #expect(ServiceCatalog.sttServerRequirement == "pipecat-local-stt-server==0.4.0")
        for service in ServiceCatalog.services(of: .stt) {
            guard case .sttHelper(_, let reqs) = service.info.runtime else { continue }
            #expect(reqs.contains { $0.hasPrefix("pipecat-local-stt-server") && $0.hasSuffix("==0.4.0") }, "\(service)")
        }
    }

    /// Two real lines from the released 0.4.0 `stt_server` (the Python test checks them
    /// against the contract): the app's decoder reads them.
    @Test func recordedUpstreamLinesDecode() throws {
        let url = URL(filePath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appending(path: "tests/fixtures/stt_supervised_lines.jsonl")
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        let ready = try #require(ServerCLIEvent.parse(lines[0]))
        #expect(ready.event == "ready" && ready.backend == "echo" && ready.model == nil)
        #expect(ready.host == "127.0.0.1" && ready.port == 18770 && ready.rate == 16000 && ready.pid == 42342)
        let error = try #require(ServerCLIEvent.parse(lines[1]))
        #expect(error.event == "error" && error.errorCode == .addressInUse)
    }

    @Test func supervisedErrorCodesIncludeModelInvalid() {
        #expect(SupervisedErrorCode(rawValue: "ModelInvalidError") == .modelInvalid)
        #expect(SupervisedErrorCode.allCases.count == 8)
    }

    @Test func otherLicenceLabel() {
        #expect(WeightsLicence.other.label == "Custom licence")
        #expect(!WeightsLicence.other.detail.isEmpty)
        #expect(Service.nemotron.info.licence == .other)
        #expect(Service.parakeet.info.licence == .ccBy4)
        #expect(!Service.nemotron.info.licence.isRestrictive)
    }

    @Test func sttSnapshotsCarryNoRevisionPins() {
        for service in ServiceCatalog.services(of: .stt) {
            guard let repo = service.info.modelRepo else { continue }
            let snapshots = ServiceCatalog.snapshots(for: service)
            #expect(snapshots.map(\.repo) == [repo], "\(service)")
            #expect(snapshots.allSatisfy { $0.revision == nil && $0.kind == .model && $0.required }, "\(service)")
        }
        #expect(ServiceCatalog.snapshots(for: .kyutai2B).first?.files == .allButDocs)
        #expect(ServiceCatalog.snapshots(for: .whisper).first?.files == .allButDocs)
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
            // A non-default variant's name already carries its label, so a line naming the
            // model (`TryItSession.testLine`) uses the name alone and never says "8-bit 8-bit".
            if service != service.family, let label = info.variantLabel {
                #expect(info.displayName.contains(label), "\(service)")
            }
        }
        #expect(Service.phononQ8.info.displayName == "Phonon 8-bit")
        #expect(Service.phonon.info.launchdLabel == "pipecat.tts-server.phonon")
        #expect(Service.phononQ8.info.launchdLabel == nil)
    }

    static func manager() throws -> (EnvironmentManager, AppPaths) {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-variants-\(UUID().uuidString.prefix(8))")
        // Model roots inside the temp dir too: a test never deletes from the real caches.
        let paths = AppPaths(
            supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"),
            hubDir: root.appending(path: "hub"), derivedModelsDir: root.appending(path: "derived"))
        try paths.prepare()
        let tools = Tools(
            uv: URL(filePath: "/usr/bin/true"), wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"),
            constraints: nil, source: .override)
        return (EnvironmentManager(paths: paths, tools: tools), paths)
    }

    @Test func commands() throws {
        let (manager, paths) = try Self.manager()
        let serve = try #require(manager.serveArguments(for: Service.phononQ8.info, port: 9366))
        #expect(Array(serve.prefix(7)) == ["-m", "tts_server", "serve", "--backend", "phonon", "--model", "phonon-q8"])
        #expect(manager.serveArguments(for: Service.phonon.info, port: 9365)?.contains("--model") == false)
        let prefetch = try #require(manager.prefetchArguments(for: Service.phononQ4.info, check: true))
        #expect(prefetch == ["-m", "tts_server", "prefetch", "--backend", "phonon", "--json", "--model", "phonon-q4", "--check"])

        // STT launches the upstream CLI, the one entry point a LaunchAgent also runs.
        let stt = try #require(manager.serveArguments(for: Service.whisperSmall.info, port: 9568))
        #expect(stt == [
            "-m", "stt_server", "serve", "--supervised", "--backend", "mlx",
            "--model", "mlx-community/whisper-small-mlx", "--host", "127.0.0.1", "--port", "9568",
        ])
        let parakeet = try #require(manager.serveArguments(for: Service.parakeet.info, port: 9765))
        #expect(parakeet == [
            "-m", "stt_server", "serve", "--supervised", "--backend", "parakeet",
            "--model", "mlx-community/parakeet-tdt-0.6b-v3", "--host", "127.0.0.1", "--port", "9765",
        ])
        let nemotron = try #require(manager.serveArguments(for: Service.nemotron.info, port: 9865))
        #expect(nemotron == [
            "-m", "stt_server", "serve", "--supervised", "--backend", "nemotron",
            "--model", "mlx-community/nemotron-3.5-asr-streaming-0.6b", "--host", "127.0.0.1", "--port", "9865",
        ])
        let kyutai = try #require(manager.serveArguments(for: Service.kyutai2B.info, port: 9666))
        #expect(Array(kyutai.prefix(6)) == ["-m", "stt_server", "serve", "--supervised", "--backend", "kyutai"])
        #expect(kyutai.contains("kyutai/stt-2.6b-en-mlx"))
        let sttPrefetch = try #require(manager.prefetchArguments(for: Service.whisperSmall.info, check: false))
        #expect(sttPrefetch == [
            "-m", "stt_server", "prefetch", "--backend", "mlx",
            "--model", "mlx-community/whisper-small-mlx", "--json",
        ])
        let sttCheck = try #require(manager.prefetchArguments(for: Service.nemotron.info, check: true))
        #expect(sttCheck == [
            "-m", "stt_server", "prefetch", "--backend", "nemotron",
            "--model", "mlx-community/nemotron-3.5-asr-streaming-0.6b", "--json", "--check",
        ])
        // No pins, no helper script, no state dir: the upstream CLI owns all three.
        #expect(!(stt + sttPrefetch).contains { $0.hasSuffix(".py") || $0 == "--state-dir" || $0 == "--revision" })
        #expect(manager.serveArguments(for: Service.appleSpeech.info, port: 9465) == nil)
        #expect(manager.prefetchArguments(for: Service.appleSpeech.info, check: false) == nil)

        // One environment per family; logs per variant.
        #expect(paths.envDir(.whisperTiny) == paths.envDir(.whisper))
        #expect(paths.python(.phononQ8) == paths.python(.phonon))
        #expect(paths.appLog(.phononQ8) != paths.appLog(.phonon))
    }

    /// STT environments install against their engine's hash-pinned constraints
    /// (`--require-hashes`); TTS against the `uv.lock` export, without hashes.
    @Test(arguments: [Service.kyutai, .whisperSmall, .parakeet, .nemotron, .phonon])
    func packagesInstallWithTheirConstraints(_ service: Service) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-pins-\(UUID().uuidString.prefix(8))")
        let paths = AppPaths(
            supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"),
            hubDir: root.appending(path: "hub"), derivedModelsDir: root.appending(path: "derived"))
        try paths.prepare()
        let pins = root.appending(path: "constraints")
        try FileManager.default.createDirectory(at: pins, withIntermediateDirectories: true)
        for engine in ["whisper", "kyutai", "parakeet", "nemotron"] {
            FileManager.default.createFile(atPath: pins.appending(path: "stt-\(engine).txt").path, contents: Data())
        }
        let lock = root.appending(path: "constraints.txt")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let argsFile = root.appending(path: "uv-args")
        let uv = root.appending(path: "uv")
        try "#!/bin/sh\nprintf '%s\\n' \"$PWD\" \"$@\" > '\(argsFile.path)'\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let tools = Tools(
            uv: uv, wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"), constraints: lock,
            sttConstraints: pins, source: .override)
        let manager = EnvironmentManager(paths: paths, tools: tools)
        try await Self.fakeEnvironment(service, manager, paths)

        try await manager.install(service, mode: .packages).consume { _ in }

        let args = try String(contentsOf: argsFile, encoding: .utf8).split(separator: "\n").map(String.init)
        let expected: URL? = switch service.info.runtime {
        case .sttHelper(let engine, _): pins.appending(path: "stt-\(engine).txt")
        default: lock
        }
        #expect(try tools.constraints(for: service.info) == expected)
        let constraint = try #require(args.firstIndex(of: "--constraint"))
        #expect(args[constraint + 1] == expected?.lastPathComponent)
        // uv runs from the file's folder (the bundle path has spaces uv would split).
        #expect(URL(filePath: args[0]).resolvingSymlinksInPath().path == expected?.deletingLastPathComponent().resolvingSymlinksInPath().path)
        #expect(args.contains("--require-hashes") == (service.kind == .stt))
        // The pins are not part of the fingerprint: adding them leaves an existing environment ready.
        guard case .ready = manager.environmentStatus(service) else {
            Issue.record("constraints must not mark an environment outdated")
            return
        }
    }

    /// A missing `stt-<engine>.txt` is optional only for repository and override
    /// runs; a bundled build fails closed (its pins are what the build shipped).
    @Test(arguments: [Tools.Source.override, .repository, .bundle])
    func sttConstraintsAreOptionalOnlyOutsideTheBundle(source: Tools.Source) throws {
        let tools = Tools(
            uv: URL(filePath: "/usr/bin/true"), wheel: URL(filePath: "/tmp/x.whl"), constraints: nil,
            sttConstraints: URL(filePath: "/nonexistent"), source: source)
        if source == .bundle {
            #expect(throws: ToolLocatorError.self) { try tools.constraints(for: Service.kyutai.info) }
        } else {
            #expect(try tools.constraints(for: Service.kyutai.info) == nil)
        }
        #expect(try tools.constraints(for: Service.appleSpeech.info) == nil)
        let present = FileManager.default.temporaryDirectory.appending(path: "stt-constraints-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: present, withIntermediateDirectories: true)
        try "x==1 --hash=sha256:00\n".write(to: present.appending(path: "stt-kyutai.txt"), atomically: true, encoding: .utf8)
        let found = Tools(
            uv: URL(filePath: "/usr/bin/true"), wheel: URL(filePath: "/tmp/x.whl"), constraints: nil,
            sttConstraints: present, source: source)
        #expect(try found.constraints(for: Service.kyutai.info)?.lastPathComponent == "stt-kyutai.txt")
    }

    /// A bundled STT install with no pins file is refused at the packages step.
    @Test func aBundledSTTInstallWithoutPinsIsRefused() async throws {
        let paths = try InstallCancellationTests.paths()
        let uv = paths.supportDir.appending(path: "uv")
        try "#!/bin/sh\n[ \"$1\" = venv ] && mkdir -p \"$4/bin\" && printf '#!/bin/sh\\necho 3.12.0\\n' > \"$4/bin/python\" && chmod 755 \"$4/bin/python\"\nexit 0\n"
            .write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths,
            tools: Tools(
                uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil,
                sttConstraints: paths.supportDir.appending(path: "missing"), source: .bundle))
        do {
            try await manager.install(.kyutai).consume { _ in }
            Issue.record("an unpinned bundled STT install went ahead")
        } catch let error as InstallError {
            #expect(error.stage == .packages && error.message.contains("stt-"), "\(error.message)")
        }
        #expect(!manager.isRequested(.kyutai))
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

        let derived = URL(filePath: "/Users/x/.cache/pipecat-tts-server")
        #expect(EnvironmentManager.isDeletableModelPath(repo, hub: hub, derived: derived))
        #expect(EnvironmentManager.isDeletableModelPath(q8, hub: hub, derived: derived))
        #expect(!EnvironmentManager.isDeletableModelPath(URL(filePath: "/Users/x/Documents"), hub: hub, derived: derived))
        #expect(!EnvironmentManager.isDeletableModelPath(derived, hub: hub, derived: derived))
    }

    /// The delete guard's whole contract: a candidate is deletable iff it is a
    /// `models--*` folder directly in the hub, or `<derived>/<backend>/<key>`.
    @Test func deletionStaysInsideTheModelRoots() {
        let hub = URL(filePath: "/Users/x/.cache/huggingface/hub")
        let derived = URL(filePath: "/Users/x/.cache/pipecat-tts-server")
        let cases: [(String, Bool)] = [
            ("/Users/x/.cache/huggingface/hub/models--org--name", true),
            ("/Users/x/.cache/huggingface/hub/models--org--name/", true),
            ("/Users/x/.cache/pipecat-tts-server/phonon/abc-q8", true),
            // Look-alike names outside the roots.
            ("/Users/x/Documents/models--archive", false),
            ("/Users/x/models--x", false),
            ("/Users/x/.cache/huggingface/hub/sub/models--org--name", false),
            ("/Users/x/Documents/pipecat-tts-server/phonon/abc", false),
            ("/tmp/pipecat-tts-server/a/b", false),
            // Not a repo folder, or the roots themselves.
            ("/Users/x/.cache/huggingface/hub", false),
            ("/Users/x/.cache/huggingface/hub/models--", false),
            ("/Users/x/.cache/huggingface/hub/datasets--org--name", false),
            ("/Users/x/.cache/huggingface/hub/.locks", false),
            ("/Users/x/.cache/pipecat-tts-server", false),
            ("/Users/x/.cache/pipecat-tts-server/phonon", false),
            ("/Users/x/.cache/pipecat-tts-server/phonon/abc/deeper", false),
            ("/Users/x/.cache/pipecat-tts-server/.hidden/abc", false),
            // `..` that resolves out of (or back into) a root.
            ("/Users/x/.cache/huggingface/hub/../../../Documents/models--x", false),
            ("/Users/x/.cache/pipecat-tts-server/phonon/../../../../Documents", false),
            ("/Users/x/Documents/../.cache/huggingface/hub/models--org--name", true),
        ]
        for (path, deletable) in cases {
            #expect(
                EnvironmentManager.isDeletableModelPath(URL(filePath: path), hub: hub, derived: derived) == deletable,
                "\(path)")
        }
    }

    @Test func deletionRootsAreComparedWithSymlinksResolved() throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-links-\(UUID().uuidString.prefix(8))")
        let real = root.appending(path: "real-hub")
        try FileManager.default.createDirectory(at: real.appending(path: "models--org--name"), withIntermediateDirectories: true)
        let link = root.appending(path: "hub-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let elsewhere = root.appending(path: "elsewhere")
        #expect(EnvironmentManager.isDeletableModelPath(link.appending(path: "models--org--name"), hub: real, derived: elsewhere))
        #expect(EnvironmentManager.isDeletableModelPath(real.appending(path: "models--org--name"), hub: link, derived: elsewhere))
        #expect(!EnvironmentManager.isDeletableModelPath(root.appending(path: "models--org--name"), hub: link, derived: elsewhere))
    }

    /// Every component of a path to delete resolves inside its root after
    /// symlinks are resolved; only the leaf itself is not followed (deleting a
    /// link removes the link). Shapes on disk x {allowed, refused}.
    @Test func deletionNeverFollowsALinkOutOfTheRoots() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "toolbar-derived-\(UUID().uuidString.prefix(8))")
        defer { try? fm.removeItem(at: root) }
        let hub = root.appending(path: "hub")
        let derived = root.appending(path: "derived")
        let outside = root.appending(path: "outside")
        for dir in [
            hub.appending(path: "models--org--name"), derived.appending(path: "phonon/key"),
            outside.appending(path: "key"), outside.appending(path: "models--org--name"),
            root.appending(path: "derived-evil/phonon/key"),
        ] {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        try fm.createSymbolicLink(at: derived.appending(path: "linked"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: derived.appending(path: "phonon/leaflink"), withDestinationURL: outside.appending(path: "key"))
        try fm.createSymbolicLink(at: hub.appending(path: "models--org--link"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: root.appending(path: "derived-link"), withDestinationURL: derived)
        let cases: [(String, Bool)] = [
            ("derived/phonon/key", true),  // plain
            ("derived/phonon/leaflink", true),  // symlinked leaf: the link is removed, not its target
            ("hub/models--org--link", true),  // symlinked hub leaf, likewise
            ("derived-link/phonon/key", true),  // a link to the root itself resolves to the root
            ("derived/linked/key", false),  // symlinked backend directory (the reported escape)
            ("derived/linked/../phonon/key", true),  // `..` is lexical: deletes derived/phonon/key (below)
            ("derived/phonon/../linked/key", false),
            ("derived", false),  // the root itself
            ("derived/phonon", false),
            ("derived-evil/phonon/key", false),  // sibling prefix of the root
            ("outside/key", false),
        ]
        for (path, deletable) in cases {
            #expect(
                EnvironmentManager.isDeletableModelPath(root.appending(path: path), hub: hub, derived: derived) == deletable,
                "\(path)")
        }
        // What is deleted is the path that was vetted, never what the kernel would reach through the link.
        #expect(
            EnvironmentManager.deletionTarget(root.appending(path: "derived/linked/../phonon/key"), hub: hub, derived: derived)?
                .path == derived.appending(path: "phonon/key").path)
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

/// The Subprocess lifecycle contract over {launch fails, stopped before launch,
/// exits by itself, stopped: child obeys / ignores SIGTERM} x {no descendant,
/// a descendant that obeys / ignores SIGTERM}: the exit signal always
/// resolves (so `waitForExit()` and `stop()` return), and once `stop()`
/// returns no process of the child's group is left.
@Suite struct SubprocessLifecycleTests {
    /// `op`'s result, or nil if it is still running after `limit` (a hang fails
    /// the test instead of hanging it).
    static func within<T: Sendable>(_ limit: Duration, _ op: @escaping @Sendable () async -> T) async -> T? {
        let box = RaceBox<T>()
        return await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            box.set(continuation)
            Task { box.resume(await op()) }
            Task {
                try? await Task.sleep(for: limit)
                box.resume(nil)
            }
        }
    }

    static func alive(_ pid: Int32, polls: Int = 40) async -> Bool {
        // A killed descendant is reparented and reaped shortly after.
        for _ in 0..<polls {
            if Darwin.kill(pid, 0) != 0 { return false }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return true
    }

    static func sh(_ script: String) -> Subprocess {
        Subprocess(.init(executable: URL(filePath: "/bin/sh"), arguments: ["-c", script], environment: ProcessEnvironment.base()))
    }

    @Test func aLaunchFailureResolvesTheExit() async throws {
        let sub = Subprocess(.init(executable: URL(filePath: "/nonexistent/tool"), arguments: [], environment: [:]))
        #expect(throws: (any Error).self) { try sub.run() }
        #expect(await Self.within(.seconds(2)) { await sub.waitForExit() } == Subprocess.notLaunched)
        #expect(await Self.within(.seconds(2)) { await sub.stop(grace: .seconds(30)) } == Subprocess.notLaunched)
    }

    /// A port probe's subprocess (`PortProbe.collect`, the `lsof` step) stops
    /// when its task is cancelled (Stop or quit), and the call returns once it exited.
    @Test func aCancelledPortProbeStopsItsSubprocess() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "probe-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appending(path: "pid")
        let sub = Self.sh("echo $$ > '\(pidFile.path)'; exec sleep 30")
        let probe = Task { await PortProbe.collect(sub) }
        var pid: Int32?
        let deadline = ContinuousClock.now + .seconds(10)
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let started = try #require(pid, "the probe never started")
        probe.cancel()
        let ended = await Self.within(.seconds(5)) { await probe.value?.status }
        #expect(ended != nil, "the cancelled probe kept running")
        #expect(!(await Self.alive(started, polls: 10)), "the probe's subprocess outlived its cancel")
    }

    /// Once the child is reaped, its pid may be reused: a process that holds it
    /// is another one, and its group is never signalled (a stop after the exit,
    /// such as a cancelled port probe whose `lsof` already ended). With no
    /// process on the pid, the group can only be the child's descendants.
    @Test func aReapedChildsReusedPidIsNeverSignalled() {
        #expect(Subprocess.mayTargetGroup(reaped: false, pidHeldByAnother: false))
        #expect(Subprocess.mayTargetGroup(reaped: true, pidHeldByAnother: false))
        #expect(!Subprocess.mayTargetGroup(reaped: true, pidHeldByAnother: true))
    }

    /// After the child exited on its own, a stop still reaches a descendant
    /// that outlived it (no process holds the reaped pid, so the group is ours).
    @Test func aStopAfterTheExitStillStopsAnOrphanedDescendant() async throws {
        let dir = FileManager.default.temporaryDirectory.appending(path: "orphan-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let pidFile = dir.appending(path: "pid")
        let sub = Self.sh("sleep 30 </dev/null >/dev/null 2>&1 & echo $! > '\(pidFile.path)'")
        try sub.run()
        #expect(await Self.within(.seconds(10)) { await sub.waitForExit() } == 0)
        let descendant = try #require(
            (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) })
        defer { Darwin.kill(descendant, SIGKILL) }
        #expect(await Self.within(.seconds(5)) { await sub.stop(grace: .milliseconds(500)) } != nil)
        #expect(!(await Self.alive(descendant, polls: 10)), "the descendant outlived the stop")
    }

    /// The probe case: registered for shutdown before `collect()` launches it.
    @Test func stopBeforeLaunchRefusesTheLaunch() async throws {
        let sub = Self.sh("sleep 30")
        #expect(await Self.within(.seconds(2)) { await sub.stop(grace: .seconds(30)) } == Subprocess.notLaunched)
        await #expect(throws: CancellationError.self) { _ = try await sub.collect() }
        #expect(sub.pid == 0)
        #expect(await Self.within(.seconds(2)) { await sub.waitForExit() } == Subprocess.notLaunched)
    }

    @Test func stopAfterAnExitReturnsItsStatus() async throws {
        let sub = Self.sh("exit 4")
        try sub.run()
        #expect(await sub.waitForExit() == 4)
        #expect(await Self.within(.seconds(2)) { await sub.stop(grace: .seconds(30)) } == 4)
    }

    enum Descendant: CaseIterable { case none, obeysTerm, ignoresTerm }

    @Test(arguments: [false, true], Descendant.allCases)
    func stopLeavesNoDescendant(childIgnoresTerm: Bool, descendant: Descendant) async throws {
        let trap = childIgnoresTerm ? "trap '' TERM; " : ""
        let spawn: String
        switch descendant {
        case .none: spawn = "echo 0; "
        case .obeysTerm: spawn = "(trap - TERM; exec sleep 30) & echo $!; "
        // A shell loop, not `exec sleep`: sleep(1) does not keep an ignored SIGTERM.
        case .ignoresTerm: spawn = "(trap '' TERM; while :; do sleep 0.1; done) & echo $!; "
        }
        // `wait` returns on a signal; the loop keeps an ignoring child alive.
        let sub = Self.sh(trap + spawn + "while :; do wait; sleep 0.05; done")
        try sub.run()
        var lines = sub.stdout.makeAsyncIterator()
        let line = try #require(await lines.next())
        let pid = try #require(Int32(line))
        defer { if pid > 0 { Darwin.kill(pid, SIGKILL) } }
        let clock = ContinuousClock()
        let start = clock.now
        let status = await Self.within(.seconds(5)) { await sub.stop(grace: .milliseconds(600)) }
        #expect(status != nil, "stop() hung")
        #expect(clock.now - start < .seconds(3))
        #expect(!sub.isRunning)
        if pid > 0 { #expect(!(await Self.alive(pid)), "descendant \(descendant) outlived stop()") }
    }
}

private final class RaceBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T?, Never>?
    private var early: T??

    func set(_ continuation: CheckedContinuation<T?, Never>) {
        let ready: T?? = lock.withLock {
            if let early { return early }
            self.continuation = continuation
            return nil
        }
        if let ready { continuation.resume(returning: ready) }
    }

    func resume(_ value: T?) {
        let pending: CheckedContinuation<T?, Never>? = lock.withLock {
            defer { continuation = nil }
            if continuation == nil, early == nil { early = .some(value) }
            return continuation
        }
        pending?.resume(returning: value)
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
        #expect(hello.protocolVersion == "0.1")

        // The live hello maps back to the service that was started (the server is on an
        // ephemeral port, so the match is made on tone's own catalog port).
        let live = try await HelloFixtures.liveHello(port: readyPort)
        #expect(live.backendName == "tone" && live.model == nil && live.protocolVersion == "0.1")
        #expect(HelloFixtures.entry(for: live, port: Service.tone.info.port)?.service == .tone)
        #expect(HelloFixtures.entry(for: live, port: readyPort) == nil, "an ephemeral port belongs to no entry")
        // The probe reads the same hello with no Origin header (a 403 would be `needsToken`);
        // on this port it is a mismatch, and it names the tone server that answered.
        guard case .mismatch(let probed) = await ExternalProbe().probe(port: readyPort) else {
            Issue.record("expected the live tone hello to be read by the probe")
            return
        }
        #expect(probed.backendName == "tone" && probed.protocolVersion == "0.1")

        for frame in TTSClientFrame.request(TTSRequest(id: "tryit-1", text: "Hello there.", voice: nil)) {
            try await client.send(frame)
        }
        var frames = 0
        var finished = false
        while let event = try await client.next() {
            if case .audio = event { frames += 1 }
            if case .done = event { finished = true; break }
            if case .failed(_, _, let message) = event { Issue.record("failed: \(message)"); break }
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
        #expect(hello.backend == "fake" && hello.rate == STTWire.rate)
        #expect(try await client.transcribe(Data(count: 32000)) == "heard 32000 bytes")
        // A second utterance on the same connection.
        #expect(try await client.transcribe(Data(count: 1000), chunkBytes: 300) == "heard 1000 bytes")
        await client.close()
    }

    /// One stt wire format: what the server advertises is what the converter makes.
    @Test func advertisesTheConvertersWireFormat() {
        let audio = STTServerConnection.audioObject()
        #expect(audio["format"] as? String == "pcm16" && STTWire.encoding == "pcm16")
        #expect(audio["rate"] as? Int == STTWire.rate && audio["channels"] as? Int == STTWire.channels)
        let made = PCMStreamConverter.wireFormat
        #expect(made.commonFormat == .pcmFormatInt16 && made.isInterleaved)
        #expect(made.sampleRate == Double(STTWire.rate) && Int(made.channelCount) == STTWire.channels)
        #expect(STTWebSocketServer.maxBufferBytes == 300 * Int(made.sampleRate) * 2 * Int(made.channelCount))
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

@Suite struct LifecycleTests {
    /// A `uv` stand-in that records its pid and then blocks, like a long download.
    static func slowUV(in dir: URL) throws -> (uv: URL, pidFile: URL) {
        let pidFile = dir.appending(path: "uv.pid")
        let uv = dir.appending(path: "uv")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 60\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        return (uv, pidFile)
    }

    static func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    @Test func shutdownStopsAnInFlightInstall() async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-quit-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"))
        try paths.prepare()
        let (uv, pidFile) = try Self.slowUV(in: root)
        let tools = Tools(
            uv: uv, wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"), constraints: nil,
            source: .override)
        let manager = EnvironmentManager(paths: paths, tools: tools)

        let install = Task { () -> Error? in
            do {
                for try await _ in manager.install(.tone) {}
                return nil
            } catch { return error }
        }
        var pid: Int32?
        for _ in 0..<200 where pid == nil {  // up to ~10 s for the stand-in to start
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let installer = try #require(pid, "the installer subprocess never started")
        #expect(Self.alive(installer))

        await manager.shutdown(grace: .seconds(2))

        // Gone before shutdown returned, and the install unwound as a cancellation, not a hang.
        #expect(!Self.alive(installer))
        #expect(await install.value is CancellationError)
        // Nothing can start after shutdown.
        var late: Error?
        do { for try await _ in manager.install(.tone) {} } catch { late = error }
        #expect(late is CancellationError)
    }

    @Test func removingAnOutdatedEnvironmentDeletesItsModel() async throws {
        let (manager, paths) = try VariantTests.manager()
        let hub = paths.supportDir.appending(path: "hub")
        let repo = hub.appending(path: "models--mlx-community--pocket-tts")
        let snapshot = repo.appending(path: "snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: snapshot.appending(path: "w.safetensors").path, contents: Data(count: 8))

        // The environment's python answers `prefetch --check --json` like the real one.
        let python = paths.python(.pocketTTS)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = """
            {"event":"check","path":"\(snapshot.path)","cached":true}
            {"event":"summary","cached":true,"size_bytes":8}
            """
        try "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        // Installed by an older app build: the fingerprint no longer matches.
        try EnvironmentMarker(service: Service.pocketTTS.rawValue, fingerprint: "old.whl", python: "3.12.0", createdAt: Date())
            .write(paths.marker(.pocketTTS))
        guard case .outdated = manager.environmentStatus(.pocketTTS) else {
            Issue.record("expected an outdated environment")
            return
        }

        try await manager.remove(.pocketTTS, deleteModel: true)

        #expect(manager.environmentStatus(.pocketTTS) == .missing)
        #expect(!FileManager.default.fileExists(atPath: repo.path), "model weights survived removal")
    }

    /// An environment whose `prefetch --check` prints `rows`, for removal tests.
    static func checkingEnvironment(_ service: Service, _ paths: AppPaths, rows: [String]) throws {
        let python = paths.python(service)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        let json = (rows + [#"{"event":"summary","cached":false,"size_bytes":8}"#]).joined(separator: "\n")
        try "#!/bin/sh\ncat <<'EOF'\n\(json)\nEOF\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try EnvironmentMarker(service: service.rawValue, fingerprint: "old.whl", python: "3.12.0", createdAt: Date())
            .write(paths.marker(service))
    }

    /// Delete Everything removes every repo the check names, cached or partial
    /// (a cancelled download, a missing codec), not only the cached ones.
    @Test func removalDeletesPartiallyDownloadedRepos() async throws {
        let (manager, paths) = try VariantTests.manager()
        let cached = paths.hubDir.appending(path: "models--org--weights")
        let snapshot = cached.appending(path: "snapshots/abc")
        let partial = paths.hubDir.appending(path: "models--org--codec")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: partial.appending(path: "blobs"), withIntermediateDirectories: true)
        try Self.checkingEnvironment(.pocketTTS, paths, rows: [
            #"{"event":"check","repo":"org/weights","path":"\#(snapshot.path)","cached":true}"#,
            #"{"event":"check","repo":"org/codec","path":null,"cached":false}"#,
        ])
        try await manager.remove(.pocketTTS, deleteModel: true)
        #expect(!FileManager.default.fileExists(atPath: cached.path))
        #expect(!FileManager.default.fileExists(atPath: partial.path), "a partial repo survived Delete Everything")
    }

    /// A reported folder the deletion guard refuses is a failure, never a silent success.
    @Test func aRefusedModelFolderIsReported() async throws {
        let (manager, paths) = try VariantTests.manager()
        let outside = paths.supportDir.appending(path: "elsewhere/models--org--weights")
        let snapshot = outside.appending(path: "snapshots/abc")
        try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
        try Self.checkingEnvironment(.pocketTTS, paths, rows: [
            #"{"event":"check","path":"\#(snapshot.path)","cached":true}"#
        ])
        await #expect(throws: RemovalError.self) {
            try await manager.remove(.pocketTTS, deleteModel: true)
        }
        #expect(FileManager.default.fileExists(atPath: outside.path), "a refused folder was deleted")
    }

    @Test func modelFilesThatCannotBeDeletedAreReported() async throws {
        let (manager, paths) = try VariantTests.manager()
        let repo = paths.supportDir.appending(path: "hub/models--org--stuck")
        try FileManager.default.createDirectory(at: repo.appending(path: "snapshots/abc"), withIntermediateDirectories: true)
        // A read-only parent makes the delete fail.
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: repo.deletingLastPathComponent().path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.deletingLastPathComponent().path) }
        await #expect(throws: RemovalError.self) {
            try await manager.remove(.pocketTTS, deleteModel: true, known: ModelCacheStatus(cached: false, sizeBytes: 0, repoFolders: [repo]))
        }
    }

    @Test func hubCacheFollowsHuggingFaceVariables() {
        let home = URL(filePath: "/Users/x")
        #expect(AppPaths.huggingFaceHub(environment: [:], home: home).path == "/Users/x/.cache/huggingface/hub")
        #expect(AppPaths.huggingFaceHub(environment: ["XDG_CACHE_HOME": "/c"], home: home).path == "/c/huggingface/hub")
        #expect(AppPaths.huggingFaceHub(environment: ["HF_HOME": "/hf", "XDG_CACHE_HOME": "/c"], home: home).path == "/hf/hub")
        #expect(AppPaths.huggingFaceHub(environment: ["HF_HUB_CACHE": "/hub", "HF_HOME": "/hf"], home: home).path == "/hub")
    }
}

/// A flag any task can set and poll (for "did it finish in time" checks that
/// must not hang the test when the answer is no).
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    var value: Bool { lock.withLock { set } }
    func raise() { lock.withLock { set = true } }

    /// Polls for up to `limit`.
    func wait(_ limit: Duration) async -> Bool {
        let deadline = ContinuousClock.now + limit
        while !value, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(20)) }
        return value
    }
}

final class Lines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func append(_ line: String) { lock.withLock { lines.append(line) } }
    var all: [String] { lock.withLock { lines } }
}

@Suite struct SupervisedExitOrderingTests {
    /// The exit lands first and the child's last line after it (the order the
    /// two pipes' queues can deliver them in): the line is still read before
    /// the exit is reported.
    @Test func exitIsReportedAfterTheFinalLine() async throws {
        let sub = Subprocess(
            .init(
                executable: URL(filePath: "/bin/sh"),
                arguments: ["-c", #"(sleep 0.3; printf '{"event":"error","code":"EADDRINUSE"}\n') & exit 1"#],
                environment: ProcessEnvironment.base()))
        try sub.run()
        let lines = Lines()
        let reader = Task { for await line in sub.stdout { lines.append(line) } }
        let status = await sub.waitForExit(after: reader)
        #expect(status == 1)
        #expect(lines.all.compactMap(ServerCLIEvent.parse).last?.errorCode == .addressInUse)
    }

    @Test func drainIsBoundedWhenThePipeStaysOpen() async throws {
        let sub = Subprocess(
            .init(executable: URL(filePath: "/bin/sh"), arguments: ["-c", "(sleep 30) & exit 0"], environment: ProcessEnvironment.base()))
        try sub.run()
        let reader = Task { for await _ in sub.stdout {} }
        let clock = ContinuousClock()
        let start = clock.now
        #expect(await sub.waitForExit(after: reader, drainLimit: .milliseconds(300)) == 0)
        #expect(clock.now - start < .seconds(5))
    }
}

@Suite struct StreamConsumeTests {
    enum Boom: Error { case boom }

    /// How a consumer ends, for every way the stream or the consumer can end.
    @Test func everyEndingIsReportedAsItHappened() async throws {
        enum Ending { case finished, threw, cancelled }
        for ending in [Ending.finished, .threw, .cancelled] {
            let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self, throwing: (any Error).self)
            continuation.yield(1)
            let seen = Lines()
            let consumer = Task { () -> (any Error)? in
                do {
                    try await stream.consume { seen.append("\($0)") }
                    return nil
                } catch { return error }
            }
            while seen.all.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            switch ending {
            case .finished: continuation.finish()
            case .threw: continuation.finish(throwing: Boom.boom)
            case .cancelled: consumer.cancel()
            }
            let error = await consumer.value
            switch ending {
            case .finished: #expect(error == nil)
            case .threw: #expect(error is Boom)
            // The bug: a cancelled `for try await` returns normally, like `.finished`.
            case .cancelled: #expect(error is CancellationError)
            }
            #expect(seen.all == ["1"], "\(ending)")
        }
    }

    /// Nothing is delivered once the task is cancelled, even an element that
    /// was already buffered: the cancel lands while `body` handles element 1
    /// (the stream iterator would still hand out the buffered 2).
    @Test func aBufferedElementIsNotDeliveredAfterACancel() async throws {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Int.self, throwing: (any Error).self)
        continuation.yield(1)
        continuation.yield(2)
        let seen = Lines()
        let consumer = Task { () -> (any Error)? in
            do {
                try await stream.consume { element in
                    seen.append("\(element)")
                    withUnsafeCurrentTask { $0?.cancel() }
                }
                return nil
            } catch { return error }
        }
        let error = await consumer.value
        #expect(error is CancellationError)
        #expect(seen.all == ["1"], "an element was delivered after the cancel")
    }
}

@Suite struct OutboundBudgetTests {
    /// Pending bytes never pass the limit; a reply that would is refused (the
    /// connection then closes), and sent replies free their share.
    @Test func neverQueuesPastTheLimit() {
        var budget = OutboundBudget(limit: 100)
        var granted: [Bool] = []
        for bytes in [60, 40, 1] { granted.append(budget.reserve(bytes)) }
        #expect(granted == [true, true, false])
        #expect(budget.pending == 100)
        budget.release(60)
        granted = [budget.reserve(50), budget.reserve(11)]
        #expect(granted == [true, false] && budget.pending == 90)
        budget.release(1000)
        #expect(budget.pending == 0)
        // A single reply larger than the limit is refused outright.
        var fresh = OutboundBudget(limit: 100)
        let oversize = fresh.reserve(101)
        #expect(!oversize && fresh.pending == 0)
    }
}

@Suite struct STTServerStartupTests {
    /// Stop while the listener is still coming up: start() must end (with an
    /// error, or the port if it bound first), never hang.
    @MainActor @Test func stopDuringStartupEndsTheStart() async throws {
        for _ in 0..<20 {
            let server = STTServerTests.fakeServer()
            let started = Flag()
            let start = Task { @MainActor in
                defer { started.raise() }
                _ = try await server.start(port: 0)
            }
            await Task.yield()
            server.stop()
            let ended = await started.wait(.seconds(3))
            #expect(ended, "start() never returned after stop()")
            guard ended else { return }
            _ = await start.result
        }
    }
}

@Suite struct InstallCancellationTests {
    static func paths() throws -> AppPaths {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-cancel-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let paths = AppPaths(
            supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"),
            hubDir: root.appending(path: "hub"), derivedModelsDir: root.appending(path: "derived"))
        try paths.prepare()
        return paths
    }

    /// An installer that ignores SIGTERM is killed after the grace period, so
    /// Cancel always ends the install (and frees the family lock).
    @Test func cancelKillsAnInstallerThatIgnoresSigterm() async throws {
        let paths = try Self.paths()
        let pidFile = paths.supportDir.appending(path: "uv.pid")
        let uv = paths.supportDir.appending(path: "uv")
        try "#!/bin/sh\ntrap '' TERM\necho $$ > '\(pidFile.path)'\nexec sleep 30\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths,
            tools: Tools(uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil, source: .override),
            cancelGrace: .milliseconds(500))

        let ended = Flag()
        let install = Task {
            defer { ended.raise() }
            try await manager.install(.tone).consume { _ in }
        }
        var pid: Int32?
        for _ in 0..<200 where pid == nil {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let installer = try #require(pid, "the installer subprocess never started")
        install.cancel()
        #expect(await ended.wait(.seconds(5)), "the cancelled install never ended")
        let dead = Flag()
        Task {
            while LifecycleTests.alive(installer) { try? await Task.sleep(for: .milliseconds(20)) }
            dead.raise()
        }
        #expect(await dead.wait(.seconds(5)), "the installer survived Cancel")
        // The family lock is free again: the next install gets past `.queued`.
        let reached = Flag()
        let again = Task {
            try? await manager.install(.tone).consume { if $0 == .stage(.python) { reached.raise() } }
        }
        #expect(await reached.wait(.seconds(5)), "the family lock was still held")
        again.cancel()
    }

    /// Cancel ends the installer's descendants before the install ends, so the
    /// family lock is never free while one (here ignoring SIGTERM) still runs.
    @Test func cancelEndsTheInstallersDescendantsFirst() async throws {
        let paths = try Self.paths()
        let pidFile = paths.supportDir.appending(path: "grandchild.pid")
        let uv = paths.supportDir.appending(path: "uv")
        // The descendant lets go of the pipes, so their EOF does not wait for it.
        try "#!/bin/sh\n(trap '' TERM; exec >/dev/null 2>&1; while :; do sleep 0.1; done) &\necho $! > '\(pidFile.path)'\nwait\n"
            .write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths,
            tools: Tools(uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil, source: .override),
            cancelGrace: .milliseconds(500))
        let ended = Flag()
        let install = Task {
            defer { ended.raise() }
            try await manager.install(.tone).consume { _ in }
        }
        var pid: Int32?
        for _ in 0..<200 where pid == nil {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(50)) }
        }
        let grandchild = try #require(pid, "the installer never started its child")
        defer { Darwin.kill(grandchild, SIGKILL) }
        install.cancel()
        #expect(await ended.wait(.seconds(5)), "the cancelled install never ended")
        // The next install gets the family lock only once the descendant is gone.
        let locked = Flag()
        let again = Task {
            try? await manager.install(.tone).consume { if $0 == .stage(.python) { locked.raise() } }
        }
        #expect(await locked.wait(.seconds(5)), "the family lock was never freed")
        again.cancel()
        // Killed before the lock was freed; allow only for the reaping.
        #expect(!(await SubprocessLifecycleTests.alive(grandchild, polls: 6)), "a descendant outlived the cancelled install")
    }

    /// After app quit begins, the offline cache probe spawns nothing (an install
    /// unwinding from the quit refreshes, which used to start `prefetch --check`).
    @Test func noCacheProbeStartsAfterShutdown() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.pocketTTS, manager, paths)
        let ran = paths.supportDir.appending(path: "probe-ran")
        try "#!/bin/sh\ntouch '\(ran.path)'\necho '{\"event\":\"summary\",\"cached\":true,\"size_bytes\":1}'\n"
            .write(to: paths.python(.pocketTTS), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python(.pocketTTS).path)
        #expect(await manager.modelCacheStatus(.pocketTTS)?.cached == true)
        #expect(FileManager.default.fileExists(atPath: ran.path))
        try FileManager.default.removeItem(at: ran)

        await manager.shutdown(grace: .milliseconds(200), drain: .milliseconds(200))
        #expect(await manager.modelCacheStatus(.pocketTTS) == nil)
        #expect(!FileManager.default.fileExists(atPath: ran.path), "a probe ran after shutdown")
    }
}

extension VariantTests {
    /// Quit while a cache probe (`prefetch --check`) runs: the manager's
    /// `shutdown()` stops it, so it can't outlive the app (`AppLifecycle`'s quit
    /// always runs the manager shutdown, whatever the services are doing).
    @Test func shutdownStopsAnInFlightCacheProbe() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.pocketTTS, manager, paths)
        let pidFile = paths.supportDir.appending(path: "probe-pid")
        try "#!/bin/sh\necho $$ > '\(pidFile.path)'\nexec sleep 30\n"
            .write(to: paths.python(.pocketTTS), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python(.pocketTTS).path)
        let probe = Task { await manager.modelCacheStatus(.pocketTTS) }
        var pid: Int32?
        let deadline = ContinuousClock.now + .seconds(10)
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        let started = try #require(pid, "the cache probe never started")
        await manager.shutdown(grace: .milliseconds(500), drain: .milliseconds(200))
        #expect(!(await SubprocessLifecycleTests.alive(started, polls: 10)), "the cache probe outlived shutdown")
        #expect(await probe.value == nil)
    }

    /// Delete Everything on Phonon 8-bit while full precision stays installed,
    /// and quit begins during the sibling's check: the stopped check is
    /// "unknown", so the voices repo full precision uses (not its model repo,
    /// known only from its check) is kept and reported, never deleted.
    @Test func quitDuringARemovalKeepsWhatASiblingMayUse() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.phonon, manager, paths)
        try await manager.recordVariant(.phonon, installed: true)
        try await manager.recordVariant(.phononQ8, installed: true)
        let repo = paths.hubDir.appending(path: "models--gradium--phonon-31m-en")
        let voices = paths.hubDir.appending(path: "models--gradium--phonon-voices")
        let q8 = paths.derivedModelsDir.appending(path: "phonon/abc-q8")
        for folder in [repo, voices, q8] {
            try FileManager.default.createDirectory(at: folder.appending(path: "snapshots/abc"), withIntermediateDirectories: true)
        }
        // The 8-bit check answers at once; full precision's (no `--model`) hangs
        // until quit stops it.
        let pidFile = paths.supportDir.appending(path: "sibling-check-pid")
        let rows = """
            {"event":"check","repo":"gradium/phonon-31m-en","path":"\(repo.path)/snapshots/abc","cached":true}
            {"event":"check","repo":"gradium/phonon-voices","path":"\(voices.path)/snapshots/abc","cached":true}
            {"event":"summary","cached":true,"size_bytes":8,"quantized":true,"quantized_path":"\(q8.path)"}
            """
        let script = """
            #!/bin/sh
            case "$*" in
            *phonon-q8*) cat <<'EOF'
            \(rows)
            EOF
            ;;
            *) echo $$ > '\(pidFile.path)'; exec sleep 30 ;;
            esac
            """
        try script.write(to: paths.python(.phonon), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python(.phonon).path)

        let removal = Task { try await manager.remove(.phononQ8, deleteModel: true) }
        var pid: Int32?
        let deadline = ContinuousClock.now + .seconds(10)
        while pid == nil, ContinuousClock.now < deadline {
            pid = (try? String(contentsOf: pidFile, encoding: .utf8)).flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            if pid == nil { try await Task.sleep(for: .milliseconds(20)) }
        }
        _ = try #require(pid, "the sibling's check never started")
        await manager.shutdown(grace: .milliseconds(500), drain: .seconds(5))

        await #expect(throws: RemovalError.self) { try await removal.value }
        #expect(FileManager.default.fileExists(atPath: voices.path), "a repo the sibling uses was deleted")
        #expect(FileManager.default.fileExists(atPath: repo.path))
        #expect(!manager.isRequested(.phononQ8) && manager.isRequested(.phonon))
    }
}

@Suite struct QueuedInstallCancelTests {
    /// Cancel while queued behind a sibling's install: it records nothing,
    /// though the environment it would share exists.
    @Test func aCancelledQueuedInstallRecordsNothing() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.phonon, manager, paths)
        // `prefetch` blocks, so the first install holds the family lock.
        try "#!/bin/sh\nsleep 30\n".write(to: paths.python(.phonon), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python(.phonon).path)

        let first = Task { try await manager.install(.phononQ8).consume { _ in } }
        let deadline = ContinuousClock.now + .seconds(5)
        while !manager.isRequested(.phononQ8), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(20)) }
        #expect(manager.isRequested(.phononQ8), "the first install never reached its download")

        let queued = Flag()
        let second = Task {
            try await manager.install(.phononQ4).consume { if $0 == .stage(.queued) { queued.raise() } }
        }
        #expect(await queued.wait(.seconds(5)), "the second install was not queued")
        second.cancel()
        first.cancel()
        _ = await first.result
        // The cancelled install unwinds in the background once the lock frees.
        let settle = ContinuousClock.now + .seconds(2)
        while !manager.isRequested(.phononQ4), ContinuousClock.now < settle { try await Task.sleep(for: .milliseconds(20)) }
        if case .failure(let error) = await second.result {
            #expect(error is CancellationError)
        } else {
            Issue.record("the cancelled install finished")
        }
        #expect(!manager.isRequested(.phononQ4), "a cancelled queued install recorded its variant")
    }
    enum Script { case ok, fail, block }
    enum Outcome: Equatable { case finished, failed(InstallStage), cancelled }

    /// Every way a variant install can end, and whether it records the variant:
    /// the marker is written after packages and before the model download, so
    /// only an install that got that far (and was not cancelled first) has one.
    @Test(arguments: [
        // (environment outdated?, uv, prefetch, cancel while running?) -> outcome, recorded
        (false, Script.ok, Script.ok, false, Outcome.finished, true),
        (false, .ok, .fail, false, .failed(.model), true),
        (false, .ok, .block, true, .cancelled, true),  // resumable: needsModel
        (true, .fail, .ok, false, .failed(.packages), false),
        (true, .block, .ok, true, .cancelled, false),
        (true, .ok, .ok, false, .finished, true),
    ])
    func everyEndingRecordsTheVariantOnlyPastPackages(
        outdated: Bool, uv: Script, prefetch: Script, cancel: Bool, outcome: Outcome, recorded: Bool
    ) async throws {
        let root = FileManager.default.temporaryDirectory.appending(path: "toolbar-ending-\(UUID().uuidString.prefix(8))")
        let paths = AppPaths(
            supportDir: root, cacheDir: root.appending(path: "cache"), logsDir: root.appending(path: "logs"),
            hubDir: root.appending(path: "hub"), derivedModelsDir: root.appending(path: "derived"))
        try paths.prepare()
        let started = root.appending(path: "started")
        func script(_ kind: Script) -> String {
            switch kind {
            case .ok: "#!/bin/sh\nexit 0\n"
            case .fail: "#!/bin/sh\necho 'error: boom' >&2\nexit 1\n"
            case .block: "#!/bin/sh\ntouch '\(started.path)'\nexec sleep 30\n"
            }
        }
        let uvPath = root.appending(path: "uv")
        try script(uv).write(to: uvPath, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uvPath.path)
        let manager = EnvironmentManager(
            paths: paths,
            tools: Tools(uv: uvPath, wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"), constraints: nil,
                         source: .override),
            cancelGrace: .milliseconds(300))
        try await VariantTests.fakeEnvironment(.phonon, manager, paths)
        if outdated {
            try EnvironmentMarker(service: "phonon", fingerprint: "old.whl", python: "3.12.0", createdAt: Date())
                .write(paths.marker(.phonon))
        }
        try script(prefetch).write(to: paths.python(.phonon), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: paths.python(.phonon).path)

        let install = Task { try await manager.install(.phononQ8).consume { _ in } }
        if cancel {
            let deadline = ContinuousClock.now + .seconds(5)
            while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(20))
            }
            install.cancel()
        }
        let ended: Outcome
        switch await install.result {
        case .success: ended = .finished
        case .failure(let error as InstallError): ended = .failed(error.stage)
        case .failure(let error): ended = error is CancellationError ? .cancelled : .failed(.queued)
        }
        #expect(ended == outcome)
        // A cancelled install unwinds in the background: give it time to (wrongly) record.
        try await Task.sleep(for: .milliseconds(cancel ? 500 : 50))
        #expect(manager.isRequested(.phononQ8) == recorded)
    }
}

@Suite struct FreshInstallCancelTests {
    /// A fresh build cancelled during the Python version probe (which ignores
    /// Cancel) wrote the environment marker but no variant: it must read as not
    /// installed, not fall back to the pre-variant marker.
    @Test func aFreshInstallCancelledDuringTheVersionProbeIsNotInstalled() async throws {
        let paths = try InstallCancellationTests.paths()
        let started = paths.supportDir.appending(path: "probing")
        // The venv's python answers the version probe slowly; uv's steps succeed.
        let python = paths.supportDir.appending(path: "python-src")
        try "#!/bin/sh\ntouch '\(started.path)'\nsleep 1\necho 3.12.0\n".write(to: python, atomically: true, encoding: .utf8)
        let uv = paths.supportDir.appending(path: "uv")
        try """
        #!/bin/sh
        if [ "$1" = venv ]; then mkdir -p "$4/bin"; cp '\(python.path)' "$4/bin/python"; chmod 755 "$4/bin/python"; fi
        exit 0

        """.write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths, tools: Tools(uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil, source: .override))
        let install = Task { try await manager.install(.tone).consume { _ in } }
        // Generous: the whole suite runs in parallel and spawns many processes.
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path), "the install never reached the version probe")
        install.cancel()
        _ = await install.result
        // The probe finishes (it ignores Cancel) and the marker is written.
        let written = ContinuousClock.now + .seconds(15)
        while EnvironmentMarker.read(paths.marker(.tone)) == nil, ContinuousClock.now < written {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(EnvironmentMarker.read(paths.marker(.tone)) != nil, "the probe did not get to write the marker")
        #expect(!manager.isRequested(.tone), "a cancelled fresh install reads as installed")
    }

    /// An environment from before variants (marker only, no `.variants/`) still
    /// counts its builder as installed, and only its builder.
    @Test func aPreVariantEnvironmentStillReadsAsInstalled() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.phononQ8, manager, paths)
        #expect(!FileManager.default.fileExists(atPath: paths.variantsDir(.phonon).path))
        #expect(manager.isRequested(.phononQ8))
        #expect(!manager.isRequested(.phonon))
    }

    /// A pre-variant environment (marker only) built by Phonon 8-bit from an
    /// older wheel, with a python that answers the version probe after `delay`.
    static func preVariantOutdatedEnvironment(delay: String) throws -> (EnvironmentManager, AppPaths, URL) {
        let paths = try InstallCancellationTests.paths()
        let started = paths.supportDir.appending(path: "probing")
        let python = paths.python(.phononQ8)
        try FileManager.default.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch '\(started.path)'\nsleep \(delay)\necho 3.12.0\n".write(to: python, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
        try EnvironmentMarker(service: Service.phononQ8.rawValue, fingerprint: "an older wheel", python: "3.12.0", createdAt: Date())
            .write(paths.marker(.phononQ8))
        let uv = paths.supportDir.appending(path: "uv")
        try "#!/bin/sh\nexit 0\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths, tools: Tools(uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil, source: .override))
        return (manager, paths, started)
    }

    /// Rule for marker-only environments: an existing one records its builder
    /// in `.variants/` before a sibling's install changes anything (a fresh
    /// build starts with an empty `.variants/`). A sibling's package refresh
    /// rewrites the marker; the builder stays installed next to the sibling.
    @Test func aSiblingInstallKeepsAPreVariantBuilder() async throws {
        let (manager, paths, _) = try Self.preVariantOutdatedEnvironment(delay: "0")
        #expect(manager.isRequested(.phononQ8) && !manager.isRequested(.phonon))
        try await manager.install(.phonon, mode: .packages).consume { _ in }
        #expect(EnvironmentMarker.read(paths.marker(.phonon))?.service == Service.phonon.rawValue)
        #expect(manager.isRequested(.phonon), "the sibling was not recorded")
        #expect(manager.isRequested(.phononQ8), "the pre-variant builder was lost")
    }

    /// Cancel after the sibling's marker write but before its variant record:
    /// the sibling does not read as installed, and the builder still does.
    @Test func aCancelledSiblingInstallLeavesAPreVariantBuilderInstalled() async throws {
        let (manager, paths, started) = try Self.preVariantOutdatedEnvironment(delay: "1")
        let install = Task { try await manager.install(.phonon, mode: .packages).consume { _ in } }
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: started.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path), "the install never reached the version probe")
        install.cancel()
        _ = await install.result
        let written = ContinuousClock.now + .seconds(15)
        while EnvironmentMarker.read(paths.marker(.phonon))?.service != Service.phonon.rawValue, ContinuousClock.now < written {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(EnvironmentMarker.read(paths.marker(.phonon))?.service == Service.phonon.rawValue, "the marker was not rewritten")
        #expect(!manager.isRequested(.phonon), "a cancelled sibling install reads as installed")
        #expect(manager.isRequested(.phononQ8), "the pre-variant builder disappeared")
    }

    /// A variant record that can't be written fails the call instead of
    /// reporting success.
    @Test func aVariantRecordThatCannotBeWrittenThrows() async throws {
        let (manager, paths) = try VariantTests.manager()
        try await VariantTests.fakeEnvironment(.phonon, manager, paths)
        try await manager.recordVariant(.phonon, installed: true)
        let dir = paths.variantsDir(.phonon)
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir.path) }
        await #expect(throws: (any Error).self) { try await manager.recordVariant(.phononQ8, installed: true) }
        await #expect(throws: (any Error).self) { try await manager.recordVariant(.phonon, installed: false) }
        #expect(manager.isRequested(.phonon) && !manager.isRequested(.phononQ8))
    }
}

@Suite struct PipeDrainTests {
    /// A child that exits while a grandchild still holds its pipes.
    static let leaky = "(sleep 20) &\necho out\necho failed >&2\nexit 3\n"

    /// Waits until a test script has started (it touches `marker` first). The
    /// first exec of a newly written executable waits for macOS to assess it,
    /// and with the whole suite writing scripts at once that queue reaches
    /// seconds (measured: median 2.3 s, max 4.2 s for 40 new scripts at once;
    /// 26 ms re-exec'd). A bound on how promptly an install ends is timed from
    /// here, so it measures the install, not that OS queue.
    static func waitUntilStarted(_ marker: URL) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: marker.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(FileManager.default.fileExists(atPath: marker.path), "the child never started")
    }

    @Test func anInstallStepEndsWhenAGrandchildHoldsItsPipes() async throws {
        let paths = try InstallCancellationTests.paths()
        let started = paths.supportDir.appending(path: "started")
        let uv = paths.supportDir.appending(path: "uv")
        try "#!/bin/sh\ntouch '\(started.path)'\n\(Self.leaky)".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let manager = EnvironmentManager(
            paths: paths, tools: Tools(uv: uv, wheel: URL(filePath: "/tmp/x.whl"), constraints: nil, source: .override))
        let ended = Flag()
        let install = Task {
            defer { ended.raise() }
            try await manager.install(.tone).consume { _ in }
        }
        try await Self.waitUntilStarted(started)
        #expect(await ended.wait(.seconds(8)), "the install waited for the grandchild")
        if case .failure(let error) = await install.result {
            #expect((error as? InstallError)?.stage == .python)
        } else {
            Issue.record("a failing step finished")
        }
    }

    @Test func collectEndsWhenAGrandchildHoldsItsPipes() async throws {
        let sub = Subprocess(
            .init(executable: URL(filePath: "/bin/sh"), arguments: ["-c", Self.leaky], environment: ProcessEnvironment.base()))
        let ended = Flag()
        let result = Task {
            defer { ended.raise() }
            return try await sub.collect()
        }
        #expect(await ended.wait(.seconds(8)), "collect waited for the grandchild")
        let collected = try await result.value
        #expect(collected.status == 3 && collected.stdout == ["out"] && collected.stderr == ["failed"])
    }
    enum Child: CaseIterable { case exits, fails, leaksAndFails, ignoresTermThenCancelled, leaksThenCancelled }

    /// Every way an install subprocess (a uv step or `prefetch`) can end, with
    /// and without a grandchild holding its pipes: the install ends promptly and
    /// the family lock is free for the next one.
    @Test(arguments: Child.allCases, [false, true])
    func everyChildEndingReleasesTheFamily(child: Child, inPrefetch: Bool) async throws {
        let paths = try InstallCancellationTests.paths()
        let started = paths.supportDir.appending(path: "started")
        let body: String
        switch child {
        case .exits: body = "[ \"$1\" = venv ] && mkdir -p \"$4\"\nexit 0"
        case .fails: body = "exit 3"
        case .leaksAndFails: body = "(sleep 20) &\nexit 3"
        case .ignoresTermThenCancelled: body = "trap '' TERM\ntouch '\(started.path)'\nsleep 20"
        case .leaksThenCancelled: body = "(sleep 20) &\ntouch '\(started.path)'\nexec sleep 20"
        }
        let cancelled = child == .ignoresTermThenCancelled || child == .leaksThenCancelled
        // A child that is cancelled marks its start once it is set up; any other marks it first.
        let script = paths.supportDir.appending(path: "child")
        try "#!/bin/sh\n\(cancelled ? "" : "touch '\(started.path)'\n")\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let manager = EnvironmentManager(
            paths: paths,
            tools: Tools(
                uv: inPrefetch ? URL(filePath: "/usr/bin/true") : script,
                wheel: URL(filePath: "/tmp/pipecat_local_tts_server-0-py3-none-any.whl"), constraints: nil,
                source: .override),
            cancelGrace: .milliseconds(300), drainLimit: .milliseconds(300))
        let service: Service = inPrefetch ? .phonon : .tone
        if inPrefetch {
            try await VariantTests.fakeEnvironment(.phonon, manager, paths)
            try FileManager.default.removeItem(at: paths.python(.phonon))
            try FileManager.default.copyItem(at: script, to: paths.python(.phonon))
        }

        let ended = Flag()
        let install = Task {
            defer { ended.raise() }
            try await manager.install(service).consume { _ in }
        }
        try await Self.waitUntilStarted(started)
        if cancelled { install.cancel() }
        #expect(await ended.wait(.seconds(5)), "\(child): the install did not end")
        let result = await install.result
        switch child {
        case .exits: if case .failure(let error) = result { Issue.record("\(child): \(error)") }
        case .fails, .leaksAndFails: #expect((try? result.get()) == nil)
        case .ignoresTermThenCancelled, .leaksThenCancelled:
            if case .failure(let error) = result { #expect(error is CancellationError) } else { Issue.record("finished") }
        }
        // The lock comes free (a cancelled install unwinds in the background): the
        // next install of the family gets past `.queued`.
        let progressed = Flag()
        let next = Task {
            try? await manager.install(service).consume { if case .stage(let s) = $0, s != .queued { progressed.raise() } }
        }
        #expect(await progressed.wait(.seconds(3)), "\(child): the family lock was still held")
        next.cancel()
        _ = await next.value
    }
}

@Suite struct STTServerLifetimeTests {
    /// Stop and release the server while a client is connected: the connection's
    /// late callbacks (cancelled state, close completion) must not touch it.
    @Test func connectionsOutliveAReleasedServer() async throws {
        // A decode in flight keeps its session alive past stop().
        var server: STTWebSocketServer? = STTWebSocketServer(identity: .init(name: "slow", model: nil)) { _, _ in
            // Ignores cancellation, as a real decode can.
            await withCheckedContinuation { done in DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) { done.resume() } }
            return "late"
        }
        let port = try await server!.start(port: 0)
        let client = STTClient(port: port)
        _ = try await client.connect()
        let pending = Task { try? await client.transcribe(Data(count: 3200)) }
        try await Task.sleep(for: .milliseconds(150))
        weak let released = server
        let queue = server!.queue
        let gate = DispatchSemaphore(value: 0)
        server?.stop()
        // Hold the server queue so the connection's callbacks run after the release.
        queue.async { gate.wait() }
        server = nil
        #expect(released == nil, "the test needs the server gone")
        gate.signal()
        try await Task.sleep(for: .milliseconds(1000))
        _ = await pending.value
        await client.close()
    }

    @Test func connectionsBeyondTheCapAreRefused() async throws {
        let server = STTServerTests.fakeServer()
        let port = try await server.start(port: 0)
        defer { server.stop() }
        var clients: [STTClient] = []
        for _ in 0..<STTWebSocketServer.maxConnections {
            let client = STTClient(port: port)
            _ = try await client.connect()
            clients.append(client)
        }
        let extra = STTClient(port: port)
        await #expect(throws: (any Error).self) { _ = try await extra.connect() }
        // A freed slot is usable again.
        await clients.removeFirst().close()
        try await Task.sleep(for: .milliseconds(200))
        let again = STTClient(port: port)
        _ = try await again.connect()
        for client in clients + [again, extra] { await client.close() }
    }

    @Test func decodesRunOneAtATime() async throws {
        let gauge = ConcurrencyGauge()
        let server = STTWebSocketServer(identity: .init(name: "slow", model: nil)) { pcm, _ in
            gauge.enter()
            defer { gauge.leave() }
            try await Task.sleep(for: .milliseconds(200))
            return "heard \(pcm.count)"
        }
        let port = try await server.start(port: 0)
        defer { server.stop() }
        let a = STTClient(port: port)
        let b = STTClient(port: port)
        _ = try await a.connect()
        _ = try await b.connect()
        async let first = a.transcribe(Data(count: 3200))
        async let second = b.transcribe(Data(count: 6400))
        #expect(try await [first, second] == ["heard 3200", "heard 6400"])
        #expect(gauge.peak == 1, "two transcriptions ran at once")
        await a.close()
        await b.close()
    }
}

final class ConcurrencyGauge: @unchecked Sendable {
    private let lock = NSLock()
    private var now = 0
    private var max = 0
    func enter() { lock.withLock { now += 1; max = Swift.max(max, now) } }
    func leave() { lock.withLock { now -= 1 } }
    var peak: Int { lock.withLock { max } }
}

@Suite(.serialized) struct CredentialEnvironmentTests {
    /// `uv` runs package build scripts: it never sees the Hugging Face token.
    @Test func onlyModelProcessesGetTheHuggingFaceToken() throws {
        let saved = ProcessInfo.processInfo.environment["HF_TOKEN"]
        setenv("HF_TOKEN", "hf_test_secret", 1)
        defer { if let saved { setenv("HF_TOKEN", saved, 1) } else { unsetenv("HF_TOKEN") } }
        let paths = try InstallCancellationTests.paths()
        #expect(ProcessEnvironment.uv(paths: paths)["HF_TOKEN"] == nil)
        #expect(ProcessEnvironment.base()["HF_TOKEN"] == nil)
        #expect(ProcessEnvironment.huggingFace()["HF_TOKEN"] == "hf_test_secret")
    }

    /// Parakeet's `serve` child sees Homebrew's `ffmpeg`; nothing else gets a wider `PATH`.
    @Test func onlyParakeetServeGetsTheHomebrewPath() {
        let base = ProcessEnvironment.base()["PATH"]
        let parakeet = ProcessEnvironment.serve(.parakeet)["PATH"] ?? ""
        #expect(parakeet == (base ?? "") + ":/opt/homebrew/bin:/usr/local/bin")
        for service in Service.allCases where service != .parakeet {
            #expect(ProcessEnvironment.serve(service)["PATH"] == base, "\(service)")
        }
    }
}

@Suite struct PCMStreamConverterTests {
    /// A 440 Hz tone at 48 kHz float, in microphone-tap-sized buffers.
    static func toneBuffers(seconds: Double = 1, chunk: Int = 4096) -> [AVAudioPCMBuffer] {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48000, channels: 1)!
        let total = Int(48000 * seconds)
        return stride(from: 0, to: total, by: chunk).map { start in
            let count = min(chunk, total - start)
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
            buffer.frameLength = AVAudioFrameCount(count)
            for i in 0..<count { buffer.floatChannelData![0][i] = 0.5 * sin(2 * .pi * 440 * Float(start + i) / 48000) }
            return buffer
        }
    }

    static func samples(_ data: Data) -> [Int16] {
        data.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }

    /// The largest jump between neighbouring samples: a 440 Hz tone at half
    /// scale at 16 kHz moves at most ~2830 per sample; a seam jumps further.
    static func maxStep(_ s: [Int16]) -> Int {
        zip(s, s.dropFirst()).map { abs(Int($1) - Int($0)) }.max() ?? 0
    }

    @Test func buffersJoinWithoutSeams() throws {
        let converter = PCMStreamConverter()
        var out = Data()
        for buffer in Self.toneBuffers() { out += try converter.pcm16(from: buffer) }
        out += try converter.finish()
        let s = Self.samples(out)
        #expect(abs(s.count - 16000) <= 2, "\(s.count) samples for 1 s")
        #expect(Self.maxStep(s) < 3200, "a seam: step \(Self.maxStep(s))")
    }

    /// The reported bug, as the app did it: a converter per buffer.
    @Test func aConverterPerBufferLeavesSeams() throws {
        var out = Data()
        for buffer in Self.toneBuffers() {
            let converter = PCMStreamConverter()
            out += try converter.pcm16(from: buffer) + converter.finish()
        }
        #expect(Self.maxStep(Self.samples(out)) >= 3200)
    }

    @Test func aNewInputFormatStartsANewStream() throws {
        let converter = PCMStreamConverter()
        _ = try converter.pcm16(from: Self.toneBuffers(seconds: 0.1)[0])
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600))
        buffer.frameLength = 1600
        let out = try converter.pcm16(from: buffer) + converter.finish()
        #expect(abs(out.count / 2 - 1600) <= 2)
    }
}

/// The repository bootstrap's uv steps are registered so app quit stops them.
@Suite struct BootstrapProcessTests {
    @Test func quitStopsTheRepositoryWheelBuild() async throws {
        let paths = try InstallCancellationTests.paths()
        let started = paths.supportDir.appending(path: "building")
        let uv = paths.supportDir.appending(path: "uv")
        try "#!/bin/sh\ntouch '\(started.path)'\nsleep 30\n".write(to: uv, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: uv.path)
        let processes = ProcessRegistry()
        let clock = ContinuousClock()
        let begin = clock.now
        let build = Task {
            try await ToolLocator.buildFromRepository(paths.supportDir, uv: uv, paths: paths, processes: processes)
        }
        let deadline = clock.now + .seconds(30)
        while !FileManager.default.fileExists(atPath: started.path), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: started.path), "uv build never started")
        await processes.shutdown(grace: .seconds(1))
        await #expect(throws: (any Error).self) { try await build.value }
        #expect(clock.now - begin < .seconds(20), "the build outlived quit")
        // Nothing starts after quit.
        let late = Subprocess(.init(executable: uv, arguments: [], environment: [:]))
        await #expect(throws: CancellationError.self) { _ = try await processes.collect(late) }
    }
}

/// One decoder for the `server.hello` text frame, shared by the probe and both clients.
@Suite struct ServerHelloFrameTests {
    @Test func decodesTheRecordedToneHello() throws {
        let frame = try HelloFixtures.frame(HelloFixtures.recordedTone)
        #expect(frame.backendName == "tone")
        #expect(frame.model == nil)
        #expect(frame.protocolVersion == "0.1")
        #expect(frame.rate == 24000)
    }

    @Test func decodesModelAndRate() throws {
        let frame = try HelloFixtures.frame(HelloFixtures.json(for: .dia))
        #expect(frame.backendName == "dia" && frame.model == "mlx-community/Dia-1.6B-fp16")
        #expect(frame.rate == 44100)
    }

    @Test func aMissingProtocolVersionIsNilNotAGuess() throws {
        let frame = try HelloFixtures.frame(HelloFixtures.json(name: "tone", model: nil, protocolVersion: nil))
        #expect(frame.protocolVersion == nil)
    }

    @Test func otherFramesAndNonJSONAreNotHellos() {
        #expect(ServerHelloFrame.decode(#"{"type":"server.status","voices":[],"queue_depth":0}"#) == nil)
        #expect(ServerHelloFrame.decode(#"{"type":"response.audio.done","response_id":"r1"}"#) == nil)
        #expect(ServerHelloFrame.decode("not json") == nil)
        #expect(ServerHelloFrame.decode("") == nil)
    }

    @Test func aHelloWithoutABackendNameIsNeverAdopted() throws {
        // Unsupported (plan): either the decoder rejects it or the match does.
        let json = HelloFixtures.json(name: nil, model: nil)
        if let frame = ServerHelloFrame.decode(json) {
            for service in Service.allCases where service != .appleSpeech {
                #expect(HelloFixtures.entry(for: frame, port: service.info.port) == nil, "\(service)")
            }
        }
    }

    /// The TTS client's hello carries the version too, and a memberwise `ServerHello`
    /// without it still compiles (`TTSRequestMachineTests` builds one).
    @Test func ttsClientHelloKeepsTheProtocolVersion() throws {
        guard case .hello(let hello)? = TTSEvent.decode(HelloFixtures.recordedTone) else {
            Issue.record("not a hello")
            return
        }
        #expect(hello.protocolVersion == "0.1")
        #expect(hello.backend == "tone" && hello.rate == 24000)
        guard case .hello(let bare)? = TTSEvent.decode(HelloFixtures.json(name: "tone", model: nil, protocolVersion: nil)) else {
            Issue.record("not a hello")
            return
        }
        #expect(bare.protocolVersion == nil)
        #expect(ServerHello(backend: "x", model: nil, rate: 1, channels: 1, streaming: false, voiceCount: 0, maxTextChars: nil, languages: []).protocolVersion == nil)
    }
}

/// `entry(for:port:)`: the one place a hello becomes a catalog entry.
@Suite struct HelloMatchingTests {
    static let catalogServices = Service.allCases.filter { $0 != .appleSpeech }

    /// Each entry reports a `backend.name` the catalog expects, independent of the fixtures.
    @Test func expectedBackendNames() {
        for service in Service.allCases where service.kind == .tts {
            #expect(service.info.expectedBackendName == service.family.rawValue, "\(service)")
        }
        // Whisper's variants are all the `mlx` backend; Kyutai's both `kyutai`.
        for service in Service.whisper.variants { #expect(service.info.expectedBackendName == "mlx", "\(service)") }
        for service in Service.kyutai.variants { #expect(service.info.expectedBackendName == "kyutai", "\(service)") }
        #expect(Service.parakeet.info.expectedBackendName == "parakeet")
        #expect(Service.nemotron.info.expectedBackendName == "nemotron")
    }

    @Test func launchdLabelsExistPerFamilyOnly() {
        for service in Service.allCases where service.kind == .tts {
            let expected = service == service.family ? "pipecat.tts-server.\(service.rawValue)" : nil
            #expect(service.info.launchdLabel == expected, "\(service)")
        }
        #expect(Service.tone.info.launchdLabel == "pipecat.tts-server.tone")
        #expect(Service.whisper.info.launchdLabel == "pipecat.stt-server")
        #expect(Service.kyutai.info.launchdLabel == "pipecat.stt-server.kyutai")
        #expect(Service.parakeet.info.launchdLabel == "pipecat.stt-server.parakeet")
        #expect(Service.nemotron.info.launchdLabel == "pipecat.stt-server.nemotron")
        for service in Service.whisper.variants.dropFirst() + Service.kyutai.variants.dropFirst() {
            #expect(service.info.launchdLabel == nil, "\(service)")
        }
        #expect(Service.appleSpeech.info.launchdLabel == nil)
    }

    /// Every service's hello, on its own port, maps back to exactly that service.
    @Test func everyHelloMapsBackToItsService() throws {
        for r in HelloFixtures.synthesized {
            let info = try #require(try HelloFixtures.match(HelloFixtures.json(for: r.service), port: r.service.info.port), "\(r.service)")
            #expect(info.service == r.service)
        }
        #expect(Set(HelloFixtures.synthesized.map(\.service)) == Set(Self.catalogServices))
    }

    @Test func recordedToneHelloMapsToTone() throws {
        let info = try #require(try HelloFixtures.match(HelloFixtures.recordedTone, port: Service.tone.info.port))
        #expect(info.service == .tone)
    }

    @Test func phononVariantsReportTheirAlias() throws {
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q8"), port: 9366)?.service == .phononQ8)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q4"), port: 9367)?.service == .phononQ4)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "gradium/phonon-31m-en"), port: 9365)?.service == .phonon)
        // The quantized servers report the alias, not the repo they fetched.
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "gradium/phonon-31m-en"), port: 9366) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "gradium/phonon-31m-en"), port: 9367) == nil)
        // Full precision does not answer on a quantized port, nor q8 on the full port.
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q8"), port: 9365) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q8"), port: 9367) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q4"), port: 9366) == nil)
    }

    @Test func whisperVariantsAllReportMlx() throws {
        for service in Service.whisper.variants {
            let repo = try #require(service.info.modelRepo)
            let json = HelloFixtures.json(name: "mlx", model: repo, rate: 16000)
            #expect(try HelloFixtures.match(json, port: service.info.port)?.service == service, "\(service)")
            // The model decides which variant; another size's repo on this port is a mismatch.
            for other in Service.whisper.variants where other != service {
                #expect(try HelloFixtures.match(json, port: other.info.port) == nil, "\(service) on \(other)")
            }
        }
        // The family name is not the backend name.
        let turbo = try #require(Service.whisper.info.modelRepo)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "whisper", model: turbo), port: Service.whisper.info.port) == nil)
    }

    @Test func kyutaiVariantsMatchByModel() throws {
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .kyutai), port: 9665)?.service == .kyutai)
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .kyutai2B), port: 9666)?.service == .kyutai2B)
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .kyutai2B), port: 9665) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .kyutai), port: 9666) == nil)
    }

    @Test func toneWithAModelIsAMismatch() throws {
        // Tone pins no model: only a hello without one matches.
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "tone", model: nil), port: 8665)?.service == .tone)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "tone", model: "some/model"), port: 8665) == nil)
    }

    @Test func kokoroWithNoModelIsAMismatch() throws {
        // A missing model matches only an entry that pins none; kokoro pins its repo.
        let repo = try #require(Service.kokoro.info.modelRepo)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "kokoro", model: repo), port: 8765)?.service == .kokoro)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "kokoro", model: nil), port: 8765) == nil)
    }

    @Test func unknownModelForAKnownBackendIsAMismatch() throws {
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "kokoro", model: "someone/else-82M"), port: 8765) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "phonon", model: "phonon-q2"), port: 9365) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "mlx", model: "mlx-community/whisper-huge"), port: 9565) == nil)
    }

    @Test func unknownBackendNameIsAMismatch() throws {
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "echo", model: nil), port: 8665) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(name: "TONE", model: nil), port: 8665) == nil)
        // Another entry's backend name on this entry's port.
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .kokoro), port: Service.tone.info.port) == nil)
        #expect(try HelloFixtures.match(HelloFixtures.json(for: .tone), port: Service.kokoro.info.port) == nil)
    }

    @Test(arguments: [nil, "", "0", "0.2", "0.10", "1", "1.0", "v0.1"] as [String?])
    func protocolVersionMustBeZeroPointOne(version: String?) throws {
        for service in Self.catalogServices {
            let json = HelloFixtures.json(for: service, protocolVersion: version)
            #expect(try HelloFixtures.match(json, port: service.info.port) == nil, "\(service) with \(String(describing: version))")
        }
        let ok = HelloFixtures.json(for: .tone, protocolVersion: "0.1")
        #expect(try HelloFixtures.match(ok, port: 8665)?.service == .tone)
    }

    @Test func aHelloOnAnyOtherPortIsAMismatch() throws {
        for r in HelloFixtures.synthesized {
            let json = HelloFixtures.json(for: r.service)
            let own = r.service.info.port
            for port in [own + 1000, own - 1, 0, 1, 65535] where port != own {
                // No other entry shares a model, so a stray port matches nothing.
                #expect(try HelloFixtures.match(json, port: port)?.service != r.service, "\(r.service) on \(port)")
            }
            for other in Self.catalogServices where other != r.service {
                #expect(try HelloFixtures.match(json, port: other.info.port)?.service != r.service, "\(r.service) on \(other)")
            }
        }
    }

    @Test func theMatchIsPureAndStable() throws {
        let json = HelloFixtures.json(for: .phononQ8)
        let frame = try HelloFixtures.frame(json)
        let first = HelloFixtures.entry(for: frame, port: 9366)
        #expect(first == HelloFixtures.entry(for: frame, port: 9366))
        #expect(first == Service.phononQ8.info)
    }
}

/// `PortProbe.owner`: the source line names a LaunchAgent only when that agent holds the port, i.e.
/// the pid in `launchctl print` is the pid `lsof` reports for the port.
@Suite struct PortProbeOwnerTests {
    /// The shape of `launchctl print gui/<uid>/<label>` for a running agent: the service's own
    /// `pid = N` sits one tab in; nested blocks indent further.
    static func printOutput(pid: Int?, nestedPid: Int? = nil) -> [String] {
        var lines = [
            "gui/501/pipecat.tts-server.tone = {",
            "\tactive count = 1",
            "\tpath = /Users/x/Library/LaunchAgents/pipecat.tts-server.tone.plist",
            "\tstate = \(pid == nil ? "waiting" : "running")",
            "",
        ]
        if let nestedPid {
            lines += ["\tdomain = {", "\t\tpid = \(nestedPid)", "\t}"]
        }
        lines += ["\tprogram = /usr/bin/python3", "\targuments = {", "\t\t/usr/bin/python3", "\t}"]
        if let pid { lines.append("\tpid = \(pid)") }
        lines += ["\timmediate reason = inefficient", "}"]
        return lines
    }

    @Test func launchctlPidReadsTheServicesOwnPid() {
        #expect(PortProbe.launchctlPid(Self.printOutput(pid: 4242)) == 4242)
    }

    @Test func aNestedPidDoesNotStandInForTheServicesPid() {
        #expect(PortProbe.launchctlPid(Self.printOutput(pid: 4242, nestedPid: 1)) == 4242)
        #expect(PortProbe.launchctlPid(Self.printOutput(pid: nil, nestedPid: nil)) == nil)
    }

    @Test func aLoadedButNotRunningAgentHasNoPid() {
        #expect(PortProbe.launchctlPid(Self.printOutput(pid: nil)) == nil)
        #expect(PortProbe.launchctlPid([]) == nil)
        #expect(PortProbe.launchctlPid(["\tpid = soon"]) == nil)
    }

    /// The label is set only on a pid match: a loaded agent whose pid is not the port's holder (a
    /// second server on the port, or an agent that is down) does not own the row.
    @Test func theLabelNeedsThePidToMatchTheLsofHolder() {
        let label = "pipecat.stt-server"
        let output = Self.printOutput(pid: 4242)
        // Match: the agent holds the port.
        #expect(PortProbe.launchdLabel(label, launchctlStatus: 0, launchctlLines: output, lsofPid: 4242) == label)
        // A different holder, no holder, an agent that is loaded but down, a failed `launchctl print`.
        #expect(PortProbe.launchdLabel(label, launchctlStatus: 0, launchctlLines: output, lsofPid: 99) == nil)
        #expect(PortProbe.launchdLabel(label, launchctlStatus: 0, launchctlLines: output, lsofPid: nil) == nil)
        #expect(
            PortProbe.launchdLabel(label, launchctlStatus: 0, launchctlLines: Self.printOutput(pid: nil), lsofPid: 4242)
                == nil)
        #expect(PortProbe.launchdLabel(label, launchctlStatus: 113, launchctlLines: output, lsofPid: 4242) == nil)
    }

    /// Against a real listener (this process, on an ephemeral port) for a service with no LaunchAgent
    /// label, so no `launchctl` runs: the holder's pid is found and no label is set.
    @Test func aServiceWithoutALaunchAgentNeverGetsALabel() async throws {
        #expect(Service.phononQ8.info.launchdLabel == nil)
        let server = try await FakeHelloServer.start(.upgradeAndStaySilent)
        defer { server.stop() }
        let owner = await PortProbe.owner(of: server.port, backend: .phononQ8)
        #expect(owner.pid == getpid())
        #expect(owner.launchdLabel == nil)
    }
}
