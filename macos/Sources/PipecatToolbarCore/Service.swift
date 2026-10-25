import Foundation

/// Whether a service turns text into speech or speech into text.
public enum ServiceKind: String, CaseIterable, Identifiable, Sendable, Codable {
    case tts, stt

    public var id: String { rawValue }
    public var title: String { self == .tts ? "Text to Speech" : "Speech to Text" }
    public var shortTitle: String { self == .tts ? "TTS" : "STT" }
}

/// One local speech service the toolbar can install and serve.
///
/// Some services are weights variants of another (Phonon 8-bit, Whisper Small):
/// each is its own entry with its own port, so siblings can run side by side,
/// but they share their family's environment. A family's first case is its
/// default and keeps the family's name.
///
/// Raw values of family defaults are `tts_server serve --backend` names (TTS) or
/// the toolbar's own engine names (STT); variants add a suffix.
public enum Service: String, CaseIterable, Identifiable, Sendable, Codable {
    // Text to speech (pipecat-local-tts-server)
    case tone
    case kokoro
    case phonon
    case phononQ8 = "phonon_q8"
    case phononQ4 = "phonon_q4"
    case pocketTTS = "pocket_tts"
    case qwen3TTS = "qwen3_tts"
    case voxtralTTS = "voxtral_tts"
    case dia
    case fishTTS = "fish_tts"
    // Speech to text
    case appleSpeech = "apple_speech"
    case whisper
    case whisperLargeV3 = "whisper_large_v3"
    case whisperMedium = "whisper_medium"
    case whisperSmall = "whisper_small"
    case whisperBase = "whisper_base"
    case whisperTiny = "whisper_tiny"
    case kyutai
    case kyutai2B = "kyutai_2_6b"

    public var id: String { rawValue }
    public var info: ServiceInfo { ServiceCatalog.info(for: self) }
    public var kind: ServiceKind { info.kind }

    /// The family default whose environment and server backend this service uses.
    public var family: Service {
        switch self {
        case .phononQ8, .phononQ4: .phonon
        case .whisperLargeV3, .whisperMedium, .whisperSmall, .whisperBase, .whisperTiny: .whisper
        case .kyutai2B: .kyutai
        default: self
        }
    }

    /// Every variant in this service's family, default first.
    public var variants: [Service] { Service.allCases.filter { $0.family == family } }
}

/// How a service is installed and run.
public enum ServiceRuntime: Sendable, Equatable {
    /// `pipecat-local-tts-server[extra]` from the bundled wheel, run with
    /// `python -m tts_server serve --supervised`.
    case ttsServer(extra: String?)
    /// Pinned PyPI requirements (built on `pipecat-local-stt-server`), run with the
    /// bundled helper's `serve-stt --engine <engine>`.
    case sttHelper(engine: String, requirements: [String])
    /// Apple's on-device SpeechAnalyzer, served by the app itself (macOS 26+).
    case appleSpeech

    public var usesPython: Bool { self != .appleSpeech }
}

/// The licence the model weights are published under (no weights are bundled).
public enum WeightsLicence: Sendable, Equatable {
    case none, system, apache2, mit, ccBy4, ccByNC, researchOnly

    public var label: String {
        switch self {
        case .none: "No weights"
        case .system: "Built into macOS"
        case .apache2: "Apache-2.0"
        case .mit: "MIT"
        case .ccBy4: "CC-BY-4.0"
        case .ccByNC: "CC-BY-NC"
        case .researchOnly: "Research only"
        }
    }

    /// True when commercial use is not granted.
    public var isRestrictive: Bool { self == .ccByNC || self == .researchOnly }

    public var detail: String {
        switch self {
        case .none: "Synthetic test signal, no model weights."
        case .system: "Apple's on-device speech model, covered by the macOS licence."
        case .apache2, .mit: "Commercial use allowed."
        case .ccBy4: "Commercial use allowed with attribution."
        case .ccByNC: "Non-commercial use only."
        case .researchOnly: "Fish Audio Research License: non-commercial; commercial use needs a separate agreement."
        }
    }
}

