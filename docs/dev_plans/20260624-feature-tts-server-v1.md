# Task: pipecat-local-tts-server — v1 local websocket TTS server (Kokoro-first)

**Status**: Planned — design locked on paper; no code yet. mlx-audio API claims
verified against installed **0.4.4** via `scripts/verify_mlx_tts_api.py` (2026-06-24);
pin `mlx-audio==0.4.4` (API drifted from 0.3.0 — see R8).
**Component**: tts-server (server, protocol, backends, client)
**Assigned to**: Varun Singh
**Priority**: High (unblocks gamealerts TTS-server migration)
**Branch**: main (founding work) → feature branches per phase
**Created**: 2026-06-24

## Objective

Build a standalone, open-source **local websocket TTS server** that takes **text in
and streams audio out**, supporting multiple **mlx-audio** models behind one wire
protocol. It mirrors the sibling `pipecat-local-stt-server` (same transport, protocol
philosophy, backend abstraction, packaging) so the two are operationally identical.
First consumer is gamealerts (see its companion plan
`gamealerts/docs/dev_plans/20260624-feature-tts-server-client-integration.md`), but the
server is app-agnostic.

## Context

- **Why a server:** today gamealerts loads Kokoro **in-process** (in a subprocess),
  coupling heavy mlx/torch deps to the app and re-loading the model on every restart.
  This server replaces that subprocess. The STT side already solved this with a shared
  local server (`stt_server`, websockets over a Unix socket, lazy-imported per-model
  backends). This project does the TTS-side mirror.
- **gamealerts client contract (authoritative, from the consumer side):** the client owns
  the output device, resampling, and buffering; the server owes it exactly two things.
  (1) **An exact, stable advertised rate.** `MacAudioSurface` plays through the selected
  device (often a 48 kHz Focusrite Scarlett USB interface) and resamples model-rate →
  device-rate driven entirely by `hello.audio.rate`. A past "croaky" bug was a rate/buffer
  mismatch on that USB device; a wrong/variable advertised rate makes the client resample
  at the wrong ratio → pitch/speed distortion. Format stays int16-LE mono at that rate.
  (2) **A steady in-response stream.** That croak was a playback-buffer underrun; in-process
  the audio was always immediately available, but over a socket a server-side stall is a
  new way to starve the client's playback buffer. Don't stall mid-response. These map to
  R1 (rate) and R4 (rate + steady streaming).
- **Template:** `pipecat-local-stt-server` v0.3.2 is the authoritative reference —
  `protocol.py` (OpenAI-Realtime-inspired event subset), `backend.py`
  (`TranscriptionBackend`/`BackendStream` Protocols + `EchoBackend`), lazy-extra
  backends, `python -m stt_server {serve,status}`, optional bearer auth, send-queue
  high-water limits.
- **mlx-audio API (verified against installed mlx-audio 0.4.4 via
  `scripts/verify_mlx_tts_api.py`, not docs — pin in R8):** `mlx_audio.tts.utils.load(model_path,
  lazy=False, strict=True, **kwargs)` (signature confirmed) returns a model whose
  `model.generate(text, ...)` is a **generator that `yield`s `GenerationResult`s**
  (Kokoro splits on `\n+`, one per segment). `GenerationResult` fields are
  `.audio` (float32 `mx.array`, **1-D mono**, observed in [-1, 1] — Kokoro "Goal!"
  peak ±0.22 on one sample; clip before scaling, see R3), `.samples`, `.sample_rate`,
  `.segment_idx`, `.token_count`, `.audio_duration`, `.real_time_factor`, `.prompt`,
  `.audio_samples`, `.processing_time_seconds`, `.peak_memory_usage`, **and
  `.is_streaming_chunk` / `.is_final_chunk`** (these DO exist as of 0.4.4 — they were
  absent in 0.3.0; the streaming drain loop should use `.is_final_chunk` to fire
  `response.audio.done`, with `.segment_idx` as the per-segment index). There is no
  `generate_audio(...)` wrapper on `tts.utils` — we use the generator directly.
  **Per-model `generate()` kwargs are disjoint** (see R7): each backend advertises its
  own effective set — there is no global one. **Version-sensitive:** the API drifted
  between 0.3.0 and 0.4.4 (the streaming-chunk fields appeared; `voxtral_tts` was added;
  `pocket_tts` dropped dead kwargs) — re-run `scripts/verify_mlx_tts_api.py` before any
  mlx-audio bump.

