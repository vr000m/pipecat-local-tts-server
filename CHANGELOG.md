# Changelog

All notable changes to this project are documented here.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- macOS app: the Running panel suggests a model for the idle category when the other has an active service (starting, running, stopping, external or crashed).
  It offers the model you last started there, else the default, else the first installed one whose cache check does not refuse it.
  It never suggests `tone`, and Reset clears the last-used choice (`lastUsed.tts`, `lastUsed.stt`).

## [0.9.0] - 2026-10-29

### Added

- macOS app: running services are restored on the next launch (preference `restoreOnLaunch`, on by default; the toggle is in the panel's gear menu).
  A stale or busy port ends Failed and is not retried.
- macOS app: Quit asks for confirmation when a client is connected to a server the app started.
  It also asks when the count cannot be read.
  Connections are counted from one bounded `lsof` call, excluding the app's own sockets.
  An `lsof` still running at its 2 s deadline is sent SIGKILL, and the count is unknown (asks).
  The killed `lsof` is reaped within 0.2 s, else by a background reaper.
  A launch failure, signal death or any stderr also asks. So does an exit other than 0 (or 1 with no output).
  So does a pipe held open past the deadline.
  So does any malformed or unknown `lsof` line, or a process with no readable socket.
  So does a line not ended by `\n`, or an empty line. So does a pid or fd with a sign or leading zero.
  So does a socket name that is not two whole IPv4 or bracketed IPv6 endpoints joined by one `->`.
  IPv6 may use `::`, a dotted IPv4 tail or a `%scope`.
  Endpoints are checked without a C parser: ASCII only, no leading zero in an octet or port.
  Exit 1 with no output is zero.
  System-initiated quits are not asked. That exemption rests on a provisional quit-reason code table.
  The table holds the documented Apple Event codes, not yet observed.
  A manual Log Out / Restart / Shut Down check has not run.
  Half-open peers count until keepalive reaps them: about 140 s at the TTS server's keepalive defaults.
  The STT servers' keepalive is not verified here.
- `macos/scripts/quit_app.sh` says a quit confirmation may be waiting in the app when it exits 1.
- macOS app: Reset also clears the saved set of services to restore (`restore.wanted`), so the next
  launch restores none. Quitting never changes the set; a Stop during shutdown still clears that service.
- `just app-smoke` (`macos/scripts/ui_smoke.sh`) relaunches with tone wanted and restore on.
  It checks an External tone server is adopted and no server of the app's own is started.
  Every launch uses a throwaway `PIPECAT_TOOLBAR_DEFAULTS_SUITE` plus `-restoreOnLaunch` and
  `-restore.wanted` launch arguments.
  The run fails if a read-only hash of the real `restore.wanted` changed.

## [0.8.3] - 2026-10-28

### Fixed

- `just app-open` waits for a running Pipecat Service Toolbar to exit before launching (the quit is
  asynchronous, so `open` used to re-activate the old copy) and stops, without launching, when the old copy
  has not quit within `QUIT_WAIT_SECS`. It now signs with the self-signed `Code Signing` identity when the
  keychain has it (ad hoc otherwise; it used to always sign ad hoc), so Microphone / Speech Recognition
  grants carry across `app-open` and `app-install`.
- Both recipes share `macos/scripts/quit_app.sh`: one `QUIT_WAIT_SECS` deadline for the whole step,
  osascript calls included (one that ignores SIGTERM is killed). Exit 1 when the app is still running, or
  osascript gave no answer, at the deadline; exit 3 when osascript fails or answers anything but true/false,
  so whether the app runs is unknown and the recipe stops instead of reading it as "not running". No
  osascript outlives the script on any exit path.
- Both recipes choose their default identity in `macos/scripts/resolve_sign_identity.sh`, which asks
  `macos/scripts/has_sign_identity.sh`. That check reads only the identity lines of the keychain listing
  and takes an identity as codesign does: a full 40-hex SHA-1 (any case) or a case-insensitive substring of
  a name. It is advisory: two identities sharing a name still count as present, and codesign decides at
  signing. A failing `security` query stops the recipe instead of reading as "no identity". The old
  `app-install` check matched the listing's own `Policy: Code Signing` header, so it passed for
  `Code Signing` on every machine and a missing identity failed only at the last build step.

## [0.8.2] - 2026-10-27

### Added

- `just app-install`: build Pipecat Service Toolbar signed with the self-signed `Code Signing`
  identity (so Microphone / Speech Recognition grants survive rebuilds) and install it into
  `~/Applications`, replacing any installed copy.

## [0.8.1] - 2026-10-27

### Changed

- `serve` now holds a bearer token to one rule: visible ASCII only (no internal whitespace,
  newlines or non-ASCII), whether it comes from `--auth-token-file` or `PIPECAT_TTS_AUTH_TOKEN`.
  **Upgrade note:** a token with internal whitespace or other characters outside visible ASCII,
  which `serve` used to accept, now makes it exit 1 (a launchd agent would restart every 10 s),
  so re-issue such a token with visible ASCII only.
- Pipecat Service Toolbar: the External probe waits 2 s for a server's hello (was 5 s). Measured
  across every TTS backend mid-synthesis and every STT engine while its model loads, the slowest
  hello was 187 ms.

### Fixed

- `serve` no longer runs with auth silently off on an empty token. An empty or whitespace-only
  `--auth-token-file`, an empty `--auth-token-file ""` value, a non-UTF-8 token file, and a
  set-but-blank `PIPECAT_TTS_AUTH_TOKEN` all exit 1 at startup (as `ConfigError` under
  `--supervised`), before the model loads. An unset or empty `PIPECAT_TTS_AUTH_TOKEN` still means
  no auth, and `status` still reads its token leniently. Closes #23; mirrors the STT server's fix.
- `scripts/install_tts_agent.sh` validates `PIPECAT_TTS_AUTH_TOKEN_FILE` before it writes or loads
  anything, with the same reader plus a file policy: an absolute path to an owner-only regular file
  (no symlink, no group/other bits) in directories owned by you or root that no other user can
  write (group write only on root-owned ones). The plist records the symlink-free path that was
  checked.
- Pipecat Service Toolbar: an External row's LaunchAgent label is cut in the middle, not at the
  end, so `pipecat.stt-server.kyutai` / `…parakeet` / `…nemotron` stay distinguishable in the
  panel, and hovering the line shows the whole label.

## [0.8.0] - 2026-10-27

### Added

- **Pipecat Service Toolbar adopts running servers (External).** At launch and while
  the panel is open (every 15 s) the app probes the catalog ports (loopback TCP) with
  a `server.hello` and shows a matching server it did not start as **External**;
  it starts its own only when none answers. External rows offer Try it (for STT, the
  test clip only, never the microphone) and Copy but no per-service Stop, Delete, Get
  or Install (the app-wide Reset deletes only the app's own environments and layout
  file, never signals an External server, and is not blocked by one), show the
  LaunchAgent label when `launchctl`
  confirms it holds the port (else `127.0.0.1:<port>`), and **Quit leaves them
  running** ("Stop All & Quit" appears only when the app started a server). The app
  only signals, stops or deletes processes it started. An app-started server and a
  `just tts-install` / `just stt-*` agent on one port: a matching agent is adopted;
  a holder that does not identify as that service makes Start report the port busy,
  naming it when `launchctl` confirms it. Unix sockets, LAN endpoints and
  token-protected servers are not discovered.
- **Parakeet (9765) and Nemotron (9865)** STT services, matching the
  `pipecat.stt-server.parakeet` / `nemotron` agent ports, installed against their own
  hash-pinned `macos/constraints/stt-parakeet.txt` / `stt-nemotron.txt` (regenerate with
  `uv run python macos/scripts/compile_stt_constraints.py`). Parakeet needs `ffmpeg` on
  the machine (Homebrew `/opt/homebrew/bin` or `/usr/local/bin`; the app adds those to
  Parakeet's server `PATH` only); without it the server exits with `BackendStartError:
  FFmpeg is not installed or not in your PATH`.
- `macos/scripts/ui_smoke.sh` starts a tone server outside the app on 8665, checks the
  bootstrap log reports it as External and that it is still running after Quit
  (skipped when 8665 is held, a `pipecat.tts-server.tone` LaunchAgent is loaded, or the
  repo `.venv` cannot import `tts_server`).

### Changed

- Pipecat Service Toolbar: STT now runs through the upstream
  `pipecat-local-stt-server==0.5.0` CLI (`python -m stt_server serve --supervised`,
  `prefetch --json`); the bundled `pipecat_app_helper.py`, `PIPECAT_TOOLBAR_HELPER`
  and the helper's cooperative cancel are removed, with the helper's `MODEL_REVISIONS`
  pins and `ServiceCatalog.sttModelRevisions` (0.7.0 listed both). An STT server on an
  older version is adopted by its hello, but an app-started STT server needs 0.5.0.
- STT model weights are pinned by upstream, not by the app: `pipecat-local-stt-server`
  0.5.0 pins the four default models (Whisper large-v3-turbo, Kyutai 1B, Parakeet,
  Nemotron) to a recorded Hub commit in code (`prefetch --json` reports it as
  `revision`). It has no revision flag, so the app passes none; any other `--model`
  (the other Whisper sizes, Kyutai 2.6B) follows the repo's `main`.
- `docs/supervised-contract.json` lists error codes per emitter (contract `version` 2;
  version 1 had one flat list); `ModelInvalidError` is emitted by the STT server only (`tts_server/supervise.py` is unchanged).

## [0.7.0] - 2026-10-25

### Added

- **`serve --supervised`** for a managing parent process: stdout carries only JSON
  lines (`ready` once listening with the real port, or `error` with a stable `code`
  such as `EADDRINUSE`, `ModuleNotFoundError`, `ModelDownloadError`), a busy port is
  reported before the model loads, and stdin EOF stops the server like SIGTERM.
- **`prefetch` subcommand**: downloads exactly what `serve` would fetch (model repo,
  dia's codec, pocket_tts voice embeddings, phonon's pinned revision and enabled
  voices, and the phonon-q8/q4 conversion) with optional JSON-lines progress, and
  `--check` reports whether the weights are cached without touching the network (a
  snapshot with an unfinished download blob, or missing a shard its index names, is not
  cached).
  Each backend module now exports `prefetch_specs(model)`.
- `pipecat-tts` console script (same CLI as `python -m tts_server`).
- **App-path smoke** (`just smoke-supervised [backend]`, `just smoke-supervised-all`;
  `tests/smoke/supervised_smoke.py`): drives a backend the way the menu bar app does
  (`prefetch --json --check`, `serve --supervised` on an ephemeral loopback port with the
  app's environment, the `ready` line, a TCP synthesis, a busy-port `EADDRINUSE`, and a
  stdin-EOF stop with no orphan). Never downloads weights unless `--download`.
- **Pipecat Service Toolbar** (`macos/`): native SwiftUI menu bar app that installs
  and serves local speech services on fixed loopback ports. TTS: every backend here
  (bundled pinned `uv` + this wheel + `uv.lock` constraints; a managed CPython 3.12 and
  one venv per service). STT: Apple Speech (SpeechAnalyzer behind a native WebSocket
  server), Whisper and Kyutai (`moshi_mlx`), all on the `pipecat-local-stt-server` wire
  protocol. Running-only main menu, an Add Models catalog, copy URL / Pipecat service /
  env from a right-click menu, model deletion, and "Try it" for both directions.
  Quitting stops the install or download step in flight (and the bootstrap's wheel
  build), lets no later step start, and waits up to 20 s for installs and removals to
  unwind; deleting a service with "Delete Everything" removes its model weights even
  when its environment is outdated, and reports any it could not delete. An abandoned
  Kyutai transcription releases the backend (cancelled per 80 ms frame). Cancel
  always ends an install (SIGKILL 5 s after SIGTERM) and never counts as a finished
  one; deleting a service mid-install cancels the install first; model deletion only
  touches `models--*` folders in the Hugging Face hub cache and the server's own
  derived-weights folder; a startup error is never lost to the server's exit; the
  TTS "Try it" request lifecycle is one pure state machine (`TTSRequestMachine`,
  tested over every state x event cell, random interleavings against a model server
  and a live tone server): requests go out one at a time on a reused connection,
  each starting with `input_text.clear`; Stop before the commit sends no commit and
  Stop after it sends `response.cancel` behind it; a frame acts only on the request
  its `response_id` / `previous_event_id` names; each request reports its outcome
  once; a request the server goes silent on times out and reconnects. It shows
  server error messages and ends cleanly when the output device changes. A cancelled queued install records
  nothing; an install step no longer waits on a grandchild holding its pipes.
  STT environments install against checked-in, hash-pinned constraints
  (`macos/constraints/stt-<engine>.txt`, `--require-hashes`) and load model weights
  pinned to a commit, which `prefetch` downloads and `serve-stt` loads; neither pin
  marks an existing environment outdated. The supervised/prefetch JSON lines both
  emitters write (this server and the STT helper) are fixed in
  `docs/supervised-contract.json` and drift-tested from both sides.
  `HF_TOKEN` reaches only `prefetch` and `serve`, never `uv`. The Apple Speech
  server caps clients at 8 and decodes one at a time, and survives Stop with a
  decode in flight; microphone audio is resampled without per-buffer seams.
  Model deletion refuses a path whose backend directory is a symlink out of the
  cache; stopping a subprocess also ends its descendants (process group) and never
  hangs on a failed or refused launch; a server exit reported after a removal no
  longer marks the service installed; quit cancels an Apple Speech model install;
  the Apple Speech server closes a client that stops reading its replies.
  `just app-build` / `app-open` / `app-run` / `app-test`. Right-click a running
  service for **Test Voice** (speaks "Hello world, this is the Pipecat test server
  using the <model> model.") or **Test Transcription** (a bundled spoken clip, no
  microphone, checked against its sentence); the STT Try it "Test Clip" button uses
  the same clip instead of a live system-voice synthesis.

### Changed

- `docs/protocol.md` §3 now states the request lifecycle on a reused connection
  (no wire change, protocol stays v0.1): every refusal of an append or commit keeps the
  buffer, so a client MUST `input_text.clear` before its next append after any append or
  commit that was not admitted and that it will not retry (a refusal, a failed send, or a
  request abandoned before it was admitted), and SHOULD clear before every request; a
  barge-in cancel must follow the commit it stops. "Try it" now does
  both, so a refused request's text can no longer prefix the next one and Stop between
  append and commit no longer leaves a synthesis holding the connection.
- Pipecat Service Toolbar internals (no change to behaviour, ports or on-disk layout):
  the per-service lifecycle state machine moved from the app target into
  `PipecatToolbarCore` as a pure reducer (`ServiceLifecycle.reduce`) plus an effect
  runner (`ServiceDriver`) with injectable environment, process, port, Apple Speech
  and clock seams; `ServiceModel` is now a thin `@Observable` adapter and the Swift
  tests depend on Core only. Add Models' download size now counts every snapshot an
  install fetches at its pinned revision (Phonon's pin, dia's codec, pocket_tts's
  voice embeddings, the STT helper's file filter at its `MODEL_REVISIONS` pin, which
  `ServiceCatalog.sttModelRevisions` repeats) from `ServiceCatalog.snapshots(for:)`,
  which a lean drift test compares with each backend's `prefetch_specs(model)` and
  with the helper's pins.
- `_clear_stale_unix_socket` raises `SocketInUseError` / `SocketPathConflictError`
  (both still `RuntimeError` subclasses).
- `TTSServer.listening_port()` returns `None` for a Unix socket instead of a
  character of its path; `TTSServer` exposes read-only `backend` and `config`.
- Backend names live in one registry, `tts_server.backends.BACKENDS` (module,
  class, default-model constant, prefetch hooks per backend). `make_backend`, the
  `--backend` choices of `serve`/`prefetch` (`__main__.BACKEND_CHOICES`), the
  default-model fallback and the `prefetch` dispatch all derive from it; the hook
  shapes are Protocols in `tts_server.backend` (`BackendPrefetch`,
  `SupportsPrefetchFinalize`, `SupportsPrefetchCheckExtra`). No CLI or output change.
- `serve()` takes `lifecycle=` (a `tts_server.server.ServeLifecycle`: `attach`,
  `startup_abandoned`) instead of the unreleased `stop_on_stdin_eof=`. The
  `--supervised` policy (ready/error lines, exit codes, stdin-EOF stop, hard exit
  when the supervisor leaves mid-startup) moved to `tts_server.supervise`
  (`run_supervised`, `StdinEofLifecycle`, `emit_ready`); `server` no longer imports
  `supervise` or calls `os._exit`. JSON lines and exit codes are unchanged.

### Fixed

- phonon: a q8/q4 conversion killed by SIGTERM (the app's Cancel) or `os._exit` no
  longer leaves its temp folder forever; the next conversion of the same key removes
  temp folders whose process is gone.
- Pipecat Service Toolbar: a late refresh (Reset, Try Again, a sibling's install, a
  slow cache probe) no longer hides a running server or undoes a Delete; Cancel during
  the busy-port check works and a late answer is dropped; an obsolete server's `error`
  line no longer judges the next server; an Apple Speech download already under way
  is attached to (progress and Cancel work); a fresh install cancelled during setup
  reads as not installed; Delete Everything also removes partially downloaded repos
  and reports any folder it refused; a bundled app missing an STT engine's hash pins
  refuses that install instead of resolving unpinned; choosing "Default voice" in
  Try it is remembered; stale audio no longer replays after an output-device change;
  `just app-open` quits the bundle id the build used.
- Pipecat Service Toolbar: an environment from before variants keeps its builder
  installed when a sibling variant installs or is cancelled; a variant record that
  can't be written or removed now fails the install or removal instead of reporting
  success; Reset is refused while a service is running, installing or removing;
  Stop and quit stop a busy-port probe (`lsof`) in flight; quit always stops the
  environment manager's subprocesses (a cache probe included) and waits for a
  bootstrap or Reset in flight; Try Again and Reset no longer start a second
  bootstrap or Reset while one runs.
- Pipecat Service Toolbar: Delete Everything on one variant keeps (and reports) the
  model folders when a sibling's cache check gives no answer, such as one quit stopped,
  so quitting while Phonon 8-bit is removed no longer deletes the voices Phonon still
  uses; a late bootstrap refresh after quit no longer attaches an Apple Speech install,
  and the download-size lookup no longer starts after quit; Stop cancels a busy-port
  probe at once instead of after its re-read; Get, Start and Delete wait while Reset
  or a bootstrap runs (a Start during Reset no longer fails with "missing the STT
  helper"); a stop after a process was reaped never signals a reused pid's group.

## [0.6.1] - 2026-10-23

### Changed

- Reference Pipecat adapter retries a commit rejected with `busy`, honouring the
  server's `retry_after_ms` (+ up to 25% jitter), up to `busy_retries` (default 3)
  within `busy_retry_budget_s` (default 3.0 s) of total waiting. Only the commit is
  re-sent (the server keeps the buffered text on `busy`); a barge-in during the wait
  cancels and clears. Past either bound it drops the utterance as before;
  `busy_retries=0` restores the previous behaviour exactly.

### Fixed

- `scripts/render_tts_plist.py` validated values with `re.match` against `^…$`, where
  `$` also matches before a trailing newline (`"zoey\n"` passed). Every validated value
  now uses `fullmatch`.
- Phonon removes orphaned quantize temp directories (`.<name>.tmp-<pid>-<tid>`, left by
  a crash during the first conversion of an alias) when a quantized alias starts, but
  only real directories with that exact name pattern that are more than ten minutes old.

## [0.6.0] - 2026-10-22

### Added

- **`phonon` backend** (extra `phonon`; `gradium/phonon-31m-en`, pinned revision,
  streaming, 24 kHz, English). The 31M weights, tokenizer and voices are Apache-2.0
  (model card); the 40M siblings are CC-BY-NC-4.0/gated per their Hugging Face card
  metadata (checked 2026-10-21) and unsupported. Canonical
  launchd port 9365, `just smoke-phonon` / `smoke-multiconn-phonon`.
- Phonon fails a response whose sentence chunk reaches the model's ~45 s limit
  (`response.failed`, `BACKEND_ERROR`) instead of reporting a clipped, clean completion;
  checked per chunk via `_generate_audio_stream_short_text` (mlx-audio 0.6.1, pinned).
  Only for the pinned model revision and its aliases; an unpinned repo or local path, a
  pinned revision without a measured ceiling, or an mlx-audio without the chunk method
  starts with the guard off and a warning (the ceiling is measured only for the pinned
  model). Clients see the generic "backend synthesis failed"; the detail is logged.
- Phonon quantized-weight aliases: `--model phonon-q8` / `phonon-q4` (and `phonon` for
  the default fp weights). The pinned snapshot is converted once into
  `$XDG_CACHE_HOME/pipecat-tts-server/phonon/` and loaded from there; saves
  memory/disk/load time, TTFB/RTF unchanged. fp stays the default.
- `PIPECAT_TTS_PHONON_VOICES` (server env, comma-separated catalog slugs): enables
  extra named voices (one file downloaded each; unknown/unfetchable slugs are
  skipped with a warning). Validated and baked into the launchd plist for `phonon`.
  A resolved voice file must be an absolute, existing path ending in `.safetensors`
  (no `@`); anything else is skipped with a warning.
- `python -m tts_server voices [--backend phonon] [--language] [--json] [--refresh]`:
  lists the bundled 102-voice catalog (enabled/cached columns; `cached` is `?`/`null`
  without `huggingface_hub`); `--refresh` diffs the live `voices.jsonl`
  (added/removed/changed, plus duplicate and invalid/reserved slugs) and changes nothing.
- Measured on an M4 Max (warm cache, in-process `rtf_benchmark.py`): cold start 0.6 s,
  warm TTFB 0.01-0.02 s, RTF 0.04 for the default voice and a named voice; server-level
  TTFB 0.021 s with a 0.014 s max inter-delta gap; barge-in acknowledged in ~1 ms.
  Re-run while a local STT app transcribed a live call: same TTFB/RTF (STT CPU not sampled
  during the run). Details: `scripts/profiling/README.md`.
- New smokes: `tests/smoke/phonon_cancel_smoke.py` (named voice, voice validation,
  barge-in, abrupt disconnect) and `tests/smoke/pipecat_adapter_e2e.py` (reference
  adapter in a real pipeline); `latency_smoke.py` prints `max_gap`; `reconnect_smoke.py`
  accepts `--backend phonon`.

### Changed

- **mlx-audio 0.4.4 -> 0.6.1 for every backend extra** (`kokoro`, `voxtral_tts`,
  `pocket_tts`, `dia`, `qwen3_tts`, `fish_tts`); mlx moves to 0.32.4 and
  transformers to 5.20. Verified with `scripts/verify_mlx_tts_api.py`
  (`generate()` signatures and streaming fields unchanged), the full unit suite
  (415 passed, 2 skipped), every live smoke (`just smoke-*`, multiconn, reconnect) and an
  A/B `rtf_benchmark.py` run against 0.4.4 under identical conditions: no
  steady-state TTFB/RTF regression on any backend (see `scripts/profiling/README.md`).
- Shared synthesis bridge (`_stream_util.py`): the worker now closes the synthesis
  generator before releasing the Metal lock, so an upstream generator's cleanup (for
  example `pocket_tts` restoring its sampling state) finishes before the next commit can
  take the lock. Affects every bridged backend; previously this ran only after the lock
  was released on a cancel.
- `pocket_tts` extra now declares `requests` explicitly: mlx-audio 0.6.1's
  `pocket_tts` module imports it without declaring it.
- Existing `uv.lock` environments need `uv sync` to pick up the new pin.
- Probed unpatched on 0.6.1: Kokoro no longer hits the upstream `SineGen` broadcast
  bug, so `_apply_kokoro_vocoder_fix` is now removable (left in place here; follow-up,
  see `docs/upstream/mlx-audio-kokoro-sinegen-broadcast.md`).

## [0.5.0] - 2026-08-09

### Added

- **`fish_tts` backend** — Fish Audio S2 Pro backend (mlx-audio 0.4.4,
  `fish_qwen3_omni`; default model `mlx-community/fish-audio-s2-pro`,
  `streaming:false`, no voice concept, extras `temperature`/`top_k`/`top_p`/
  `instruct`). `--backend fish_tts` CLI choice, `fish_tts` extra, canonical
  launchd port **9265**, `just smoke-fish_tts` / `smoke-multiconn-fish_tts`
  recipes, and two-layer test suites (`tests/test_fish_lean.py` no-mlx +
  `tests/test_fish_backend.py` mlx-gated). Weights: FISH AUDIO RESEARCH
  LICENSE AGREEMENT — non-commercial; a separate written agreement is
  required for commercial use.
- A real per-batch token-ceiling truncation tripwire
  (`FishTruncationError`), mirroring mlx-audio's private
  `semantic_token_budget = min(max_new_tokens, max(32, text_token_count *
  12))` formula (`fish_speech.py:699-703`) rather than a naive flat
  `>= 1024` check — a short/medium batch's own 12x-input-token budget can
  bind tighter than the flat default, so the naive check would let those
  truncations through as a silent `completed` response. A ceiling hit
  **fails the response** instead.
- Two pre-flight guards that reject a high-risk input shape at commit time,
  before a slot is consumed: non-whitespace text preceding the first
  `<|speaker:N|>` tag that mlx-audio's batch split would otherwise silently
  drop (`FishUntaggedPrefixError`, raised from `FishBackend.validate_text` /
  `_check_untagged_prefix` via the new `SupportsTextValidation` server hook —
  see below), and a near-floor-length commit combined with a non-empty
  `instruct` extra (`FishInstructTruncationRiskError`, raised from
  `_check_instruct_truncation_risk` inside `_gen_factory`, since it needs a
  tokenizer call under the Metal lock) — a shape at elevated risk of the same
  silent-truncation failure mode the tripwire above catches after the fact.
  The instruct guard is scoped out for speaker-tagged multi-batch text (each
  batch gets its own real per-batch ceiling, so a whole-buffer estimate
  wouldn't measure the right thing) — the post-hoc tripwire above still
  covers that case, since it runs unconditionally per batch regardless of
  tagging.
- The server now rejects an empty/whitespace-only committed buffer generically
  (`BUFFER_EMPTY`, `state.buffer.strip()` in `server.py`) ahead of any
  backend-specific check — not a `fish_tts`-specific error type.

### Changed

- Extracted the shared segment-level `TTSStream` adapter (`feed`/`end`/
  `cancel`/`wait_closed`/`events`) into `tts_server/backends/_bridge_stream.py`
  as `BridgedStream` (renamed from `SegmentStream`, formerly
  `_segment_stream.py`); `dia`, `qwen3_tts`, `fish_tts`, `kokoro`,
  `voxtral_tts`, and `pocket_tts` all now inherit it — each subclass keeps
  only its own constructor state and `_gen_factory` override.
- Added a `SupportsTextValidation` protocol (`tts_server/backend.py`) —
  parallel to the existing `SupportsExtrasValidation` — letting a backend
  reject an input-shape-specific failure in the committed text itself (e.g.
  `fish_tts`'s untagged-prefix guard) as a clean `INVALID_CONFIG` at commit
  time, before scheduler admission. `server.py` calls it right after the
  empty-buffer/max-chars checks and before per-commit overrides are applied.
  `BridgedStream`'s earlier `_preflight_check()` synthesis-time hook was
  removed in favor of this commit-time server hook — validation now happens
  before a slot is consumed, not after synthesis has already started.

## [0.4.0] - 2026-07-04

### Added

- **`qwen3_tts` backend** — Qwen3-TTS streaming backend (mlx-audio 0.4.4, no pin
  bump; default model `mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16`,
  9 named speakers, default voice `ryan`; the `Base` variant is supported via
  `--model` as a no-voice model). `--backend qwen3_tts` CLI choice, `qwen3_tts`
  extra, canonical launchd port **9165**, `just smoke-qwen3_tts` /
  `smoke-multiconn-qwen3_tts` recipes, two-layer test suites, and a profiling
  entry (TTFB 0.12 s, RTF 0.27 — fastest quality-voice streamer in the stable).
  Weights: HF card tag `apache-2.0` (no LICENSE file in the repos).
- Known-upstream workarounds baked into the backend: `mx.disable_compile()` in
  `start()` (mlx 0.31.2's thread-local CompilerCache segfaults on worker-thread
  exit; qwen3 is the only model family using `mx.compile`) and
  `_MAX_TEXT_CHARS = 800` + a token-ceiling tripwire (mlx-audio's
  `max_tokens=4096` truncates silently; degenerate text paces at ~0.19 s
  audio/char). The tripwire counts tokens **per segment** (`segment_idx`) —
  the cap is per generation, and the Base path splits a commit on `\n` into
  independent generations — and a ceiling-hit **fails the response**
  (`response.failed`/`BACKEND_ERROR` via `Qwen3TruncationError`) instead of
  logging and completing with silently missing audio.

### Changed

- Sampling-extras coercion (`temperature`/`top_k`/`top_p` bounds + validation)
  extracted to a shared stdlib-only `tts_server/backends/_extras_util.py`;
  qwen3/voxtral/dia/pocket now import it (each keeps its own allowlist).
  Behavior change: JSON booleans are rejected with `INVALID_CONFIG` for **all**
  numeric extras (previously `{"temperature": true}` silently coerced to 1.0;
  only `top_k` rejected bools).

## [0.3.0] - 2026-07-01

### Added

- **`dia` backend** (formerly v1 Phase 5c, now its own plan) — a multi-speaker
  **dialogue** backend, `streaming:false` and segment-level (`split_pattern='\n'`,
  like Kokoro). Speakers are addressed **purely in-text** via `[S1]`/`[S2]` tags
  inside an ordinary `text_format: "plain"` payload (Option A — no server-side
  change): the backend advertises `voice_count: 0`, so the server accepts a
  supplied `voice` and the backend **structurally ignores** it (`_DiaStream` takes
  no `voice` param). Behind the new `dia` extra (just `mlx-audio==0.4.4`, like
  Pocket); model `mlx-community/Dia-1.6B-fp16`, **Apache-2.0** (commercial-safe).
  Rate **44100 Hz** (read from `model.sample_rate`). Advertised `extras`:
  `temperature`/`top_p` (no `ref_audio`/`ref_text` → no voice cloning, decision #2);
  `validate_extras` clamps/rejects out-of-range or non-finite values. Wired into
  `--backend` and `make_backend`; canonical launchd port **9065**. The dialogue
  contract lives only in client convention — see `docs/protocol.md` §6 (Option A /
  Option B upgrade path). Manual `tests/smoke/dia_dialogue_smoke.py`
  (listen-and-judge, mlx-gated) drives the live dialogue check.

### Fixed

- **Websocket keepalive no longer truncates in-flight TTS under Metal/GIL load.**
  The `websockets` library default (`ping_interval=20s`, `ping_timeout=20s`)
  closed a live connection with `1011 keepalive ping timeout` when GIL-holding
  mlx/Metal compute starved the asyncio loop past 20s during a heavy or cold-start
  generation, cutting off the spoken line. The server and `TTSClient` now keep the
  periodic ping but use a **large finite pong timeout (120s) by default** — long
  enough that a briefly-starved loop can't drop a live connection, yet bounded so
  a dead *idle* peer is still reaped within `interval + timeout` (~140s). (An
  earlier iteration disabled the timeout entirely, but `ping_timeout=None` leaks
  idle dead peers: an idle session has no application send, so the per-send timeout
  can't catch it and TCP only gives up after ~2h.) Both knobs are configurable:
  `ServerConfig(ping_interval_seconds=, ping_timeout_seconds=)`, `serve(...)`, env
  `TTS_WS_PING_INTERVAL` / `TTS_WS_PING_TIMEOUT` (server), and
  `TTSClient(ping_interval=, ping_timeout=)` (so a starved server loop can't trip
  the client's keepalive either). New behavioral tests in `test_keepalive.py`
  assert both directions off the live connection objects and that the server reaps
  a peer which completes the handshake then stops answering pings.
## [0.2.0] - 2026-06-28

### Added

- **Phase 6 launchd ops parity + port-per-backend** — each backend runs as its own
  launchd user agent bound to a canonical loopback port (`tone`=8665 / `kokoro`=8765 /
  `voxtral_tts`=8865 / `pocket_tts`=8965; `dia` reserved at 9065). New `just` lifecycle
  recipes: `tts-install`, `tts-uninstall`, `tts-enable`, `tts-disable`, `tts-start`,
  `tts-restart`, `tts-stop`, `tts-logs`. `tts-list` and `tts-status` are now port-aware (the socket quick-start branch
  is preserved). New scripts: `scripts/render_tts_plist.py` (pure `plistlib` renderer,
  XML/injection-safe, fail-closed auth) and `scripts/install_tts_agent.sh` (env-keyed
  `launchctl bootstrap` lifecycle: `PIPECAT_TTS_LABEL`, `PIPECAT_TTS_BACKEND`,
  `PIPECAT_TTS_HOST`, `PIPECAT_TTS_PORT`, `PIPECAT_TTS_MODEL`, `PIPECAT_TTS_AUTH_TOKEN_FILE`).
  Because launchd does not inherit the installer's shell environment, server-runtime
  env is handled explicitly: `PIPECAT_TTS_KOKORO_EXTRA_LANGS` is baked into the agent's
  plist `EnvironmentVariables`, and an install that sets `PIPECAT_TTS_AUTH_TOKEN` (a
  secret, which must not land in a plaintext plist) without `PIPECAT_TTS_AUTH_TOKEN_FILE`
  is **rejected** so auth is never silently disabled — use the token file for agents.
  New lean tests: `test_render_tts_plist.py` (incl. the env-passthrough + auth-drop guard),
  `test_justfile_recipes.py` (backend drift guard + `_plist_endpoint`),
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

[Unreleased]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.9.0...HEAD
[0.9.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.8.3...v0.9.0
[0.8.3]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.8.2...v0.8.3
[0.8.2]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.8.1...v0.8.2
[0.8.1]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.8.0...v0.8.1
[0.8.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.7.0...v0.8.0
[0.7.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.6.1...v0.7.0
[0.6.1]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.6.0...v0.6.1
[0.6.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.5.0...v0.6.0
[0.5.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.4.0...v0.5.0
[0.4.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/vr000m/pipecat-local-tts-server/compare/v0.1.0...v0.2.0
[0.1.0]: https://github.com/vr000m/pipecat-local-tts-server/releases/tag/v0.1.0
