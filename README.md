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

# dia DIALOGUE backend — streaming:false, multi-speaker via in-text [S1]/[S2]
# tags (Apple Silicon; mlx-audio==0.4.4). Weights are Apache-2.0 (commercial-safe).
uv add "pipecat-local-tts-server[dia]"

# Qwen3-TTS backend — streaming:true, multilingual, 9 named speakers (Apple
# Silicon; mlx-audio==0.4.4). Weights carry the HF card tag apache-2.0.
uv add "pipecat-local-tts-server[qwen3_tts]"

# Fish (S2 Pro) backend — streaming:false, instruct + inline [tag]/
# <|speaker:N|> style control (Apple Silicon; mlx-audio==0.4.4). Weights are
# under the Fish Audio Research License — free for research/non-commercial
# use, commercial use requires a separate agreement (business@fish.audio).
uv add "pipecat-local-tts-server[fish_tts]"
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

# dia DIALOGUE backend — streaming:false, multi-speaker via in-text [S1]/[S2]
# tags (Apple Silicon; mlx-audio==0.4.4). Weights are Apache-2.0 (commercial-safe).
uv sync --extra dia

# Qwen3-TTS backend — streaming:true, multilingual, 9 named speakers (Apple
# Silicon; mlx-audio==0.4.4). Weights carry the HF card tag apache-2.0.
uv sync --extra qwen3_tts

# Fish (S2 Pro) backend — streaming:false, instruct + inline [tag]/
# <|speaker:N|> style control (Apple Silicon; mlx-audio==0.4.4). Weights are
# under the Fish Audio Research License; see "Backends & licenses".
uv sync --extra fish_tts

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
| dia | `pipecat.tts-server.dia` | 9065 |
| qwen3_tts | `pipecat.tts-server.qwen3_tts` | 9165 |
| fish_tts | `pipecat.tts-server.fish_tts` | 9265 |

```sh
# install + start the kokoro agent on 127.0.0.1:8765 (runs at login, KeepAlive)
just tts-install kokoro
just tts-list            # every pipecat.tts-server* agent + live backend probe
just tts-status kokoro   # probe one backend's canonical host:port
```

> `kokoro=8765` is assumed free and is **not** collision-checked — it matches
> this repo's own kokoro examples. A launchd tts agent binds a loopback port, so
> two installed agents never collide; the only risk is an ad-hoc process you run
> by hand on the same port.

> **launchd does not inherit your shell environment.** Server-runtime env you set
> for an ad-hoc `serve` is *not* carried into an installed agent, so it is handled
> explicitly at install time: `PIPECAT_TTS_KOKORO_EXTRA_LANGS` is baked into the
> agent's plist, and **auth must use a token file** —
> `PIPECAT_TTS_AUTH_TOKEN_FILE=/path/to/token just tts-install kokoro`. Running
> `PIPECAT_TTS_AUTH_TOKEN=… just tts-install` is **rejected** (the secret must not
> be written into a plaintext plist, and it would otherwise be silently dropped,
> leaving the agent with auth disabled).

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
| `TTS_WS_PING_INTERVAL` | server | Keepalive ping period in seconds (default `20`). A disable token (`none`/`off`/`disable`/`disabled` or any zero) disables pings. |
| `TTS_WS_PING_TIMEOUT` | server | Seconds to wait for a pong before closing (default `120`). A disable token (`none`/`off`/`disable`/`disabled` or any zero) disables the timeout (keeps pings, never closes on a slow pong — reintroduces the idle-leak below). |

