import Foundation
import Observation
import PipecatToolbarCore

/// "Try it": sends text to a running server and plays the streamed audio.
///
/// The request lifecycle is `TTSRequestMachine`'s (run by `TTSRequestDriver`);
/// this class only turns user actions into its events and its effects into
/// playback and the phase the card shows.
@MainActor
@Observable
final class TryItSession {
    enum Phase: Equatable {
        case idle
        case connecting
        case speaking
        case failed(String)
    }

    var text: String
    var voices: [String] = []
    /// `nil` = the server's default voice.
    var voice: String?
    private(set) var phase: Phase = .idle
    private(set) var hello: ServerHello?

    let backend: Service
    private let driver: TTSRequestDriver
    private let player = AudioPlayer()

    init(backend: Service, port: Int) {
        self.backend = backend
        self.driver = TTSRequestDriver(port: port)
        self.text = UserDefaults.standard.string(forKey: Self.textKey) ?? Self.sample(for: backend)
        self.voice = UserDefaults.standard.string(forKey: voiceKey)
        driver.perform = { [weak self] effect in self?.perform(effect) }
        player.onDrained = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
        }
        player.onInterrupted = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.driver.handle(.abort("Playback stopped: the audio output changed. Press Speak to try again."))
        }
    }

    private static let textKey = "tryIt.text"
    private var voiceKey: String { "tryIt.voice.\(backend.rawValue)" }

    static func sample(for backend: Service) -> String {
        switch backend {
        case .dia: "[S1] Welcome to Pipecat. [S2] It all runs on this Mac."
        case .tone: "A short test tone."
        default: "Hello from Pipecat. This voice is running entirely on your Mac."
        }
    }

    /// The line the menu's "Test Voice" speaks: it names the model under test.
    static func testLine(for info: ServiceInfo) -> String {
        // A variant's display name already carries its label ("Phonon 8-bit"), so the
        // label is not appended: that said "Phonon 8-bit 8-bit".
        let model = info.displayName
        switch info.service {
        case .dia: return "[S1] Hello world, this is the Pipecat test server using \(model). [S2] It all runs on this Mac."
        case .tone: return sample(for: .tone)
        default: return "Hello world, this is the Pipecat test server using the \(model) model."
        }
    }

    var isBusy: Bool { phase == .connecting || phase == .speaking }
    var isSpeaking: Bool { phase == .speaking }
    var overLimit: Bool {
        guard let limit = hello?.maxTextChars else { return false }
        return text.count > limit
    }

    func speak() async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }
        UserDefaults.standard.set(text, forKey: Self.textKey)
        // "Default voice" (nil) is a choice too: forget the last named one.
        if let voice { UserDefaults.standard.set(voice, forKey: voiceKey) } else { UserDefaults.standard.removeObject(forKey: voiceKey) }
        driver.handle(.userSpeak(text: trimmed, voice: voice))
    }

    /// Speaks `line` once, leaving the Try it text box and its saved text alone.
    func speakTest(_ line: String) async {
        guard !isBusy else { return }
        driver.handle(.userSpeak(text: line, voice: voice))
    }

    func stop() async {
        driver.handle(.userStop)
    }

    /// Loads voices without speaking (when the detail view opens). A failure here
    /// stays silent; pressing Speak retries and reports it.
    func prepare() async {
        driver.handle(.userPrepare)
    }

    func detach() {
        driver.handle(.detach)
    }

    private func perform(_ effect: TTSRequestMachine.Effect) {
        switch effect {
        case .connect, .disconnect, .send, .drop:
            break
        case .hello(let hello):
            self.hello = hello
        case .voices(let voices):
            self.voices = voices
            if let voice, !voices.contains(voice) { self.voice = nil }
        case .waiting:
            phase = .connecting
        case .begin:
            do {
                try player.begin(rate: hello?.rate ?? 24000)
                phase = .speaking
            } catch {
                driver.handle(.abort(error.localizedDescription))
            }
        case .play(let pcm):
            player.enqueue(pcm16: pcm)
        case .finish(_, .completed):
            // Idle once the queued audio has played (`onDrained`).
            player.finish()
        case .finish, .stopAudio:
            player.stop()
            phase = .idle
        case .failed(_, _, let message):
            player.stop()
            phase = .failed(message)
        }
    }
}
