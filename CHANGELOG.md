# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

First release of `pipecat-local-tts-server` — a standalone, local WebSocket
**text-to-speech** server, client, and pluggable mlx-audio backends mirroring the
sibling [`pipecat-local-stt-server`](https://github.com/vr000m/pipecat-local-stt-server).
Not yet tagged or published; landing here as it is validated.

### Added

- **WebSocket TTS server** (`tts_server.server`, `python -m tts_server serve`) —
  text in, int16-LE mono PCM audio out over a Unix domain socket or loopback TCP.
  Streams `response.audio.delta` frames (base64 pcm16, gapless `seq` from 0) ending
  in `response.audio.done`; `response.cancel` for barge-in.
- **Wire protocol v0.1** — OpenAI-Realtime-inspired JSON message subset, fully
  specified in [`docs/protocol.md`](docs/protocol.md). Client drives the session
  (`session.update` → `input_text.append`* → `input_text.commit`); the commit is
  the unit of work. Per-backend `server.hello.capabilities`.
- **Kokoro backend** (`tts_server.backends.kokoro`, behind the `[kokoro]` extra) —
  mlx-audio on Apple Silicon, lazy-imported so the lean base never pulls
  mlx/torch/spacy. Verified against `mlx-community/Kokoro-82M-bf16` (mlx-audio
  pinned to `0.4.4`): 24000 Hz, 54 voices, languages
  `en/ja/zh/fr/es/it/pt/hi`, `speed` extra.
- **Tone backend** — stdlib-only (no numpy at runtime) reference/test backend that
  emits a deterministic tone; exercises the full protocol without a model.
- **Async client** (`tts_server.client.TTSClient`) — speaks the wire protocol,
  resamples model-rate → device-rate off the single `server.hello.audio.rate`.
- **CLI** — `serve` (run the server) and `status` (handshake + `server.status`
  snapshot: backend, model, audio format/rate, capabilities, queue depth, voice
  list, buffered chars, uptime, pid; non-zero exit if unreachable).
- **Endpoint resolution** — precedence **URI > socket > host+port** for both server
  and client; `TTS_WS_*` env vars mirroring `STT_WS_*`.
- **Optional bearer auth** — server reads `PIPECAT_TTS_AUTH_TOKEN`; client reads
  `TTS_WS_TOKEN` (no fallback to the server's env var). Token-less server on a
  non-loopback TCP address logs a cleartext-remote warning.
- **Operator `justfile`** — read-only `tts-list` and `tts-status` recipes
  (macOS/launchctl) mirroring the stt operator surface.
- **Examples** — `examples/reference_client.py` (stdlib + `websockets` oracle that
  writes reassembled audio to a WAV) and `examples/pipecat_tts_service.py`
  (`LocalTTSService`, a reference Pipecat-framework `TTSService` adapter, behind the
  `[examples]` extra).
- **Test suite** — protocol, streaming/cancel, backpressure, resource limits,
  multi-connection fairness, session lifecycle, Kokoro backend + lazy import,
  config validation, endpoint resolution, import safety, cleartext guard, and
  tone end-to-end coverage.

### Security

- **`voice` is validated against the advertised voice list** (`session.update`
  and `input_text.commit`), mirroring `language`. An unvalidated voice reached
  mlx-audio's loader, which treats a `*.safetensors` value as a filesystem path
  (arbitrary-file load) and otherwise triggers a Hugging Face download
  (client-driven network egress); both are now rejected with `invalid_config`.
  The check **fails closed**: when a backend advertises voices (`voice_count` >
  0) but cannot enumerate them (e.g. Kokoro's discovery fallback returns a count
  with an empty name list), a client-supplied voice is rejected rather than
  waved through — the client must omit it and take the server default. Only a
  backend with no voice concept at all skips the check. Membership is checked
  against a `frozenset` cached after `start()` (O(1) on the per-commit path).
- **`speed` extra is bounded** — finite values are clamped to `[0.5, 2.0]` and
  non-finite (`NaN`/`inf`) or non-numeric values are rejected, so a degenerate
  rate can no longer drive very-long synthesis while holding the Metal lock. The
  rejection happens at the `session.update` / `input_text.commit` boundary (via
  the optional `validate_extras` backend hook) as `invalid_config`, **before** a
  scheduler slot is consumed — instead of raising deep inside `open_stream` and
  surfacing as a misleading `backend_error` after the commit was dispatched.

### Changed

- **Optional backend capabilities are now explicit protocols** (`SupportsVoices`,
  `SupportsWaitClosed`, `SupportsExtrasValidation`) checked via `isinstance`,
  instead of methods declared on the base protocol but accessed through `getattr`.
  `SupportsWaitClosed.wait_closed` takes an optional `timeout`.
- **`make_backend` raises `ValueError`** (not `SystemExit`) for an unknown
  backend name; the CLI translates it to a clean exit. The default server backend
  is built through `make_backend("tone")` so the server depends only on the
  abstract protocol types.
- **Client checks `server.hello.protocol_version`** and warns on a mismatch
  (protocol §8 SHOULD).
- **`examples` extra pins `pipecat-ai==1.4.0`** (same policy as the `mlx-audio`
  pin) — the reference adapter overrides pipecat's read-only `sample_rate`
  property by writing its private `_sample_rate` backing field (no public
  post-handshake setter), so a version skew could silently mis-negotiate the
  audio rate. `LocalTTSService._update_sample_rate` now guards the write and
  raises loudly if the field is gone, and a dedicated `test-examples` CI job runs
  the adapter tests against the pinned version in isolation (importing pipecat
  pulls numpy/audioop, which would pollute the lean job's import-safety
  invariants).

### Fixed

- **`session.close` drain timeout now covers synthesis, not queue waiting** — a
  commit still queued behind other connections' work is given the drain budget
  for its actual synthesis (waiting for dispatch first), instead of being
  cancelled for head-of-line waiting it did not control. The two phases each get
  their own `drain_timeout_seconds` budget (so a long queue wait does not eat the
  synthesis budget), so worst-case close latency is up to 2× that timeout.
- **Terminal EOF enqueue no longer truncates a slow consumer's audio tail** — on
  normal exhaustion the bridge enqueues EOF with full backpressure (never drops a
  buffered chunk), however slow the consumer is. The put is not pinned: it
  re-polls the cancel flag every `_PUT_TIMEOUT_SECONDS`, and the consumer's
  `finally` sets cancel on any teardown (break / exception / `aclose` / async-gen
  finalization), so an abandoned consumer still releases the daemon worker. (An
  earlier attempt-bounded EOF put could drop the tail of a merely-slow consumer.)
- **Kokoro vocoder `broadcast_shapes` bug** — worked around an upstream mlx-audio
  defect (mlx-audio [#803](https://github.com/Blaizzy/mlx-audio/issues/803)) via a
  scoped vocoder-fix shim.
- Drain-after-close lock pinning and a bridge double-put race in the server;
  deduplicated the error object; capped caches; dropped dead fields
  (code-review + Codex adversarial review findings).
- **Cancelled synthesis no longer under-reports busy capacity** — the dispatcher
  now waits for the backend worker to exit and release the process-wide Metal
  lock before freeing a commit's scheduler slot. Previously a cancelled-but-still-
  draining Kokoro `generate` could keep the lock until its next yield boundary
  while admission / `queue_depth` advertised free capacity, so the next commit
  silently blocked on the held lock. This wait is **bounded** by
  `drain_timeout_seconds`: a wedged native `generate` that never releases can no
  longer hang the single dispatcher (and every other connection's commit) — on
  timeout the slot is freed and the next commit serializes on the lock normally.
- **Stale Unix socket no longer blocks the documented restart** — on start the
  server unlinks a leftover socket from a crashed instance, refuses to clobber a
  non-socket file at the path, and refuses to steal a socket a live server is
  still listening on (asyncio's own bind would silently unlink it).
- **Reference Pipecat adapter** — `_connect()` now drains the `session.update`
  ack before any commit is sent (a rejected config surfaced after a commit would
  otherwise abandon a live response and pin the backend lock), and a mid-synthesis
  server `error` cancels the response before breaking.
- **Outbound sends are bounded by a per-send wall-clock timeout** — a reader that
  stops draining mid-send (the socket write buffer fills *while* the drain loop
  awaits `ws.send`) is not caught by the pre-send high-water guard, which samples
  pending bytes only *before* the send. An unbounded wedge parked the drain loop,
  backed up the bounded backend→session bridge, and left the backend worker
  holding the process-wide synthesis lock — stalling every other session. Each
  send is now wrapped in `send_timeout_seconds` (default 5 s); on timeout the
  session is marked closed and the socket closed (1011) so the drain loop frees
  the lock.
- **Kokoro no longer advertises languages it cannot synthesize** — the advertised
  `languages` set was derived from voice-name prefixes, so `ja`/`zh` were listed
  even though their G2P needs a package (`misaki[ja]`/`misaki[zh]`) the `kokoro`
  extra does not install. A client trusting the capability contract could pick
  `ja`, pass validation, consume a synthesis slot, then get `backend_error`.
  `ja`/`zh` are now dropped from the advertised set by default, so a request for
  them is rejected up front with `invalid_config` (before a slot is consumed).
  An operator who installs the extra G2P package re-enables a language via
  `PIPECAT_TTS_KOKORO_EXTRA_LANGS` (e.g. `ja,zh`); the advertised set is logged at
  startup. (Reported by adversarial review.)
