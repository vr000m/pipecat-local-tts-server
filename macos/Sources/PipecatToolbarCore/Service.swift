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
    case parakeet
    case nemotron

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
    /// upstream CLI: `python -m stt_server serve --supervised --backend <b>`, where
    /// `<b>` is the entry's `expectedBackendName`. `engine` names the environment's
    /// hash-pinned constraints file (`macos/constraints/stt-<engine>.txt`).
    case sttHelper(engine: String, requirements: [String])
    /// Apple's on-device SpeechAnalyzer, served by the app itself (macOS 26+).
    case appleSpeech

    public var usesPython: Bool { self != .appleSpeech }
}

/// The licence the model weights are published under (no weights are bundled).
public enum WeightsLicence: Sendable, Equatable {
    case none, system, apache2, mit, ccBy4, ccByNC, researchOnly, other

    public var label: String {
        switch self {
        case .none: "No weights"
        case .system: "Built into macOS"
        case .apache2: "Apache-2.0"
        case .mit: "MIT"
        case .ccBy4: "CC-BY-4.0"
        case .ccByNC: "CC-BY-NC"
        case .researchOnly: "Research only"
        case .other: "Custom licence"
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
        case .other: "Published under a custom licence; read the model card before commercial use."
        }
    }
}

/// Static facts about a service, mirrored from the server READMEs.
public struct ServiceInfo: Sendable, Equatable {
    public let service: Service
    public let kind: ServiceKind
    /// `backend.name` of this entry's `server.hello` (`mlx` for every Whisper size).
    public let expectedBackendName: String
    /// `backend.model` of Apple Speech's in-app server (its `server.hello` and its running row).
    public static let appleSpeechModel = "SpeechTranscriber"
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
    /// The LaunchAgent a `just` recipe installs for this family's default entry, if any:
    /// `pipecat.tts-server.<backend>` for every TTS backend (tone included) and
    /// `pipecat.stt-server[.<engine>]` for the STT families. Variants (Phonon q8/q4,
    /// Whisper sizes, Kyutai 2.6B) and Apple Speech have none.
    public var launchdLabel: String? {
        switch kind {
        case .tts: family == service ? "pipecat.tts-server.\(service.rawValue)" : nil
        case .stt:
            switch service {
            case .whisper: "pipecat.stt-server"
            case .kyutai: "pipecat.stt-server.kyutai"
            case .parakeet: "pipecat.stt-server.parakeet"
            case .nemotron: "pipecat.stt-server.nemotron"
            default: nil
            }
        }
    }
    /// The service's `serve` child runs a tool from Homebrew (`PATH` needs its prefixes):
    /// `parakeet-mlx` decodes audio by running `ffmpeg`, also during its warm-up before
    /// `ready`. No other service runs a tool from `PATH` (`ProcessEnvironment.serve`).
    public var serveRunsHomebrewTools: Bool { family == .parakeet }
    /// What a server's hello must report as `backend.model` to be this entry: the
    /// `--model` argument when the entry passes one (Phonon reports the alias), else the repo.
    /// Nil for an entry that pins no model (tone, Apple Speech).
    public var expectedModel: String? { modelArgument ?? modelRepo }
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

    /// The one decision function: which catalog entry, if any, a server that answered `hello`
    /// on `port` is. Pure and strict, and the only place that decides; every caller
    /// (discovery, the Start-path probe, the tests) uses it.
    ///
    /// A match needs the entry's own port, `backend.name` equal to `expectedBackendName`,
    /// `protocol_version` exactly `0.1`, and `backend.model` equal to the entry's `expectedModel`.
    /// A hello with no model matches only an entry that pins none (tone); an unknown model for
    /// a known backend matches nothing. Apple Speech runs in the app and is never adopted.
    public static func entry(for hello: ServerHelloFrame, port: Int) -> ServiceInfo? {
        guard hello.protocolVersion == ServerHelloFrame.supportedProtocolVersion, !hello.backendName.isEmpty else {
            return nil
        }
        return ServiceCatalog.all.first {
            $0.runtime != .appleSpeech && $0.port == port && $0.expectedBackendName == hello.backendName
                && $0.expectedModel == hello.model
        }
    }