/// Static facts about a service, mirrored from the server READMEs.
public struct ServiceInfo: Sendable, Equatable {
    public let service: Service
    public let kind: ServiceKind
    public let displayName: String
    public let tagline: String
    public let runtime: ServiceRuntime
    /// Canonical loopback port. TTS ports match the tts repo's `justfile`
    /// `_resolve` table; STT ports continue the same `x65` pattern.
    public let port: Int
    public let modelRepo: String?
    public let licence: WeightsLicence
    public let streaming: Bool
    /// SF Symbol used for the service's tile.
    public let symbol: String
    /// Shown in the list as a recommended default.
    public var isDefault: Bool = false
    /// The variant's name within its family ("8-bit", "Small"); nil for a family of one.
    public var variantLabel: String? = nil
    /// How the variant differs from its siblings ("Best quality").
    public var variantDetail: String? = nil
    /// `--model` for `serve` and `prefetch`, when not the backend's default.
    public var modelArgument: String? = nil

    public var family: Service { service.family }
    public var needsModelDownload: Bool { modelRepo != nil }
    /// The launchd agent `just tts-install` creates; it serves the backend's default model.
    public var launchdLabel: String? {
        kind == .tts && family == service ? "pipecat.tts-server.\(service.rawValue)" : nil
    }
    public var endpoint: String { "ws://\(ServiceCatalog.host):\(port)/" }

    /// Client environment for a Pipecat bot (`TTS_WS_*` / `STT_WS_*`).
    public func environment(port: Int? = nil) -> String {
        let prefix = kind == .tts ? "TTS_WS" : "STT_WS"
        return "\(prefix)_HOST=\(ServiceCatalog.host) \(prefix)_PORT=\(port ?? self.port)"
    }

    /// The Pipecat service constructor to paste into a pipeline.
    ///
    /// TTS: `LocalTTSService` from the tts repo's `examples/pipecat_tts_service.py`.
    /// STT: `LocalWebSocketSTTService` from `stt_server.examples.pipecat_stt_service`.
    public func pipecatService(port: Int? = nil) -> String {
        let cls = kind == .tts ? "LocalTTSService" : "LocalWebSocketSTTService"
        return "\(cls)(host=\"\(ServiceCatalog.host)\", port=\(port ?? self.port))"
    }

    /// A weights variant of this (family default) service: same runtime and
    /// environment, its own port and model.
    func variant(
        _ service: Service, name: String, label: String, detail: String, port: Int,
        modelArgument: String? = nil, modelRepo: String? = nil, tagline: String? = nil
    ) -> ServiceInfo {
        ServiceInfo(
            service: service, kind: kind, displayName: name, tagline: tagline ?? self.tagline, runtime: runtime,
            port: port, modelRepo: modelRepo ?? self.modelRepo, licence: licence, streaming: streaming,
            symbol: symbol, variantLabel: label, variantDetail: detail, modelArgument: modelArgument)
    }
}

public enum ServiceCatalog {
    public static let host = "127.0.0.1"

    /// Pins for the STT engines' environments (verified together).
    public static let sttServerRequirement = "pipecat-local-stt-server==0.3.3"

    public static let all: [ServiceInfo] = Service.allCases.map(info(for:))

    public static func services(of kind: ServiceKind) -> [Service] {
        Service.allCases.filter { $0.kind == kind }
    }

    /// The commit each STT model repo is pinned to: the helper's `MODEL_REVISIONS`
    /// (`macos/Helper/pipecat_app_helper.py`), which `prefetch --repo` downloads and
    /// `serve-stt` loads, so the download size is measured at the same commit.
    /// `tests/test_macos_catalog_drift.py` checks the two tables are equal.
    public static let sttModelRevisions: [String: String] = [
        "mlx-community/whisper-large-v3-turbo": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
        "mlx-community/whisper-large-v3-mlx": "49e6aa286ad60c14352c404340ded53710378a11",
        "mlx-community/whisper-medium-mlx": "7fc08c4eac4c316526498f147dfdee6f6303f975",
        "mlx-community/whisper-small-mlx": "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e",
        "mlx-community/whisper-base-mlx": "1e3e249fb8d01c655324bd6841b1deadffd6d04c",
        "mlx-community/whisper-tiny-mlx": "6caf9c55601caafbe6508a8b0d216bdf4783c4e8",
        "kyutai/stt-1b-en_fr-mlx": "2b995724eef1e964b7ccb6a762b35a665c4abe0d",
        "kyutai/stt-2.6b-en-mlx": "5ccfc8f844ab8abaf591c7954f70c07e72325554",
    ]

