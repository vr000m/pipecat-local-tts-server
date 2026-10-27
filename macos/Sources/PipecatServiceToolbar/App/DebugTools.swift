#if DEBUG
    import AVFoundation
    import Foundation
    import PipecatToolbarCore

    /// Debug-only command-line checks for paths the UI drives.
    ///
    /// `PipecatServiceToolbar --apple-speech-selftest <16k-mono.wav>` checks
    /// SpeechAnalyzer's status (installing the model if needed), transcribes the
    /// file directly, then again through `STTWebSocketServer` + `STTClient`.
    @MainActor
    enum DebugTools {
        static func runIfRequested() -> Bool {
            let args = CommandLine.arguments
            // `--apple-speech-status`: prints this binary's asset status and exits. The
            // status is per client (the asset is reserved for the app), so a test asks the app.
            if args.contains("--apple-speech-status") {
                Task {
                    print(await AppleSpeech.status())
                    exit(0)
                }
                return true
            }
            if let i = args.firstIndex(of: "--serve-apple-speech"), i + 1 < args.count, let port = Int(args[i + 1]) {
                Task {
                    let server = STTWebSocketServer(identity: .init(name: Service.appleSpeech.info.expectedBackendName, model: "SpeechTranscriber")) { pcm, language in
                        try await AppleSpeech.transcribe(pcm16: pcm, language: language)
                    }
                    server.onLog = { print($0) }
                    do {
                        let bound = try await server.start(port: port)
                        print("{\"event\":\"ready\",\"port\":\(bound)}")
                        while true { try await Task.sleep(for: .seconds(3600)) }
                    } catch {
                        print("serve failed: \(error.localizedDescription)")
                        exit(1)
                    }
                }
                return true
            }
            guard let i = args.firstIndex(of: "--apple-speech-selftest"), i + 1 < args.count else { return false }
            let wav = URL(filePath: args[i + 1])
            Task {
                do {
                    try await appleSpeechSelfTest(wav: wav)
                    exit(0)
                } catch {
                    print("SELFTEST FAILED: \(error.localizedDescription)")
                    exit(1)
                }
            }
            return true
        }

        static func appleSpeechSelfTest(wav: URL) async throws {
            var status = await AppleSpeech.status()
            print("status: \(status) (locale \(AppleSpeech.localeDescription))")
            if status == .needsDownload || status == .downloading {
                try await AppleSpeech.install { print(String(format: "  install %.0f%%", $0 * 100)) }
                status = await AppleSpeech.status()
                print("status after install: \(status)")
            }
            guard status == .installed else { throw AppleSpeechError.unsupported }

            let file = try AVAudioFile(forReading: wav)
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
            try file.read(into: buffer)
            let pcm = try PCMConverter.pcm16(from: buffer)
            print("audio: \(pcm.count / 32000) s")

            let clock = ContinuousClock()
            var start = clock.now
            let direct = try await AppleSpeech.transcribe(pcm16: pcm, language: nil)
            print("direct (\(clock.now - start)): \(direct)")

            let server = STTWebSocketServer(identity: .init(name: Service.appleSpeech.info.expectedBackendName, model: "SpeechTranscriber")) { pcm, language in
                try await AppleSpeech.transcribe(pcm16: pcm, language: language)
            }
            let port = try await server.start(port: 0)
            defer { server.stop() }
            let client = STTClient(port: port)
            let hello = try await client.connect()
            start = clock.now
            let viaSocket = try await client.transcribe(pcm)
            print("via ws://127.0.0.1:\(port) [\(hello.backend)] (\(clock.now - start)): \(viaSocket)")
            await client.close()
        }
    }
#endif
