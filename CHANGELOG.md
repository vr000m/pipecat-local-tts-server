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
- **`speed` extra is bounded** — finite values are clamped to `[0.5, 2.0]` and
  non-finite (`NaN`/`inf`) or non-numeric values are rejected, so a degenerate
  rate can no longer drive very-long synthesis while holding the Metal lock.

### Changed

- **Optional backend capabilities are now explicit protocols** (`SupportsVoices`,
  `SupportsWaitClosed`) checked via `isinstance`, instead of methods declared on
  the base protocol but accessed through `getattr`.
- **`make_backend` raises `ValueError`** (not `SystemExit`) for an unknown
  backend name; the CLI translates it to a clean exit. The default server backend
  is built through `make_backend("tone")` so the server depends only on the
  abstract protocol types.
- **Client checks `server.hello.protocol_version`** and warns on a mismatch
  (protocol §8 SHOULD).

### Fixed

- **`session.close` drain timeout now covers synthesis, not queue waiting** — a
  commit still queued behind other connections' work is given the drain budget
  for its actual synthesis (waiting for dispatch first), instead of being
  cancelled for head-of-line waiting it did not control.
- **Bounded the terminal EOF enqueue in the streaming bridge** — a consumer
  abandoned without setting the cancel flag can no longer pin the daemon synth
  thread indefinitely; the worker falls back to the non-blocking EOF path after a
  few attempts and exits.
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
  silently blocked on the held lock.
- **Stale Unix socket no longer blocks the documented restart** — on start the
  server unlinks a leftover socket from a crashed instance, refuses to clobber a
  non-socket file at the path, and refuses to steal a socket a live server is
  still listening on (asyncio's own bind would silently unlink it).
- **Reference Pipecat adapter** — `_connect()` now drains the `session.update`
  ack before any commit is sent (a rejected config surfaced after a commit would
  otherwise abandon a live response and pin the backend lock), and a mid-synthesis
  server `error` cancels the response before breaking.
