# Task: pipecat-local-tts-server — v1 local websocket TTS server (Kokoro-first)

**Status**: In Progress — Phases 0–4 complete (merged on `feature/tts-server-phases-0-4`); Phase 5 pending. mlx-audio API claims
verified against installed **0.4.4** via `scripts/verify_mlx_tts_api.py` — including the
runtime `--load` path and `scripts/prosody_check.py`, **executed 2026-06-24 on
arm64/vr000m-manganese, mlx-audio 0.4.4** (so the runtime facts below — rate, audio range,
voice count, prosody numbers — are measured, not inferred); pin `mlx-audio==0.4.4` (API
drifted from 0.3.0 — see R8).
**Component**: tts-server (server, protocol, backends, client)
**Assigned to**: Varun Singh
**Priority**: High (unblocks gamealerts TTS-server migration)
**Branch**: `feature/tts-server-phases-0-4` (PR #2)
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
- **gamealerts client contract (asserted from the companion plan — confirm against
  `gamealerts/docs/dev_plans/20260624-feature-tts-server-client-integration.md` before Phase 4
  integration; the two load-bearing claims to verify are (i) the client resamples driven
  *solely* by `hello.audio.rate`, and (ii) a server-side mid-response stall starves playback):**
  the client owns the output device, resampling, and buffering; the server owes it exactly two things.
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
  `.audio` (float32 `mx.array`, **1-D mono** — confirmed via `verify_mlx_tts_api.py --load`
  2026-06-24: shape `(32400,)`, range [-0.199, 0.225], peak ±0.22; in [-1,1] on this sample
  but **not** a decoder-guaranteed bound, so clip before scaling, see R3), `.samples`, `.sample_rate`,
  `.segment_idx`, `.token_count`, `.audio_duration`, `.real_time_factor`, `.prompt`,
  `.audio_samples`, `.processing_time_seconds`, `.peak_memory_usage`, **and
  `.is_streaming_chunk` / `.is_final_chunk`** (field *presence* verified as of 0.4.4 via
  `dataclasses.fields` — they were absent in 0.3.0; but **Kokoro never *sets* `.is_final_chunk`** —
  `kokoro.py:345-367` yields `GenerationResult(...)` with the field defaulting `False`, confirmed
  2026-06-24. So the drain loop fires `response.audio.done` on **generator exhaustion**, treating
  `.is_final_chunk` as advisory only; `.segment_idx` is the per-segment index). There is no
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
6. **The client segments; the commit is the unit of work.** `server.hello` `capabilities`
   carries `streaming: bool` and an `ideal_words` hint; the **client** uses these to split
   long text into commits (see R7), and the server just synthesizes whatever each
   `input_text.commit` delivers. The commit is also the unit of GPU-lock holding and
   cross-connection fairness (see R4 / Architecture & Call Flow). The server does NOT
   expose its queue depth and does NOT require clients to infer load from latency/TTFB —
   overload is signalled explicitly via backpressure (R1 `ErrorCode.BUSY`).
   **Never split mid-sentence.** `ideal_words` is a soft target the client rounds up to the
   next sentence boundary; a half-sentence commit makes the model apply sentence-final
   prosody mid-phrase. Measured on Kokoro (`scripts/prosody_check.py`, run 2026-06-24 on
   arm64/vr000m-manganese, mlx-audio 0.4.4): splitting "The quick brown fox jumps over the
   lazy dog." at a non-boundary ran +22.3% longer (3975 ms vs 3250 ms) and injected a
   389 ms terminal pause after "fox" — audibly wrong.

## Requirements

- **R1 — Protocol** (`protocol.py`): `PROTOCOL_VERSION="0.1"`, pcm16 mono, per-backend
  rate. Event set per Technical Specifications. `ErrorCode` enum mirroring stt.
  **Rate is a correctness contract, not metadata** (client requirement, see Context →
  *gamealerts client contract*): `hello.audio.rate` is the true model rate (Kokoro
  24000 — confirmed via `--load` 2026-06-24: `model.sample_rate` returned 24000 *before*
  any `generate()` ran — read at connect, no warmup dependency), and every
  `response.audio.delta` for the session MUST be int16-LE mono at exactly that rate with
  no per-utterance drift. The client resamples model-rate → device-rate (e.g. 48 kHz USB)
  off this single advertised value; a wrong or variable rate makes it resample at the
  wrong ratio and pitch/speed-distorts playback. **`audio_format` is strict:** the only
  accepted value is the advertised pcm16-at-`hello.audio.rate`; any other `audio_format` in
  `session.update` is rejected with `error {code: UNSUPPORTED_FORMAT}`. `input_text.commit`
  has no `audio_format` field in v1; if a client sends one, it is handled as an unknown-field
  protocol error, not as a format negotiation path. (The field stays in the wire schema for
  `session.update` so a later binary-audio optimization has a home, but v1 enforces a single
  format.) The `ErrorCode` enum adds **`BUSY`** (the
  websocket-native analog of HTTP 429): the `error` event carries `retry_after_ms` when a
  commit is rejected for synthesis-backlog backpressure (see R4).
- **R2 — Backend abstraction** (`backend.py`): `TTSBackend` + `TTSStream` Protocols +
  a dependency-free `ToneBackend` (sine) reference for tests. Unlike stt's one-shot
  `EchoBackend`, `ToneBackend` MUST emit **multiple segments with a configurable per-segment
  delay** so it drives the per-segment `events()` streaming contract (R4) and the 20 ms
  re-chunker — it is the *streaming* reference, not a one-shot echo. `ToneBackend` and the
  shared float→pcm16 converter are **stdlib-only runtime code** (e.g. `math`/`array`/`struct`);
  `numpy` may stay in the dev group for verification scripts, but public runtime modules and
  lean tests must not require a dev-only dependency.
- **R3 — Kokoro backend** (`backends/kokoro.py`): mlx-audio load/generate, float→pcm16
  (**clip to [-1, 1] and map asymmetrically to signed PCM16: negative samples scale by
  32768, non-negative samples by 32767, so `-1.0 → -32768` and `+1.0 → +32767`** — the
  [-1,1] range is observed on one sample, not a decoder-guaranteed bound, so clip to avoid
  int16 overflow/clicks on an outlier),
  runs the generate generator in a dedicated thread (Metal is not concurrent-safe — adapt
  the **Lock-pair + in-flight-drain** idea from the stt backends, but note the scope
  **differs**: stt holds the lock around a *single* blocking `transcribe()` call, whereas TTS
  holds the process-wide Metal lock around the **entire `generate()` generator-drain** (many
  `yield`s) — this is the mechanism behind "commit = the unit of GPU-lock holding" (R4).
  Round-robin fairness is owned by the server-side synthesis scheduler, not by independent
  worker threads racing for the lock. `cancel()` MUST break the generator out so a cancelled
  response does not pin the lock. The lock + per-chunk queue live in `backends/_stream_util.py`, not in
  `_thread_util.run_in_daemon_thread`, which only marshals *one* Future per call and does not
  serialize — see Architecture & Call Flow). `sample_rate` is **24000** and is readable as
  `model.sample_rate` (a config property) immediately after `load()` — **no warmup-generate
  needed to learn it** (confirmed via `--load` 2026-06-24: the value printed before any
  `generate()` ran); warmup at `start()` is still worthwhile to pay Metal JIT cost off the hot path,
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
  until full synthesis while `events()` replays a stored result (that buffer-then-flush
  shape is stt's, and is the **anti-pattern** here — see Architecture & Call Flow);
  `events()` must yield frames as segments land. The client
  carries a deep (8192-frame) buffer to absorb normal jitter, so the bar is "don't stall
  mid-response," not a redesign.
  **Multi-connection isolation (correctness):** the server accepts concurrent connections
  from different apps; each gets its own `_SessionState` (text buffer, config, `response_id`
  space) — there is **no shared mutable session state**, so one connection's text/synthesis
  can never pollute another's (mirrors stt's per-connection `_SessionState`). What IS shared
  is the single model + a process-wide Metal lock (Metal is not concurrency-safe), so the
  **commit is the unit of scheduler selection and GPU-lock holding**: the server admits commits
  into per-connection queues, a single dispatcher selects connections round-robin at commit
  boundaries, and only the selected commit's worker may acquire the Metal lock. Fairness is bounded
  by one selected commit's synthesis time, which is why the `ideal_words` size discipline
  (decision #6 / R7) is a fairness lever, not just a latency one.
  **Backpressure — synthesis backlog (distinct from send-queue high-water).** Two separate
  protections: (1) the existing per-connection **outbound** send-queue high-water *close*
  (slow audio *reader*); (2) a new **inbound** admission control on the global synthesis
  backlog — when the bounded synthesis queue is full the server **rejects the commit
  (does NOT enqueue it)** with `error {code: BUSY, retry_after_ms}` (R1). A per-connection
  in-flight cap (≤K queued commits) keeps one app from filling the global queue and starving
  others. **v1 sets K=1** — one active-or-queued response per connection — which keeps the
  `response.cancel {response_id?}` optional-`response_id` form unambiguous (there is only one
  cancellable response). If K>1 is later enabled, `response_id` becomes **required** on cancel
  whenever >1 response is active/queued, and the plan must then define whether cancel may drop a
  queued-but-not-started commit (v1 K=1 sidesteps this — cancel always targets the single in-flight
  response and clears the queue). Client retry policy is **out of the wire contract** but recommended: hold the text,
  retry after `retry_after_ms` with **capped** backoff + jitter, **giving up after 5 retries**.
  The server is protected by the queue cap regardless of client behavior. The threshold is a
  bounded queue depth in commits (safe because commits are size-capped per decision #6); if
  short-commit over-counting causes premature rejection, upgrade the metric to queued input
  characters later.
- **R5 — Client** (`client.py`): async `TTSClient` — `connect() -> hello`, `update()`,
  `append()`, `commit()`, `cancel()`, `events()`, `status()`, `close()`. Transport-generic
  (no app labels/frame types — the pipecat adapter lives in `examples/`).
- **R6 — CLI** (`__main__.py`): `python -m tts_server serve --backend kokoro --model …
  --socket-path …` (logs resolved backend+model at startup) and `status` health probe
  (connect → hello → status → print backend/model/rate/queue depth), mirroring stt.
- **R7 — Capabilities for client chunking:** `capabilities` MUST expose `streaming`,
  `ideal_words`, `text_formats`, `languages`, `extras` (accepted model-kwarg names),
  `max_text_chars`. `ideal_words` is a **soft** chunk-size target the client rounds up to the
  next **sentence boundary** (never split mid-sentence — decision #6); `max_text_chars` is the
  **hard** server cap (reject beyond it). For a `streaming:false` backend the client MUST chunk
  at sentences (else it eats both penalties — slow generation AND no audio until done); for a
  `streaming:true` backend it MAY pass larger text (incremental audio), though bounded commits
  still serve cross-connection fairness (R4). Unknown `extras` keys are dropped (debug-logged),
  never errored. **`extras` is per-backend and must list only kwargs that are real AND
  effective for that model** (verified via `scripts/verify_mlx_tts_api.py` against 0.4.4 — live
  `generate()` signatures re-surveyed 2026-06-24 for kokoro/voxtral_tts/pocket_tts/dia via the
  script's **source-regex** extraction (not `inspect.signature`), so for Phase-5 backends
  re-verify via `inspect.signature` on the actual callable before wiring):
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
- [ ] `pyproject.toml` (uv-build), package layout `tts_server/{__init__,__main__,protocol,backend,client,server,env}.py` + `backends/` (incl. `backends/_stream_util.py` shipped as a **stdlib-only stub** in Phase 0 — the daemon-thread→`asyncio.Queue` bridge logic lands in Phase 1 — so the import-safety test stays green; see Architecture & Call Flow), extras `client`/`kokoro` (pin `mlx-audio==0.4.4`), lean base. Runtime package code stays **stdlib + websockets only** outside backend extras; `numpy` is dev-only for verification scripts/tests that explicitly opt into it, not a dependency of `ToneBackend` or the shared pcm16 converter.
- [ ] CI: stand up the **two-job split now** (structure mirrors stt's `.github/workflows/test.yml`): a **lean job** that syncs **only `--extra client`** (never `kokoro` — keeps torch out of "lean") and runs an **explicit allow-list of lean test files**, **plus a ruff step — which stt's CI does not have** (a deliberate addition, not part of the mirror); a **full macOS/Apple-Silicon job** that syncs all declared extras and runs everything that is not explicitly network/model-gated. Phase 2's mlx-gated tests are simply *not* on the lean allow-list — no runtime skip-marker reliance. **The Phase-0 allow-list contains only the import-safety test** (the only lean test that exists yet); Phases 1, 2, and 3 each **extend the allow-list in the same commit** that adds their lean tests (`pytest` errors on a missing allow-listed path, so the list must grow with the tests, not ahead of them). Before relying on the full macOS job as acceptance evidence, add a Phase-0 CI verification note or separate smoke step proving the runner can `uv sync` the intended TTS extras; if Kokoro model download/weights/network are unavailable in CI, mark Kokoro synth tests as manual or gated and document that in the workflow.
- [ ] Phase-0 **import-safety test** asserts only that base install (no mlx) `import tts_server` succeeds. (Constructing `ToneBackend` moves to Phase 1, where it first exists — a Phase-0 commit must stay green.)

### Phase 1 — Protocol + Tone end-to-end (no model)
- [ ] `protocol.py` events/constants/ErrorCode.
- [ ] `backend.py` Protocols + `ToneBackend` (deterministic sine of N ms); `backends/_stream_util.py` (daemon thread + bounded queue bridge with producer-side blocking/cooperative put + EOF sentinel + cancel) so Kokoro and the streaming backends share one bridge.
- [ ] `server.py` session loop, handshake, append/commit, 20 ms re-chunker, cancel.
  **Per-connection `_SessionState` isolation is built here** (no shared mutable session
  state — mirrors stt); endpoint resolution plus the cleartext-remote warning/guard land here
  so the Phase-1 endpoint tests pass. Only auth enforcement, resource-limit caps, and synthesis
  backpressure *caps* are deferred to Phase 3.
- [ ] `client.py` async client.
- [ ] **Extend the lean CI allow-list** with the Phase-1 test files added below.
- [ ] **Move here:** the import-safety test that constructs `ToneBackend` with no mlx (lean CI).
- [ ] Tests (all lean-CI on `ToneBackend`, no mlx): tone end-to-end; cancel mid-stream **asserting no `response.audio.delta` for that `response_id` after `response.cancelled`, acknowledged within one segment-delay**; protocol round-trip **asserting `hello.protocol_version=="0.1"` and per-`ErrorCode` error paths** (unknown event, invalid JSON, empty-buffer commit, bad extras); **endpoint precedence** (URI>socket>host+port) + cleartext-remote guard; **`session.update`→`updated` and `input_text.clear`→`cleared`** round-trips; **`response.failed`** via a raising `ToneBackend` (carries `{code,message}`, session stays usable); **capabilities** shape + **unknown-extras dropped not errored** + an extra colliding with a fixed param (`voice`/`language`) rejected before the `**extras` call; **`seq` monotonicity** — `seq` starts at 0, increments by 1 with no gaps across a multi-segment utterance, and resets per new `response_id` (the client reassembles ordered PCM off `seq`; a gap silently corrupts audio); **standalone `PROTOCOL_VERSION=="0.1"` trip-wire** (a constant-pin test separate from the handshake round-trip — mirrors stt; catches bumps the round-trip would not); **`session.update.audio_format` reject** — any value other than the advertised pcm16-at-model-rate → `error {code: UNSUPPORTED_FORMAT}`; **unknown `input_text.commit.audio_format` reject** — because commit has no format field in v1, this is an invalid/unknown-field protocol error rather than format negotiation; **`text_format` reject** — a non-`plain` `text_format` (e.g. `ssml`) is rejected (only `plain` advertised); **`session.cancel` vs `session.close`** — distinct semantics (close = drain, cancel = discard) and both distinct from `response.cancel`.

### Phase 2 — Kokoro backend
- [ ] `backends/kokoro.py`: load/generate, float→pcm16, thread executor; rate from `model.sample_rate` (warmup is JIT-only, decoupled from rate discovery — see R3).
- [ ] `capabilities()` → `streaming:false`, chunk-size hints, voices count, languages; advertised `extras` == Kokoro's effective set `{speed}`.
- [ ] Tests (gated on mlx / Apple Silicon, not on the lean allow-list): synthesize "GOAL!" → non-empty PCM16 at advertised rate; **assert `hello.audio.rate` is populated from `model.sample_rate` after `load()` with no `generate()` having run** (R3's pre-warmup invariant); assert Kokoro `capabilities()["extras"] == ["speed"]`, advertised voice/language shape, unsupported kwargs excluded, and at least one non-default ISO language maps to the expected Kokoro `lang_code` before `generate()`; run a long single-segment cancellation probe and record the measured `response.cancel` acknowledgement/no-more-delta latency. If long-segment cancellation exceeds the barge-in target, require client sentence/newline chunking for Kokoro or weaken Kokoro cancel semantics to "best effort at generator yield boundaries."
- [ ] **Clip-invariant unit test (lean-CI, no mlx):** the float→int16 converter is a standalone stdlib helper importable without `mlx_audio` or `numpy`; feed it `±1.5` and assert it **saturates** to `+32767`/`−32768`, not wraps (R3 — the [-1,1] range is observed, not guaranteed). Add this test file to the lean allow-list.
- [ ] **Kokoro lazy-import lean test:** import or backend-registry-resolve `tts_server.backends.kokoro` with the `kokoro` extra absent and assert module import succeeds without importing `mlx_audio`; actual model startup remains in the mlx-gated suite.

### Phase 3 — Ops parity with stt
- [ ] `status` subcommand; startup model logging.
- [ ] Optional bearer auth; resource limits + send-queue high-water.
- [ ] **Backpressure caps** (per-connection `_SessionState` isolation already built in Phase 1): global synthesis-queue cap + per-connection in-flight cap → reject excess `commit` with `error {code: BUSY, retry_after_ms}` (not enqueued).
- [ ] Tests (mirror stt, lean-CI on `ToneBackend`): `status` round-trip (connect→hello→status→assert backend/model/rate/queue-depth) + missing-server nonzero exit; **auth** — token-required reject, token-absent TCP startup warning, UDS no-warn, and client `TTS_WS_TOKEN` vs server `PIPECAT_TTS_AUTH_TOKEN` precedence (client must NOT fall back to the server token); **resource limits** — stalled-reader trips send-queue high-water → connection closed (not unbounded), and `max_text_chars` over-limit rejection; **backpressure + isolation** (see Testing Notes) — `BUSY`/`retry_after_ms` on a full synthesis queue (assert `retry_after_ms` is a **positive, bounded integer** — not zero/absurd, else the client hot-loops), per-connection in-flight cap, **cancel frees an in-flight slot** (fill to K, `response.cancel` one, assert a new `commit` is accepted — guards a barge-in-heavy client from self-DoSing into permanent `BUSY`), and the 2-connection no-intermix / round-robin-fairness assertions.

### Phase 4 — Reference adapter + docs
- [ ] `examples/pipecat_tts_service.py` (reference `LocalTTSService`, a `TTSService` subclass — not `InterruptibleTTSService`, which is the cloud-reconnect base; rationale in the module docstring). The
  lightweight `examples/reference_client.py` (stdlib + `websockets`, no pipecat dependency)
  already exists as a testing oracle; the pipecat-framework adapter is the additional Phase-4
  deliverable.
- [ ] `README.md`; **`docs/protocol.md` already authored** (2026-06-24) — Phase 4 verifies it
  matches the shipped `protocol.py` and updates the Kokoro-only capabilities/extras table
  (Phase 5 revisits it when the other backends land). `python -m tts_server status` usage.

### Phase 5 — More backends (later)

**Split into independent sub-phases** (each adds a heavy dep + CI extra + model-gating
decision, so each is its own branch/commit). Signatures and streaming behaviour below are
**VERIFIED via `inspect.signature` on the live 0.4.4 callables + source read** (2026-06-24,
arm64; supersedes the earlier source-regex survey — see Findings → *Phase 5 signature
verification*). The session loop, 20 ms re-chunker, scheduler, and `_stream_util` bridge are
already backend-agnostic (Phases 1–2), so a new backend is: lazy-import + `generate()` adapter +
`capabilities()` + extras filtering. **No bridge/queue/re-chunker code changes are needed** —
sub-segment chunks feed the same bounded queue, and `response.audio.done.duration_ms` is computed
from the total sample count in the drain path (`server.py::_run_drain`, ~`server.py:1137`; not
`chunks × interval`), so sub-segment
chunking changes only the chunk *count*, not the totals. (This is *why* "nothing downstream changes"
holds — confirmed against the drain path; it is not a bare assertion. Each sub-phase still adds its
own backend module, tests, packaging, and a verified streaming-cadence default — see below.)

**`streaming_interval` plumbing (applies to 5a/5b).** There is no constructor/CLI channel for it:
`make_backend(name, model)` (`tts_server/backends/__init__.py:23`) and the CLI take only
`--backend`/`--model`. So each streaming backend carries `streaming_interval` as a **per-backend
module constant baked into its `_gen_factory()` `generate()` call** — exactly how `kokoro.py`
hardcodes `lang_code`/`speed` — NOT a new constructor param, CLI flag, or client `extras` key.

**`voice=None` handling (applies to 5a/5b; `dia` is now its own plan — see Companion plans).** The server **intentionally forwards**
`voice=msg.get("voice", config.get("voice"))` — i.e. `voice=None` — straight into `open_stream`
(`server.py`, the `open_stream(..., voice=voice)` call is unconditional **by design**; do NOT add an
omit there). The model defaults differ per backend (voxtral `'casual_male'`, pocket/dia `None` with
dialogue-tag semantics), so **the omit-when-None logic lives in each backend's `_gen_factory`/
`open_stream` (the TTSStream layer), not the server**: when the resolved `voice is None`, omit the
`voice` kwarg from the `generate()` call so the model's own default stands rather than forwarding
`voice=None`. Kokoro's `_gen_factory` does this for `speed` (it passes `voice` **unconditionally** —
there is no existing `voice`-omit to copy); replicate that **`speed`-omit pattern, applied to `voice`**. A
per-backend test spies the `generate()` kwargs and asserts `voice` is absent when the client omits it
(same `open_stream`-spy harness as the negative-guard test — see per-sub-phase tests).

**`ToneBackend` streaming fixture (5a prerequisite, lean CI).** `ToneBackend.capabilities()` is
hardcoded `"streaming": False` (`tts_server/backend.py:282`). Add a `streaming: bool` constructor
param (it already parametrizes `extras`/`languages`) so the `streaming:true` capabilities branch and
the client no-split path are exercisable in **lean CI**, independent of the mlx-gated real backends.

#### Phase 5a — `voxtral_tts` (streaming reference) — do first
- [ ] `backends/voxtral_tts.py`. VERIFIED signature: `generate(text, voice='casual_male',
  temperature=0.8, top_k=50, top_p=0.95, max_tokens=4096, verbose=False, stream=False,
  streaming_interval=2.0, **kwargs)`. Native `stream`/`streaming_interval`, **no `ref_audio`**
  — the cleanest streaming backend (exercises the `streaming:true` no-split client path with no
  cloning concern). `capabilities()` → `streaming:true`, extras `{temperature, top_k, top_p}`.
  Apply the `streaming_interval` plumbing and `voice=None` rule above.
- [ ] **Default `streaming_interval` small — ~0.3–0.5s is a STARTING ESTIMATE, not a measured
  optimum.** **Observed mechanism (0.4.4 source read, NOT script-asserted — `verify_mlx_tts_api.py`
  does not compute cadence; `voxtral_tts.py:671-716`, line numbers approximate):** with `stream=True`
  the model yields
  a `GenerationResult` every `frames_per_chunk = max(1, int(streaming_interval/0.08))` frames
  (1 frame = 80 ms), so the model default 2.0s buffers ~2 s before the **first** chunk; the 20 ms
  re-chunker cannot lower TTFB (it re-frames only *after* a chunk arrives). What is **NOT** verified:
  (a) that 0.3–0.5s is the floor that still yields clean audio — voxtral adds `context_frames`
  overlap per chunk to avoid boundary artifacts, so a smaller interval carries a decode-overhead and
  artifact cost not yet quantified; (b) absolute TTFB — that is dominated by model prefill +
  first-decode, unmeasured for voxtral. **Measurement step (mirror Phase-2 discipline):** before
  locking the default, measure TTFB at 0.3 / 0.5 / 1.0s and record the chosen value in Findings.
  **TTFB is the objective, automatable leg; "audio quality" is a MANUAL listening check recorded in
  Findings, NOT an automated acceptance gate** (no metric/threshold is defined for it). The automated
  backend test asserts only the single locked TTFB-driven `streaming_interval` value (below) plus a
  no-NaN / no-clipping sanity check on a decoded chunk; the subjective quality judgement gates the
  human's choice of value, not CI. The interval bounds *added buffering* latency, not absolute TTFB.
- [ ] EOF stays keyed off **generator exhaustion**, not `.is_final_chunk`. **Observed (0.4.4 source
  read, NOT script-verified — the committed `verify_mlx_tts_api.py` checks only field *presence*, not
  the set-True behavior; `voxtral_tts.py:781-782`, line numbers approximate):** voxtral *appears to*
  set `is_final_chunk=True` on its last chunk — unlike Kokoro, which never sets it. **Correctness does
  NOT depend on this:** exhaustion handles both shapes, so no code change; the bridge contract holds
  across both. (Optional: add a `--load` assertion to `verify_mlx_tts_api.py` that drains a voxtral
  generator and inspects the last result's `.is_final_chunk` to upgrade this from observation to
  verified.) **`kyutai` is still not an mlx-audio TTS family**; `moss_tts*` is unrelated to
  Kyutai/Moshi.
- [ ] `_stream_util` bridge `maxsize`: `_BRIDGE_MAXSIZE=8` is a **module constant in `kokoro.py`**
  (passed into `stream_generate(maxsize=...)`), tuned for Kokoro's *few large* per-segment chunks;
  voxtral emits *many small* sub-segment chunks (~one per `streaming_interval`). **Each backend module
  declares its OWN `_BRIDGE_MAXSIZE`** with a streaming-cadence rationale, passed into the
  already-per-call `stream_generate(maxsize=…)` — the rule is *don't share the value*, **no
  `_stream_util.py` code change is implied** (the `maxsize` arg already exists); do not edit Kokoro's
  constant or copy its bound/comment verbatim.
- [ ] Tests:
  - **Lean (no mlx, `ToneBackend(streaming=True)`):** assert `capabilities()["streaming"] is True`
    and the `streaming:true` no-split client path.
  - **Bridge unit (lean, no mlx) — `is_final_chunk=True` EOF:** drive `_stream_util.stream_generate`
    **directly** with fake `GenerationResult`s whose last carries `is_final_chunk=True`, and assert
    EOF still comes from **generator exhaustion** (the flag is advisory). This CANNOT go through
    `ToneBackend` — `AudioEvent` carries only `{kind, pcm}` (`backend.py:47-48`), so the model flag
    never reaches it; the bridge is the only layer that sees `is_final_chunk`. (Closes the "both
    shapes" claim — the existing EOF guard only covers Kokoro's `is_final_chunk=False`.)
  - **Backend-unit (no model load):** assert `streaming_interval` is **not** in
    `capabilities()["extras"]` (it is backend config, not a client knob). For the *value* itself the
    assertion is **provisional and must cite the measured Findings value** — assert the backend's
    effective `streaming_interval` equals the value recorded by the measurement step (above), NOT a
    hard-coded `0.3 <= value <= 0.5` band: if measurement lands the floor at e.g. 0.7s, the test
    follows the measurement rather than contradicting it. The test asserts equality to the **single
    locked Findings value** (never a range); the `0.3–0.5s` band is only a pre-measurement placeholder,
    replaced by that one value in the same sub-phase.
  - **mlx-gated — sub-segment streaming proven at the NATIVE boundary, not the wire:** a wire
    `response.audio.delta` count is meaningless — the 20 ms re-chunker (`server.py::_run_drain`)
    splits even one large *non-streaming* native chunk into many 20 ms deltas, so "≥2 deltas" passes
    for a single Kokoro-style chunk. Instead spy on the backend's **native** yields (count
    `GenerationResult`/bridge chunks, or the stream's `events()` `"delta"` `AudioEvent`s) and assert
    **≥2 native chunks** for a single no-newline sentence — the structural difference from Kokoro
    (which yields once per `\n+` segment). The test MUST assert its input text contains **no newline**
    as an explicit precondition — an incidental `\n` would let a Kokoro-style multi-segment yield pass
    falsely and mask a non-streaming regression.

#### Phase 5b — `pocket_tts` (streaming + ref_audio negative guard) — do second
- [ ] `backends/pocket_tts.py`. VERIFIED signature: `generate(text, voice=None, ref_audio=None,
  temperature=None, verbose=False, stream=False, streaming_interval=2.0, frames_after_eos=None,
  **kwargs)`. Native streaming (**observed in 0.4.4 source, not script-asserted; `pocket_tts.py:285-318`,
  line numbers approximate** — yields per
  `interval_samples = streaming_interval * sample_rate`); imports cleanly in 0.4.4. `capabilities()`
  → `streaming:true`, extras `{temperature}` **only**. Apply the `streaming_interval` plumbing,
  `voice=None` rule, per-backend bridge `maxsize`, and small-interval measurement step from 5a.
- [ ] **Leave `ref_audio` AND `frames_after_eos` unwired** (decision 2 + undocumented param). This
  is the backend that exercises the decision-#2 negative guard — voxtral structurally cannot
  (it has no `ref_audio`).
- [ ] Negative-guard test — the load-bearing assertion is at the **backend layer, not end-to-end.**
  The server's `_validate_extras` (`server.py:614-646`) already drops any extra not in the advertised
  set *before* the backend, so an end-to-end client `extras={"ref_audio": ...}` never reaches
  `generate()` regardless of backend correctness — a spy on that path passes trivially and proves
  nothing. Instead: (1) assert `capabilities()["extras"]` **excludes `ref_audio`/`frames_after_eos`**;
  (2) call the backend's `open_stream(extras={"ref_audio": ..., "frames_after_eos": ...})`
  **directly** (bypassing server validation, exercising the backend's own last-defense filter —
  mirror Kokoro's at `kokoro.py:513-521`) and spy the `generate()` kwargs, asserting neither key
  appears — the real "cannot reach `generate()`" invariant, robust to a future unfiltered `**extras`
  refactor. Place in the already-lean-allow-listed `tests/test_capabilities_extras.py` (or add a new
  lean file AND extend the allow-list in the same commit — see *Per sub-phase*).
- [ ] **Streaming-flag assert:** `capabilities()["streaming"] is True`.
- [ ] **Re-run + extend the live smoke tests against a `streaming:true` backend** (after 5a and 5b
  land). `tests/smoke/` today only covers `streaming:false` backends (tone/Kokoro), so the steady
  sub-segment streaming cadence (R4) and the `streaming:true` client **no-split** path are never
  exercised end-to-end. Re-run `tests/smoke/run_smoke.sh --backend voxtral_tts`/`pocket_tts` and the
  multi-connection driver, and add a streaming-cadence assertion (deltas arrive at roughly
  `streaming_interval`, not all-at-end) plus a check that interleaving + BUSY + max-buffer still hold
  when audio streams incrementally. See `tests/smoke/README.md` → *Future work*.

#### Phase 5c — `dia` (dialogue, NON-streaming) — SPLIT OUT to its own plan (2026-06-25)
`dia` is no longer part of this v1 plan. It carries an **unsolved design** — the `[S1]`/`[S2]`
dialogue speaker-tag mapping changes the single-voice `open_stream(voice=…)` contract that 5a/5b
share — so it gets its own design + review + test lifecycle. Two `/review-plan` lenses (architecture,
spec-and-testing) recommended the split. See **`docs/dev_plans/20260625-feature-tts-dia-backend.md`**.
It follows the 5a/5b backend-add pattern below once its dialogue-mapping design is settled.

#### Per sub-phase (5a/5b)
- [ ] **Wire the backend into the resolver AND the CLI choices** in the same commit — two separate
  call sites, both required, or `--backend <new>` is dead end-to-end:
  (1) `tts_server/backends/__init__.py::make_backend` currently resolves only `tone`/`kokoro` and
  `raise ValueError` otherwise — add a **lazy-import** branch (mirror Kokoro's: import inside the
  branch, `mlx_audio` only in `start()`);
  (2) the argparse **`--backend choices` tuple** (`__main__.py:305`, today `("tone", "kokoro")`) —
  add the new name, else argparse rejects `--backend voxtral_tts|pocket_tts` before the resolver
  is ever reached (a passing `make_backend` unit test will NOT catch this).
  Add a **lean construction/lazy-import test** asserting the name is an accepted `--backend` choice,
  resolves via `make_backend`, and imports without `mlx_audio` present.
- [ ] **Per-backend `sample_rate` discovery** (R1/R3 rate contract): each backend must expose
  `sample_rate` after `start()`/load so `server.start()` (`server.py:400-437`, connect→load→hello)
  advertises the true model rate in `server.hello.audio.rate`; decouple it from warmup per R3. Add an
  mlx-gated test asserting `hello.audio.rate` equals the loaded model's rate **before any synth runs**
  (voxtral/pocket rates are per-model and unverified — Kokoro's is 24000; do NOT assume these match).
  The test MUST read the rate from `model.sample_rate` (the config property), **not** from a backend
  literal — otherwise a wrong hardcoded constant satisfies both sides of `hello == model` and the test
  passes while the advertised rate is wrong (R1 resample-correctness bug).
- [ ] Packaging/CI update in the **same commit** as each new backend: add the `pyproject.toml`
  optional dependency extra, and **switch the macOS job's sync to `uv sync --all-extras`** (do this
  once in 5a so it cannot drift per-backend) — the line is `.github/workflows/test.yml:84`
  (`uv sync --extra client --extra kokoro`), inside the **`test-macos-smoke`** job.
  **Ordering edge — 5a MUST merge before 5b:** the `--all-extras` flip lands only in 5a, so if 5b
  merged first the macOS smoke job would still sync just `--extra client --extra kokoro` and never
  install-smoke the new `pocket_tts` extra. 5a is the prerequisite that makes every later backend's
  extra install-smoked; conduct 5a → 5b in order (not in parallel worktrees). **Reality check
  (decided):** that job is an **import smoke that deliberately runs NO pytest**, so installing a new
  extra there does NOT run any backend synthesis test in CI — and that is **accepted, not a gap**:
  backend synth tests stay **local/mlx-gated only**, exactly as the Phase-2 Kokoro decision already
  established (Kokoro's synth tests don't run in CI either). So `--all-extras` here only proves the
  runner can *resolve/install* the extra (an install-smoke), it is not a synthesis-coverage path.
  Keep lean CI free of those heavy deps, and decide model-download/network gating (same constraint
  that made Phase 2 environment-gated; larger weights than Kokoro — confirm runner access before 5a).
- [ ] **If a sub-phase adds a NEW lean test file, extend the lean allow-list
  (`.github/workflows/test.yml:40-55`) in the same commit** (`pytest` errors on a missing
  allow-listed path — the discipline Phases 1–3 each followed). Folding the negative-guard assertion
  into the already-allow-listed `tests/test_capabilities_extras.py` avoids this edit.
- [ ] **Update the Phase-4 README/protocol-doc capabilities & extras table** for the new backend
  (they were Kokoro-only when first written) — including its `streaming` flag.
- [ ] **If Phase 6 (launchd ops) is already in place**, add the backend's `(label, port)` row to the
  justfile `_resolve` map + the README port-table row **in the same commit** — otherwise the Phase-6
  drift test (`tests/test_justfile_recipes.py`) goes red between phases. (If Phase 6 has not landed
  yet, skip this; Phase 6 adds the row when it lands.)
- [ ] **Re-verify the live `generate()` signature via `inspect.signature` before wiring** if the
  `mlx-audio` pin is bumped past 0.4.4 (R7/R8).

## Technical Specifications

### Wire events
> The full wire contract is written up in **`docs/protocol.md`** (authored 2026-06-24, ahead
> of implementation). Phase 1 implements `protocol.py` against that doc; the lightweight
> stdlib+`websockets` test client **`examples/reference_client.py`** speaks it and has been
> smoke-tested against a mock server (handshake → append → commit → 3 pcm16 deltas reassembled
> by `seq` → done → valid 24 kHz mono WAV). The summary below is the source of truth that
> `docs/protocol.md` expands; keep the two in sync.

**Client→server:** `session.update {voice?,model?,language?,audio_format?,extras?}` ·
`input_text.append {text,text_format?}` · `input_text.commit {voice?,language?,extras?}` ·
`input_text.clear` · `response.cancel {response_id?}` · `session.cancel` · `session.close` ·
`server.status`.
**Server→client:** `server.hello {protocol_version,backend:{name,model},audio:{format,rate,channels},capabilities}` ·
`session.created`/`updated` · `input_text.committed {response_id}` · `input_text.cleared` ·
`response.created {response_id}` · `response.audio.delta {response_id,seq,audio(base64 pcm16)}` ·
`response.audio.done {response_id,duration_ms}` · `response.cancelled`/`response.failed {response_id,error?}` ·
`server.status` · `error {code,message,retry_after_ms?}` (`retry_after_ms` present when `code==BUSY` — synthesis-backlog backpressure, R4).

### capabilities (server.hello) — Kokoro example, verified fields annotated
```jsonc
{ "streaming": false, "binary_audio": false,                  // rate is NOT here — canonical rate is hello.audio.rate (24000, VERIFIED); R1 client reads that
  "text_formats": ["plain"],                                   // ssml/ipa UNVERIFIED for Kokoro — plain confirmed; drop until checked
  "languages": ["en","ja","zh","fr","es","it","pt","hi"],     // VERIFIED as voice-prefix/lang_code mapping only via --load 2026-06-24: a:20,b:8→en, e:3→es, f:1→fr, h:4→hi, i:2→it, j:5→ja, p:3→pt, z:8→zh; full non-English long-text behaviour needs the Phase-2 language probe
  "voice_count": 54,                                           // VERIFIED via --load 2026-06-24 (54 distinct voices in mlx-community/Kokoro-82M-bf16)
  "extras": ["speed"],                                         // Kokoro effective set ONLY; temperature/instruct/cfg_scale/ddpm_steps are NOT Kokoro params
  "ideal_words": 40, "max_text_chars": 2000 }                  // ideal_words: soft target, client rounds UP to next sentence boundary; max_text_chars: hard server cap. Values are chosen defaults (not model facts).
```
Note: Kokoro's `language` maps to a single-letter `lang_code` (`a`/`b`=en, `e`=es, `f`=fr,
`h`=hi, `i`=it, `j`=ja, `p`=pt, `z`=zh) — the backend must translate the ISO `language` to
the letter. Treat this as a verified mapping, not proof that every non-English language has
equivalent long-text G2P/chunking behaviour; Phase 2 must probe short synth and long/newline-split
cases before the language list becomes a supported client contract. Other backends advertise
different `extras`/`rate`/`streaming` (pocket_tts is
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

### Streaming bridge (`backends/_stream_util.py`)
The single shared daemon-thread→`asyncio.Queue` bridge every streaming-capable backend uses
(Kokoro + `voxtral_tts` + `pocket_tts`), so "backend-agnostic" is enforced, not aspirational.
The interface (Phase 1 deliverable; Phase 0 ships a stdlib-only stub):
```python
async def stream_generate(
    gen_factory: Callable[[], Iterator[GenerationResult]],  # builds the blocking generate() generator
    *,
    loop: asyncio.AbstractEventLoop,
    metal_lock: threading.Lock,   # process-wide; held for the WHOLE generator-drain (see R3)
    cancel: threading.Event,      # set by TTSStream.cancel(); breaks the generator out
    maxsize: int,                 # bounded async queue; producer blocks/cooperates when full
) -> AsyncIterator[bytes]: ...    # yields int16-LE PCM per chunk; EOF sentinel ends iteration
```
A daemon thread acquires `metal_lock`, runs `gen_factory()`, converts each yielded
`GenerationResult.audio` (clipped and mapped per R3) to int16-LE PCM, and performs a
producer-side blocking/cooperative put into the bounded async queue; `call_soon_threadsafe` alone
is **not** sufficient because it schedules and returns without applying backpressure. The concrete
stdlib shape can be `asyncio.run_coroutine_threadsafe(queue.put(pcm), loop).result(timeout=...)`
with cancel/error handling, or an equivalent thread-safe queue plus async wrapper, but the invariant
is fixed: a full bridge blocks or cancels the producer, never drops chunks or schedules unbounded
callbacks. `cancel` breaks the generator out (releasing the lock so it is not pinned by a cancelled
response). **EOF is enqueued on generator exhaustion in a `finally`**, NOT keyed off `.is_final_chunk`
(Kokoro never sets that field — see R-note below; it is advisory only).
Kokoro yields
per-segment; `voxtral_tts`/`pocket_tts` yield intra-segment chunks — both feed the same queue
and nothing downstream changes. This is the one boundary `_thread_util` does **not** cross (it
marshals a single Future, not a per-chunk queue).

## Architecture & Call Flow

Five independently-executing components and the context that crosses each boundary. This
section is the contract for the streaming lifecycle. **This seam is net-new, not an stt
mirror.** stt's actual shape is *commit-then-drain*: `end()` blocks until full synthesis
(`stt_server/backends/parakeet.py` marshals a single Future via `_thread_util`) and `events()`
then replays a stored result. That shape is the **anti-pattern** here — it would violate both
client contracts (R1 rate, R4 steady stream). The TTS drain loop is therefore built from
scratch on `backends/_stream_util.py` (a per-chunk queue), **not** on `_thread_util`; the
Critical requirement is that `end()` returns before the first segment completes and `events()`
yields per segment as audio lands.

```
client ──ws──> session loop (server.py) ──> TTSStream (backend) ──> daemon worker thread
  ▲                  │  ▲                         │  ▲                    │ (Metal, serialized)
  │                  │  │                         │  │                    │ model.generate() yields
  │ response.audio.* │  │ 20 ms re-chunker        │  │ bounded bridge     │ GenerationResult per
  └──────────────────┘  └─────────────────────────┘  └── blocking/cooperative put ── segment (\n+)
```

**Components & triggers**
- **Client** drives the session: `session.update` → `input_text.append`* → `input_text.commit`.
  Owns device, resampling, buffering. Reads `hello.audio.rate` once.
- **Session loop** (`server.py`): the **recv loop** stays live for the whole connection so
  `response.cancel`/`session.*` are always serviceable. On `commit` it allocates a `response_id`,
  emits `response.created`, admits the commit into the **global synthesis scheduler** (bounded
  backlog, per-connection cap), opens a backend stream for the admitted work, and runs the **drain
  loop** (below) in a **tracked task** — NOT inline in the recv loop (mirror stt:
  `asyncio.create_task(self._run_decode(...))`
  held in `state.in_flight_task` + an `_active_decodes` set, `stt_server/server.py:568`). If the
  drain loop ran inline, synthesis would block recv and a cancel could never be read. **Outbound
  websocket writes are serialized through one writer/queue** (the recv loop and the drain task both
  produce frames), so there is a single component touching the socket while cancel can still interrupt
  active synthesis.
- **TTSStream** (`open_stream`): adapts one utterance. `feed(text)`/`end()` enqueue work;
  `events()` is an **async generator that yields `AudioEvent`s as segments land** — it does
  NOT wait for full synthesis. `cancel()` stops the worker.
- **Daemon worker thread** (per the stt Lock-pair + in-flight-drain pattern): runs the
  blocking `model.generate(...)` generator. Metal is not concurrency-safe, so a process-wide
  lock serializes generate calls. Each yielded `GenerationResult.audio` (float32 mono,
  clipped/mapped per R3) is converted to int16-LE PCM and pushed onto the bounded bridge with
  producer-side backpressure; the worker does not use bare `loop.call_soon_threadsafe(...)` as the
  data path. **EOF comes from generator exhaustion** (the worker enqueues
  the EOF sentinel in a `finally`), NOT from `.is_final_chunk`: that field exists in 0.4.4 but
  **Kokoro never sets it** — `kokoro.py` yields `GenerationResult(...)` with the field defaulting
  `False` (kokoro.py:345-367), so treating it as the EOF trigger would hang forever. `.is_final_chunk`
  is **advisory only**. **This is the boundary `_thread_util` does not cross** (it marshals one Future
  per call; streaming needs the per-chunk queue), so it lives in a **dedicated shared
  module `backends/_stream_util.py`** — one implementation that Kokoro and the streaming
  backends (`voxtral_tts`, `pocket_tts`) all use, so "backend-agnostic" is real and the
  backends cannot drift.
- **20 ms re-chunker**: lives in the session/drain layer, between the queue and the send
  loop. Slices native segment PCM into fixed 20 ms frames at `backend.sample_rate` so
  barge-in latency is bounded regardless of segment length. **Tail policy:** the final frame
  of a response MAY be short (no silence padding — padding would inject audible gaps the
  steady-stream contract forbids); `response.audio.done.duration_ms` is computed from the
  **original total sample count**, not from `frames × 20 ms`. The re-chunker re-frames the full
  per-response PCM stream, not each segment independently, so a segment whose length is not a
  multiple of 20 ms does not emit a short frame mid-response — only the response's last frame is short.

**Synthesis drain loop (the steady-stream contract, R4)**
1. `commit` → `response.created {response_id}`.
2. `await stream.feed(text)`; `await stream.end()` — **non-blocking**: `end()` signals
   end-of-input and kicks off the worker; it must NOT block until synthesis completes.
3. `async for ev in stream.events():` — for each segment that lands, push its PCM through
   the 20 ms re-chunker and emit `response.audio.delta {response_id, seq, audio}` **as it
   arrives**. First audio therefore ships after the *first* segment, not the whole utterance
   (lowers time-to-first-audio; keeps the client's 8192-frame buffer fed).
4. On **generator exhaustion** (not `.is_final_chunk`) → flush any short tail frame →
   `response.audio.done {response_id, duration_ms}` (`duration_ms` from the original sample count).

**Rate (R1)**: `hello.audio.rate` is read from `model.sample_rate` at connect (pre-warmup,
confirmed via `--load` 2026-06-24), is the *only* rate on the wire, and every `delta` frame is
int16-LE mono at exactly that rate — the re-chunker never resamples, so there is no
per-utterance drift. **Ordering edge (new vs stt):** because the rate is read from the loaded
model (stt uses a static `protocol` constant), the backend's `start()`/model-load MUST complete
before the first `server.hello` is sent — connect→load→hello, a dependency edge stt does not have.

**Cancel / barge-in (R4)**: `response.cancel {response_id}` → session sets a cancel flag,
calls `stream.cancel()` (best-effort stop at the next generator yield/segment boundary),
drains/clears the queue, and emits `response.cancelled {response_id}`. No further `delta` for that
`response_id` may be sent after `cancelled`. Because Kokoro yields only after a segment is generated,
promptness for long single-segment utterances is an **assumption to verify in Phase 2**, not a
paper guarantee; until measured, the hard guarantee is "no more deltas after cancelled" and the
latency target is yield-boundary best effort.

**Backpressure (two distinct queues plus one scheduler)**: (1) *Outbound* — if the client stops reading, the
per-connection send queue hits its high-water mark and the connection is **closed** (R4)
rather than buffering unboundedly; a stalled *reader* is a client bug. (2) *Inbound* — the
**global synthesis backlog** (commits waiting on the shared Metal lock across all
connections). When the bounded synthesis queue is full, a new `commit` is **rejected, not
enqueued**, with `error {code: BUSY, retry_after_ms}`; a per-connection in-flight cap (≤K
queued commits) stops one app from filling the queue. The recommended client response is
capped backoff + jitter, giving up after 5 retries (retry policy is outside the wire
contract; the queue cap protects the server regardless). This is distinct from a *server-side
synthesis stall*, which the steady-stream contract forbids. (3) *Scheduler* — the synthesis
backlog is the owner of fairness and lock acquisition: admitted commits are keyed by connection,
and a single dispatcher selects the next commit (round-robin across non-empty per-connection
queues for v1) before creating/running the worker that acquires `metal_lock`. Independent daemon
threads must not race directly for `metal_lock`; that would make fairness a side effect of OS
scheduling rather than the server contract.

**Multi-connection isolation & fairness**: each connection has its own `_SessionState` (no
shared mutable state → no cross-connection text/audio pollution). The model + Metal lock are
shared, so the **commit is the unit of scheduler selection and lock-holding**. The dispatcher
round-robins admitted commits at connection boundaries before worker creation; per-commit
`ideal_words` sizing (decision #6) bounds head-of-line blocking so a long commit on connection A
delays connection B's *first audio* by at most ~one already-selected commit.

**Topology note**: only `voxtral_tts`/`pocket_tts` add a sub-segment streaming layer (native
`stream`/`streaming_interval`); for them the worker yields intra-segment chunks into the same
queue, and nothing downstream of the queue changes. The session loop, re-chunker, and send
path are backend-agnostic.

## Testing Notes
- `ToneBackend` makes Phase-1 fully deterministic with **no mlx dependency** — protocol,
  re-chunking, cancel, and the lean-base import-safety test all run in plain CI.
- Kokoro tests are marked/skipped when mlx or Apple Silicon is absent.
- Assert the 20 ms re-chunker emits uniform frame sizes from both a single-chunk
  (non-streaming) and multi-chunk (simulated streaming) backend. **Tail policy:** feed a
  total PCM length that is **not** a multiple of 20 ms and assert every frame except the
  **last** is exactly 20 ms, the last MAY be short, **no silence padding** is added, and
  `response.audio.done.duration_ms` equals the original-sample-count duration (not
  `frames × 20 ms`).
- **EOF without `.is_final_chunk`:** with a `ToneBackend` that yields all chunks with
  `is_final_chunk=False` (the Kokoro shape — Kokoro never sets it), assert `response.audio.done`
  still fires on generator exhaustion (regression guard against keying EOF off the flag).
- **Cancel during active synthesis:** assert `response.cancel` is acknowledged *while a
  response is mid-synthesis* (the recv loop is not blocked by the drain task) — drive a
  slow/delayed `ToneBackend`, send `cancel` before synthesis completes, and assert
  `response.cancelled` arrives promptly with no further `delta`.
- **Rate-exactness:** assert every `response.audio.delta` frame's implied rate matches
  `hello.audio.rate` and is constant across a multi-segment utterance (a `ToneBackend`
  with a fixed rate makes this deterministic in plain CI).
- **Steady streaming / no jitter starvation:** with a `ToneBackend` whose segments
  complete with an injected delay, assert first audio arrives before the whole utterance
  is synthesized (time-to-first-frame << total synth time) and that the send loop is not
  blocked between segments — i.e. `events()` yields per segment, it does not buffer the
  full utterance then flush. Also assert an **inter-`delta` gap bound** with a deterministic
  fixture: configure `ToneBackend` for at least 3 segments with `segment_delay_ms=120`; after the
  first `delta`, the max gap between consecutive `response.audio.delta`s for that response must be
  `<= segment_delay_ms + 50ms` on the test loop, and the test must fail if the backend buffers all
  segments then flushes. This is the "no burst-then-gap" half of the steady-stream contract and the
  actual underrun/croak cause (a passing first-audio test does not by itself catch a mid-stream gap).
- **Multi-connection isolation & fairness:** with two concurrent connections on a
  delayed `ToneBackend`, assert (a) their `response.audio.delta` streams **never intermix**
  (each `response_id` belongs to exactly one connection; bytes are not interleaved across
  sessions) and (b) a long commit on connection A delays connection B's **first audio** by
  at most one already-selected commit (the scheduler dispatches round-robin at commit granularity),
  not by A's full utterance or by whichever daemon thread wins the OS lock race.
- **Backpressure:** drive the global synthesis queue past its cap and assert the next
  `commit` gets `error {code: BUSY, retry_after_ms}` and is **not** synthesized; assert a
  per-connection in-flight cap rejects a connection's (K+1)th queued commit while others
  still get served. Fill the backend→session bridge queue and assert the producer blocks or exits
  via cancel/error rather than dropping chunks or scheduling unbounded callbacks. (Distinct from
  the send-queue high-water *close* test under R4.)

## Acceptance Criteria
- `python -m tts_server serve --backend kokoro` serves; `status` prints backend/model/rate.
- A client synthesizes text → non-empty PCM16 frames at the advertised rate; `response.cancel`
  stops the deterministic Tone path promptly and produces no further deltas after
  `response.cancelled`. Kokoro long-segment cancellation latency is measured in Phase 2 and either
  meets the barge-in target or is documented as yield-boundary best effort with client chunking.
- **Rate contract:** every emitted frame is int16-LE mono at exactly `hello.audio.rate`,
  constant across the whole utterance (no per-utterance drift).
- **Steady-stream contract:** for a multi-segment utterance, first audio reaches the client
  before full synthesis completes, and audio is delivered continuously (no burst-then-gap —
  asserted via the inter-`delta` gap bound in Testing Notes) so the client playback buffer
  never starves.
- Base install (no `kokoro` extra) imports and runs the Tone path; no mlx at import time.
- Lean/base runtime code does not import dev-only `numpy`; Kokoro module import stays lazy with
  `mlx_audio` absent.

## Decided defaults (locked so `/conduct` doesn't fork; revisit only if a phase surfaces a reason)
1. Audio framing: **base64-in-JSON** for v1 (advertise `binary_audio:false`; binary is a later optimization).
2. Event naming: **`response.audio.*`** (OpenAI-Realtime-aligned).
3. Wire frame size: **20 ms**.
4. Voices: **count in hello, full list via `status`**.
5. Repo: dev on `vr000m/pipecat-local-tts-server`; PR to `pipecat-ai/` upstream later.

## Conduct Readiness
Closest of the two to conduct-ready:
1. **Reviewed** via `/review-plan` (2026-06-24): 28 findings across five lenses, all folded in
   — runtime mlx-audio facts confirmed via `--load` + `prosody_check.py`, the streaming seam
   reframed as net-new (not an stt mirror), `_stream_util` interface specified, and the
   protocol-detail test gaps (`seq`, clip invariant, `audio_format`, `session.cancel/close`)
	   added. A follow-up **Codex adversarial pass** (2026-06-24) added 5 more, incl. 2 Critical
	   verified against source: the drain loop must run in a **tracked task** (not inline in the recv
	   loop, else cancel can't be serviced — stt `server.py:568`), and EOF must come from **generator
	   exhaustion** (Kokoro never sets `.is_final_chunk` — `kokoro.py:345-367`). A second
	   `/review-plan` pass on 2026-06-24 found 14 more issues; all are now folded in: Phase-1/3
	   cleartext sequencing, exact `audio_format` ownership, asymmetric PCM16 mapping, stdlib-only
	   Tone/pcm16 runtime, full-extra CI verification, Kokoro cancel/language verification,
	   scheduler-owned fairness, bridge backpressure, Phase-5 packaging/CI, and concrete
	   steady-stream gap tests. A **third `/review-plan` pass (2026-06-25)**, focused on Phase 5 conduct-readiness, folded in the 5a-before-5b ordering edge, the audio-quality manual-check reframing, the un-script-verified mlx-audio claims relabelled "observed in 0.4.4 source" (voxtral `is_final_chunk`, cadence formula, external line numbers), the Kokoro `voice`-omit wording, the native ≥2-chunks no-newline precondition, and refreshed in-repo line numbers; **`dia` (formerly 5c) was split into `20260625-feature-tts-dia-backend.md`** (unsolved dialogue-tag design). Its review marker is the
	   `/conduct` readiness signal.
2. Phases 0–5a/5b are drafted with per-phase acceptance tightened in review (mlx-gated Kokoro
   tests vs lean CI split; numpy in the `dev` group; per-phase allow-list extension); `dia` lives in
   its own plan (`20260625-feature-tts-dia-backend.md`).
3. This plan has **no external blocker** — it can be conducted first; the gamealerts plan
   depends on its Phases 0–2.

### Autonomous conduct
This plan is structured to be conducted end-to-end with no human-in-the-loop gate through
Phase 3:
- **Branching/commits:** one feature branch per phase off `main`; each phase ends at a green
  commit. The **lean CI job must pass at every commit** (it is the markdown-plan analog of
  "tests pass") — that is the per-phase done-check, alongside each phase's acceptance bullets.
- **No open decisions block Phases 0–3.** All forks are locked in *Decided defaults* and the
  *Locked design decisions*; the one deferred item ("division of labour … settled with
  gamealerts") is a Phase-4 integration nicety, not a Phase 0–3 dependency, and v1 has a safe
  default (newline-join one commit).
- **Phase 2 is the only environment-gated phase:** Kokoro synth tests need Apple Silicon +
  model weights/network. They are **off the lean allow-list** (no runtime skip-markers), and
  Phase 0's CI note requires proving the full job can `uv sync` the extras / marking Kokoro
  tests manual-or-gated if the runner lacks model access. A conductor without Apple Silicon
  can complete Phases 0/1/3 (all lean, `ToneBackend`-only) and leave Phase 2's mlx-gated tests
  to the full job.
- **Contracts are pre-authored:** `docs/protocol.md` is the wire spec Phase 1 implements
  against; `examples/reference_client.py` is a runnable oracle (validated against a mock) for
  manual end-to-end checks once the server is up — so the conductor implements to a written
  contract rather than re-deriving it.

## Companion plans
- gamealerts client/integration work: `gamealerts/docs/dev_plans/20260624-feature-tts-server-client-integration.md`.
- `dia` dialogue backend (formerly Phase 5c, split out 2026-06-25):
  `docs/dev_plans/20260625-feature-tts-dia-backend.md`.

<!-- reviewed: 2026-06-25 @ 2cf9eb4b97b5cc727db57856d3c622142a30ca23 -->

## Progress

- [x] Phase 0: Scaffold — committed d56d502 (import-safety 12 passed, ruff clean)
- [x] Phase 1: Protocol + Tone end-to-end — committed (70 lean tests pass, ruff clean)
- [x] Phase 2: Kokoro backend — committed (80 lean + 5 mlx-gated tests pass; live synth verified)
- [x] Phase 3: Ops parity with stt — committed (103 lean tests pass; scheduler/auth/backpressure verified)
- [x] Phase 4: Reference adapter + docs — committed (pipecat adapter, README, protocol.md reconciled)
- [ ] Phase 5: More streaming backends — 5a `voxtral_tts`, 5b `pocket_tts` (5a before 5b). `dia` (formerly 5c) split to `20260625-feature-tts-dia-backend.md`.
- [x] Post-v1 ops: operator `justfile` (`tts-list`, `tts-status`) — mirrors the stt justfile; smoke-tested with a live tone server. Launchd install/enable/disable/uninstall recipes deferred (no tts install path yet — see *Operator justfile (post-review)* below).

## Findings

### Phase 2 measured results (Apple Silicon, mlx-audio 0.4.4, Kokoro-82M-bf16)
- **Kokoro long single-segment cancellation latency ≈ 51 s** (measured 2026-06-24, arm64). Kokoro yields a no-newline segment as ONE delta only at the END of `generate()`, and the bridge checks the cancel flag at the per-result boundary — so a single-segment cancel cannot take effect until `generate()` completes. This confirms the plan's documented **"yield-boundary best effort"** limitation: long single-segment cancellation far exceeds any barge-in target. **Resolution (per plan R3/Phase-2 fallback): the client MUST chunk at sentence/newline boundaries for Kokoro to get prompt barge-in.** The server's hard guarantee remains "no more deltas after `response.cancelled`" (asserted in tests).
- **mlx-audio 0.4.4 `broadcast_shapes` bug:** a very long single segment (~542k samples) and certain short inputs (e.g. "Warm up") trip an internal `broadcast_shapes` error inside Kokoro `generate()`, unrelated to our code. Warmup is therefore best-effort (caught/logged/non-fatal) and uses the verified-safe phrase "Hello there."; rate discovery is independent of warmup per R3.
- **Packaging fix:** Phase 0's `kokoro` extra was missing `misaki[en]` (R3's G2P dep, lazily imported by mlx-audio 0.4.4 so not a transitive hard dep). Added in Phase 2; `mlx-audio==0.4.4` pin kept.

### Phase 3 notes
- **Send-queue high-water guard — trippability over loopback (stt-parity limitation):** the outbound send-queue high-water *close* logic is correct and unit-tested deterministically (a fake connection reporting `pending > high_water` → `state.closed`, `ws.close(1011, "send_queue_overflow")`, overflowing frame dropped). BUT over loopback the drain blocks inside a single `await ws.send()` while the kernel/asyncio absorbs the bytes, and the guard only samples `transport.get_write_buffer_size()` *before* each send — so a never-reading raw client is not actually closed (buffer reads 0 during the in-progress send). **This matches the stt reference exactly** (same guard, no live-socket trip test there); the plan says "mirror stt". Future hardening (if a true end-to-end stall-close is needed): re-check the buffer while a send is in progress, or bound buffering differently. Recorded, not fixed (out of v1 mirror scope).
- Phase 3 mid-phase review: scheduler/auth/concurrency invariants verified sound (single-dispatcher Metal-lock serialization, fair round-robin, no lost-wakeup, no starvation, no slot double-free). One Minor cosmetic finding (redundant `except` tuple in `_SynthScheduler.stop()`) left as advisory.

### Phase 5 signature verification (pre-implementation, 2026-06-24, arm64, mlx-audio 0.4.4)
Ran `inspect.signature` on the live `Model.generate` callables + source read (supersedes the
earlier source-regex survey; satisfies R7's "re-verify via `inspect.signature` before wiring").
- **All extras assertions confirmed:** kokoro `{speed}`, voxtral_tts `{temperature, top_k, top_p}`,
  pocket_tts `{temperature}`, dia `{temperature, top_p}`.
- **voxtral_tts & pocket_tts are genuine sub-segment streamers** (native `stream`/`streaming_interval`,
  confirmed yielding incrementally in source). **dia is NOT** — no `stream` param, uses
  `split_pattern` like Kokoro → `streaming:false`.
- **`streaming_interval` default 2.0s is too coarse** — first chunk lands after ~2s of audio
  (mechanism verified; the 20 ms re-chunker cannot lower TTFB). It is a backend config, not a client
  extra. ≈0.3–0.5s is a **starting estimate, not measured** — the plan now requires measuring TTFB +
  audio quality before locking a default (see Phase 5a measurement step).
- **voxtral *appears to* set `is_final_chunk=True`** on its last chunk (Kokoro never does) —
  **observed in 0.4.4 source, not script-verified** (`verify_mlx_tts_api.py` checks only field
  *presence*). EOF-on-exhaustion handles both shapes, so no bridge change and correctness does not
  depend on it.
- **Undocumented params to keep unwired:** pocket_tts `frames_after_eos`; dia `ref_text` (in
  addition to `ref_audio`). Negative-guard tests must cover these.
- **Backend split rationale confirmed:** voxtral has no `ref_audio` (can't test decision-#2 guard);
  pocket_tts/dia do (they exercise it). → Phase 5 split 5a voxtral / 5b pocket / 5c dia.

### Phase 5 plan review rounds (2026-06-24, pre-implementation)
Two review passes on the revised Phase 5 section; all findings folded into the plan body above.
- **`/review-plan` (5 lenses):** 15 findings (0 Critical at plan level, 2 Critical test gaps, 9
  Important, 4 Minor); codebase-claims clean (78/78 references verified). Folded: `streaming_interval`
  plumbing as a per-backend module constant; `voice=None` must be omitted from `generate()`; the
  ~0.3–0.5s default reframed as an unmeasured estimate + measurement step; two-layer negative-guard
  tests; `streaming:true/false` advertisement asserts; `ToneBackend` streaming ctor param; per-backend
  bridge `maxsize`; macOS CI `--extra` flip / `--all-extras`; lean allow-list extension; EOF
  `is_final_chunk=True` test.
- **Codex adversarial pass:** 5 Important findings, all verified against code and folded:
  (1) sub-segment streaming must be asserted at the **native** chunk boundary — wire-delta count is
  meaningless because the 20 ms re-chunker splits one big chunk into many deltas; (2) negative-guard
  test must call `open_stream(extras=...)` **directly** — `_validate_extras` (`server.py:614-646`)
  drops unadvertised extras before the backend, so the e2e path proves nothing; (3) the
  `is_final_chunk=True` EOF test must drive `_stream_util.stream_generate` directly — `ToneBackend`
  can't carry the flag (`AudioEvent` is `{kind, pcm}` only); (4) per-backend `sample_rate` discovery
  before `server.hello` is unstated (rates are per-model, unverified); (5) new backends must be wired
  into `make_backend` (resolves only `tone`/`kokoro` today) + a lean construction test, else
  `--backend voxtral_tts|…` is dead end-to-end.

### Phase 1 mid-phase review (advisory, deferred to later phases)
- **[Phase 2]** `backends/_stream_util.py` EOF sentinel is enqueued via `loop.call_soon_threadsafe(queue.put_nowait, _EOF)`; if the consumer broke out early (cancel) leaving a full queue, `put_nowait` raises `QueueFull` inside the loop callback (logged, benign — Metal lock still releases, no hang). The bridge cancel path is first exercised by Kokoro in Phase 2 — harden the EOF put there (swallow `QueueFull` / drain-then-put).
- **[Phase 4 — RESOLVED]** `server.py` emits a `session.closed` event (reason `client_cancel`/`client_close`) on `session.cancel`/`session.close`. `docs/protocol.md` §5 now lists `session.closed {session_id, reason}` — reconciled in Phase 4.
- **[Phase 3]** In-flight commit rejection (K=1) currently uses `ErrorCode.INVALID_EVENT`; when Phase 3 wires `BUSY`/`retry_after_ms`, map the in-flight/backlog rejection to the right code.

## Operator justfile (post-review)

Added after the reviewed contract, so it lives here in the workspace rather than in the
Implementation Checklist (keeps the `<!-- reviewed -->` hash valid). Mirrors the sibling
`pipecat-local-stt-server/justfile`. macOS / `launchctl` only.

### Shipped now (read-only recipes — work against any running server)
- **`default`** — `just --list`.
- **`tts-list`** — sweep `~/Library/LaunchAgents/pipecat.tts-server*.plist`, print state/pid via
  `launchctl print`, and for the canonical label (`pipecat.tts-server` → `~/Library/Caches/pipecat-tts/tts.sock`)
  probe the live backend with `python -m tts_server status`. Because the TTS server has **no launchd
  install path yet**, the recipe also falls back to probing the canonical ad-hoc socket directly, so a
  server started by hand (README quick-start) still shows up. Read-only sweep — always exits 0.
- **`tts-status [socket]`** — wraps `python -m tts_server status --socket-path <socket>`; defaults to
  the canonical `tts.sock`. Exits with the probe's own status (mirrors stt's behaviour).
- Smoke-tested 2026-06-24 (arm64): `just tts-list` correctly reports "no agents" with no server, and
  surfaces an ad-hoc tone server (`live: tone`) when one is running; `tts-status` prints the full status block.

### Phase 6 — launchd ops parity + port-per-backend (PLANNED; not yet reviewed/conducted)
Status: spec lives in the workspace (below the `<!-- reviewed -->` marker) so it does **not** claim
review coverage it hasn't had and does not perturb the Phase 0–5 contract hash. **Before conducting:
promote this into the Implementation Checklist and run `/review-plan` (refresh the marker) — same
discipline applied to Phase 5.**

**Goal.** Run each backend as its own launchd **user agent** bound to a canonical **loopback port**,
with `just` wrappers for the full lifecycle (install/enable/disable/start/stop/uninstall) on top of
the read-only `tts-list`/`tts-status` that already ship. Mirrors the sibling stt ops surface
(`scripts/install_stt_agent.sh` + `render_stt_plist.py` + `stt-install/enable/disable/uninstall`),
which the TTS repo deliberately omitted until an install path existed.

**Substrate is already complete — Phase 6 is glue, not server changes.** VERIFIED 2026-06-24:
- `serve` host+port binding works (`server.py:403-406` `ws_serve(host=…, port=…)`;
  `ServerConfig` accepts `host+port` as a valid endpoint, `server.py:150`).
- `status` is already port-capable (`_add_endpoint_flags(p_status, include_uri=True)`,
  `__main__.py`), so `python -m tts_server status --host 127.0.0.1 --port 8765` works today.
- `127.0.0.1` is loopback (`env.py:24`), so port binding does **not** trip the cleartext-remote
  auth warning. No server code changes are needed.

So the two example commands the convention targets work the moment the backend exists + is in the
`--backend` choices tuple:
```
python -m tts_server serve --backend kokoro     --host 127.0.0.1 --port 8765
python -m tts_server serve --backend pocket_tts --host 127.0.0.1 --port 8965   # after Phase 5b
```
(`pocket`, not `pocket_tts`, and the missing `--backend` choice are why the second line fails today.)

**Canonical `backend → (label, host, port)` map** (chosen defaults; ports on `127.0.0.1`):

| backend | label | port |
|---|---|---|
| tone | `pipecat.tts-server.tone` | 8665 |
| kokoro | `pipecat.tts-server.kokoro` | 8765 |
| voxtral_tts | `pipecat.tts-server.voxtral_tts` | 8865 |
| pocket_tts | `pipecat.tts-server.pocket_tts` | 8965 |
| dia | `pipecat.tts-server.dia` | 9065 |

The **Unix socket stays the default** for a single ad-hoc server / README quick-start
(`pipecat.tts-server` → `tts.sock`); **ports are the multi-backend convention.** This **resolves the
old open question** ("does `tone` get its own canonical label?"): with ports making multi-agent the
norm, `tone` gets its own agent (a dependency-free smoke agent) at 8665.

**One `serve` process = one backend = one port.** `make_backend` resolves a single backend per
process (`backends/__init__.py`), so a model is never shared across backends in one server —
multi-backend means *multiple agents*, one per row above. The `voxtral_tts`/`pocket_tts`/`dia` rows
are **conducted only after their backend lands** (`voxtral_tts`/`pocket_tts` with Phase 5a/5b; the
`dia` row waits on its own plan, `20260625-feature-tts-dia-backend.md`); a top-to-bottom conductor
must not stand up an agent for a backend that has no `--backend` choice yet.

**Impl files**
- `scripts/render_tts_plist.py` — emits a user-agent plist: `Label`, `ProgramArguments`
  (`… python -m tts_server serve --backend B --host H --port P [--model M] [--auth-token-file F]`),
  `RunAtLoad=true`, `KeepAlive=true`, `StandardOutPath`/`StandardErrorPath` under
  `~/Library/Caches/pipecat-tts/logs/<label>.{out,err}`.
- `scripts/install_tts_agent.sh` — port of the stt installer; env-keyed `PIPECAT_TTS_LABEL` /
  `PIPECAT_TTS_BACKEND` / `PIPECAT_TTS_HOST` / `PIPECAT_TTS_PORT` / `PIPECAT_TTS_MODEL`; renders the
  plist → `~/Library/LaunchAgents` → `launchctl bootstrap gui/$uid`.
- `justfile` — a `_resolve <backend>` map yielding `(label, host, port)`, plus recipes
  `tts-install/uninstall/enable/disable/start/stop <backend>` (lifecycle = `launchctl
  bootstrap`/`bootout`, `enable`/`disable`, `kickstart -k`/`kill`, mirroring stt). Extend `tts-list`
  and `tts-status` to be **port-aware** via the map (`status --host/--port`) — today both are
  socket-only (`justfile:54,95`).

**Auth note.** Loopback ports need no token. A non-loopback bind MUST set `PIPECAT_TTS_AUTH_TOKEN`
via `--auth-token-file` in the plist (the cleartext-remote guard warns otherwise).

**Drift guard.** Add a README "Per-backend port convention" table and
`tests/test_justfile_recipes.py` asserting README table ↔ justfile `_resolve` map ↔
`render_tts_plist.py` defaults agree (the stt repo's drift test is the model). Point
`la_dir`/`cache_dir` at a temp `$HOME`, as the stt tests do.
**Scope at Phase-6 merge:** the drift test asserts exactly the backends present in the `--backend`
choices tuple **at merge time** — not a hardcoded `tone`/`kokoro` pair. If Phase 6 lands before any
Phase-5 backend, that set is just `tone`/`kokoro`; **if 5a/5b merged first, Phase 6 MUST seed their
rows too** (read the choices tuple as the source of truth so an already-merged `voxtral_tts`/`pocket_tts`
is not silently missing a `_resolve`/README/plist row). Each of 5a/5b **extends the test** (and the
table + `_resolve` map) with its own row in the same commit it lands (see the Phase-5 per-sub-phase
checklist). The test must not assert rows for backends not yet in the choices tuple, or it goes red between phases.
Test command: `uvx pytest tests/test_justfile_recipes.py -v`.

**Sequencing — Phase 6 does NOT block on Phase 5.** It needs only the serve binding (exists) + a
backend module. It can be conducted right after Phase 4 for `tone`/`kokoro`; each Phase 5 backend
adds exactly one map row + one README row + one `--backend` choice when it lands. (Numbered 6 for
ordering, but independent of 5.)

**Pre-promotion verify (launchd is ported on faith).** Phase 6 ports the stt installer/plist
mechanism (`RunAtLoad`/`KeepAlive`/`bootstrap`/`bootout`/`kickstart`) assuming it works; those are
launchctl environmental facts, not code we can unit-test. Before conducting, **confirm the existing
stt agent actually comes up under `RunAtLoad`** (one `launchctl print gui/$uid/<stt-label>` showing
`state = running` + a pid) so the port rests on observed behaviour, not plist keys alone.

**Acceptance (install/lifecycle is manual-only — NOT CI-covered).** Only the drift test is automated;
the lifecycle below is an **operator/manual check** (it bootstraps real launchd agents and binds
ports, which CI does not do). `just tts-install kokoro` loads the agent; `RunAtLoad` brings it up on
`127.0.0.1:8765`; `just tts-list` shows running + pid; `just tts-status kokoro` prints
`backend=kokoro` + rate; `tts-stop`/`tts-disable`/`tts-uninstall` tear it down cleanly; the drift
test is green; lean CI is unaffected (recipes/scripts are not python runtime).