## Locked design decisions

1. **Text in, audio out. Playback stays in the client** — the server never touches an
   audio device. (gamealerts keeps its `MacAudioSurface` playback, ducking, barge-in.)
2. **Local mlx-audio only for v1.** No cloud fronting. **No voice cloning** (handled by
   the separate `vr000m/qwen3-tts-clone-and-speak` repo) → the server stays purely
   text-in/audio-out with no `ref_audio` upload channel. (Note: `pocket_tts` and `dia`
   `generate()` accept a `ref_audio` param — backends MUST leave it unwired to honour
   this decision.) **No nemotron/Riva** (NVIDIA, no mlx ports).
3. **Transport:** websockets over a Unix domain socket by default (also ws://host:port,
   full URI). Endpoint precedence `URI > socket > host+port`, `TTS_WS_*` env vars
   mirroring `STT_WS_*`.
4. **Uniform backend path:** every backend uses `load()` + in-memory `model.generate()`;
   convert `result.audio` float32 → int16 PCM16-LE.
5. **Re-chunk in the session layer, not the backend.** Backends yield native chunks; the
   session slices to fixed **20 ms** wire frames so barge-in latency is bounded
   regardless of a model's `streaming_interval`.
6. **Streaming + chunk-size are advertised, never branched in the protocol.** `server.hello`
   `capabilities` carries `streaming: bool` and an `ideal_chunk_chars`/`max_chunk_chars`
   hint. The **client** uses these to decide how to split long text (see Requirement R7);
   the server just synthesizes whatever each `input_text.commit` delivers.

## Requirements

- **R1 — Protocol** (`protocol.py`): `PROTOCOL_VERSION="0.1"`, pcm16 mono, per-backend
  rate. Event set per Technical Specifications. `ErrorCode` enum mirroring stt.
  **Rate is a correctness contract, not metadata** (client requirement, see Context →
  *gamealerts client contract*): `hello.audio.rate` is the true model rate (Kokoro
  24000, read from `model.sample_rate` at connect — no warmup dependency), and every
  `response.audio.delta` for the session MUST be int16-LE mono at exactly that rate with
  no per-utterance drift. The client resamples model-rate → device-rate (e.g. 48 kHz USB)
  off this single advertised value; a wrong or variable rate makes it resample at the
  wrong ratio and pitch/speed-distorts playback.
- **R2 — Backend abstraction** (`backend.py`): `TTSBackend` + `TTSStream` Protocols +
  a dependency-free `ToneBackend` (sine) reference for tests (the `EchoBackend` analog).
- **R3 — Kokoro backend** (`backends/kokoro.py`): mlx-audio load/generate, float→pcm16
  (**clip to [-1, 1] before `* 32767`** — the [-1,1] range is observed on one sample, not a
  decoder-guaranteed bound, so clip to avoid int16 overflow/clicks on an outlier),
  runs the generate generator in a dedicated thread (Metal is not concurrent-safe — reuse
  the **Lock-pair + in-flight-drain** serialization pattern from the stt backends; note
  `_thread_util.run_in_daemon_thread` itself only marshals *one* Future per call and does
  not serialize). `sample_rate` is **24000** and is readable as `model.sample_rate`
  (a config property) immediately after `load()` — **no warmup-generate needed to learn
  it**; warmup at `start()` is still worthwhile to pay Metal JIT cost off the hot path,
  but decouple it from rate discovery so the handshake can advertise the rate before the
  first synth. Lazy-imports `mlx_audio` inside `start()`/`_get_model`, never at module
  load ("lean-base invariant"). **Dependency note:** importing the Kokoro model pulls
  `misaki` (G2P), whose `[en]` extra drags in `num2words`, `spacy`, an auto-downloaded
  `en_core_web_sm`, **and `torch`** — so the `kokoro` extra is heavy (and re-introduces
  torch, the very dep the server exists to keep out of the app; keep it behind the extra
  and out of lean base). Kokoro yields per-segment (`split_pattern=r"\n+"`), so its
  effective "streaming" granularity is per-segment even though it advertises
  `streaming:false`.
