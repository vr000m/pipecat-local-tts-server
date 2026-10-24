# Task: macOS menu bar app (phase 1: TTS)

**Status**: Complete. Shipped on `feature/macos-menubar-app`, then extended and renamed by [phase 2](20261023-feature-stt-service-toolbar.md).
**Component**: macos (new), tts-server (supervised mode, prefetch)
**Branch**: `feature/macos-menubar-app` (off `main` @ `802914b`)
**Created**: 2026-10-23

This is the plan approved before implementation, copied verbatim below the line.
It used the working name "Pipecat TTS". Where the build differs:

- **Name and layout.** The app is now **Pipecat Service Toolbar**. Targets are
  `PipecatServiceToolbar` and `PipecatToolbarCore`, and `Backend` is `Service`.
  Data lives under `Pipecat Service Toolbar` folders. See phase 2.
- **Constraints path.** uv 0.12.5 splits a `--constraint` path at spaces, so
  the install step runs from the file's folder and passes the bare file name.
  The end-to-end test found this.
- **Icon.** The app icon is the Pipecat catmark, drawn from vector paths by the
  app itself (`--render-icon`). There is no separate icon script.
- **Rendering check.** A debug-only `--snapshot <dir>` renders the panel in
  sample states, used to review the UI without driving the menu bar.

---

# Plan: "Pipecat TTS" macOS menu bar app

## Context

`pipecat-local-tts-server` is a Python WebSocket TTS server (`python -m tts_server serve`)
with eight backends (tone, kokoro, voxtral_tts, pocket_tts, dia, qwen3_tts, fish_tts,
phonon). Today an operator installs extras with `uv`, runs the CLI or a launchd plist,
and model weights download silently inside `serve`. The goal is a native macOS menu bar
app: a small icon in the menu bar opens a panel where you download a TTS provider
(Python env + model weights), start/stop it as a local server on its canonical loopback
port, and try it with live audio. UI is Swift/SwiftUI; Python is embedded only as a
managed runtime that the app installs on demand.

Decisions already made with the user:
- **Python runtime:** bundle the `uv` binary + this repo's wheel in the `.app`; on first
  "Download", `uv` installs a managed CPython 3.12 and a per-backend venv under
  `~/Library/Application Support/Pipecat TTS/`. No Python in the bundle.
- **Project form:** SwiftPM package at `macos/` + a shell script that assembles and
  codesigns `Pipecat TTS.app` (no Xcode project, no new tools; opens in Xcode via
  `Package.swift`).
- **Endpoint:** loopback TCP on the canonical per-backend ports (tone 8665, kokoro 8765,
  voxtral_tts 8865, pocket_tts 8965, dia 9065, qwen3_tts 9165, fish_tts 9265, phonon
  9365). Several backends may run at once.
- **v1 scope:** provider list with download/start/stop/remove, progress, detail view,
  "Try it" with AVAudioEngine playback. Launch-at-login, log viewer, copy-env snippet are
  hooks only.
- Environment: macOS 27.0.1, Xcode 27 / Swift 6.4, uv 0.12.5, Apple Development signing
  identities present. No `.venv` in this checkout.

The work has two halves that can land as two PRs: **(A) Python-side hooks** the app needs
(mergeable on its own, lean-CI safe), then **(B) the `macos/` app**.

---

## Part A — Python side (`tts_server/`)

### A1. `serve --supervised` (new flag)

New stdlib-only module `tts_server/supervise.py`:
- `emit(event: dict)` writes one compact JSON line to a `dup` of the original fd 1
  (taken before redirect) and flushes.
- `redirect_stdout_to_stderr()` sets `sys.stdout = sys.stderr` so stray `print()`s from
  mlx_audio/transformers never pollute the JSON channel.
- `watch_stdin_eof(loop, on_eof)` — daemon thread doing `os.read(fd, 4096)` until EOF, then
  `loop.call_soon_threadsafe(on_eof)`. (Not `connect_read_pipe`: fails on TTY stdin.)
- `classify_startup_error(exc) -> (code, message)` table, in order: `ModuleNotFoundError`
  → `"ModuleNotFoundError"`; `OSError` errno `EADDRINUSE` or new `SocketInUseError` →
  `"EADDRINUSE"`; errno `EACCES` → `"EACCES"`; new `SocketPathConflictError` →
  `"SocketPathConflict"`; exception whose `type(exc).__module__` starts with
  `huggingface_hub`/`requests`/`urllib3`/`hf_xet`, or `ConnectionError`/`TimeoutError` →
  `"ModelDownloadError"`; else `"BackendStartError"`. (Module-name matching keeps the
  lean base free of hf imports.)

