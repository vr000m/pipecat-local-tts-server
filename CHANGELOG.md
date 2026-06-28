# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **Phase 6 launchd ops parity + port-per-backend** — each backend runs as its own
  launchd user agent bound to a canonical loopback port (`tone`=8665 / `kokoro`=8765 /
  `voxtral_tts`=8865 / `pocket_tts`=8965; `dia` reserved at 9065). New `just` lifecycle
  recipes: `tts-install`, `tts-uninstall`, `tts-enable`, `tts-disable`, `tts-start`,
  `tts-stop`. `tts-list` and `tts-status` are now port-aware (the socket quick-start branch
  is preserved). New scripts: `scripts/render_tts_plist.py` (pure `plistlib` renderer,
  XML/injection-safe, fail-closed auth) and `scripts/install_tts_agent.sh` (env-keyed
  `launchctl bootstrap` lifecycle: `PIPECAT_TTS_LABEL`, `PIPECAT_TTS_BACKEND`,
  `PIPECAT_TTS_HOST`, `PIPECAT_TTS_PORT`, `PIPECAT_TTS_MODEL`, `PIPECAT_TTS_AUTH_TOKEN_FILE`).
  New lean tests: `test_render_tts_plist.py`, `test_justfile_recipes.py` (backend drift guard),
  `test_status_port.py` (tone-on-port status). launchd install/lifecycle is operator-manual
  and NOT CI-verified (bootstraps real agents / binds ports).

- **`pocket_tts` backend** (Phase 5b) — a second `streaming:true` backend, and
  the no-cloning negative-guard backend: its `generate()` exposes `ref_audio`
  (voice cloning) and `frames_after_eos`, both deliberately **unwired**
  (decision #2) and dropped by the backend's own extras filter. Behind the
  `pocket_tts` extra (just `mlx-audio==0.4.4` — its `sentencepiece`/
  `huggingface-hub` deps are transitive); model `mlx-community/pocket-tts`,
  **CC-BY-4.0** (commercial OK with attribution). Advertised `extras`:
  `temperature` only. `streaming_interval` locked 0.3 s (TTFB ~0.03 s, RTF≈0.05×
  — fast). `just smoke-pocket_tts` / `just smoke-multiconn-pocket_tts`.

- **`voxtral_tts` backend** (Phase 5a) — the first `streaming:true` backend
  (native sub-segment streaming via mlx-audio's `stream`/`streaming_interval`,
  locked to 0.3 s after on-host TTFB measurement: 0.395 s). Behind the new
  `voxtral_tts` extra (`mlx-audio==0.4.4` + `mistral-common[audio]`); model
  `mlx-community/Voxtral-4B-TTS-2603-mlx-bf16`. Advertised `extras`:
  `temperature`/`top_k`/`top_p` (no `ref_audio` → no voice cloning). Wired into
  `--backend` and `make_backend`; `just smoke-voxtral_tts` /
  `just smoke-multiconn-voxtral_tts` drive the live latency + concurrency smoke.
  **Model weights are CC-BY-NC (non-commercial)** — Kokoro (Apache-2.0) remains
  the default commercial-safe backend. See README → *Backends & licenses*.
- `ToneBackend(streaming=True)` constructor flag so the `streaming:true`
  capabilities branch and the client no-split path are covered in lean CI.
- Live **latency / streaming-cadence smoke driver** (`tests/smoke/latency_smoke.py`):
  asserts TTFB bound + that deltas stream during synthesis (not buffer-then-flush).

### Changed

- The macOS CI smoke job now `uv sync --all-extras` (install-smokes every backend
  extra) instead of a fixed `--extra` list.

## [0.1.0] - 2026-06-26

First release of `pipecat-local-tts-server` — a standalone, local WebSocket
**text-to-speech** server, client, and pluggable mlx-audio backends mirroring the
sibling [`pipecat-local-stt-server`](https://github.com/vr000m/pipecat-local-stt-server).

Ships Phases 0–4 of the dev plan: the wire protocol (`v0.1`), the `tone` (stdlib
reference) and `kokoro` (mlx-audio, Apple Silicon) backends, an async client, a
reference Pipecat `TTSService` adapter, and ops parity (status, optional auth,
backpressure). The wire protocol is still `0.x` and may change as the streaming
backends land.

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
  `en/es/fr/hi/it/pt` (default; `ja`/`zh` opt-in via
  `PIPECAT_TTS_KOKORO_EXTRA_LANGS`), `speed` extra.
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
- **UDS parent-directory hardening** — the `0o600` socket mode protects the
  inode but not the *name*: under a group/world-writable parent dir, another
  local user could `unlink` the socket and `bind` an impostor at the same path.
  Two changes close this: the `umask(0o077)` is now set *before* `mkdir`, so a
  parent dir the server creates is `0700` (not the process default ~`0755`); and
  the server refuses to bind when the parent is group/world-writable without the
  sticky bit (a `/tmp`-style sticky dir, where only the owner may unlink, is
  still accepted).
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
- **~400× faster Kokoro synthesis (RTF 12× → 0.03×)** — the streaming bridge's
  `_audio_to_pcm` passed mlx-audio's `GenerationResult.audio` (an `mx.array`)
  straight into the stdlib `float_to_pcm16`, which iterates element-by-element —
  forcing a device→host sync **per sample** (~78k syncs for a 3 s line ≈ 40 s of
  pure overhead, scaling linearly with audio length). The neural synthesis itself
  was always fast (~0.08 s; raw `model.generate()` runs at ~0.03× realtime). Fix:
  bulk-materialize the array with `.tolist()` (one transfer) before conversion.
  Kokoro now synthesizes ~33× faster than realtime (viable for live use); guarded
  by `tests/test_stream_util_audio_conversion.py`. Profilers live in
  `scripts/profiling/`. (Surfaced by client-side latency reports.)
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

[Unreleased]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/vr000m/pipecat-local-tts-server/releases/tag/v0.1.0