- **R4 — Server/session** (`server.py`): handshake (`server.hello`), per-session text
  buffer, commit→synthesize, the 20 ms re-chunker, `response.cancel` (barge-in),
  send-queue high-water close, resource limits. **Two behavioral contracts the socket
  imposes on playback** (client requirement, see Context → *gamealerts client contract*):
  (a) **exact, stable emitted rate** — every frame matches the advertised `hello.audio.rate`
  (per R1); (b) **steady in-response streaming, no jitter starvation** — once
  `response.created` fires, feed the client buffer continuously: do NOT block the send
  loop on synthesis between chunks, and do NOT emit one large burst then a long gap. For
  Kokoro (yields per `.segment_idx` on `\n+`), **emit each segment's audio as it
  completes** rather than buffering the whole utterance — this lowers time-to-first-audio
  and keeps the client's playback buffer fed. This makes the streaming lifecycle a
  correctness requirement, not an optimization: `open_stream`'s `end()` must NOT block
  until full synthesis while `events()` replays a stored result (the stt-mirrored
  commit-then-drain shape); `events()` must yield frames as segments land. The client
  carries a deep (8192-frame) buffer to absorb normal jitter, so the bar is "don't stall
  mid-response," not a redesign.
- **R5 — Client** (`client.py`): async `TTSClient` — `connect() -> hello`, `update()`,
  `append()`, `commit()`, `cancel()`, `events()`, `status()`, `close()`. Transport-generic
  (no app labels/frame types — the pipecat adapter lives in `examples/`).
- **R6 — CLI** (`__main__.py`): `python -m tts_server serve --backend kokoro --model …
  --socket-path …` (logs resolved backend+model at startup) and `status` health probe
  (connect → hello → status → print backend/model/rate/queue depth), mirroring stt.
- **R7 — Capabilities for client chunking:** `capabilities` MUST expose `streaming`,
  `ideal_chunk_chars`, `max_chunk_chars`, `text_formats`, `languages`, `extras` (accepted
  model-kwarg names), `max_text_chars`. Unknown `extras` keys are dropped (debug-logged),
  never errored. **`extras` is per-backend and must list only kwargs that are real AND
  effective for that model** (verified via `scripts/verify_mlx_tts_api.py` against 0.4.4):
  Kokoro → `{speed}` only (`temperature`/`cfg_scale`/`ddpm_steps` are NOT Kokoro params);
  `voxtral_tts` → `{temperature, top_k, top_p}` (native `stream`/`streaming_interval`, no
  `ref_audio`); `pocket_tts` → `{temperature}` (also native streaming, but exposes
  `ref_audio` — leave unwired per decision 2); dia → `{temperature, top_p}`. A backend
  MUST drop, not forward, a kwarg the model ignores, so the advertised `extras` never
  lies to the client.
- **R8 — Packaging:** package `pipecat-local-tts-server`, import `tts_server`. Lean base =
  `websockets` only. Extras: `client`, `kokoro` (+ later `voxtral_tts`, `pocket_tts`,
  `dia`/`chatterbox`). Backends lazy-import heavy deps. **Pin `mlx-audio==0.4.4`** in the
  backend extras — the TTS API drifted between 0.3.0 and 0.4.4 (streaming-chunk fields,
  `voxtral_tts`, kwarg changes), so an unpinned bump can silently break verified facts;
  re-run `scripts/verify_mlx_tts_api.py` before widening the pin.
- **R9 — Auth (optional):** bearer token, server-side `PIPECAT_TTS_AUTH_TOKEN`, client-side
  `TTS_WS_TOKEN`, cleartext-remote guard — mirror stt exactly.

## Implementation Checklist