`tts_server/server.py` ([server.py:1627](tts_server/server.py:1627) `serve()`):
- Add `SocketInUseError(RuntimeError)` / `SocketPathConflictError(RuntimeError)` raised
  from `_clear_stale_unix_socket` (existing `match="already"` tests still pass).
- Add read-only `backend` / `config` properties on `TTSServer`; fix `listening_port()`
  to return only when `getsockname()` is a tuple (UDS returns a str today).
- `serve(..., stop_on_stdin_eof: bool = False)`: create `stop` future + `_request_stop`
  **before** `server.start()`; if `stop_on_stdin_eof`, start the watcher first, then race
  `server.start()` against `stop` with `asyncio.wait(FIRST_COMPLETED)`; if the supervisor
  went away mid-load, log and `os._exit(0)` (executor thread mid-download cannot be
  cancelled; hf `.incomplete` blobs resume). After ready, EOF takes the exact SIGTERM
  path. The existing unused `ready` callback is the hook for the ready line.

`tts_server/__main__.py` (`_cmd_serve`, [__main__.py:212](tts_server/__main__.py:212)):
- `--supervised` (store_true). In supervised mode: `redirect_stdout_to_stderr()`, then a
  **preflight bind probe** (`_clear_stale_unix_socket` for UDS; `socket.bind` with
  `SO_REUSEADDR` for TCP, skipped for port 0) so port-busy is reported in milliseconds
  rather than after a model load.
- `ready` callback emits
  `{"event":"ready","backend","model","host","port","socket_path","rate","pid"}`
  (`port` from `listening_port()` so `--port 0` reports the real port).
- Wrap `asyncio.run(serve(...))`: on any exception (not KeyboardInterrupt/SystemExit)
  log the traceback to stderr, `emit({"event":"error","code","message","exc_type"})`,
  `SystemExit(1)`. Non-supervised behaviour is byte-for-byte unchanged.

### A2. `prefetch` subcommand

`python -m tts_server prefetch --backend X [--model ID] [--check] [--json]`

