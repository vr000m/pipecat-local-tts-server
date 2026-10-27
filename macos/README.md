# Pipecat Service Toolbar

**Local speech services for Pipecat, from the menu bar.**

A native macOS menu bar app that downloads speech models (text to speech and
speech to text) and serves each one on a fixed loopback port. Point a Pipecat
app at the port and it uses the model with no cloud API. It has no Dock icon.
Servers the app started stop when it quits, even if it crashes; servers it didn't start are left running. Quitting also cancels running installs and downloads.

## Quickstart

Requires Apple Silicon and macOS 15+. Apple Speech needs macOS 26+.

```bash
git clone https://github.com/vr000m/pipecat-local-tts-server.git
cd pipecat-local-tts-server
just app-open      # build macos/build/Pipecat Service Toolbar.app and launch it
```

`just app-install` builds and installs it into `~/Applications` instead, signed with the
self-signed `Code Signing` identity so Microphone / Speech Recognition grants survive
rebuilds (ad hoc is cdhash-bound and resets them).

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
| Parakeet | STT | 9765 | `mlx-community/parakeet-tdt-0.6b-v3` | CC-BY-4.0 |
| Nemotron | STT | 9865 | `mlx-community/nemotron-3.5-asr-streaming-0.6b` | Custom licence (`license:other`) |
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
Any client of either works unchanged. The ports match the `just tts-install`
and `just stt-*` launchd agents; see [Servers you didn't start](#servers-you-didnt-start)
for running both.

## Servers you didn't start

- **Adopt first.** The app probes each catalog port (loopback TCP only) with a
  `server.hello`. A running server whose backend and model match a catalog entry
  is adopted and shown as **External**; the app starts its own only when
  nothing answers. Discovery runs once at launch, then every 15 s while the panel
  is open.
- **Ownership.** The app only signals, stops or deletes processes it started.
  An External service has no per-service Stop, Delete, Get or Install; it offers
  Try it (for STT, the test clip only, never the microphone) and the Copy items.
  Reset is app-wide: it deletes only the app's own `envs` directory and layout
  file, never signals or stops an External server, and is not blocked by one.
  **Quit leaves it running**
  (the Quit item reads "Quit" when the app owns nothing, "Stop All & Quit" when it does).
- **Beside launchd agents.** `just tts-install` and `just stt-*` agents use the
  same ports, so a running agent whose hello matches shows as External. If
  whatever holds the port does not identify as that service (a different
  backend or model, no hello, or a token), Start reports the port busy, naming
  the holder when `launchctl` confirms it (the agent's label).
- **Not discovered:** Unix sockets, servers on other ports, LAN endpoints. A
  server that needs a bearer token is not adopted (Start then reports the port busy
  because it wants a token); the app stores no token.
- **Support floor.** STT starts through `pipecat-local-stt-server==0.5.0`'s own CLI
  (`python -m stt_server serve --supervised`). An STT agent on an older version
  is still adopted by its hello, but an app-started STT server needs 0.5.0.


## Menu bar

- **Running**: the main menu lists the services the app started and the External
  ones it adopted, grouped into Text to Speech and Speech to Text, each with its
  address and a copy button; Stop only on the app's own (External rows show
  `External · <agent label or address>`).
- **Add Models**: every model, by type, with Get, Start and download progress.
  Python and model weights are fetched on first Get; nothing is bundled.
- **Right-click** any service: **Copy URL**, **Copy Pipecat Service**,
  **Copy Environment Variables**, Start/Stop, **Delete Model…** (an External
  service gets the Copy items, Test and Show Details only). Deleting
  removes the model's Python environment and, unless another installed variant
  still uses them, its weights. The detail page's **Delete…** offers **Keep
  Model Files** or **Delete Everything**. Weights live in the shared Hugging
  Face cache, so a command-line or launchd server using the same model
  downloads them again after a delete.
- **Try it**: type text and hear a TTS model. For STT, record from the
  microphone or transcribe a fixed spoken test clip (`STTSampleClip`, no
  microphone) and see whether the transcript matches its sentence. An External
  STT server gets the clip only: the app never sends it live microphone audio.
  Right-click a running service for **Test Voice** (speaks a line naming the
  model) or **Test Transcription** (the clip); both open the details view,
  which shows the result.
- **Problems** show inline: a busy port names the process (and the launchd
  agent) holding it; a crashed server keeps its log and a Restart button.
- **Try Again**: if the app can't find its tools at launch (`uv`, the server
  wheel), the main menu shows why with a Try Again button, which re-runs the
  check. It is disabled while a check runs.