### Phase 0 — Scaffold
- [ ] `pyproject.toml` (uv-build), package layout `tts_server/{__init__,__main__,protocol,backend,client,server,env}.py` + `backends/` (incl. `backends/_stream_util.py`, the shared daemon-thread→`asyncio.Queue` streaming bridge — see Architecture & Call Flow), extras `client`/`kokoro` (pin `mlx-audio==0.4.4`), lean base.
- [ ] CI: stand up the **two-job split now** (mirror stt's `.github/workflows/test.yml`): a **lean job** that syncs **only `--extra client`** (never `kokoro` — keeps torch out of "lean") and runs ruff + an **explicit allow-list of lean test files**; a **full macOS/Apple-Silicon job** that syncs all extras and runs everything. Phase 2's mlx-gated tests are simply *not* on the lean allow-list — no runtime skip-marker reliance.
- [ ] Phase-0 **import-safety test** asserts only that base install (no mlx) `import tts_server` succeeds. (Constructing `ToneBackend` moves to Phase 1, where it first exists — a Phase-0 commit must stay green.)

### Phase 1 — Protocol + Tone end-to-end (no model)
- [ ] `protocol.py` events/constants/ErrorCode.
- [ ] `backend.py` Protocols + `ToneBackend` (deterministic sine of N ms); `backends/_stream_util.py` (daemon thread + bounded `asyncio.Queue` + `call_soon_threadsafe` + EOF sentinel + cancel) so Kokoro and the streaming backends share one bridge.
- [ ] `server.py` session loop, handshake, append/commit, 20 ms re-chunker, cancel.
- [ ] `client.py` async client.
- [ ] **Move here:** the import-safety test that constructs `ToneBackend` with no mlx (lean CI).
- [ ] Tests (all lean-CI on `ToneBackend`, no mlx): tone end-to-end; cancel mid-stream **asserting no `response.audio.delta` for that `response_id` after `response.cancelled`, acknowledged within one segment-delay**; protocol round-trip **asserting `hello.protocol_version=="0.1"` and per-`ErrorCode` error paths** (unknown event, invalid JSON, empty-buffer commit, bad extras); **endpoint precedence** (URI>socket>host+port) + cleartext-remote guard; **`session.update`→`updated` and `input_text.clear`→`cleared`** round-trips; **`response.failed`** via a raising `ToneBackend` (carries `{code,message}`, session stays usable); **capabilities** shape + **unknown-extras dropped not errored** + an extra colliding with a fixed param (`voice`/`language`) rejected before the `**extras` call.

### Phase 2 — Kokoro backend
- [ ] `backends/kokoro.py`: load/generate, float→pcm16, thread executor; rate from `model.sample_rate` (warmup is JIT-only, decoupled from rate discovery — see R3).
- [ ] `capabilities()` → `streaming:false`, chunk-size hints, voices count, languages; advertised `extras` == Kokoro's effective set `{speed}`.
- [ ] Tests (gated on mlx / Apple Silicon, not on the lean allow-list): synthesize "GOAL!" → non-empty PCM16 at advertised rate; **assert `hello.audio.rate` is populated from `model.sample_rate` after `load()` with no `generate()` having run** (R3's pre-warmup invariant).

### Phase 3 — Ops parity with stt
- [ ] `status` subcommand; startup model logging.
- [ ] Optional bearer auth + cleartext-remote guard; resource limits + send-queue high-water.
- [ ] Tests (mirror stt, lean-CI on `ToneBackend`): `status` round-trip (connect→hello→status→assert backend/model/rate/queue-depth) + missing-server nonzero exit; **auth** — token-required reject, token-absent TCP startup warning, UDS no-warn, and client `TTS_WS_TOKEN` vs server `PIPECAT_TTS_AUTH_TOKEN` precedence (client must NOT fall back to the server token); **resource limits** — stalled-reader trips send-queue high-water → connection closed (not unbounded), and `max_text_chars` over-limit rejection.

### Phase 4 — Reference adapter + docs
- [ ] `examples/pipecat_tts_service.py` (reference `InterruptibleTTSService` wrapper).
- [ ] `README.md`, protocol doc; `python -m tts_server status` usage.

### Phase 5 — More backends (later)
- [ ] **Streaming backend** = `backends/voxtral_tts.py` (verified present in mlx-audio
  0.4.4; it was NOT in 0.3.0). `voxtral_tts.generate(text, voice, temperature, top_k,
  top_p, max_tokens, verbose, stream, streaming_interval)` has native `stream`/`streaming_interval`
  and **no `ref_audio`** — so it's the cleanest streaming backend (exercises the no-split
  client path with no cloning concern). extras `{temperature, top_k, top_p}`. **`kyutai`
  is still not an mlx-audio TTS family**; `moss_tts*` exists but is unrelated to Kyutai/Moshi.
- [ ] `backends/pocket_tts.py` — also native streaming, but exposes `ref_audio` (leave
  unwired per decision 2); needs `requests` to import in 0.4.4. `backends/dia.py`
  (multi-speaker **dialogue** model — `[S1]`/`[S2]` tags, `extras` `{temperature, top_p}`,
  `ref_audio` unwired; its `voice`/text semantics differ from single-voice backends).
- [ ] Test (when these backends land): assert each backend's advertised `capabilities["extras"]`
  **excludes `ref_audio`** and that a client-supplied `ref_audio` cannot be passed through —
  the negative guard for locked decision #2.

## Technical Specifications

### Wire events
**Client→server:** `session.update {voice?,model?,language?,audio_format?,extras?}` ·
`input_text.append {text,text_format?}` · `input_text.commit {voice?,language?,extras?}` ·
`input_text.clear` · `response.cancel {response_id?}` · `session.cancel` · `session.close` ·
`server.status`.
**Server→client:** `server.hello {protocol_version,backend:{name,model},audio:{format,rate,channels},capabilities}` ·
`session.created`/`updated` · `input_text.committed {response_id}` · `input_text.cleared` ·
`response.created {response_id}` · `response.audio.delta {response_id,seq,audio(base64 pcm16)}` ·
`response.audio.done {response_id,duration_ms}` · `response.cancelled`/`response.failed {response_id,error?}` ·
`server.status` · `error {code,message}`.

### capabilities (server.hello) — Kokoro example, verified fields annotated
```jsonc
{ "streaming": false, "binary_audio": false,                  // rate is NOT here — canonical rate is hello.audio.rate (24000, VERIFIED); R1 client reads that
  "text_formats": ["plain"],                                   // ssml/ipa UNVERIFIED for Kokoro — plain confirmed; drop until checked
  "languages": ["en","ja","zh","fr","es","it","pt","hi"],     // VERIFIED from 54 voice prefixes (a/b→en, e→es, f→fr, h→hi, i→it, j→ja, p→pt, z→zh)
  "voice_count": 54,                                           // VERIFIED (54 distinct voices in mlx-community/Kokoro-82M-bf16)
  "extras": ["speed"],                                         // Kokoro effective set ONLY; temperature/instruct/cfg_scale/ddpm_steps are NOT Kokoro params
  "ideal_chunk_chars": 280, "max_chunk_chars": 500, "max_text_chars": 2000 }
```
Note: Kokoro's `language` maps to a single-letter `lang_code` (`a`/`b`=en, `e`=es, `f`=fr,
`h`=hi, `i`=it, `j`=ja, `p`=pt, `z`=zh) — the backend must translate the ISO `language` to
the letter. Other backends advertise different `extras`/`rate`/`streaming` (pocket_tts is
`streaming:true`); capabilities is built per-backend, never copied from this example.
Note: `streaming:false` means **no sub-segment streaming** — segment-level streaming still
happens (R4 emits each Kokoro `\n+` segment as it completes). So the client's sentence-chunking
on non-streaming backends is about choosing sentence boundaries *within a commit*, not a
substitute for the server's per-segment delivery. (Division of labour — newline-join one
commit vs per-sentence commits — is settled with gamealerts at integration; it only matters
for long Q&A, not commentary.)