New `tts_server/prefetch.py` (lean at import; `huggingface_hub`/`tqdm` lazy):
- `DEFAULT_ALLOW_PATTERNS` = mlx_audio's `DEFAULT_ALLOW_PATTERNS` (`*.json, *.safetensors,
  *.py, *.model, *.tiktoken, *.txt, *.jinja, *.jsonl, *.yaml, *.npz, *.pth`);
  `phonon.ALLOW_PATTERNS` becomes `list(DEFAULT_ALLOW_PATTERNS)`.
- `@dataclass(frozen=True) SnapshotSpec(repo_id, revision=None, allow_patterns=DEFAULT,
  kind="model"|"codec"|"voice", required=True)`.
- `specs_for(backend, model)` → `[]` for tone, else `importlib.import_module(
  f"tts_server.backends.{backend}").prefetch_specs(model)` (mirrors `make_backend`'s lazy
  style; no backend instance constructed, nothing heavy imported).
- Patchable seams `_snapshot_download(spec, *, local_files_only, tqdm_class)` and
  `_dir_size(path)`; `check_spec`, `fetch_spec`, `run_prefetch(backend, model, *, check,
  json_mode) -> int`.
- Progress: `tqdm_class` subclassing **plain** `tqdm.tqdm` (hf's subclass is disabled by
  `HF_HUB_DISABLE_PROGRESS_BARS`); hf 2.x feeds it aggregate byte bars; emit only from the
  `unit=="B"` bar whose desc starts with `"Reconstructing"`, throttled to 5 Hz.
  `total_bytes` grows as files are discovered (moving total). In `--json` mode set
  `HF_HUB_DISABLE_PROGRESS_BARS=1` and redirect stdout.
- `--check` uses `local_files_only=True`; `FileNotFoundError` (hf 2.x
  `LocalEntryNotFoundError`, raised for incomplete snapshots) → `cached: false`. Never
  touches the network. Missing `huggingface_hub` → error event `ModuleNotFoundError`,
  exit 1, before any network.

Per-backend module-level `prefetch_specs(model)` next to each `DEFAULT_*_MODEL`:
- kokoro / voxtral_tts / qwen3_tts / fish_tts: `[SnapshotSpec(model or DEFAULT)]`; a local
  path model → `[]`.
- dia: + `SnapshotSpec("mlx-community/descript-audio-codec-44khz", kind="codec")`.
- pocket_tts: + voice embeddings spec from `mlx_audio...pocket_tts.utils.PREDEFINED_VOICES`
  (try/except ImportError with hardcoded fallback `kyutai/pocket-tts-without-voice-cloning`
  @ `d4fdd22…`, `allow_patterns=("embeddings/*.safetensors",)`, `required=False`).
  **Verify the 0.6.1 values first.**
- phonon ([phonon.py:62-117](tts_server/backends/phonon.py:62)): resolve `_alias_for` →
  `_pin_for` exactly as `start()`; pinned spec with `ALLOW_PATTERNS`; one `required=False`
  voice spec per slug from `phonon_voices.resolve_enabled(_enabled_from_env())`. Optional
  hooks found via `getattr`: `prefetch_finalize(model, paths)` runs `_ensure_quantized`
  for `phonon-q8/q4` (emits `convert` events); `prefetch_check_extra(model)` reports
  `{"quantized": bool, "path"}`.

Event stream (`--json`), one line each:
`start{repo,revision,kind}` → `progress{repo,file:null,downloaded_bytes,total_bytes}`* →
`done{repo,path,size_bytes}` (→ `convert{repo,bits,state,path}` for phonon aliases) …
→ `complete{backend,model,cached:true,size_bytes}`; failure → `error{code,message,repo}`
exit 1 (`required=False` specs warn and continue). `--check --json`:
`check{repo,revision,kind,cached,path,size_bytes}` per spec →
`summary{backend,model,cached,size_bytes}`; tone → summary `cached:true` with no hf import.

CLI: factor the backend `choices` tuple into `BACKEND_CHOICES`; add `p_prefetch`; add
`"prefetch"` to the subcommand set in `main()`; `_cmd_prefetch` → `_resolve_model` →
`run_prefetch`.

Not covered by prefetch (document): Metal JIT/warmup (serve still warms up), kokoro's
first misaki/espeak G2P call (pip assets, slow but no download), HEAD drift for
backends loading `main`.

### A3. Packaging

- `pyproject.toml`: add `[project.scripts] pipecat-tts = "tts_server.__main__:main"`
  (`main()` at [__main__.py:466](tts_server/__main__.py:466) is arg-free). Bump to
  `0.7.0`; CHANGELOG Unreleased entry.
- Wheel: `uv build --wheel` → `dist/pipecat_local_tts_server-<ver>-py3-none-any.whl`.
  Install with extras from a local wheel (PEP 508 form, verify once):
  `uv pip install "pipecat-local-tts-server[kokoro] @ file:///abs/path/x.whl"`.
- Managed Python pin: **3.12** (only version CI smokes extras on).

### A4. Tests / CI / docs

- `tests/test_supervised_cli.py` (lean, subprocess like `tests/test_status_port.py`):
  ready line + stdin EOF stops with exit 0; port-in-use → `EADDRINUSE` fast; missing
  extra via a `tmp_path` fake `mlx_audio` package that raises `ModuleNotFoundError`;
  `classify_startup_error` table; unsupervised stdout stays empty.
- `tests/test_prefetch_cli.py` (lean, in-process `main()` + `capsys` like
  `tests/test_phonon_voices_cli.py`, patching `tts_server.prefetch._snapshot_download`):
  `specs_for` per backend; `--check --json` cached/uncached/ImportError; `--json` fetch
  event order with a fake seam driving the tqdm class; phonon alias `convert`.
- Add `tts_server.prefetch`, `tts_server.supervise` to `_TTS_MODULES` in
  `tests/test_import_safety.py`; add both new test files to the lean allow-list in
  `.github/workflows/test.yml`.
- README: `--supervised` paragraph (schemas, stdin-EOF contract), "Prefetching models"
  section, env rows for `HF_HOME`/`HF_HUB_CACHE`. AGENTS.md: CLI table rows, layout
  bullets, tests paragraph. Optional `just tts-prefetch <backend>`.

---

## Part B — `macos/` Swift app

### B1. Layout

```
macos/
├── Package.swift                      # tools 6.0, macOS 15, Swift 6 strict concurrency, no deps
├── README.md
├── scripts/
│   ├── build_app.sh                   # wheel + uv + swift build + bundle + codesign
│   ├── fetch_uv.sh                    # pinned uv 0.12.5 aarch64 tarball, sha256-verified, cached
│   ├── Info.plist.template            # LSUIElement=true, CFBundleIdentifier ai.pipecat.LocalTTS, ...
│   └── PipecatTTS.entitlements        # minimal (hardened runtime, no sandbox)
├── Resources/AppIcon.icns
├── Sources/PipecatTTS/
│   ├── App/        PipecatTTSApp.swift (MenuBarExtra .window), AppDelegate.swift, Launch.swift
│   ├── Model/      Backend.swift, BackendCatalog.swift, BackendState.swift, AppModel.swift, BackendModel.swift
│   ├── Services/   Paths.swift, ToolLocator.swift, Subprocess.swift, LineSplitter.swift,
│   │               EnvironmentManager.swift, ServerProcess.swift, ServerSupervisor.swift,
│   │               PortProbe.swift, LogSink.swift, Settings.swift
│   ├── Protocol/   TTSMessages.swift, TTSWebSocketClient.swift
│   ├── Audio/      AudioPlayer.swift, TryItSession.swift
│   └── Views/      MenuBarLabel, RootView, HeaderView, BackendListView, BackendRowView,
│                   BackendDetailView, TryItView, LicenceBadge, StatusDot, Components
└── Tests/PipecatTTSTests/  LineSplitterTests, BackendCatalogTests, BackendStateTests, PCMConversionTests
```

`justfile` additions: `app-build`, `app-run *args` (`swift run PipecatTTS`), `app-open`,
`app-test`. `.gitignore`: `macos/.build/`, `macos/build/`. Re-run
`tests/test_justfile_recipes.py` after editing the justfile.

### B2. Build script (`build_app.sh`)

1. `uv build --wheel --out-dir dist` at repo root; pick newest `pipecat_local_tts_server-*.whl`.
2. `fetch_uv.sh` → cached `uv` (pinned version + committed sha256; `curl --retry 3`;
   `shasum -c`; strip quarantine defensively).
3. `swift build -c release`; locate binary via `swift build --show-bin-path`.
4. Assemble `macos/build/Pipecat TTS.app`: `Contents/MacOS/PipecatTTS`, `Info.plist`
   (version patched via PlistBuddy from `pyproject.toml`), `AppIcon.icns`,
   `Resources/bin/uv`, `Resources/wheels/<whl>` + `MANIFEST` naming it, `PkgInfo`.
5. Codesign inside-out: `uv` first, then the bundle with `--options runtime` and the
   entitlements; `SIGN_IDENTITY` env defaults to `-` (ad-hoc). `codesign --verify --deep
   --strict`.

### B3. Services

- **`AppPaths`**: `~/Library/Application Support/Pipecat TTS/{python,cache,envs/<b>}`,
  `envs/<b>/.pipecat-tts.json` marker `{wheel, version, extra, createdAt}`,
  `.layout-version` = `1`, logs at `~/Library/Logs/pipecat-tts/<b>.app.log`.
- **`ToolLocator`**: uv from bundle `Resources/bin/uv` → `$UV` → `~/.local/bin/uv` → PATH;
  wheel from bundle `MANIFEST` → `--wheel`/`$PIPECAT_TTS_WHEEL` → if running from the
  checkout (walk up for `pyproject.toml`), run `uv build --wheel`.
- **`Subprocess`** (`@unchecked Sendable` class, the Swift 6 pitfall layer): `Process` +
  `Pipe`s; `readabilityHandler` → `LineSplitter` (splits on `\n` **and** `\r`, uv uses
  CR progress) → `AsyncStream<String>` for stdout/stderr; `terminationHandler` finishes
  streams and resolves a termination task; closures capture only Sendable continuations.
  Optional held stdin pipe (`closeStdin()`), `signal(_:)`, explicit **clean environment**
  (`PATH`, `HOME`, `TMPDIR`, `LANG`, `PYTHONUNBUFFERED=1`, `NO_COLOR=1`, `TERM=dumb`,
  `UV_*`, `HF_HUB_DISABLE_TELEMETRY=1`). Do **not** set `HF_HOME`: share the user's
  standard HF cache so weights are shared with CLI/launchd usage.
- **`EnvironmentManager`** (actor, serialises installs): `uv venv --python 3.12
  --no-config <env>` with `UV_PYTHON_INSTALL_DIR`, `UV_CACHE_DIR`, `UV_NO_CONFIG=1`,
  `UV_PYTHON_PREFERENCE=only-managed`; `uv pip install --python <env>/bin/python
  "pipecat-local-tts-server[<extra>] @ file://<wheel>"`; write marker; then
  `<env>/bin/python -m tts_server prefetch --backend <b> --json` decoding the A2 event
  stream. Events: `phase(venv|install|prefetch)`, `log(line)`, `downloadStart`,
  `downloadProgress(downloaded,total?)`, `convert`, `done`. `checkModelCached` runs
  `prefetch --check --json`. `remove` = `rm -rf envs/<b>` (HF cache untouched). Cancel =
  SIGTERM the current subprocess.
- **`ServerProcess`** (actor): spawns `<env>/bin/python -m tts_server serve --backend b
  --host 127.0.0.1 --port P --supervised` with held stdin; waits for the `ready` JSON
  line (timeout 15 s tone / 180 s model backends); stdout `error` event → typed failure
  (`EADDRINUSE` → portBusy); stderr → `LogSink` file + 200-line ring. `stop()` = SIGTERM
  + close stdin, wait ≤10 s, SIGKILL.
- **`ServerSupervisor`** (actor): `Backend → ServerProcess`; `shutdownAll(grace: 10s)` in
  parallel.
- **`PortProbe`**: bind test; `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fpc` for owner;
  `launchctl print gui/<uid>/pipecat.tts-server.<b>` to name a loaded launchd agent in
  the error message, with a copyable command.
- **`TTSWebSocketClient`** (actor over `URLSessionWebSocketTask`, `ws://127.0.0.1:P/`):
  `connect() -> ServerHello`, `events` stream (`hello/status/created/delta/done/
  cancelled/failed/error/closed`), `requestStatus`, `speak(text, voice)` =
  `session.update` (if voice) → `input_text.append` → `input_text.commit`, `cancel()` =
  `response.cancel`, `close()`. Decode via `Envelope{type}` then concrete structs;
  `audio` base64 → `Data`. Keep it behind a small `TTSTransport` protocol: **verify
  early** that URLSession sends no `Origin` header (server 403s any Origin,
  [server.py:592](tts_server/server.py:592)); fallback is `NWConnection` +
  `NWProtocolWebSocket`.
