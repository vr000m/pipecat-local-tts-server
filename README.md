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

```sh
# client-only (lean base: websockets) — for a bot that just talks to a server
uv sync --extra client

# Kokoro backend (Apple Silicon; pulls mlx-audio==0.4.4 + misaki[en], which
# drags in spacy/num2words/torch — heavy by design, kept out of lean base)
uv sync --extra kokoro

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

The server logs the resolved backend + model at startup, *before* the
(potentially slow) model load, so you can see what is being loaded. The rate is
read from the loaded model, so model load completes before the first
`server.hello` is sent.

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

For day-to-day operation on macOS the [`justfile`](justfile) carries read-only
operator recipes mirroring the sibling stt server: `just tts-list` lists every
`pipecat.tts-server*` launchd agent with state, pid, and live backend, and
`just tts-status` runs the wire `status` probe against the canonical socket
(override with `just tts-status socket=…`).

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

### Kokoro capabilities (as shipped)

Built per-backend (`server.hello.capabilities`). Verified against
mlx-community/Kokoro-82M-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, not capabilities |
| `streaming` | `false` | no sub-segment streaming; segments still stream per `\n+` |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en","ja","zh","fr","es","it","pt","hi"]` | advertised from voice prefixes — **`ja`/`zh` fail at synthesis** without extra G2P (see below) |
| `voice_count` | `54` | full list via `status` |
| `extras` | `["speed"]` | Kokoro's only effective `generate()` kwarg |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

### Kokoro language support (advertised vs. as-shipped)

The advertised `languages` list is derived from the model's voice-name prefixes,
not from what the default `kokoro` extra can phonemize. That extra pins
`misaki[en]` only. Verified live against mlx-community/Kokoro-82M-bf16:

- **`en`** uses misaki[en]; **`es`/`fr`/`it`/`pt`/`hi`** route through the
  espeak-ng G2P bundled with misaki[en] — all synthesize fine. (`hi`'s first
  call loads its G2P lazily and can exceed a 60 s client timeout.)
- **`ja` and `zh` fail at synthesis** (`response.failed`, `code=backend_error`)
  out of the box: they need `misaki[ja]` (`pyopenjtalk`) and `misaki[zh]`
  (`ordered_set`) respectively, which the extra does not install. The server
  degrades gracefully — the session stays usable — but a client trusting the
  advertised list hits a runtime failure. Enable with
  `uv pip install "misaki[ja]" "misaki[zh]"`.

See [`tests/smoke/`](tests/smoke/) for the live end-to-end smoke scripts that
verify this (`just smoke-tone` / `just smoke-kokoro` / `just smoke-multilingual`).

### Kokoro cancellation caveat

Kokoro yields one segment per `\n+` boundary and the cancel flag is only checked
at a segment boundary, so a **long single-segment** commit cannot be cancelled
until `generate()` finishes (measured ≈ tens of seconds on Apple Silicon — a
single no-newline segment is one delta emitted only at the end). For prompt
barge-in, **clients should chunk at sentence/newline boundaries** for Kokoro.
The server's hard guarantee is only "no more audio after `response.cancelled`";
sub-segment cancel promptness is yield-boundary best-effort.

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
