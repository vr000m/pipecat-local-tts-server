import AVFoundation
import Foundation
import Observation
import PipecatToolbarCore

/// "Try it" for speech-to-text: speak into the microphone, or let the Mac read a
/// sample sentence, then send the audio to the running server and show the transcript.
@MainActor
@Observable
final class STTTryItSession {
    enum Phase: Equatable {
        case idle
        case recording
        case preparingSample
        case transcribing
        case failed(String)
    }

    static let sampleSentence = "Pipecat runs speech services right here on this Mac."

    private(set) var phase: Phase = .idle
    private(set) var transcript: String?
    private(set) var lastSource: String?
    private(set) var latency: Duration?
    private(set) var level: Float = 0

    let port: Int
    private let engine = AVAudioEngine()
    private var recorded = Data()

    init(port: Int) {
        self.port = port
    }

    var isBusy: Bool { phase != .idle && !isFailed }
    var isFailed: Bool { if case .failed = phase { true } else { false } }

    /// Microphone use needs a usage description (bundled app) and the user's consent.
    static var microphoneAvailable: Bool {
        Bundle.main.object(forInfoDictionaryKey: "NSMicrophoneUsageDescription") != nil
    }

    // MARK: Microphone

    func toggleRecording() async {
        if phase == .recording {
            await stopRecording()
        } else {
            await startRecording()
        }
    }

    private func startRecording() async {
        guard Self.microphoneAvailable else {
            return fail("Microphone access needs the bundled app (just app-open).")
        }
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        guard granted else {
            return fail("Microphone access is off. Allow it in System Settings > Privacy & Security > Microphone.")
        }
        recorded = Data()
        transcript = nil
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.removeTap(onBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let pcm = try? PCMConverter.pcm16(from: buffer)
            let rms = Self.rms(buffer)
            Task { @MainActor in
                guard let self, self.phase == .recording else { return }
                if let pcm { self.recorded.append(pcm) }
                self.level = rms
            }
        }
        do {
            try engine.start()
            phase = .recording
        } catch {
            input.removeTap(onBus: 0)
            fail("Couldn't start the microphone: \(error.localizedDescription)")
        }
    }

    private func stopRecording() async {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        level = 0
        let audio = recorded
        recorded = Data()
        guard audio.count > 3200 else {
            phase = .idle
            return
        }
        await transcribe(audio, source: "Microphone")
    }

    nonisolated private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let data = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        var sum: Float = 0
        for i in 0..<Int(buffer.frameLength) { sum += data[0][i] * data[0][i] }
        return min(1, sqrt(sum / Float(buffer.frameLength)) * 6)
    }

    // MARK: Sample sentence

    /// Synthesizes the sample sentence with the system voice and transcribes it.
    func transcribeSample() async {
        guard !isBusy else { return }
        phase = .preparingSample
        transcript = nil
        do {
            let audio = try await Self.synthesize(Self.sampleSentence)
            await transcribe(audio, source: "Sample: \u{201C}\(Self.sampleSentence)\u{201D}")
        } catch {
            fail("Couldn't synthesize the sample: \(error.localizedDescription)")
        }
    }

    private static func synthesize(_ text: String) async throws -> Data {
        let synthesizer = AVSpeechSynthesizer()
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        let collector = SampleCollector()
        let audio: Data = try await withCheckedThrowingContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer else { return }
                if pcm.frameLength == 0 {
                    if collector.finish() { continuation.resume(returning: collector.data) }
                    return
                }
                if let chunk = try? PCMConverter.pcm16(from: pcm) { collector.append(chunk) }
            }
        }
        withExtendedLifetime(synthesizer) {}
        return audio
    }

    // MARK: Transcribe

    private func transcribe(_ audio: Data, source: String) async {
        phase = .transcribing
        lastSource = source
        let client = STTClient(port: port)
        let clock = ContinuousClock()
        let start = clock.now
        do {
            _ = try await client.connect()
            let text = try await client.transcribe(audio)
            latency = clock.now - start
            transcript = text.isEmpty ? "(no speech detected)" : text
            phase = .idle
        } catch {
            fail(error.localizedDescription)
        }
        await client.close()
    }

    func cancel() {
        if phase == .recording {
            engine.inputNode.removeTap(onBus: 0)
            engine.stop()
        }
        level = 0
        phase = .idle
    }

    private func fail(_ message: String) {
        phase = .failed(message)
    }
}

/// Thread-safe accumulator for synthesizer callbacks.
private final class SampleCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var done = false

    var data: Data { lock.withLock { buffer } }
    func append(_ chunk: Data) { lock.withLock { buffer.append(chunk) } }

    /// True the first time only.
    func finish() -> Bool {
        lock.withLock {
            defer { done = true }
            return !done
        }
    }
}