- **`AudioPlayer`**: `AVAudioEngine` + `AVAudioPlayerNode`, Float32 mono format at
  `hello.audio.rate` (mixer resamples); Int16LE → Float32 (`/32768`) via `vDSP_vflt16`;
  coalesce ~100 ms per scheduled buffer, schedule immediately on `done`; `flush()` on
  cancel; `onDrained` from the last buffer's `.dataPlayedBack` completion.
- **`TryItSession`** (`@MainActor @Observable`): `attach(port)` → hello → voices via
  `server.status` when `voice_count > 0`; `speak`, `cancel`, `detach`; phases
  idle/connecting/speaking/cancelling/failed; drop late deltas for a cancelled response;
  warn when text exceeds `capabilities.max_text_chars`.

### B4. State machine (per backend, owned by `AppModel`/`BackendModel`)

```
notInstalled ─DOWNLOAD→ installingEnv ─ok→ downloadingModel ─done→ ready ─START→ starting ─ready line→ running
   ▲                      │fail                  │fail/cancel          ▲             │exit early         │unexpected exit
   └─REMOVE─ error(envInstallFailed)      error(modelDownloadFailed)  └─exit─ stopping ←STOP─┘   error(serverCrashed)
tone skips downloadingModel. RETRY after a model failure re-runs only prefetch (resumable).
```
Derived from disk at launch, never stored: env exists (python + marker, wheel filename
matches current wheel → else `needsReinstall`), model cached (`prefetch --check --json`,
lazy, 10 s timeout), layout version. Running state is never persisted (servers die with
the app via `--supervised`). UserDefaults only: last Try-it text, last voice per backend,
`launchAtLogin` hook, dev overrides.