- **Reset**: when environments from an incompatible app version are found, a
  banner offers Reset, which deletes every Python environment (not model
  weights) and checks the services again. It is refused while a server the app
  started runs, or a service installs or is being deleted; an External server
  does not block it (Reset deletes only the app's own environments and never
  touches that server). While Reset or the launch check runs, the
  Python services' Get, Start and Delete are disabled.

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
| `~/Library/Caches/pipecat-tts-build/uv/<version>/` | the pinned `uv` the build bundles (build time only; `PIPECAT_TTS_BUILD_CACHE` moves the root) |

App diagnostics: `log stream --predicate 'subsystem == "ai.pipecat.ServiceToolbar"'`.

## How it works

- **TTS**: `uv pip install "pipecat-local-tts-server[<backend>] @ <bundled wheel>"`,
  pinned to `uv.lock`, then `python -m tts_server prefetch` and
  `serve --supervised`.
- **Whisper, Kyutai, Parakeet, Nemotron**: PyPI packages hash-pinned to the last
  transitive dependency (`constraints/stt-<engine>.txt`, `uv pip install
  --require-hashes`; a bundled app missing that file refuses the install rather
  than resolve unpinned), run by the upstream CLI (`python -m stt_server prefetch`
  and `serve --supervised`). The four default STT models (Whisper large-v3-turbo,
  Kyutai 1B, Parakeet, Nemotron) are pinned to a recorded Hub commit by upstream 0.5.0
  itself (`PINNED_REVISIONS`; `prefetch --json` reports the `revision`). The app passes
  no revision flag (there is none), only `--model <repo>`: a model other than a pinned
  default (the other Whisper sizes, Kyutai 2.6B) follows the repo's `main`. Kyutai runs as a `moshi_mlx` backend inside `stt_server`.
  Parakeet needs `ffmpeg` installed (Homebrew: `/opt/homebrew/bin` or
  `/usr/local/bin`; the app adds those to Parakeet's server `PATH` only). Without
  it the server exits with `BackendStartError: FFmpeg is not installed or not in
  your PATH`.
- **Apple Speech**: SpeechAnalyzer in the app process, behind a Swift
  WebSocket server that speaks the same STT protocol.
- **Supervision**: every server prints a JSON `ready` line and exits when the
  app closes its stdin. Every event and error code is fixed in
  [`docs/supervised-contract.json`](../docs/supervised-contract.json).

## Docs

- [Architecture](docs/architecture.md): components, runtimes, the supervision
  contract, protocols, state, packaging.
- [Loopback auth](docs/loopback-auth.md): why the listeners have no token, and
  what one would take.
- [Plans](docs/plans/): the phase 1 (TTS menu bar app) and phase 2 (STT,
  Service Toolbar) plans and their verification.

## Development

```bash
just app-run     # run unbundled from the checkout (swift run)
just app-test    # Swift tests
PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter EndToEnd   # real installs
swift run --package-path macos PipecatServiceToolbar --snapshot /tmp/shots  # render the UI
just app-smoke   # unattended UI smoke: render, launch, quit and SIGTERM with no leftovers
```

`AppleSpeechEndToEndTests` (in the `EndToEnd` filter) runs the debug app binary's
`--serve-apple-speech <port>` mode, the same `STTWebSocketServer` + SpeechAnalyzer the
app serves, and transcribes `say` clips through `STTClient`. It needs no permission
prompt, but it skips unless the debug binary's own speech asset is installed (assets
are reserved per client, so the bundled app's install does not count). Once:
`swift build --package-path macos`, then
`macos/.build/debug/PipecatServiceToolbar --apple-speech-selftest <16 kHz mono .wav>`
(downloads the asset if needed); `--apple-speech-status` prints `installed` after.

`just app-smoke` (`scripts/ui_smoke.sh`) needs no Accessibility or Screen Recording
grant, so it cannot open the panel or click. It launches the app with your real
support and log folders (installing nothing) and refuses while another copy runs.
Its last step starts a tone server outside the app on 8665, checks the bootstrap
log reports it as External, and checks it is still running after Quit; it skips
that step when 8665 is held, a `pipecat.tts-server.tone` LaunchAgent is loaded, or
the repo `.venv` cannot import `tts_server`.
Manual UI checklist, for what needs a person (or a terminal granted Accessibility):

1. `just app-open`; the Pipecat icon appears in the menu bar; click it, the panel opens.
2. Tone > Install: progress, then Installed. Start: the row turns running and
   `lsof -nP -iTCP:8665 -sTCP:LISTEN` shows the server; Try it plays a tone.
3. STT > Apple Speech > Install (if needed) > Start: `lsof -nP -iTCP:9465 -sTCP:LISTEN`
   shows the app; Try it > Test Clip shows "Matches the clip" (no microphone needed).
   Right-click a running Tone or Apple Speech row: Test Voice plays a line, Test
   Transcription shows the same match.
4. Stop each: the port closes. Quit from the panel with Tone running: within ~10 s
   `pgrep -fl "Pipecat Service Toolbar"` and `lsof -nP -iTCP:8665` print nothing.
5. Tone > Delete: the row returns to Install.

To check the server side of the app's contract without the app, `just smoke-supervised
[backend]` (or `just smoke-supervised-all`) runs the same `prefetch --json --check` and
`serve --supervised` commands the app builds, with its environment, on an ephemeral
port: `ready`, a TCP synthesis, busy-port `EADDRINUSE`, and the stdin-EOF stop. Pass
`--python <service env>/bin/python` to test an environment the app installed. See
[tests/smoke/README.md](../tests/smoke/README.md#app-path-supervised_smokepy).

The service lifecycle (install, start, stop, delete, and each service's part of quit)
lives in `PipecatToolbarCore` as a reducer, `ServiceLifecycle.reduce(_ state: inout
LifecycleState, _ event:) -> [LifecycleEffect]` (no I/O), plus `ServiceDriver`, which runs
its effects through injectable seams; the app's `ServiceModel` only publishes it. The
app-wide lifecycle (launch check, Try Again, Reset, quit) is `AppLifecycle.reduce` in
`AppLifecycle.swift`, with `AppModel` as its adapter. The
Swift tests depend on Core alone, so a lifecycle change is tested without the app
target (`ServiceLifecycleTests`, `ServiceDriverTests`, `AppLifecycleTests`). Download sizes come from
`ServiceCatalog.snapshots(for:)` in `Service.swift`; when a backend's
`prefetch_specs(model)` changes (a pin, a codec, voice files), update that table:
`uv run pytest tests/test_macos_catalog_drift.py` fails until they match.

Unbundled runs find their tools through `PIPECAT_TOOLBAR_UV`, `PIPECAT_TOOLBAR_WHEEL`,
`PIPECAT_TOOLBAR_CONSTRAINTS`, `PIPECAT_TOOLBAR_STT_CONSTRAINTS`
and `PIPECAT_TOOLBAR_REPO` (see
[Architecture](docs/architecture.md#development-overrides)); a built app uses its bundle.

After changing an STT requirement in `Service.swift`, regenerate its hash-pinned
constraints (network needed; `tests/test_supervised_contract.py` fails until you do):

```bash
uv run python macos/scripts/compile_stt_constraints.py   # writes macos/constraints/stt-<engine>.txt
```

When `ServiceCatalog.sttServerRequirement` moves, also re-record
`tests/fixtures/stt_server_<version>_source.txt` from the new tag (the lean tests fail until
its release line names the new version), then check it against that release's real source;
no CI job installs the STT server, so this check is opt-in:

```bash
# a directory holding stt_server/ and pipecat_local_stt_server-<version>.dist-info
# (a site-packages, or the app's uv cache entry)
PIPECAT_STT_SERVER_SITE=<dir> uv run pytest tests/test_supervised_contract.py -k verbatim
```

STT model weights are pinned by upstream, not by the app (see How it works): the
default models' commits live in `pipecat-local-stt-server`'s `PINNED_REVISIONS`, so moving
one means a new STT release, then bumping `ServiceCatalog.sttServerRequirement` and
regenerating the constraints. Other STT models follow `main`.

Build knobs (environment variables read by `macos/scripts/`):

| Variable | Read by | Effect |
|---|---|---|
| `SIGN_IDENTITY` | `build_app.sh` | Code-signing identity (default `-`, ad hoc). Sign for distribution with `SIGN_IDENTITY="Developer ID Application: …" just app-build`. |
| `CONFIG` | `build_app.sh` | Swift build configuration, `release` (default) or `debug`. |
| `APP_INSTALL_DIR` | `just app-install` | Install destination (default `~/Applications`). `SIGN_IDENTITY` defaults to `Code Signing` there. |
| `BUNDLE_ID` | `build_app.sh` | Overrides `CFBundleIdentifier` (default `ai.pipecat.ServiceToolbar`); `just app-open` quits the id the build wrote. |
| `PIPECAT_TTS_BUILD_CACHE` | `fetch_uv.sh` | Root of the build cache for the pinned `uv` download (default `~/Library/Caches/pipecat-tts-build`). |
| `PIPECAT_UV` | `compile_stt_constraints.py` | The `uv` binary used to compile the STT constraints (default: the app's pinned uv). |

## License

BSD-2-Clause. Model weights carry their own licences (table above).