Keepalive notes: the `websockets` library default (`ping_interval=20`,
`ping_timeout=20`) closes a live connection with `1011 keepalive ping timeout`
if a pong is late by 20s. During a heavy or cold-start generation, GIL-holding
Metal compute can starve the asyncio loop past that window and truncate the
in-flight utterance. So the server (and `TTSClient`) keep the periodic ping but
use a **large finite pong timeout (120s) by default** — long enough that a
briefly-starved loop never drops a live connection, yet bounded so a dead *idle*
peer is still reaped within `interval + timeout` (~140s). (Disabling the timeout
entirely with `none` would leak such peers: an idle session has no application
send, so the per-send timeout can't catch it, and TCP only gives up after ~2h.)
`TTSClient(ping_interval=…, ping_timeout=…)` exposes the same knobs so a starved
*server* loop can't trip the *client's* keepalive either.

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
| `dia` | `dia` | `false` | mlx-community/Dia-1.6B-fp16 | Apache-2.0 (commercial-safe) |
| `qwen3_tts` | `qwen3_tts` | `true` | mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16 | apache-2.0 (HF card tag; no LICENSE file in the repo) |
| `fish_tts` | `fish_tts` | `false` | mlx-community/fish-audio-s2-pro | **Fish Audio Research License (non-commercial; commercial requires separate agreement)** |

> **Kokoro is the default commercial-safe backend.** `voxtral_tts` weights are
> **CC-BY-NC** — do not use them in a commercial deployment. `pocket_tts`
> (CC-BY-4.0), `dia` (Apache-2.0), and Kokoro (Apache-2.0) are commercial-safe
> (pocket needs attribution). The choice of backend (and thus of model license)
> is the operator's. `fish_tts` is the **second** backend under restrictive
> terms (`voxtral_tts`'s CC-BY-NC being the first) and the first under a
> *research-only* license: free for research and non-commercial use, royalty-
> free, worldwide, non-exclusive, non-transferable, non-sublicensable, and
> revocable — **no commercial rights are granted** without a separate written
> license agreement from Fish Audio (contact: `business@fish.audio`). See
> *fish_tts capabilities* below.

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

### dia capabilities (as shipped)

A multi-speaker **dialogue** backend, `streaming:false` and segment-level
(`split_pattern='\n'`, like Kokoro). Speakers are addressed **purely in-text** via
`[S1]`/`[S2]` tags inside an ordinary `plain` payload — the server forwards the
buffer untouched and never parses the tags. There is **no voice concept**
(`voice_count: 0`): a supplied `voice` is accepted by the server and structurally
ignored by the backend. No voice cloning (`ref_audio`/`ref_text` left unwired,
decision #2). Verified against mlx-community/Dia-1.6B-fp16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **44100** | from `server.hello.audio.rate`, read from `model.sample_rate` (NOT 24000) |
| `streaming` | `false` | no sub-segment streaming; each `\n`-separated turn streams as it completes |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | dialogue `[S1]`/`[S2]` tags ride **inside** plain text (undocumented on the wire — see `docs/protocol.md` §6, Option A/B) |
| `languages` | `["en"]` | English verified on-host |
| `voice_count` | `0` | no enumerable voices; speakers are in-text `[S1]`/`[S2]` tags |
| `extras` | `["temperature","top_p"]` | dia's effective sampling kwargs (`ref_audio`/`ref_text` never advertised — no cloning) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

> **A commit is the unit of coherence.** dia is autoregressive *within* a single
> commit (every turn conditions on the others) but **stateless across commits**
> (context resets at the boundary). Committing the whole dialogue at once maximises
> cross-turn coherence; incremental commits lower latency at the cost of a coherence
> reset per commit (both are supported). Never split a single `[S1]…` turn across
> two commits. See the dev plan's *Resolved design decisions* #3.

### dia cancellation caveat

dia (like Kokoro) yields one segment per `\n` boundary and the cancel flag is
only checked at a segment boundary. The **client-visible** cancel is prompt
regardless: a `response.cancel` is acknowledged with `response.cancelled` in
~1 ms and no audio follows it. What runs to the segment boundary is the backend
worker / Metal lock: because dia decodes at **RTF ≈ 2.0** (≈ 2× slower than real
time — a model floor, not server overhead), a **long single-segment** commit
holds the lock until its `generate()` reaches the yield (which can be tens of
seconds for a full turn, bounded by `drain_timeout_seconds`), so the *next*
commit can't start synthesizing until then. To free the lock sooner for
back-to-back commits, **chunk at sentence/newline boundaries** — incremental
commits also shorten the first-segment generate that dominates TTFB. The
server's hard guarantee is "no more audio after `response.cancelled`". (See the
dev plan's *Phase 3 live smoke run* for the measured RTF / per-segment latency.)

### Qwen3-TTS capabilities (as shipped)

A genuine sub-segment streamer (native `stream=True`, ~0.4 s of audio per chunk).
The default model is the **CustomVoice** variant, which REQUIRES a speaker: when
the client sends no `voice`, the backend injects **`ryan`**. The `Base` variant
(`--model mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16`) has no speakers
(`voice_count: 0`); any supplied `voice` is accepted by the server and discarded
by the backend (speaker-unconditioned output, dia-style). No voice cloning or
`instruct` styling (never wired). Verified against
mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | native sub-segment streaming (~5 codec tokens ≈ 0.4 s per chunk; TTFB ~0.13 s) |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | |
| `languages` | dynamic | model-native FULL-WORD codes (`"english"`, `"chinese"`, …, plus `"auto"`) — NOT ISO 639-1; consult `capabilities.languages` before sending `language` |
| `voice_count` | `9` | CustomVoice speakers, all-lowercase (`ryan`, `aiden`, `serena`, …); `0` on Base |
| `extras` | `["temperature","top_k","top_p"]` | cloning/style/control kwargs are actively filtered, never advertised |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | **`800`** | hard server cap — LOWER than the siblings' 2000 (see below) |

> **A whole commit renders as ONE generation** — `generate_custom_voice()` has no
> `\n` splitting, and mlx-audio's `max_tokens=4096` single-generation ceiling
> (≈328 s of audio) truncates SILENTLY when hit. Degenerate/repetitive text can
> pace as badly as ~0.19 s of audio per character, so the 800-char cap keeps the
> worst case at ~2x margin under the ceiling; the backend also counts codec
> tokens per generation segment and, if the ceiling is ever reached, FAILS the
> response (`response.failed` with `BACKEND_ERROR`) rather than completing with
> silently missing audio. Commit shorter chunks for long content.

### fish_tts capabilities (as shipped)

A `streaming:false`, segment-level backend (mirrors the `dia` template —
`generate(stream=True)` raises `NotImplementedError` upstream, so every commit's
batches drain through the same non-streaming bridge). There is **no voice
concept** (`voice_count: 0`): Fish's `generate()` deletes its `voice` parameter
unconditionally, so a supplied `voice` is accepted by the server and structurally
discarded by the backend — even more absolute than `dia`'s discard, since Fish
never even inspects the value. No voice cloning (`ref_audio`/`ref_text` left
unwired, decision #2 — the **"Option A accepted cost"**: the WS protocol has no
reference-audio transport, so this is out of scope, not merely unwired by
convenience). Verified against mlx-community/fish-audio-s2-pro (mlx-audio 0.4.4,
Phase 0 gate):

| Field | Value | Note |
|---|---|---|
| rate | **44100** | from `server.hello.audio.rate`, read from `model.sample_rate` (NOT 24000, matches `dia`) |
| `streaming` | `false` | segment-level; one `GenerationResult` per text batch |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | `<|speaker:N|>` and `[tag]` markup ride **inside** plain text (undocumented on the wire — see `docs/protocol.md` §6, Option A/B) |
| `languages` | 38-language static list (`en`, `zh`, `ja`, `ko`, `es`, …) | from the upstream model card (Phase 0 Q6); no `language` kwarg exists in `generate()`'s signature |
| `voice_count` | `0` | no enumerable voices; speakers (if any) are addressed via in-text `<|speaker:N|>` tags |
| `extras` | `["temperature","top_k","top_p","instruct"]` | fish's effective sampling kwargs, plus `instruct` — the first backend to advertise a string-typed style-control extra (`ref_audio`/`ref_text` never advertised — no cloning) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | **`500`** | hard server cap — well below kokoro/voxtral_tts/pocket_tts/dia's 2000 (qwen3_tts is lower still, at 800); derived from Phase 0's per-batch token-ceiling calibration, not from license class — a truncation tripwire (`FishTruncationError` → `response.failed`/`BACKEND_ERROR`) also guards the real per-batch token ceiling (see the dev plan Findings for the calibration) |

**Multi-speaker tag syntax — `<|speaker:N|>` — is NOT `dia`'s `[S1]`/`[S2]`
syntax.** A caller must pick the right dialect for the backend it targets; the
server cannot disambiguate or reject a wrong-dialect tag (same "Option A
accepted cost" as `dia` — e.g. a fish `<|speaker:1|>` tag sent to Kokoro would be
read aloud literally, not interpreted). Example:

```text
<|speaker:0|>Hello, how are you today?
<|speaker:1|>I'm doing well, thanks for asking!
```

**Mixed-input hazard:** untagged prose preceding the *first* `<|speaker:N|>` tag
is silently dropped by the model's own text-splitting logic — not synthesized,
not errored. Don't mix an untagged lead-in with tagged turns in the same commit.

**Cross-batch context sharing:** consecutive `<|speaker:N|>`-tagged turns within
one committed utterance share generation context — each batch's prompt includes
the previous batch's audio codes, so a caller composing multi-turn tagged text
should expect that context-sharing, not independent per-turn generation
(Phase 0 gate Q1, confirmed on this machine).

**Inline `[tag]` emotion/expression markup** is free-form bracketed text,
accepted anywhere in the payload without server-side validation. The example
vocabulary below is the same 34 example tags from the installed mlx-audio
package's `fish_qwen3_omni/README.md` ("Fine-Grained Inline Control" section,
regrouped thematically here rather than kept in upstream's original order) — the source
itself frames these as *"Examples include"* free-form textual descriptions for
open-ended expression control, i.e. the mechanism is open-ended and other
bracketed descriptions may also work, untested:

`[pause]` `[short pause]` `[emphasis]` `[laughing]` `[laughing tone]`
`[chuckle]` `[chuckling]` `[tsk]` `[singing]` `[excited]` `[excited tone]`
`[interrupting]` `[volume up]` `[volume down]` `[loud]` `[low volume]`
`[low voice]` `[echo]` `[angry]` `[sigh]` `[whisper]` `[screaming]`
`[shouting]` `[surprised]` `[shocked]` `[delight]` `[sad]` `[moaning]`
`[exhale]` `[inhale]` `[panting]` `[audience laughter]` `[with strong accent]`
`[clearing throat]`

For the authoritative, potentially-more-current reference (Fish Audio may add
more tags upstream), see the
[`mlx-community/fish-audio-s2-pro` model card](https://huggingface.co/mlx-community/fish-audio-s2-pro)
and Fish Audio's own S2 Pro documentation. As with `dia`'s `[S1]`/`[S2]` tags,
these are plain substrings the server never parses (**"Option A accepted
cost"**): a fish-dialect tag sent to a non-fish backend is read aloud literally,
not interpreted.

**`instruct` is a separate style-control surface**, not an in-text tag — it is
a plain string request extra (see the `extras` table row above), validated to
be a non-empty (after stripping), non-oversized `str`; an oversized or
non-`str` `instruct` is **rejected**, never silently clamped or truncated
(unlike `temperature`/`top_p`/`top_k`, where any in-range value is still a
valid sample knob — a truncated instruction would silently change what the
model is told to do). **The precedence between `instruct` and an in-text
`[tag]` when they conflict is undefined and model-determined** — the server
performs no arbitration and forwards both unmodified apart from
whitespace-stripping of `instruct`; this is untested, do not assume one
overrides the other without observing actual model output.

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
