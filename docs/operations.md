# Server operations

Run, inspect, prefetch, and supervise local TTS servers. For model selection,
licenses, voices, languages, and backend limits, see [Backends](backends.md).
For wire messages and client behavior, see the [protocol](protocol.md).

## Starting a server

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


## Running multiple backends with launchd

The canonical backend-to-port map remains in the root
[README](../README.md#per-backend-port-convention), where the repository's drift
test compares it with the CLI, `justfile`, plist renderer, and macOS catalog.
Each installed backend runs as one process on its own loopback TCP port.

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

## Environment variables

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
| `PIPECAT_TTS_AUTH_TOKEN` | server | Bearer token the server requires (optional auth). Unset or empty = no auth; a set-but-blank value or one that is not visible ASCII exits 1 at startup. |
| `PIPECAT_TTS_KOKORO_EXTRA_LANGS` | server | Comma-separated ISO codes (e.g. `ja,zh`) to advertise after installing their extra G2P package. See [Kokoro language support](backends.md#kokoro-language-support-advertised--synthesizable). |
| `PIPECAT_TTS_PHONON_VOICES` | server | Comma-separated Phonon catalog slugs (e.g. `zoey,juniper`) to advertise + download; `default` is always advertised. Unknown/unfetchable slugs are warned and skipped. Baked into the plist for the `phonon` backend only. |
| `TTS_WS_PING_INTERVAL` | server | Keepalive ping period in seconds (default `20`). A disable token (`none`/`off`/`disable`/`disabled` or any zero) disables pings. |
| `TTS_WS_PING_TIMEOUT` | server | Seconds to wait for a pong before closing (default `120`). A disable token (`none`/`off`/`disable`/`disabled` or any zero) disables the timeout (keeps pings, never closes on a slow pong — reintroduces the idle-leak below). |
| `HF_HOME` / `HF_HUB_CACHE` | server | Standard Hugging Face cache location, honoured by both `serve` and `prefetch` (default `~/.cache/huggingface/hub`). |

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
`--auth-token-file`. `serve` refuses a token file that is empty, holds anything but one
visible-ASCII token, or is not UTF-8 (it would otherwise run with auth silently off) and exits 1;
the installer also requires an owner-only regular file (no symlink) in directories owned by you or
root that nobody else can write (group write only on root-owned ones). A token-less server bound to a non-loopback TCP address logs
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

For day-to-day operation on macOS the [`justfile`](../justfile) carries operator
recipes mirroring the sibling stt server. Read-only probes: `just tts-list` lists every
`pipecat.tts-server*` launchd agent with state, pid, and live backend, and
`just tts-status` runs the wire `status` probe against the canonical socket by
default; pass a backend name to probe its canonical port (`just tts-status
kokoro`) or a socket path to probe a specific socket (`just tts-status
/path/to/tts.sock`). Lifecycle recipes: `just tts-install <backend>`,
`just tts-uninstall <backend>`, `just tts-enable <backend>`,
`just tts-disable <backend>`, `just tts-start <backend>`, `just tts-restart <backend>`,
`just tts-stop <backend>`, `just tts-logs <backend>` (all operator-manual; not CI-verified).

## Prefetching models

`serve` downloads weights inside the backend's startup, silently, before it binds.
`prefetch` does the same Hugging Face downloads up front so the first start is
fast, and `--check` answers "is it cached?" without touching the network:

```sh
uv run python -m tts_server prefetch --backend kokoro            # download
uv run python -m tts_server prefetch --backend kokoro --check    # offline probe
uv run python -m tts_server prefetch --backend phonon --model phonon-q8 --json
```

It fetches exactly what `serve` would: the model repo with mlx-audio's file
patterns, plus dia's DAC codec repo, pocket_tts's predefined voice embeddings,
and phonon's pinned revision and `PIPECAT_TTS_PHONON_VOICES` files. For the
`phonon-q8`/`phonon-q4` aliases it also runs the one-time quantization. Weights go
to the standard Hugging Face cache (`HF_HOME` / `HF_HUB_CACHE`), shared with
`serve`. `--check` exits 0 whenever the probe ran; the answer is the `cached`
field. It needs `huggingface_hub`, which every model extra installs.

`--json` prints one JSON object per stdout line:

| Event | Fields |
|---|---|
| `start` | `repo`, `revision`, `kind` (`model` / `codec` / `voice`) |
| `progress` | `repo`, `downloaded_bytes`, `total_bytes`, `files_done`, `files_total`. `total_bytes` counts only files still downloading and grows as they are found. |
| `done` | `repo`, `path`, `size_bytes` |
| `convert` | `repo`, `bits`, `state` (`start` / `done`), `path` (phonon aliases only) |
| `warning` | `repo`, `message` (an optional voice snapshot failed; serve skips it too) |
| `complete` | `backend`, `model`, `cached`, `size_bytes` |
| `check` | `repo`, `revision`, `kind`, `required`, `cached`, `path`, `size_bytes` (with `--check`) |
| `summary` | `backend`, `model`, `cached`, `size_bytes`, plus `quantized` for phonon aliases (with `--check`) |
| `error` | `code`, `message`, `repo`; exit status 1 |

Prefetch does not cover Metal kernel warmup, which `serve` still runs before it
reports ready.

## Supervised mode

`serve --supervised` is for a parent process that manages the server, such as the
[macOS menu bar app](../macos/README.md). Logging on stderr is unchanged. In
addition:

- **stdout carries only JSON lines.** Once the listener is bound and the model is
  warm, the server prints one
  `{"event":"ready","backend","model","host","port","socket_path","rate","pid"}`
  line. With `--port 0` the `port` field is the real port.
- **A fatal error prints `{"event":"error","code","message","exc_type"}`** and
  exits 1. Codes: `EADDRINUSE` (reported before the model loads), `EACCES`,
  `SocketPathConflict`, `ModuleNotFoundError` (backend extra missing),
  `ModelDownloadError`, `ConfigError`, `BackendStartError`.
- **stdin EOF stops the server** exactly like SIGTERM. The parent keeps a pipe
  open and the server exits when the parent closes it or dies. If that happens
  during the model load, the process exits at once; interrupted downloads resume.

```sh
# stdin is the subshell's pipe: it closes after 5 s, so the server exits then.
( sleep 5 ) | uv run python -m tts_server serve --backend tone \
    --host 127.0.0.1 --port 0 --supervised
```

Skip any stdout line that does not parse as JSON: native code writing straight to
file descriptor 1 can bypass the redirect.