    /// A weights variant of this (family default) service: same runtime and
    /// environment, its own port and model.
    func variant(
        _ service: Service, name: String, label: String, detail: String, port: Int,
        modelArgument: String? = nil, modelRepo: String? = nil, tagline: String? = nil
    ) -> ServiceInfo {
        ServiceInfo(
            service: service, kind: kind, expectedBackendName: expectedBackendName, displayName: name, tagline: tagline ?? self.tagline, runtime: runtime,
            port: port, modelRepo: modelRepo ?? self.modelRepo, licence: licence, streaming: streaming,
            symbol: symbol, variantLabel: label, variantDetail: detail, modelArgument: modelArgument)
    }
}

public enum ServiceCatalog {
    public static let host = "127.0.0.1"

    /// Pins for the STT engines' environments (verified together).
    public static let sttServerRequirement = "pipecat-local-stt-server==0.5.0"

    public static let all: [ServiceInfo] = Service.allCases.map(info(for:))

    public static func services(of kind: ServiceKind) -> [Service] {
        Service.allCases.filter { $0.kind == kind }
    }

    /// The Hub commit upstream `pipecat-local-stt-server` pins each default STT model to
    /// (`stt_server.backends.PINNED_REVISIONS` of `sttServerRequirement`'s release), so the
    /// size estimate is of the exact weights `prefetch`/`serve` load. Any other model repo
    /// is unpinned upstream (it follows `main`) and has no entry. The app passes only
    /// `--model <repo>`; upstream applies the pin itself.
    public static let sttPinnedRevisions: [String: String] = [
        "mlx-community/whisper-large-v3-turbo": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
        "kyutai/stt-1b-en_fr-mlx": "2b995724eef1e964b7ccb6a762b35a665c4abe0d",
        "mlx-community/parakeet-tdt-0.6b-v3": "ed2b7e8c15f9aaa0b5772e2efb986255eaef7e15",
        "mlx-community/nemotron-3.5-asr-streaming-0.6b": "e550040c0478027ed679b2b6b0d055502c103663",
    ]