    /// Every Hugging Face snapshot the install's model step downloads for `service`:
    /// TTS mirrors `prefetch_specs(model)` in the backend module (run with the app's
    /// `--model`, no `PIPECAT_TTS_PHONON_VOICES`), STT the helper's `prefetch --repo`.
    /// `tests/test_macos_catalog_drift.py` compares this table with both.
    /// Kept above `info(for:)`: the drift tests' parser reads that switch to the end.
    public static func snapshots(for service: Service) -> [HubSnapshot] {
        guard let repo = info(for: service).modelRepo else { return [] }
        switch service.family {
        case .phonon:
            return [HubSnapshot(repo: repo, revision: "52433c46975bfa13144c56204c9f4ee1c5b148aa")]
        case .pocketTTS:
            return [
                HubSnapshot(repo: repo),
                HubSnapshot(
                    repo: "kyutai/pocket-tts-without-voice-cloning", revision: "d4fdd22ae8c8e1cb3634e150ebeff1dab2d16df3",
                    files: .patterns(["embeddings/*.safetensors"]), kind: .voice, required: false),
            ]
        case .dia:
            return [
                HubSnapshot(repo: repo),
                HubSnapshot(
                    repo: "mlx-community/descript-audio-codec-44khz", files: .patterns(["*.safetensors", "*.json"]),
                    kind: .codec),
            ]
        case .whisper, .kyutai:
            return [HubSnapshot(repo: repo, revision: sttModelRevisions[repo], files: .allButDocs)]
        default:
            return [HubSnapshot(repo: repo)]
        }
    }

