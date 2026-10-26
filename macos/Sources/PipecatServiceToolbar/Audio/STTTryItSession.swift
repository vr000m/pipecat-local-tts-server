import AVFoundation
import Foundation
import Observation
import PipecatToolbarCore

/// "Try it" for speech-to-text: speak into the microphone, or send a fixed spoken test
/// clip (`STTSampleClip`, no microphone), then show the transcript.
@MainActor
@Observable
final class STTTryItSession {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case failed(String)
    }

    private(set) var phase: Phase = .idle
    private(set) var transcript: String?
    private(set) var lastSource: String?
    /// For the test clip: whether the transcript is its sentence. Nil for the microphone.
    private(set) var sampleMatch: Bool?
    private(set) var latency: Duration?
    private(set) var level: Float = 0

    let port: Int
    /// False for a server the app did not start (`ExternalPresentation.Actions.microphone`):
    /// the card hides Record and `toggleRecording` refuses, so only the test clip is sent.
    let allowsMicrophone: Bool
    private let engine = AVAudioEngine()
    private var recorded = Data()

    init(port: Int, allowsMicrophone: Bool = true) {
        self.port = port
        self.allowsMicrophone = allowsMicrophone
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
        guard allowsMicrophone else {
            return fail("Recording is off for a server the app did not start. Use Test Clip.")
        }
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
        // One converter per recording: the resampler's state carries across tap buffers.
        let converter = PCMStreamConverter()
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            let pcm = try? converter.pcm16(from: buffer)
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

    // MARK: Test clip

    /// Transcribes the bundled test clip and checks the transcript against its sentence.
    func transcribeSample() async {
        guard !isBusy else { return }
        await transcribe(STTSampleClip.pcm16, source: "Test clip: \u{201C}\(STTSampleClip.sentence)\u{201D}")
        // `transcribe` clears the transcript first and sets it only on success.
        if let transcript { sampleMatch = STTSampleClip.matches(transcript) }
    }

    // MARK: Transcribe

    private func transcribe(_ audio: Data, source: String) async {
        phase = .transcribing
        lastSource = source
        sampleMatch = nil
        transcript = nil
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
