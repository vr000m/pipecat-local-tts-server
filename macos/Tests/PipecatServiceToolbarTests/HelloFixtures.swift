import Foundation

@testable import PipecatToolbarCore

enum HelloFixtureError: Error { case undecodable(String) }

/// `server.hello` frames for the hello-to-entry tests and the probe fakes.
///
/// One real frame is recorded from a lean tone server; every other backend's hello is
/// built from the source of truth (each backend's `backend_name` and default model in
/// `tts_server/backends/*.py`, the STT backend names from the plan) until a live server
/// can be recorded. `HelloMatchingTests` runs all of them through `entry(for:port:)`, so
/// a catalog edit that no longer matches what a server says fails here.
enum HelloFixtures {
    /// RECORDED 2026-10-26 from `python -m tts_server serve --backend tone --host 127.0.0.1
    /// --port <ephemeral>` (volatile `event_id` kept as sent).
    static let recordedTone =
        #"{"type": "server.hello", "event_id": "evt_9effa4fee88945c1", "protocol_version": "0.1", "backend": {"name": "tone", "model": null}, "audio": {"format": "pcm16", "rate": 24000, "channels": 1}, "capabilities": {"streaming": false, "binary_audio": false, "text_formats": ["plain"], "languages": ["en"], "voice_count": 1, "extras": ["speed"], "ideal_words": 40, "max_text_chars": 2000}}"#

    /// What a server reports for one catalog service: `backend.name` and `backend.model`.
    struct Reported: Sendable {
        let service: Service
        let name: String
        let model: String?
        let rate: Int
    }

    // synthesized from source; re-record from a live server
    // (rates are placeholders: nothing asserts them)
    /// `name` is the backend's static `backend_name`; `model` is what its `model`
    /// attribute holds: the default repo, or the raw `--model` argument (Phonon aliases,
    /// `phonon.py:455`). Whisper variants all report `mlx` (plan, STT 0.4.0 `backend.name`).
    static let synthesized: [Reported] = [
        Reported(service: .tone, name: "tone", model: nil, rate: 24000),
        Reported(service: .kokoro, name: "kokoro", model: "mlx-community/Kokoro-82M-bf16", rate: 24000),
        Reported(service: .phonon, name: "phonon", model: "gradium/phonon-31m-en", rate: 24000),
        Reported(service: .phononQ8, name: "phonon", model: "phonon-q8", rate: 24000),
        Reported(service: .phononQ4, name: "phonon", model: "phonon-q4", rate: 24000),
        Reported(service: .pocketTTS, name: "pocket_tts", model: "mlx-community/pocket-tts", rate: 24000),
        Reported(
            service: .qwen3TTS, name: "qwen3_tts", model: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
            rate: 24000),
        Reported(
            service: .voxtralTTS, name: "voxtral_tts", model: "mlx-community/Voxtral-4B-TTS-2603-mlx-bf16",
            rate: 24000),
        Reported(service: .dia, name: "dia", model: "mlx-community/Dia-1.6B-fp16", rate: 44100),
        Reported(service: .fishTTS, name: "fish_tts", model: "mlx-community/fish-audio-s2-pro", rate: 24000),
        Reported(service: .whisper, name: "mlx", model: "mlx-community/whisper-large-v3-turbo", rate: 16000),
        Reported(service: .whisperLargeV3, name: "mlx", model: "mlx-community/whisper-large-v3-mlx", rate: 16000),
        Reported(service: .whisperMedium, name: "mlx", model: "mlx-community/whisper-medium-mlx", rate: 16000),
        Reported(service: .whisperSmall, name: "mlx", model: "mlx-community/whisper-small-mlx", rate: 16000),
        Reported(service: .whisperBase, name: "mlx", model: "mlx-community/whisper-base-mlx", rate: 16000),
        Reported(service: .whisperTiny, name: "mlx", model: "mlx-community/whisper-tiny-mlx", rate: 16000),
        Reported(service: .kyutai, name: "kyutai", model: "kyutai/stt-1b-en_fr-mlx", rate: 16000),
        Reported(service: .kyutai2B, name: "kyutai", model: "kyutai/stt-2.6b-en-mlx", rate: 16000),
        Reported(service: .parakeet, name: "parakeet", model: "mlx-community/parakeet-tdt-0.6b-v3", rate: 16000),
        Reported(
            service: .nemotron, name: "nemotron", model: "mlx-community/nemotron-3.5-asr-streaming-0.6b",
            rate: 16000),
    ]

    static func reported(_ service: Service) -> Reported {
        guard let found = synthesized.first(where: { $0.service == service }) else {
            preconditionFailure("no fixture for \(service)")
        }
        return found
    }

    /// A hello frame as JSON. A nil `model` is `null` (tone); a nil `protocolVersion` or
    /// `name` leaves the key out.
    static func json(
        name: String?, model: String?, protocolVersion: String? = "0.1", rate: Int = 24000
    ) -> String {
        var backend: [String: Any] = ["model": model.map { $0 as Any } ?? NSNull()]
        if let name { backend["name"] = name }
        var object: [String: Any] = [
            "type": "server.hello", "event_id": "evt_fixture", "backend": backend,
            "audio": ["format": "pcm16", "rate": rate, "channels": 1],
            "capabilities": ["streaming": false],
        ]
        if let protocolVersion { object["protocol_version"] = protocolVersion }
        let data = try! JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(decoding: data, as: UTF8.self)
    }

    /// The synthesized hello of `service`, with the given deviations.
    static func json(for service: Service, protocolVersion: String? = "0.1") -> String {
        let r = reported(service)
        return json(name: r.name, model: r.model, protocolVersion: protocolVersion, rate: r.rate)
    }

    // MARK: The code under test, behind one place each

    /// The one decoder (`ServerHelloFrame.decode`) on a JSON text frame.
    static func frame(_ json: String) throws -> ServerHelloFrame {
        guard let frame = ServerHelloFrame.decode(json) else { throw HelloFixtureError.undecodable(json) }
        return frame
    }

    /// The one decision function (`ServiceInfo.entry(for:port:)`).
    static func entry(for frame: ServerHelloFrame, port: Int) -> ServiceInfo? {
        ServiceInfo.entry(for: frame, port: port)
    }

    static func match(_ json: String, port: Int) throws -> ServiceInfo? {
        entry(for: try frame(json), port: port)
    }

    /// The first frame a live server sends on `ws://127.0.0.1:<port>/`, decoded by the
    /// shared decoder. Sends no `Origin` header (URLSession adds none).
    static func liveHello(port: Int) async throws -> ServerHelloFrame {
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        let task = session.webSocketTask(with: URL(string: "ws://127.0.0.1:\(port)/")!)
        task.resume()
        defer { task.cancel(with: .normalClosure, reason: nil) }
        guard case .string(let text) = try await task.receive() else { throw HelloFixtureError.undecodable("binary") }
        return try frame(text)
    }
}