    public static func info(for service: Service) -> ServiceInfo {
        switch service {
        case .tone:
            ServiceInfo(
                service: .tone, kind: .tts, displayName: "Tone", tagline: "Test signal, starts instantly",
                runtime: .ttsServer(extra: nil), port: 8665, modelRepo: nil, licence: .none,
                streaming: false, symbol: "tuningfork")
        case .kokoro:
            ServiceInfo(
                service: .kokoro, kind: .tts, displayName: "Kokoro", tagline: "Fast, natural, multilingual",
                runtime: .ttsServer(extra: "kokoro"), port: 8765, modelRepo: "mlx-community/Kokoro-82M-bf16",
                licence: .apache2, streaming: false, symbol: "leaf", isDefault: true)
        case .phonon:
            ServiceInfo(
                service: .phonon, kind: .tts, displayName: "Phonon", tagline: "Tiny streaming English voice",
                runtime: .ttsServer(extra: "phonon"), port: 9365, modelRepo: "gradium/phonon-31m-en",
                licence: .apache2, streaming: true, symbol: "dot.radiowaves.left.and.right",
                variantLabel: "Full precision", variantDetail: "Best quality")
        case .phononQ8:
            info(for: .phonon).variant(
                .phononQ8, name: "Phonon 8-bit", label: "8-bit", detail: "Quantized, lighter and faster",
                port: 9366, modelArgument: "phonon-q8")
        case .phononQ4:
            info(for: .phonon).variant(
                .phononQ4, name: "Phonon 4-bit", label: "4-bit", detail: "Smallest, some quality loss",
                port: 9367, modelArgument: "phonon-q4")
        case .pocketTTS:
            ServiceInfo(
                service: .pocketTTS, kind: .tts, displayName: "Pocket TTS", tagline: "Kyutai's small streaming model",
                runtime: .ttsServer(extra: "pocket_tts"), port: 8965, modelRepo: "mlx-community/pocket-tts",
                licence: .ccBy4, streaming: true, symbol: "bolt.horizontal")
        case .qwen3TTS:
            ServiceInfo(
                service: .qwen3TTS, kind: .tts, displayName: "Qwen3 TTS", tagline: "Nine speakers, streaming",
                runtime: .ttsServer(extra: "qwen3_tts"), port: 9165,
                modelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
                licence: .apache2, streaming: true, symbol: "person.2.wave.2")
        case .voxtralTTS:
            ServiceInfo(
                service: .voxtralTTS, kind: .tts, displayName: "Voxtral TTS", tagline: "Mistral's expressive 4B model",
                runtime: .ttsServer(extra: "voxtral_tts"), port: 8865,
                modelRepo: "mlx-community/Voxtral-4B-TTS-2603-mlx-bf16",
                licence: .ccByNC, streaming: true, symbol: "wind")
        case .dia:
            ServiceInfo(
                service: .dia, kind: .tts, displayName: "Dia", tagline: "Dialogue with speaker tags",
                runtime: .ttsServer(extra: "dia"), port: 9065, modelRepo: "mlx-community/Dia-1.6B-fp16",
                licence: .apache2, streaming: false, symbol: "bubble.left.and.bubble.right")
        case .fishTTS:
            ServiceInfo(
                service: .fishTTS, kind: .tts, displayName: "Fish S2 Pro", tagline: "Fish Audio's expressive model",
                runtime: .ttsServer(extra: "fish_tts"), port: 9265, modelRepo: "mlx-community/fish-audio-s2-pro",
                licence: .researchOnly, streaming: false, symbol: "fish")
        case .appleSpeech:
            ServiceInfo(
                service: .appleSpeech, kind: .stt, displayName: "Apple Speech",
                tagline: "On-device SpeechAnalyzer, no Python",
                runtime: .appleSpeech, port: 9465, modelRepo: nil, licence: .system,
                streaming: false, symbol: "apple.logo", isDefault: true)
        case .whisper:
            ServiceInfo(
                service: .whisper, kind: .stt, displayName: "Whisper", tagline: "OpenAI's speech recognition on MLX",
                runtime: .sttHelper(
                    engine: "whisper", requirements: ["pipecat-local-stt-server[mlx]==0.3.3", "mlx-whisper==0.4.3"]),
                port: 9565, modelRepo: "mlx-community/whisper-large-v3-turbo", licence: .mit,
                streaming: false, symbol: "waveform.and.mic",
                variantLabel: "Large v3 Turbo", variantDetail: "Fast and accurate")
        case .whisperLargeV3:
            info(for: .whisper).variant(
                .whisperLargeV3, name: "Whisper Large v3", label: "Large v3", detail: "Most accurate, slowest",
                port: 9566, modelRepo: "mlx-community/whisper-large-v3-mlx")
        case .whisperMedium:
            info(for: .whisper).variant(
                .whisperMedium, name: "Whisper Medium", label: "Medium", detail: "Balanced",
                port: 9567, modelRepo: "mlx-community/whisper-medium-mlx")
        case .whisperSmall:
            info(for: .whisper).variant(
                .whisperSmall, name: "Whisper Small", label: "Small", detail: "Quick, light on memory",
                port: 9568, modelRepo: "mlx-community/whisper-small-mlx")
        case .whisperBase:
            info(for: .whisper).variant(
                .whisperBase, name: "Whisper Base", label: "Base", detail: "Very fast, less accurate",
                port: 9569, modelRepo: "mlx-community/whisper-base-mlx")
        case .whisperTiny:
            info(for: .whisper).variant(
                .whisperTiny, name: "Whisper Tiny", label: "Tiny", detail: "Fastest, least accurate",
                port: 9570, modelRepo: "mlx-community/whisper-tiny-mlx")
        case .kyutai:
            ServiceInfo(
                service: .kyutai, kind: .stt, displayName: "Kyutai STT", tagline: "Streaming, English and French",
                runtime: .sttHelper(engine: "kyutai", requirements: [sttServerRequirement, "moshi_mlx==0.3.0"]),
                port: 9665, modelRepo: "kyutai/stt-1b-en_fr-mlx", licence: .ccBy4,
                streaming: true, symbol: "text.bubble",
                variantLabel: "1B", variantDetail: "English and French, low latency")
        case .kyutai2B:
            info(for: .kyutai).variant(
                .kyutai2B, name: "Kyutai STT 2.6B", label: "2.6B", detail: "English only, more accurate",
                port: 9666, modelRepo: "kyutai/stt-2.6b-en-mlx", tagline: "Streaming, English, larger model")
        }
    }
}
