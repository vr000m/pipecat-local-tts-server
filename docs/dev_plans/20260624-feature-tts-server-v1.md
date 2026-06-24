# Task: pipecat-local-tts-server — v1 local websocket TTS server (Kokoro-first)

**Status**: Planned — design locked on paper; no code yet
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

- **Why a server:** today gamealerts loads Kokoro **in-process**, coupling heavy
  mlx/torch deps to the app and re-loading the model on every restart. The STT side
  already solved this with a shared local server (`stt_server`, websockets over a Unix
  socket, lazy-imported per-model backends). This project does the TTS-side mirror.
- **Template:** `pipecat-local-stt-server` v0.3.2 is the authoritative reference —
  `protocol.py` (OpenAI-Realtime-inspired event subset), `backend.py`
  (`TranscriptionBackend`/`BackendStream` Protocols + `EchoBackend`), lazy-extra
  backends, `python -m stt_server {serve,status}`, optional bearer auth, send-queue
  high-water limits.
- **mlx-audio API (verified from docs):** one uniform path —
  `mlx_audio.tts.utils.load(model_path, lazy=False, strict=True, **kwargs)` then an
  in-memory `model.generate(text, voice=, lang_code=, speed=, temperature=, stream=,
  streaming_interval=2.0, **kwargs)` yielding `GenerationResult` with `.audio`
  (float32 mx.array), `.sample_rate`, `.is_streaming_chunk`, `.is_final_chunk`. The
  high-level `generate_audio(...)` wrapper writes files — **we do NOT use it**; we use
  the in-memory generator.

## Locked design decisions

1. **Text in, audio out. Playback stays in the client** — the server never touches an
   audio device. (gamealerts keeps its `MacAudioSurface` playback, ducking, barge-in.)
2. **Local mlx-audio only for v1.** No cloud fronting. **No voice cloning** (handled by
   the separate `vr000m/qwen3-tts-clone-and-speak` repo) → the server stays purely
   text-in/audio-out with no `ref_audio` upload channel. **No nemotron/Riva** (NVIDIA,
   no mlx ports).
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
- **R2 — Backend abstraction** (`backend.py`): `TTSBackend` + `TTSStream` Protocols +
  a dependency-free `ToneBackend` (sine) reference for tests (the `EchoBackend` analog).
- **R3 — Kokoro backend** (`backends/kokoro.py`): mlx-audio load/generate, float→pcm16,
  runs blocking generate in a dedicated thread (Metal is not concurrent-safe — reuse a
  `_thread_util` serialization like stt), warmup-generate at `start()` to learn
  `sample_rate` + JIT. Lazy-imports `mlx_audio` inside `start()`/`_get_model`, never at
  module load ("lean-base invariant").
- **R4 — Server/session** (`server.py`): handshake (`server.hello`), per-session text
  buffer, commit→synthesize, the 20 ms re-chunker, `response.cancel` (barge-in),
  send-queue high-water close, resource limits.
- **R5 — Client** (`client.py`): async `TTSClient` — `connect() -> hello`, `update()`,
  `append()`, `commit()`, `cancel()`, `events()`, `status()`, `close()`. Transport-generic
  (no app labels/frame types — the pipecat adapter lives in `examples/`).
- **R6 — CLI** (`__main__.py`): `python -m tts_server serve --backend kokoro --model …
  --socket-path …` (logs resolved backend+model at startup) and `status` health probe
  (connect → hello → status → print backend/model/rate/queue depth), mirroring stt.
- **R7 — Capabilities for client chunking:** `capabilities` MUST expose `streaming`,
  `ideal_chunk_chars`, `max_chunk_chars`, `text_formats`, `languages`, `extras` (accepted
  model-kwarg names), `max_text_chars`. Unknown `extras` keys are dropped (debug-logged),
  never errored.
- **R8 — Packaging:** package `pipecat-local-tts-server`, import `tts_server`. Lean base =
  `websockets` only. Extras: `client`, `kokoro` (+ later `voxtral`, `chatterbox`). Backends
  lazy-import heavy deps.
- **R9 — Auth (optional):** bearer token, server-side `PIPECAT_TTS_AUTH_TOKEN`, client-side
  `TTS_WS_TOKEN`, cleartext-remote guard — mirror stt exactly.

## Implementation Checklist

### Phase 0 — Scaffold
- [ ] `pyproject.toml` (uv-build), package layout `tts_server/{__init__,__main__,protocol,backend,client,server,env}.py` + `backends/`, extras `client`/`kokoro`, lean base.
- [ ] CI: lint (ruff) + tests; **import-safety test** that base install (no mlx) imports `tts_server` and constructs `ToneBackend`.

### Phase 1 — Protocol + Tone end-to-end (no model)
- [ ] `protocol.py` events/constants/ErrorCode.
- [ ] `backend.py` Protocols + `ToneBackend` (deterministic sine of N ms).
- [ ] `server.py` session loop, handshake, append/commit, 20 ms re-chunker, cancel.
- [ ] `client.py` async client.
- [ ] Test: client synthesizes a tone end-to-end; cancel mid-stream; protocol round-trip.

### Phase 2 — Kokoro backend
- [ ] `backends/kokoro.py`: load/generate, float→pcm16, thread executor, warmup rate.
- [ ] `capabilities()` → `streaming:false`, chunk-size hints, voices count, languages.
- [ ] Test (gated on mlx / Apple Silicon, skipped in lean CI): synthesize "GOAL!" → non-empty PCM16 at advertised rate.

### Phase 3 — Ops parity with stt
- [ ] `status` subcommand; startup model logging.
- [ ] Optional bearer auth + cleartext-remote guard; resource limits + send-queue high-water.

### Phase 4 — Reference adapter + docs
- [ ] `examples/pipecat_tts_service.py` (reference `InterruptibleTTSService` wrapper).
- [ ] `README.md`, protocol doc; `python -m tts_server status` usage.

### Phase 5 — More backends (later)
- [ ] `backends/voxtral.py` (streaming:true — exercises the no-split client path), `backends/chatterbox.py` (multilingual + emotion `extras`).

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

### capabilities (server.hello)
```jsonc
{ "streaming": false, "binary_audio": false,
  "text_formats": ["plain","ssml","ipa"], "languages": ["en","ja","zh","fr","es","it","pt","hi"],
  "voice_count": 54, "extras": ["speed","temperature","instruct","cfg_scale","ddpm_steps"],
  "ideal_chunk_chars": 280, "max_chunk_chars": 500, "max_text_chars": 2000 }
```

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

## Testing Notes
- `ToneBackend` makes Phase-1 fully deterministic with **no mlx dependency** — protocol,
  re-chunking, cancel, and the lean-base import-safety test all run in plain CI.
- Kokoro tests are marked/skipped when mlx or Apple Silicon is absent.
- Assert the 20 ms re-chunker emits uniform frame sizes from both a single-chunk
  (non-streaming) and multi-chunk (simulated streaming) backend.

## Acceptance Criteria
- `python -m tts_server serve --backend kokoro` serves; `status` prints backend/model/rate.
- A client synthesizes text → non-empty PCM16 frames at the advertised rate; `response.cancel`
  stops mid-stream promptly.
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
