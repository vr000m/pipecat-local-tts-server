# pipecat-local-tts-server

Standalone, local WebSocket **text-to-speech (TTS) server** — text in, audio
out — for the Pipecat ecosystem. It mirrors the sibling
[`pipecat-local-stt-server`](https://github.com/vr000m/pipecat-local-stt-server):
same websocket transport, an OpenAI-Realtime-inspired protocol subset, a
pluggable backend abstraction, and lazy-imported per-model backends behind
optional extras so a client-only consumer never pulls the heavy TTS runtime.

Distributed as `pipecat-local-tts-server`; the import name is `tts_server`
(every `import tts_server` / `python -m tts_server` invocation works).
**Kokoro-first** (mlx-audio, Apple Silicon); more backends land later.

The server owes its client exactly two things (the contracts everything else is
built around):

1. **An exact, stable advertised rate.** `server.hello.audio.rate` is the true
   model rate (Kokoro = 24000 Hz). Every audio frame is int16-LE mono PCM at
   *exactly* that rate, with no per-utterance drift. The client resamples
   model-rate → device-rate off this single value.
2. **A steady in-response stream.** Once a response starts, audio arrives
   continuously (each model segment is emitted as it completes) so the client's
   playback buffer never starves.

## Install

The base package is lean — `websockets` only. Backends live behind extras.

From [PyPI](https://pypi.org/project/pipecat-local-tts-server/) (consumers):

```sh
# client-only lean base (websockets) — for a bot that just talks to a server
uv add pipecat-local-tts-server            # or: pip install pipecat-local-tts-server

# Kokoro backend (Apple Silicon; pulls mlx-audio==0.4.4 + misaki[en])
uv add "pipecat-local-tts-server[kokoro]"  # or: pip install "pipecat-local-tts-server[kokoro]"

# Voxtral TTS backend — streaming:true (Apple Silicon; mlx-audio==0.4.4 +
# mistral-common[audio]). NOTE: model weights are CC-BY-NC (non-commercial).
uv add "pipecat-local-tts-server[voxtral_tts]"

# Pocket TTS backend — streaming:true, fast (Apple Silicon; mlx-audio==0.4.4).
# Weights are CC-BY-4.0 (commercial OK with attribution).
uv add "pipecat-local-tts-server[pocket_tts]"
```

From source (development):

```sh
# client-only (lean base: websockets) — for a bot that just talks to a server
uv sync --extra client

# Kokoro backend (Apple Silicon; pulls mlx-audio==0.4.4 + misaki[en], which
# drags in spacy/num2words/torch — heavy by design, kept out of lean base)
uv sync --extra kokoro

# Voxtral TTS backend — streaming:true (Apple Silicon; mlx-audio==0.4.4 +
# mistral-common[audio]). Weights are CC-BY-NC; see "Backends & licenses".
uv sync --extra voxtral_tts

# Pocket TTS backend — streaming:true, fast (Apple Silicon; mlx-audio==0.4.4).
# Weights are CC-BY-4.0 (commercial OK with attribution).
uv sync --extra pocket_tts

# the reference Pipecat adapter example (pulls the Pipecat framework)
uv sync --extra examples
```

> Run every command through `uv run` (or activate the venv once per shell). A
> bare `python -m tts_server …` uses the system interpreter and fails with
> `ModuleNotFoundError: No module named 'websockets'`.

## Running the server

```sh
# Kokoro over a Unix domain socket (recommended for local use)
uv run python -m tts_server serve --backend kokoro \
    --socket-path ~/Library/Caches/pipecat-tts/tts.sock

# pick a specific model (any compatible mlx-community Kokoro repo id)
uv run python -m tts_server serve --backend kokoro \
    --model mlx-community/Kokoro-82M-bf16 \
    --socket-path ~/Library/Caches/pipecat-tts/tts.sock

# loopback TCP instead of a socket (choose any free port)
uv run python -m tts_server serve --backend kokoro --host 127.0.0.1 --port 8765
```

### Per-backend port convention

A single ad-hoc server uses the **Unix socket** quick-start above
(`pipecat.tts-server` → `~/Library/Caches/pipecat-tts/tts.sock`) — that stays
the default. Running several backends side by side as **launchd agents** uses one
loopback **TCP port** per backend instead (one backend = one process = one
port). The `just tts-*` recipes (install/uninstall/enable/disable/start/stop)
and `scripts/install_tts_agent.sh` resolve each backend to this canonical map:

| backend | label | port (on `127.0.0.1`) |
|---|---|---|
| tone | `pipecat.tts-server.tone` | 8665 |
| kokoro | `pipecat.tts-server.kokoro` | 8765 |
| voxtral_tts | `pipecat.tts-server.voxtral_tts` | 8865 |
| pocket_tts | `pipecat.tts-server.pocket_tts` | 8965 |

```sh
# install + start the kokoro agent on 127.0.0.1:8765 (runs at login, KeepAlive)
just tts-install kokoro
just tts-list            # every pipecat.tts-server* agent + live backend probe
just tts-status kokoro   # probe one backend's canonical host:port
```

> `kokoro=8765` is assumed free and is **not** collision-checked — it matches
> this repo's own kokoro examples. A launchd tts agent binds a loopback port, so
> two installed agents never collide; the only risk is an ad-hoc process you run
> by hand on the same port. The `dia` backend is reserved and not yet shipped.

The server logs the resolved backend + model at startup, *before* the
(potentially slow) model load, so you can see what is being loaded. The rate is
read from the loaded model, so model load completes before the first
`server.hello` is sent.

`--log-level` (default `INFO`) sets the server's logging verbosity (any standard
Python level name, e.g. `DEBUG`/`WARNING`).

On startup over a Unix socket, the server **auto-clears a stale socket** left by
a previous crash (`SIGKILL` / power loss), so the documented restart works
without manual `rm`. It refuses to start — surfacing a diagnostic instead of
clobbering — if a **non-socket file** exists at the path, or if a **live server**
is already listening there (the socket is genuinely in use).

### Environment variables

Endpoint precedence (server and client both): **URI > socket > host+port**. The
`TTS_WS_*` vars mirror `STT_WS_*`.

| Variable | Side | Purpose |
|---|---|---|
| `TTS_WS_URI` | client | Full `ws://`/`wss://` URI; highest endpoint precedence. |
| `TTS_WS_SOCKET` | client | Unix-socket path (used when no URI). |
| `TTS_WS_HOST` | client | TCP host (used when no URI/socket). |
| `TTS_WS_PORT` | client | TCP port (paired with host). |
| `TTS_WS_TOKEN` | client | Bearer token the client/probe sends. Never falls back to the server var. |
| `TTS_WS_DEFAULT_SOCKET` | client | Explicit fallback socket for `status` when nothing else is set. |
| `PIPECAT_TTS_AUTH_TOKEN` | server | Bearer token the server requires (optional auth). |
| `PIPECAT_TTS_KOKORO_EXTRA_LANGS` | server | Comma-separated ISO codes (e.g. `ja,zh`) to advertise after installing their extra G2P package. See [Kokoro language support](#kokoro-language-support-advertised--synthesizable). |

Auth notes: the server reads `PIPECAT_TTS_AUTH_TOKEN`; the client/probe reads
`TTS_WS_TOKEN` (the two are deliberately separate so a probe can never mask a
client 401 or leak the server secret to a remote host). A plaintext
`--auth-token` flag is intentionally unsupported (`ps` exposure) — use
`--auth-token-file`. A token-less server bound to a non-loopback TCP address logs
a cleartext-remote warning; a Unix socket does not. Sending a bearer over
cleartext `ws://` to a remote host also warns client-side — use `wss://` or a
Unix socket.

## Checking server health

```sh
uv run python -m tts_server status \
    --socket-path ~/Library/Caches/pipecat-tts/tts.sock
```

`status` connects, performs the handshake, requests a `server.status` snapshot,
and prints the backend, model, audio format/rate, capabilities
(streaming / binary_audio / voice_count), session id, synthesis **queue depth**,
the **voice list**, buffered chars, uptime, and pid. It exits non-zero if no
server is reachable.

`status` resolves its endpoint with the same **URI > socket > host+port**
precedence as the client and additionally accepts `--uri ws://…`/`wss://…` (the
serve path has no `--uri`, since it builds its listener from socket-path/host+port).
Two probe-only flags: `--timeout` (overall probe budget in seconds, default `3.0`)
and `--json` (emit the raw `hello`+`status` JSON instead of the text summary).

For day-to-day operation on macOS the [`justfile`](justfile) carries operator
recipes mirroring the sibling stt server. Read-only probes: `just tts-list` lists every
`pipecat.tts-server*` launchd agent with state, pid, and live backend, and
`just tts-status` runs the wire `status` probe against the canonical socket by
default; pass a backend name to probe its canonical port (`just tts-status
kokoro`) or a socket path to probe a specific socket (`just tts-status
/path/to/tts.sock`). Lifecycle recipes: `just tts-install <backend>`,
`just tts-uninstall <backend>`, `just tts-enable <backend>`,
`just tts-disable <backend>`, `just tts-start <backend>`, `just tts-restart <backend>`,
`just tts-stop <backend>`, `just tts-logs <backend>` (all operator-manual; not CI-verified).

## Protocol

The full wire contract is in [`docs/protocol.md`](docs/protocol.md). In brief:
every message is a JSON text frame with a `type` field. The client drives the
session — `session.update` → `input_text.append`* → `input_text.commit` — and
the server streams `response.audio.delta` frames (base64 pcm16, `seq` from 0, no
gaps) ending in `response.audio.done`. `response.cancel` is barge-in. Audio is
base64-in-JSON for v1 (`binary_audio: false`); binary frames are a later
optimization.

**The client segments the text; the commit is the unit of work.** Using
`capabilities.streaming` and `capabilities.ideal_words`, the client splits long
text into commits, rounding `ideal_words` up to the next **sentence boundary**
— never splitting mid-sentence (a half-sentence commit makes the model apply
sentence-final prosody mid-phrase). `max_text_chars` is the hard server cap.

### Backends & licenses

Each backend is its own extra; weights have their own licenses — **the package
ships only runtime code, never weights** (they download on first `serve`).
Operators are responsible for honouring each model's license.

| Backend | Extra | `streaming` | Model | Weights license |
|---|---|---|---|---|
| `tone` | (base) | `false` | none (synthetic sine) | — |
| `kokoro` | `kokoro` | `false` | mlx-community/Kokoro-82M-bf16 | Apache-2.0 (commercial-safe) |
| `voxtral_tts` | `voxtral_tts` | `true` | mlx-community/Voxtral-4B-TTS-2603-mlx-bf16 | **CC-BY-NC (non-commercial)** |
| `pocket_tts` | `pocket_tts` | `true` | mlx-community/pocket-tts | CC-BY-4.0 (commercial OK w/ attribution) |

> **Kokoro is the default commercial-safe backend.** `voxtral_tts` weights are
> **CC-BY-NC** — do not use them in a commercial deployment. `pocket_tts`
> (CC-BY-4.0) and Kokoro (Apache-2.0) are commercial-safe (pocket needs
> attribution). The choice of backend (and thus of model license) is the operator's.

### Voxtral TTS capabilities (as shipped)

`streaming:true` sub-segment streamer (native `stream`/`streaming_interval`,
locked to 0.3 s — measured TTFB 0.395 s, see the dev-plan Findings). Verified
against mlx-community/Voxtral-4B-TTS-2603-mlx-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | genuine sub-segment streaming; client MAY pass larger text |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en","fr","es","de","it","pt","nl","ar","hi"]` | from the 20 voice presets; language is selected by the voice preset (no `lang_code` kwarg) |
| `voice_count` | `20` | full list via `status` (e.g. `casual_male`, `fr_female`) |
| `extras` | `["temperature","top_k","top_p"]` | Voxtral's effective sampling kwargs (`ref_audio` is absent → no cloning; `streaming_interval` is backend config, not advertised) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

### Pocket TTS capabilities (as shipped)

`streaming:true` sub-segment streamer and **fast** (RTF ≈ 0.05–0.13× on-host).
The voice-cloning channel (`ref_audio`) and undocumented `frames_after_eos` are
**deliberately unwired** (decision #2 — no cloning in v1). Verified against
mlx-community/pocket-tts (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | genuine sub-segment streaming |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en"]` | English verified on-host (Pocket has no `lang_code` kwarg) |
| `voice_count` | `8` | `alba`, `marius`, `javert`, `jean`, `fantine`, `cosette`, `eponine`, `azelma` (via `status`) |
| `extras` | `["temperature"]` | Pocket's only effective sampling kwarg (`ref_audio`/`frames_after_eos` never advertised; `streaming_interval` is backend config) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

### Kokoro capabilities (as shipped)

Built per-backend (`server.hello.capabilities`). Verified against
mlx-community/Kokoro-82M-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, not capabilities |
| `streaming` | `false` | no sub-segment streaming; segments still stream per `\n+` |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en","es","fr","hi","it","pt"]` | from voice prefixes, minus languages needing extra G2P — **`ja`/`zh` are off by default** (opt-in, see below) |
| `voice_count` | `54` | full list via `status` |
| `extras` | `["speed"]` | Kokoro's only effective `generate()` kwarg |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

### Kokoro language support (advertised = synthesizable)

The advertised `languages` list reflects what this deployment can actually
synthesize, not just what voices the model ships. The default `kokoro` extra
pins `misaki[en]` only; verified live against mlx-community/Kokoro-82M-bf16:

- **`en`** uses misaki[en]; **`es`/`fr`/`it`/`pt`/`hi`** route through the
  espeak-ng G2P bundled with misaki[en] — all synthesize fine and are advertised.
  (`hi`'s first call loads its G2P lazily and can exceed a 60 s client timeout.)
- **`ja` and `zh` need an extra G2P package** — `misaki[ja]` (`pyopenjtalk`) and
  `misaki[zh]` (`ordered_set`) respectively, which the `kokoro` extra does not
  install. Because synthesis would fail at runtime (`response.failed`,
  `code=backend_error`) without them, **they are not advertised by default** and
  a request for them is rejected up front with `invalid_config` (before a
  synthesis slot is consumed) rather than failing mid-response.

**Enabling `ja` / `zh`** is a two-step, build-time decision:

1. Install the G2P package(s):
   `uv pip install "misaki[ja]" "misaki[zh]"`
2. Opt the language(s) back into the advertised set:
   `export PIPECAT_TTS_KOKORO_EXTRA_LANGS=ja,zh`

The server logs its advertised language set at startup (including a reminder of
any languages left disabled). The opt-in only *re-adds* a language the model
already ships voices for; it cannot advertise one the model lacks. If you set the
env var without installing the package, that language is advertised again and
will fail at synthesis — install first.

See [`tests/smoke/`](tests/smoke/) for the live end-to-end smoke scripts that
verify this (`just smoke-tone` / `just smoke-kokoro` / `just smoke-multilingual`).

### Kokoro cancellation caveat

Kokoro yields one segment per `\n+` boundary and the cancel flag is only checked
at a segment boundary. The **client-visible** cancel is prompt regardless: a
`response.cancel` is acknowledged with `response.cancelled` in ~1 ms (measured on
Apple Silicon), and no audio follows it. What runs to the segment boundary is the
backend worker / Metal lock: a **long single-segment** commit keeps the lock
until its `generate()` reaches the yield (≈ the full single-segment synthesis
time — a few seconds for a ~1700-char segment, bounded by `drain_timeout_seconds`),
so the *next* commit can't start synthesizing until then. To free the lock sooner
for back-to-back commits, **clients should chunk at sentence/newline boundaries**
for Kokoro. The server's hard guarantee is "no more audio after
`response.cancelled`". (See the dev plan's *Phase 2 measured results* for the full
re-measurement; the earlier "≈ tens of seconds" figure was a bridge-bug artifact.)

## Examples

- [`examples/reference_client.py`](examples/reference_client.py) — a lightweight
  stdlib + `websockets` oracle (no `tts_server` install, no Pipecat). It speaks
  the wire protocol directly and writes the reassembled audio to a WAV. Useful
  for manual end-to-end smoke checks once a server is running.
- [`examples/pipecat_tts_service.py`](examples/pipecat_tts_service.py) — a
  reference Pipecat-framework `TTSService` adapter (`LocalTTSService`) that wraps
  the async `tts_server.client.TTSClient` so a bot pipeline can speak through a
  running server. Streams `TTSAudioRawFrame`s at the server-advertised rate and
  sends `response.cancel` on interruption. Requires the Pipecat framework
  (`uv sync --extra examples`, which pins `pipecat-ai==1.4.0`).

## Layout

- `tts_server/` — protocol, backend abstraction, server, async client, CLI.
- `tts_server/backends/` — lazy-imported per-model backends (Kokoro first).
- `examples/` — the stdlib oracle and the Pipecat service adapter.
- `justfile` — macOS operator recipes (`tts-list`, `tts-status`).
- `docs/protocol.md` — the wire protocol specification.
- `docs/dev_plans/` — development plans.
