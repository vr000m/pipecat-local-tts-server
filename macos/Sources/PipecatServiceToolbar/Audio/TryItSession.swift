import Foundation
import Observation
import PipecatToolbarCore

/// "Try it": sends text to a running server and plays the streamed audio.
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
    private let port: Int
    private var client: TTSClient?
    private var receiveTask: Task<Void, Never>?
    private var responseID: String?
    private let player = AudioPlayer()

    init(backend: Service, port: Int) {
        self.backend = backend
        self.port = port
        self.text = UserDefaults.standard.string(forKey: Self.textKey) ?? Self.sample(for: backend)
        self.voice = UserDefaults.standard.string(forKey: voiceKey)
        player.onDrained = { [weak self] in
            guard let self, self.phase == .speaking else { return }
            self.phase = .idle
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
        if let voice { UserDefaults.standard.set(voice, forKey: voiceKey) }
        do {
            phase = .connecting
            let client = try await connectedClient()
            guard let hello else { return }
            try player.begin(rate: hello.rate)
            phase = .speaking
            responseID = nil
            try await client.speak(trimmed, voice: voice)
        } catch {
            fail(error.localizedDescription)
        }
    }

    func stop() async {
        player.stop()
        if phase == .speaking { try? await client?.cancel() }
        responseID = nil
        phase = .idle
    }

    /// Loads voices without speaking (when the detail view opens). A failure here
    /// stays silent; pressing Speak retries and reports it.
    func prepare() async {
        guard client == nil else { return }
        _ = try? await connectedClient()
    }

    func detach() {
        receiveTask?.cancel()
        receiveTask = nil
        if let client { Task { await client.close() } }
        client = nil
        player.stop()
        if phase != .idle { phase = .idle }
    }

    private func connectedClient() async throws -> TTSClient {
        if let client { return client }
        let client = TTSClient(port: port)
        let hello: ServerHello
        do {
            hello = try await client.connect()
        } catch {
            await client.close()
            throw error
        }
        self.client = client
        self.hello = hello
        receiveTask = Task { [weak self] in await self?.receive(from: client) }
        if hello.voiceCount > 0 { try await client.requestStatus() }
        return client
    }

    private func receive(from client: TTSClient) async {
        do {
            while let event = try await client.next() {
                handle(event)
            }
        } catch {
            if !Task.isCancelled, self.client === client {
                self.client = nil
                if phase == .speaking { fail("The server closed the connection.") }
            }
        }
    }

    private func handle(_ event: TTSEvent) {
        switch event {
        case .status(let voices, _):
            self.voices = voices
            if let voice, !voices.contains(voice) { self.voice = nil }
        case .responseCreated(let id):
            responseID = id
        case .audio(let rid, _, let pcm):
            guard phase == .speaking, responseID == nil || rid == responseID else { return }
            player.enqueue(pcm16: pcm)
        case .done(let rid, _):
            guard phase == .speaking, responseID == nil || rid == responseID else { return }
            player.finish()
        case .cancelled:
            player.stop()
            if phase == .speaking { phase = .idle }
        case .failed(_, let message):
            fail(message)
        case .error(let code, let message):
            fail(code == "busy" ? "The server is busy. Try again in a moment." : message)
        case .hello, .other:
            break
        }
    }

    private func fail(_ message: String) {
        player.stop()
        phase = .failed(message)
    }
}
