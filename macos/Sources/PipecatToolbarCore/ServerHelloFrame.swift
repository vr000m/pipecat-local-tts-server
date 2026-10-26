import Foundation

/// The fields of a `server.hello` frame the app reads, from either server (TTS or STT).
///
/// The one parser of that frame: `TTSClient`, `STTClient` and `ExternalProbe` all
/// decode it here, so every caller reads the same fields the same way.
public struct ServerHelloFrame: Sendable, Equatable {
    /// The only wire protocol version the app speaks (docs/protocol.md).
    public static let supportedProtocolVersion = "0.1"

    /// `backend.name`; empty when the frame carries none (such a hello matches no catalog entry).
    public var backendName: String
    /// `backend.model`; nil when absent or null.
    public var model: String?
    /// `protocol_version`; nil when absent.
    public var protocolVersion: String?
    /// `audio.rate`; nil when absent or outside `acceptedRates` (callers then use their default).
    public var rate: Int?

    /// The `audio.rate` values the app plays or resamples. A hello comes from any process that
    /// holds a catalog port (an adopted server is trusted by its hello alone), so a rate of 0, a
    /// negative one or an absurd one is dropped here rather than reaching `AVAudioFormat`.
    public static let acceptedRates = 8000...192_000

    public init(backendName: String, model: String? = nil, protocolVersion: String? = nil, rate: Int? = nil) {
        self.backendName = backendName
        self.model = model
        self.protocolVersion = protocolVersion
        self.rate = rate
    }

    /// Decodes one JSON text frame; nil unless it is a `server.hello` object.
    public static func decode(_ text: String) -> ServerHelloFrame? {
        guard let data = text.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        return decode(object: obj)
    }

    /// Decodes an already-parsed JSON object; nil unless its `type` is `server.hello`.
    public static func decode(object obj: [String: Any]) -> ServerHelloFrame? {
        guard obj["type"] as? String == "server.hello" else { return nil }
        let backend = obj["backend"] as? [String: Any] ?? [:]
        let audio = obj["audio"] as? [String: Any] ?? [:]
        return ServerHelloFrame(
            backendName: backend["name"] as? String ?? "",
            model: backend["model"] as? String,
            protocolVersion: obj["protocol_version"] as? String,
            rate: (audio["rate"] as? Int).flatMap { acceptedRates.contains($0) ? $0 : nil })
    }
}
