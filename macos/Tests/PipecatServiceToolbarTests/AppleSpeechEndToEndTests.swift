import Foundation
import Speech
import Testing

@testable import PipecatToolbarCore

/// Apple Speech, served by the app itself: the debug app binary's
/// `--serve-apple-speech <port>` mode builds the same `STTWebSocketServer`
/// (identity `apple_speech`/`SpeechTranscriber`, transcriber
/// `AppleSpeech.transcribe`) that `ServiceModel.makeNativeServer` hands the
/// driver, so this checks the real SpeechAnalyzer path over the wire with the
/// app's own client. `AppleSpeech` lives in the executable target, which this
/// test target does not link; running the binary avoids that.
///
///     swift build --package-path macos      # the debug app binary
///     PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter AppleSpeechEndToEnd
///
/// Skips (with the reason) unless: macOS 26+, an English locale resolved the way
/// the app resolves it, and the debug binary's speech asset installed. It never
/// downloads the asset. `AssetInventory` reserves assets per client, so the
/// bundled app's install does not count for the debug binary; install once with
/// `macos/.build/debug/PipecatServiceToolbar --apple-speech-selftest <16k-mono.wav>`.
/// No privacy prompt is involved: SpeechAnalyzer's on-device transcription does
/// not go through Speech Recognition authorization (ran unattended from a
/// terminal-launched `swift test`, macOS 26.6).
@Suite(.serialized, .enabled(if: ProcessInfo.processInfo.environment["PIPECAT_TOOLBAR_E2E"] == "1"))
struct AppleSpeechEndToEndTests {
    /// `PIPECAT_TOOLBAR_APP_BINARY`, else the debug build next to this package.
    static var appBinary: URL {
        if let explicit = ProcessInfo.processInfo.environment["PIPECAT_TOOLBAR_APP_BINARY"] { return URL(filePath: explicit) }
        return EndToEndTests.macosDir.appending(path: ".build/debug/PipecatServiceToolbar")
    }

    /// True when the app binary reports its speech asset installed and the locale
    /// it would use (`AppleSpeech.locale(for: nil)`) is English, as the clip is.
    /// The asset status must come from the app: `AssetInventory` answers per client
    /// (an asset the app reserved reads `.supported` from this test process).
    static func appAssetInstalledForEnglish() async -> Bool {
        guard #available(macOS 26, *) else { return false }
        var locale = await SpeechTranscriber.supportedLocale(equivalentTo: .current)
        if locale == nil { locale = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en_US")) }
        guard locale?.language.languageCode == .english else { return false }
        let probe = Subprocess(
            .init(executable: appBinary, arguments: ["--apple-speech-status"], environment: ProcessInfo.processInfo.environment))
        guard let result = try? await probe.collect() else { return false }
        return result.status == 0 && result.stdout.contains("installed")
    }

    static func freePort() -> Int {
        for _ in 0..<50 {
            let port = Int.random(in: 49_152...64_000)
            if PortProbe.isFree(port) { return port }
        }
        return 49_999
    }

    /// The serve mode's `ready` line is block-buffered on a pipe, so readiness is
    /// a successful `server.hello` on the chosen port instead.
    static func connect(port: Int, deadline: Duration = .seconds(30)) async throws -> (STTClient, STTClient.Hello) {
        let end = ContinuousClock.now + deadline
        while true {
            let client = STTClient(port: port)
            do {
                return (client, try await client.connect())
            } catch {
                await client.close()
                if ContinuousClock.now > end { throw error }
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    @Test(
        .enabled("needs the debug app binary: swift build --package-path macos") {
            FileManager.default.isExecutableFile(atPath: AppleSpeechEndToEndTests.appBinary.path)
        },
        .enabled(
            "needs macOS 26, an English locale, and the app binary's speech asset installed (`.build/debug/PipecatServiceToolbar --apple-speech-status` must print `installed`; install with --apple-speech-selftest <wav>)"
        ) {
            await AppleSpeechEndToEndTests.appAssetInstalledForEnglish()
        })
    func appServesAppleSpeechOverTheWire() async throws {
        let port = Self.freePort()
        let server = Subprocess(
            .init(executable: Self.appBinary, arguments: ["--serve-apple-speech", "\(port)"], environment: ProcessInfo.processInfo.environment))
        try server.run()
        defer { server.kill() }

        let (client, hello) = try await Self.connect(port: port)
        #expect(hello.backend == "apple_speech")
        #expect(hello.model == "SpeechTranscriber")
        #expect(hello.rate == STTWire.rate)

        // Two commits on one connection: each is its own utterance.
        let first = try await client.transcribe(try EndToEndTests.spokenClip("The weather today is sunny and warm."))
        #expect(first.lowercased().contains("weather"), "transcript: \(first)")
        #expect(first.lowercased().contains("sunny"), "transcript: \(first)")
        let second = try await client.transcribe(try EndToEndTests.spokenClip("Please call me back tomorrow morning."))
        #expect(second.lowercased().contains("tomorrow"), "transcript: \(second)")
        #expect(!second.lowercased().contains("weather"), "the second utterance carried the first: \(second)")
        // The menu's "Test Transcription" clip must pass its own check against a real model.
        let clip = try await client.transcribe(STTSampleClip.pcm16)
        #expect(STTSampleClip.matches(clip), "test clip transcript: \(clip)")
        await client.close()

        server.terminate()
        _ = await server.waitForExit()
        #expect(PortProbe.isFree(port))
    }
}
