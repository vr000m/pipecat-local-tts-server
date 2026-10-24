# Pipecat Service Toolbar

**Local speech services for Pipecat, from the menu bar.**

A native macOS menu bar app that downloads speech models (text to speech and
speech to text) and serves each one on a fixed loopback port. Point a Pipecat
app at the port and it uses the model with no cloud API. It has no Dock icon.
Servers stop when the app quits, even if it crashes.

## Quickstart

Requires Apple Silicon and macOS 15+. Apple Speech needs macOS 26+.

```bash
git clone https://github.com/vr000m/pipecat-local-tts-server.git
cd pipecat-local-tts-server
just app-open      # build macos/build/Pipecat Service Toolbar.app and launch it
```

Without `just`: `macos/scripts/build_app.sh`, then open the app. Building needs
Xcode 16+ and [uv](https://docs.astral.sh/uv/).

Click the cat in the menu bar, then **Add Models**. Click **Get** on a model,
then **Start**.

## Services

| Service | Type | Port | Model | Licence |
|---|---|---|---|---|
| **Apple Speech** (default STT) | STT | 9465 | SpeechAnalyzer (built in) | macOS |
| Whisper | STT | 9565 | `mlx-community/whisper-large-v3-turbo` | MIT |
| Kyutai STT | STT | 9665 | `kyutai/stt-1b-en_fr-mlx` | CC-BY-4.0 |
| **Kokoro** (default TTS) | TTS | 8765 | `mlx-community/Kokoro-82M-bf16` | Apache-2.0 |
| Phonon | TTS | 9365 | `gradium/phonon-31m-en` | Apache-2.0 |
| Pocket TTS | TTS | 8965 | `mlx-community/pocket-tts` | CC-BY-4.0 |
| Qwen3 TTS | TTS | 9165 | `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16` | Apache-2.0 |
| Voxtral TTS | TTS | 8865 | `mlx-community/Voxtral-4B-TTS-2603-mlx-bf16` | CC-BY-NC |
| Dia | TTS | 9065 | `mlx-community/Dia-1.6B-fp16` | Apache-2.0 |
| Fish S2 Pro | TTS | 9265 | `mlx-community/fish-audio-s2-pro` | research only |
| Tone | TTS | 8665 | test signal | — |

Some models come in several sizes or precisions. In **Add Models** a family
expands to list them, and each is its own entry with its own port, so siblings
can run side by side. Variants share their family's Python environment.

| Variant | Port | Model |
|---|---|---|
| Phonon 8-bit, 4-bit | 9366, 9367 | `phonon-q8`, `phonon-q4` (converted from Phonon's weights) |
| Whisper Large v3, Medium, Small, Base, Tiny | 9566–9570 | `mlx-community/whisper-{large-v3,medium,small,base,tiny}-mlx` |
| Kyutai STT 2.6B (English) | 9666 | `kyutai/stt-2.6b-en-mlx` |

TTS services speak this repo's protocol (`tts_server`). STT services speak the
protocol of [pipecat-local-stt-server](https://github.com/vr000m/pipecat-local-stt-server).
Any client of either works unchanged. TTS ports match the `just tts-install`
launchd agents, so run one or the other, not both.

## Menu bar

- **Running**: the main menu lists only started services, grouped into Text
  to Speech and Speech to Text, each with its address, a copy button and Stop.
- **Add Models**: every model, by type, with Get, Start and download progress.
  Python and model weights are fetched on first Get; nothing is bundled.
- **Right-click** any service: **Copy URL**, **Copy Pipecat Service**,
  **Copy Environment Variables**, Start/Stop, **Delete Model…**.
- **Try it**: type text and hear a TTS model. For STT, record from the
  microphone or transcribe a sample sentence spoken by the system voice.
- **Problems** show inline: a busy port names the process (and the launchd
  agent) holding it; a crashed server keeps its log and a Restart button.

## Use a service from Pipecat

```python
# TTS: examples/pipecat_tts_service.py in this repo
tts = LocalTTSService(host="127.0.0.1", port=8765)

# STT: pip install "pipecat-local-stt-server[client]"
from stt_server.examples.pipecat_stt_service import LocalWebSocketSTTService
stt = LocalWebSocketSTTService(host="127.0.0.1", port=9465)
```

Or set `TTS_WS_HOST`/`TTS_WS_PORT` and `STT_WS_HOST`/`STT_WS_PORT`.

## Where things live

| Path | Contents |
|---|---|
| `~/Library/Application Support/Pipecat Service Toolbar/` | managed Python, one venv per model family |
| `~/Library/Caches/Pipecat Service Toolbar/uv/` | package cache |
| `~/.cache/huggingface/hub/` | model weights, shared with CLI use (`HF_HOME` honoured) |
| `~/Library/Logs/Pipecat Service Toolbar/` | one log per service |

App diagnostics: `log stream --predicate 'subsystem == "ai.pipecat.ServiceToolbar"'`.

## How it works

- **TTS**: `uv pip install "pipecat-local-tts-server[<backend>] @ <bundled wheel>"`,
  pinned to `uv.lock`, then `python -m tts_server prefetch` and
  `serve --supervised`.
- **Whisper, Kyutai**: pinned PyPI packages, run by the bundled
  `Helper/pipecat_app_helper.py`. Kyutai runs as a `moshi_mlx` backend inside
  `stt_server`.
- **Apple Speech**: SpeechAnalyzer in the app process, behind a Swift
  WebSocket server that speaks the same STT protocol.
- **Supervision**: every server prints a JSON `ready` line and exits when the
  app closes its stdin.

## Docs

- [Architecture](docs/architecture.md): components, runtimes, the supervision
  contract, protocols, state, packaging.
- [Plans](docs/plans/): the phase 1 (TTS menu bar app) and phase 2 (STT,
  Service Toolbar) plans and their verification.

## Development

```bash
just app-run     # run unbundled from the checkout (swift run)
just app-test    # Swift tests
PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter EndToEnd   # real installs
swift run --package-path macos PipecatServiceToolbar --snapshot /tmp/shots  # render the UI
```

Sign for distribution with `SIGN_IDENTITY="Developer ID Application: …" just app-build`.

## License

BSD-2-Clause. Model weights carry their own licences (table above).