    /// Every Hugging Face snapshot the install's model step downloads for `service`:
    /// TTS mirrors `prefetch_specs(model)` in the backend module (run with the app's
    /// `--model`, no `PIPECAT_TTS_PHONON_VOICES`), STT the upstream `python -m stt_server prefetch --backend <b> --model <repo>`
    /// (at upstream's pin for a default model, `sttPinnedRevisions`).
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
            return [HubSnapshot(repo: repo, revision: sttPinnedRevisions[repo], files: .allButDocs)]
        case .parakeet:
            return [
                HubSnapshot(
                    repo: repo, revision: sttPinnedRevisions[repo], files: .patterns(["config.json", "model.safetensors"]))
            ]
        case .nemotron:
            return [HubSnapshot(repo: repo, revision: sttPinnedRevisions[repo])]
        default:
            return [HubSnapshot(repo: repo)]
        }
    }

    public static func info(for service: Service) -> ServiceInfo {
        switch service {
        case .tone:
            ServiceInfo(
                service: .tone, kind: .tts, expectedBackendName: "tone", displayName: "Tone", tagline: "Test signal, starts instantly",
                runtime: .ttsServer(extra: nil), port: 8665, modelRepo: nil, licence: .none,
                streaming: false, symbol: "tuningfork")
        case .kokoro:
            ServiceInfo(
                service: .kokoro, kind: .tts, expectedBackendName: "kokoro", displayName: "Kokoro", tagline: "Fast, natural, multilingual",
                runtime: .ttsServer(extra: "kokoro"), port: 8765, modelRepo: "mlx-community/Kokoro-82M-bf16",
                licence: .apache2, streaming: false, symbol: "leaf", isDefault: true)
        case .phonon:
            ServiceInfo(
                service: .phonon, kind: .tts, expectedBackendName: "phonon", displayName: "Phonon", tagline: "Tiny streaming English voice",
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
                service: .pocketTTS, kind: .tts, expectedBackendName: "pocket_tts", displayName: "Pocket TTS", tagline: "Kyutai's small streaming model",
                runtime: .ttsServer(extra: "pocket_tts"), port: 8965, modelRepo: "mlx-community/pocket-tts",
                licence: .ccBy4, streaming: true, symbol: "bolt.horizontal")
        case .qwen3TTS:
            ServiceInfo(
                service: .qwen3TTS, kind: .tts, expectedBackendName: "qwen3_tts", displayName: "Qwen3 TTS", tagline: "Nine speakers, streaming",
                runtime: .ttsServer(extra: "qwen3_tts"), port: 9165,
                modelRepo: "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
                licence: .apache2, streaming: true, symbol: "person.2.wave.2")
        case .voxtralTTS:
            ServiceInfo(
                service: .voxtralTTS, kind: .tts, expectedBackendName: "voxtral_tts", displayName: "Voxtral TTS", tagline: "Mistral's expressive 4B model",
                runtime: .ttsServer(extra: "voxtral_tts"), port: 8865,
                modelRepo: "mlx-community/Voxtral-4B-TTS-2603-mlx-bf16",
                licence: .ccByNC, streaming: true, symbol: "wind")
        case .dia:
            ServiceInfo(
                service: .dia, kind: .tts, expectedBackendName: "dia", displayName: "Dia", tagline: "Dialogue with speaker tags",
                runtime: .ttsServer(extra: "dia"), port: 9065, modelRepo: "mlx-community/Dia-1.6B-fp16",
                licence: .apache2, streaming: false, symbol: "bubble.left.and.bubble.right")
        case .fishTTS:
            ServiceInfo(
                service: .fishTTS, kind: .tts, expectedBackendName: "fish_tts", displayName: "Fish S2 Pro", tagline: "Fish Audio's expressive model",
                runtime: .ttsServer(extra: "fish_tts"), port: 9265, modelRepo: "mlx-community/fish-audio-s2-pro",
                licence: .researchOnly, streaming: false, symbol: "fish")
        case .appleSpeech:
            ServiceInfo(
                service: .appleSpeech, kind: .stt, expectedBackendName: "apple_speech", displayName: "Apple Speech",
                tagline: "On-device SpeechAnalyzer, no Python",
                runtime: .appleSpeech, port: 9465, modelRepo: nil, licence: .system,
                streaming: false, symbol: "apple.logo", isDefault: true)
        case .whisper:
            ServiceInfo(
                service: .whisper, kind: .stt, expectedBackendName: "mlx", displayName: "Whisper", tagline: "OpenAI's speech recognition on MLX",
                runtime: .sttHelper(
                    engine: "whisper", requirements: ["pipecat-local-stt-server[mlx]==0.5.0", "mlx-whisper==0.4.3"]),
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
                service: .kyutai, kind: .stt, expectedBackendName: "kyutai", displayName: "Kyutai STT", tagline: "Streaming, English and French",
                runtime: .sttHelper(engine: "kyutai", requirements: [sttServerRequirement, "moshi_mlx==0.3.0"]),
                port: 9665, modelRepo: "kyutai/stt-1b-en_fr-mlx", licence: .ccBy4,
                streaming: true, symbol: "text.bubble",
                variantLabel: "1B", variantDetail: "English and French, low latency")
        case .kyutai2B:
            info(for: .kyutai).variant(
                .kyutai2B, name: "Kyutai STT 2.6B", label: "2.6B", detail: "English only, more accurate",
                port: 9666, modelRepo: "kyutai/stt-2.6b-en-mlx", tagline: "Streaming, English, larger model")
        case .parakeet:
            ServiceInfo(
                service: .parakeet, kind: .stt, expectedBackendName: "parakeet", displayName: "Parakeet",
                tagline: "NVIDIA's fast multilingual recognition",
                runtime: .sttHelper(engine: "parakeet", requirements: ["pipecat-local-stt-server[parakeet]==0.5.0"]),
                port: 9765, modelRepo: "mlx-community/parakeet-tdt-0.6b-v3", licence: .ccBy4,
                streaming: false, symbol: "hare")
        case .nemotron:
            ServiceInfo(
                service: .nemotron, kind: .stt, expectedBackendName: "nemotron", displayName: "Nemotron",
                tagline: "NVIDIA's multilingual speech recognition model",
                runtime: .sttHelper(engine: "nemotron", requirements: ["pipecat-local-stt-server[nemotron]==0.5.0"]),
                port: 9865, modelRepo: "mlx-community/nemotron-3.5-asr-streaming-0.6b", licence: .other,
                streaming: false, symbol: "brain")
        }
    }
}
