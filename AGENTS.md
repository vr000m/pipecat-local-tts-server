# AGENTS.md — pipecat-local-tts-server

Operator/agent contract for this repo. Human-facing docs live in
[`README.md`](README.md) (usage) and [`docs/protocol.md`](docs/protocol.md) (wire
spec); this file is the quick command/convention reference. Mirrors the sibling
[`pipecat-local-stt-server`](https://github.com/vr000m/pipecat-local-stt-server).

## What this is

A standalone local WebSocket **text-to-speech** server: text in, int16-LE mono
PCM out over a Unix domain socket or loopback TCP. Wire protocol v0.1
(OpenAI-Realtime-inspired). The base package is lean (`websockets` only); model
backends (Kokoro, via mlx-audio on Apple Silicon) are lazy-imported behind extras
so a client-only consumer never pulls the heavy runtime. Import name: `tts_server`.

## Environment & install

Use `uv` for everything (a bare `python -m tts_server` uses the system interpreter
and fails on the missing `websockets`).

```sh
uv sync --extra client     # lean base (websockets) — client/bot consumer
uv sync --extra kokoro     # Kokoro backend (Apple Silicon; mlx-audio==0.4.4 + misaki[en])
uv sync --extra examples   # reference Pipecat adapter (pins pipecat-ai==1.4.0)
```

## CLI (`python -m tts_server <subcommand>`)

Endpoint precedence everywhere: **URI > socket > host+port**.

| Subcommand | Flags | Notes |
|---|---|---|
| `serve` (default) | `--backend {tone,kokoro}` (default `tone`), `--model <id>`, `--socket-path`, `--host`, `--port`, `--auth-token-file <path>`, `--log-level <LEVEL>` (default `INFO`) | Runs the server. `--model` defaults per backend (Kokoro repo for `kokoro`; none for `tone`). No `--uri` (the listener is built from socket-path/host+port). |
| `status` | `--socket-path`, `--host`, `--port`, `--uri <ws://…>`, `--auth-token-file`, `--timeout <s>` (default `3.0`), `--json` | Preflight health probe: handshake + `server.status`, prints backend/model/rate/caps/queue-depth/voices/uptime/pid. Exits non-zero if unreachable. `--json` emits raw `hello`+`status`. |

A plaintext `--auth-token` flag is **intentionally unsupported** (`ps` exposure) —
use `--auth-token-file`.

## Environment variables

| Variable | Side | Purpose |
|---|---|---|
| `TTS_WS_URI` / `TTS_WS_SOCKET` / `TTS_WS_HOST` / `TTS_WS_PORT` | client | Endpoint (precedence URI > socket > host+port). |
| `TTS_WS_TOKEN` | client | Bearer the client/probe sends. **Never** falls back to the server var. |
| `TTS_WS_DEFAULT_SOCKET` | client | Explicit fallback socket for `status` when nothing else is set. |
| `PIPECAT_TTS_AUTH_TOKEN` | server | Bearer the server requires (optional auth). |
| `PIPECAT_TTS_KOKORO_EXTRA_LANGS` | server | Comma-separated ISO codes (e.g. `ja,zh`) to re-advertise after installing their extra G2P package. |

CLI flags and env vars are **trusted** inputs; untrusted input is websocket
traffic. The UDS (default mode `0o600`, parent-dir guarded) is the trust boundary.

## Tests

```sh
uv run pytest                              # full suite (needs an env with extras)
uv run pytest tests/test_kokoro_backend.py # mlx-gated synthesis (Apple Silicon only)
```

CI splits into a **lean** job (client-only, asserts no mlx/numpy import; runs an
explicit allow-list of lean test files — extend it when adding a lean test), an
**examples** job (pinned pipecat-ai), and a **macOS smoke** job (verifies the
kokoro extra resolves/imports; does not run synthesis). See
`.github/workflows/test.yml`.

A separate **release** workflow (`.github/workflows/release.yml`) runs only when a
GitHub Release is *published*: it builds the sdist + wheel, fails if the release
tag does not match the `pyproject` version, then publishes to PyPI via Trusted
Publishing (OIDC — no token). A plain merge or tag push does not trigger it.

## justfile recipes (macOS operator surface)

| Recipe | Action |
|---|---|
| `just tts-list` | List `pipecat.tts-server*` launchd agents (state, pid, backend). |
| `just tts-status [target]` | Wire `status` probe. `target` is a backend name (probes its canonical `_resolve` port), a socket path, or defaults to the canonical socket. |
| `just tts-install <backend>` | Render plist + `launchctl bootstrap` (operator-manual, not CI-verified). |
| `just tts-uninstall <backend>` | `launchctl bootout` + remove plist, teardown-verified (operator-manual). |
| `just tts-enable <backend>` | Re-load from the existing plist + start (`launchctl bootstrap`/`enable`/`kickstart`). |
| `just tts-disable <backend>` | Take down until next login (`launchctl bootout`; plist kept). |
| `just tts-start <backend>` | Ensure running (`launchctl kickstart`; no-op if already up). |
| `just tts-restart <backend>` | Force-restart a loaded agent (`launchctl kickstart -k`). |
| `just tts-stop <backend>` | Send SIGTERM (`launchctl kill`; KeepAlive restarts it). |
| `just tts-logs <backend>` | Tail the agent's stdout+stderr logs. |
| `just smoke-tone` / `smoke-kokoro` / `smoke-multilingual` | Live end-to-end smoke (starts a real server on an isolated socket). |
| `just smoke-multiconn` / `smoke-reconnect` | Multi-connection fairness / reconnect smoke. |

Smoke scripts start their own server on a `mktemp` socket and tear it down — they
**never** touch the canonical operator socket.

## Protocol (summary — full spec in `docs/protocol.md`)

JSON text frames with a `type`. Client drives: `session.update` →
`input_text.append`* → `input_text.commit` (the commit is the unit of work). Server
streams `response.audio.delta` (base64 pcm16, gapless `seq` from 0) ending in
`response.audio.done`; `response.cancel` is barge-in (`response.cancelled`,
client-visible in ~1 ms). Per-backend `server.hello.capabilities`; canonical rate is
`server.hello.audio.rate` (Kokoro 24000 Hz), not in capabilities. `voice`/`language`
are validated against the advertised lists (fail-closed); `speed` is clamped to
`[0.5, 2.0]`.

## Conventions

- Keep the lean base import-clean: never import mlx/numpy/torch at module load in
  `tts_server` or its backends — lazy-import inside `start()`/`_get_model`.
- Backends implement the `TTSBackend`/`TTSStream` protocols in `tts_server/backend.py`;
  register them in `tts_server/backends/__init__.py` (`make_backend`). The server
  depends only on the abstract protocol types.
- `ruff format` **and** `ruff check` must be clean before pushing.

## Layout

- `tts_server/` — protocol, backend abstraction, server, async client, CLI.
- `tts_server/backends/` — lazy-imported per-model backends (Kokoro first).
- `examples/` — stdlib oracle (`reference_client.py`) + Pipecat adapter (`pipecat_tts_service.py`).
- `tests/`, `tests/smoke/` — unit + live smoke tests.
- `scripts/render_tts_plist.py` — plist renderer for launchd agents (pure `plistlib`, injection-safe, fail-closed auth).
- `scripts/install_tts_agent.sh` — env-keyed `launchctl bootstrap` lifecycle wrapper.
- `scripts/profiling/` — RTF/latency benchmarks (perf baseline for new backends).
- `docs/protocol.md`, `docs/dev_plans/` — wire spec, development plans.
