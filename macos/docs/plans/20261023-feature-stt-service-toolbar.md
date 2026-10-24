# Task: STT services and the Pipecat Service Toolbar (phase 2)

**Status**: Complete on `feature/macos-menubar-app`
**Component**: macos
**Branch**: `feature/macos-menubar-app`
**Created**: 2026-10-23
**Follows**: [phase 1](20261023-feature-macos-menubar-app.md)

## Objective

Turn the TTS menu bar app into **Pipecat Service Toolbar**, a menu bar app for
local speech services of both kinds:

- **STT engines.** Add speech to text with three engines: Apple SpeechAnalyzer
  (the default), Whisper and Kyutai. Serve each on the stt wire protocol so
  Pipecat's `LocalWebSocketSTTService` uses it unchanged.
- **Categories.** Show services by type (TTS, STT).
- **Copy actions.** A right-click menu with **Copy URL**, **Copy Pipecat
  Service** and **Copy Environment Variables**.
- **Delete.** Delete a model from the same right-click menu.
- **Two views.** The main menu shows only running services, by category. Every
  other model sits in an **Add Models** view.
- **Polish.** Tidy the UI and write a terse README in the style of
  [onoats](https://github.com/vr000m/onoats-bot/blob/main/README.md).
- **Docs.** Put the architecture and the plans in `macos/docs/`, and open a PR.

## Context (findings that shaped the design)

- **`pipecat-local-stt-server` 0.3.3 (PyPI)** has `mlx` (Whisper), `parakeet`
  and `nemotron` backends. It has no Kyutai backend, no supervised mode and no
  prefetch. Its `serve()` takes any backend object and has an unused `ready`
  hook, the same shape as `tts_server`. Its wire protocol is commit-oriented:
  binary pcm16 at 16 kHz mono, `input_audio_buffer.commit`, then one delta and
  one `completed`.
- **Port convention.** STT endpoints are Unix sockets under
  `~/Library/Caches/pipecat-stt/` and have no TCP port convention. Clients read
  `STT_WS_HOST` / `STT_WS_PORT` (or `STT_WS_SOCKET`).
- **Kyutai on MLX** is `moshi_mlx==0.3.0` with `kyutai/stt-1b-en_fr-mlx`
  (~2.4 GB, CC-BY-4.0). It pins `mlx<0.27` and `huggingface-hub<0.29`. That
  clashes with the other engines' stacks, but each service gets its own venv,
  so it doesn't matter here. Streaming reference: Kyutai's
  `delayed-streams-modeling/scripts/stt_from_file_mlx.py`. Audio is 24 kHz in
  80 ms frames, through Mimi then the LM, with 2 s of trailing silence.
- **`LmGen` cache.** `LmGen` does not reset the LM's transformer cache, so it
  must be reset between utterances. The LM context is 3000 frames, about 240 s.
- **Apple SpeechAnalyzer** needs macOS 26+. It uses `SpeechTranscriber` and
  `AssetInventory` for the on-device model download, which needed no permission
  prompt on macOS 27.

## Decisions

- **Ports.** STT runs on loopback TCP with canonical ports that continue the
  TTS `x65` pattern: Apple Speech 9465, Whisper 9565, Kyutai 9665. Every service
  then has a URL to copy.
- **Python STT runtime.** Whisper and Kyutai run through a helper bundled with
  the app (`Helper/pipecat_app_helper.py`), not through changes to the stt repo.
  The helper adds:
  - `prefetch`, with byte progress measured on disk so it works with any
    `huggingface_hub` version;
  - `serve-stt`, with the same supervised contract as `tts_server`;
  - a `KyutaiBackend` that plugs into `stt_server.server.serve()`.
- **STT pins.** STT environments install exact pins from PyPI:
  `pipecat-local-stt-server==0.3.3`, plus `mlx-whisper==0.4.3` or
  `moshi_mlx==0.3.0`. The environment fingerprint is the requirement list, so
  changing a pin triggers a package refresh on the next start.
- **Apple Speech serving.** Apple Speech runs inside the app behind
  `STTWebSocketServer` (Network.framework). It implements the stt protocol,
  including the 403-on-`Origin` rule. The Python `stt_server` client and
  `status` probe were run against it.
- **Navigation.** The main menu shows active services: running, starting,
  stopping, or failed at runtime. Installed-but-stopped and available models
  live in Add Models, which has a TTS / STT switch.
- **Copy strings.**
  - TTS: `LocalTTSService(host="127.0.0.1", port=N)` (this repo's
    `examples/pipecat_tts_service.py`).
  - STT: `LocalWebSocketSTTService(host="127.0.0.1", port=N)`
    (`stt_server.examples.pipecat_stt_service`).
  - Environment: `TTS_WS_*` / `STT_WS_*`.
- **Delete.** Delete removes the venv and the model's Hugging Face cache folders
  after an `NSAlert` confirmation. Apple Speech has nothing to delete, since its
  assets are managed by the system.
- **Rename.**
  - App: Pipecat Service Toolbar.
  - Bundle id: `ai.pipecat.ServiceToolbar`.
  - Package targets: `PipecatServiceToolbar`, `PipecatToolbarCore`.
  - Data folders: `… / Pipecat Service Toolbar`.
  - Overrides: `PIPECAT_TOOLBAR_*`.

## Implementation

- **Core.**
  - `Service` / `ServiceKind` / `ServiceRuntime` catalog (`Service.swift`).
  - Runtime-aware commands in `EnvironmentManager`: `requirements`,
    `prefetchArguments`, `serveArguments`.
  - `STTClient`.
  - `STTWebSocketServer`.
  - `ToolLocator` finds the helper.
- **App.**
  - `AppleSpeech` (status, install, transcribe) and `PCMConverter`.
  - `STTTryItSession`: microphone, or a sample sentence from
    `AVSpeechSynthesizer`.
  - `ServiceModel` dispatches by runtime.
  - `AppModel` has a page model (running / catalog / detail).
  - New `PanelView` (running list, catalog, right-click menu), detail-page copy
    rows, and an STT Try it card.
- **Bundle.** The helper ships in `Contents/Resources/helper`. Info.plist has
  `NSMicrophoneUsageDescription`, and the entitlements add
  `com.apple.security.device.audio-input`.

## Verification

| Check | Result |
|---|---|
| Helper `serve-stt`, Whisper, spoken clip | ready 5.4 s, transcript in 0.75 s, clean stdin-EOF exit |
| Helper `serve-stt`, Kyutai, three utterances on one socket | identical results for identical audio (state reset holds) |
| Apple Speech, direct and through `STTWebSocketServer` | 0.29 s / 0.15 s for a 4 s clip |
| Python `stt_server` client and `status` against the Swift server | two utterances, status, `close_session` all work |
| Swift tests (catalog, copy strings, STT server round trip, busy port, Origin rejection) | 27 pass |
| `PIPECAT_TOOLBAR_E2E=1`: tone, phonon, Kyutai real installs against the built bundle | 3 pass |

## Follow-ups

- **Upstream the STT features.** Move `--supervised`, `prefetch` and a Kyutai
  backend into `pipecat-local-stt-server`, so the helper's `serve-stt` becomes
  a thin call.
- **Optional STT engines.** Parakeet and Nemotron already exist in the stt
  server; adding them is a catalog entry plus requirements.
- **Streaming partials.** The stt protocol is commit-oriented today. Kyutai and
  SpeechAnalyzer can both stream partial transcripts if the protocol grows
  `delta` streaming.