### B5. UI

- `MenuBarExtra` with `.menuBarExtraStyle(.window)`, label `waveform.circle` /
  `waveform.circle.fill` when anything runs (hierarchical rendering).
- `AppDelegate`: `NSApp.setActivationPolicy(.accessory)` (needed under `swift run`);
  `applicationShouldTerminate` → `.terminateLater`, `shutdownAll`, then reply; same on
  `NSWorkspace.willPowerOffNotification`; refuse a second instance.
- `RootView` 380 pt wide: header (name, "2 running · 3 installed"), provider list rows
  (status dot colours: grey/blue-pulsing/green/orange/red; name; licence capsule badge:
  neutral Apache/CC-BY, orange CC-BY-NC, red research-only; subtitle = port/model/progress
  detail; trailing Download/Start/Stop/Retry or spinner), footer (Quit, gear hook).
- `BackendDetailView` (push navigation): Endpoint (`ws://127.0.0.1:P/` + copy), Model
  (repo, licence, cache size), Voices (chips/picker), Try it (`TextField` axis vertical,
  voice picker, Speak/Stop + activity indicator), Log (last 10 lines, monospaced, "Reveal
  log file"), Remove (destructive, confirmed).
- Progress: env step indeterminate with a sub-phase label parsed from uv's last line
  ("Installing Python 3.12…", "Creating environment…", "Installing kokoro extra…") and a
  6-line log tail; prefetch step determinate from bytes (`ByteCountFormatter`), UI
  updates throttled to ~10 Hz.

### B6. Edge cases to handle

Port busy (pre-check + classify `EADDRINUSE` from the supervised error event); offline
(`NWPathMonitor` hint before install); install failure → wipe partial env on retry;
download cancel/resume; crash → `error(serverCrashed)` with Restart, never auto-restart;
quit/SIGKILL of the app → children exit on stdin EOF; stale layout banner; env dir without
marker → "Clean up leftover files"; `uv`/wheel missing in bare mode → banner, buttons
disabled; log file rotation at 20 MB. uv-managed Python carries no quarantine attribute;
embedded `uv` must be re-signed inside the bundle.

---

## Sequencing

1. **PR A** (Python): A1 → A2 → A3 → A4. Run the verification below; merge.
2. **PR B** (macOS): B2 script skeleton + B3 `Subprocess`/`Paths`/`ToolLocator` →
   `EnvironmentManager` + `ServerProcess` → `TTSWebSocketClient` (verify Origin early) →
   `AudioPlayer`/`TryItSession` → views → justfile recipes → README.

## Verification

Python:
```sh
uv sync --extra client && uv run ruff check . && uv run ruff format --check .
uv run pytest -x tests/test_import_safety.py tests/test_supervised_cli.py tests/test_prefetch_cli.py tests/test_stale_socket.py tests/test_status_port.py
( sleep 2 ) | uv run python -m tts_server serve --backend tone --host 127.0.0.1 --port 0 --supervised; echo "exit=$?"
uv sync --extra phonon && uv run python -m tts_server prefetch --backend phonon --check --json && uv run python -m tts_server prefetch --backend phonon --model phonon-q8 --json
uv run python -c "from mlx_audio.tts.models.pocket_tts.utils import PREDEFINED_VOICES; print(PREDEFINED_VOICES)"
uv build --wheel && uv venv --python 3.12 /tmp/tts-app-venv && uv pip install --python /tmp/tts-app-venv/bin/python "pipecat-local-tts-server[phonon] @ file://$PWD/dist/pipecat_local_tts_server-0.7.0-py3-none-any.whl" && /tmp/tts-app-venv/bin/pipecat-tts --help
tests/smoke/run_smoke.sh --backend tone
```

Swift / app:
1. `cd macos && swift build && swift test` clean under strict concurrency.
2. `swift run PipecatTTS`: no Dock icon, menu bar icon present, tools located
   (`~/.local/bin/uv`, wheel built into `dist/`).
3. `just app-build`: bundle contains `Resources/bin/uv`, `Resources/wheels/*.whl`;
   `codesign --verify --deep --strict` passes; `open` launches menu-bar-only.
4. Download **tone** → ready; `envs/tone/.pipecat-tts.json` names the wheel. Start →
   running on 8665; `uv run python -m tts_server status --host 127.0.0.1 --port 8665` ok;
   log file has `listening on`. Try it → audible tone; Stop → immediate silence and
   `response.cancelled` in the log; **no 403** (else switch transport).
5. Download **phonon** → determinate model progress → ready; relaunch shows ready
   (`--check` cached). Start → running; Try it speaks with `default` voice at 24 kHz.
6. Port busy: start a listener on 8765 (or `just tts-install kokoro`), Start kokoro →
   message names pid/launchd label with copyable `launchctl print` command.
7. `kill -9 <server pid>` → row shows crashed + Restart. Quit with servers running →
   `pgrep -f "tts_server serve"` empty within 10 s; `kill -9` the app → servers exit on
   stdin EOF.
8. Remove tone → `envs/tone` gone, row back to Not installed.
9. `uv run pytest tests/test_justfile_recipes.py` still passes.