### Backend Protocol
```python
@dataclass
class AudioEvent: kind: str          # "delta" | "completed"
                  pcm: bytes         # int16-LE mono; empty on "completed"
class TTSStream(Protocol):
    async def feed(self, text: str) -> None: ...
    async def end(self) -> None: ...
    def events(self) -> AsyncGenerator[AudioEvent, None]: ...   # async def + yield
    async def cancel(self) -> None: ...
class TTSBackend(Protocol):
    backend_name: str; model: str | None; sample_rate: int
    def capabilities(self) -> dict: ...
    async def start(self) -> None: ...
    async def open_stream(self, *, voice, language, extras) -> TTSStream: ...
    async def close(self) -> None: ...
```
`extras` (validated against `capabilities["extras"]`) splats into `model.generate(**extras)`.
The validated `extras` keys MUST be disjoint from the fixed `generate` params the backend
already passes (`text`, `voice`, `language`/`lang_code`) — otherwise `**extras` raises
`TypeError` at the call site. Because `generate` accepts `**kwargs`, an *unfiltered* extra
is silently swallowed (or `del`'d) rather than rejected, so per-backend `extras` validation
is what keeps the advertised contract honest.

## Architecture & Call Flow

Five independently-executing components and the context that crosses each boundary. This
section is the contract for the streaming lifecycle; the Critical risk it resolves is the
stt-mirrored *commit-then-drain* shape (where `end()` blocks until full synthesis and
`events()` replays a stored result), which would violate both client contracts (R1 rate,
R4 steady stream).

```
client ──ws──> session loop (server.py) ──> TTSStream (backend) ──> daemon worker thread
  ▲                  │  ▲                         │  ▲                    │ (Metal, serialized)
  │                  │  │                         │  │                    │ model.generate() yields
  │ response.audio.* │  │ 20 ms re-chunker        │  │ asyncio.Queue      │ GenerationResult per
  └──────────────────┘  └─────────────────────────┘  └── call_soon_threadsafe ── segment (\n+)
```

**Components & triggers**
- **Client** drives the session: `session.update` → `input_text.append`* → `input_text.commit`.
  Owns device, resampling, buffering. Reads `hello.audio.rate` once.
- **Session loop** (`server.py`): one task per connection. On `commit` it allocates a
  `response_id`, emits `response.created`, opens a backend stream, and runs the **drain
  loop** (below). It is the *only* component that touches the websocket.
- **TTSStream** (`open_stream`): adapts one utterance. `feed(text)`/`end()` enqueue work;
  `events()` is an **async generator that yields `AudioEvent`s as segments land** — it does
  NOT wait for full synthesis. `cancel()` stops the worker.
- **Daemon worker thread** (per the stt Lock-pair + in-flight-drain pattern): runs the
  blocking `model.generate(...)` generator. Metal is not concurrency-safe, so a process-wide
  lock serializes generate calls. Each yielded `GenerationResult.audio` (float32 mono,
  clipped to [-1,1]) is converted to int16-LE PCM and pushed onto an `asyncio.Queue` via
  `loop.call_soon_threadsafe(...)`; `.is_final_chunk` (present in 0.4.4) marks the EOF
  sentinel. **This is the boundary `_thread_util` does not cross** (it marshals one Future
  per call; streaming needs the per-chunk queue), so it lives in a **dedicated shared
  module `backends/_stream_util.py`** — one implementation that Kokoro and the streaming
  backends (`voxtral_tts`, `pocket_tts`) all use, so "backend-agnostic" is real and the
  backends cannot drift.
- **20 ms re-chunker**: lives in the session/drain layer, between the queue and the send
  loop. Slices native segment PCM into fixed 20 ms frames at `backend.sample_rate` so
  barge-in latency is bounded regardless of segment length.

**Synthesis drain loop (the steady-stream contract, R4)**
1. `commit` → `response.created {response_id}`.
2. `await stream.feed(text)`; `await stream.end()` — **non-blocking**: `end()` signals
   end-of-input and kicks off the worker; it must NOT block until synthesis completes.
3. `async for ev in stream.events():` — for each segment that lands, push its PCM through
   the 20 ms re-chunker and emit `response.audio.delta {response_id, seq, audio}` **as it
   arrives**. First audio therefore ships after the *first* segment, not the whole utterance
   (lowers time-to-first-audio; keeps the client's 8192-frame buffer fed).
4. On generator exhaustion → `response.audio.done {response_id, duration_ms}`.

**Rate (R1)**: `hello.audio.rate` is read from `model.sample_rate` at connect (pre-warmup),
is the *only* rate on the wire, and every `delta` frame is int16-LE mono at exactly that
rate — the re-chunker never resamples, so there is no per-utterance drift.

**Cancel / barge-in (R4)**: `response.cancel {response_id}` → session sets a cancel flag,
calls `stream.cancel()` (stops the worker at the next segment boundary), drains/clears the
queue, and emits `response.cancelled {response_id}`. No further `delta` for that
`response_id` may be sent after `cancelled`. Because emission is per-segment (not one final
flush), cancel lands within ~one segment, not after the whole utterance.

**Backpressure**: if the client stops reading, the session send queue hits its high-water
mark and the connection is closed (send-queue high-water close, R4) rather than buffering
unboundedly — a stalled *reader* is a client bug, distinct from a server-side synthesis
stall (which the steady-stream contract forbids).

**Topology note**: only `pocket_tts` adds a sub-segment streaming layer (native
`stream`/`streaming_interval`); for it the worker yields intra-segment chunks into the same
queue, and nothing downstream of the queue changes. The session loop, re-chunker, and send
path are backend-agnostic.

## Testing Notes
- `ToneBackend` makes Phase-1 fully deterministic with **no mlx dependency** — protocol,
  re-chunking, cancel, and the lean-base import-safety test all run in plain CI.
- Kokoro tests are marked/skipped when mlx or Apple Silicon is absent.
- Assert the 20 ms re-chunker emits uniform frame sizes from both a single-chunk
  (non-streaming) and multi-chunk (simulated streaming) backend.
- **Rate-exactness:** assert every `response.audio.delta` frame's implied rate matches
  `hello.audio.rate` and is constant across a multi-segment utterance (a `ToneBackend`
  with a fixed rate makes this deterministic in plain CI).
- **Steady streaming / no jitter starvation:** with a `ToneBackend` whose segments
  complete with an injected delay, assert first audio arrives before the whole utterance
  is synthesized (time-to-first-frame << total synth time) and that the send loop is not
  blocked between segments — i.e. `events()` yields per segment, it does not buffer the
  full utterance then flush.

## Acceptance Criteria
- `python -m tts_server serve --backend kokoro` serves; `status` prints backend/model/rate.
- A client synthesizes text → non-empty PCM16 frames at the advertised rate; `response.cancel`
  stops mid-stream promptly.
- **Rate contract:** every emitted frame is int16-LE mono at exactly `hello.audio.rate`,
  constant across the whole utterance (no per-utterance drift).
- **Steady-stream contract:** for a multi-segment utterance, first audio reaches the client
  before full synthesis completes, and audio is delivered continuously (no burst-then-gap)
  so the client playback buffer never starves.
- Base install (no `kokoro` extra) imports and runs the Tone path; no mlx at import time.

## Decided defaults (locked so `/conduct` doesn't fork; revisit only if a phase surfaces a reason)
1. Audio framing: **base64-in-JSON** for v1 (advertise `binary_audio:false`; binary is a later optimization).
2. Event naming: **`response.audio.*`** (OpenAI-Realtime-aligned).
3. Wire frame size: **20 ms**.
4. Voices: **count in hello, full list via `status`**.
5. Repo: dev on `vr000m/pipecat-local-tts-server`; PR to `pipecat-ai/` upstream later.

## Conduct Readiness
NOT yet conduct-ready, but closest of the two:
1. **Not reviewed:** run `/review-plan` (adds the marker `/conduct` checks).
2. Phases 0–5 are drafted; per-phase acceptance should be tightened in review (esp. the
   mlx-gated Kokoro tests vs lean CI split).
3. This plan has **no external blocker** — it can be conducted first; the gamealerts plan
   depends on its Phases 0–2.

## Companion plan
gamealerts client/integration work: `gamealerts/docs/dev_plans/20260624-feature-tts-server-client-integration.md`.
