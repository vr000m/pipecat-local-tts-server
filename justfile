# Operator-convenience recipes for managing the pipecat TTS LaunchAgents.
#
# macOS / launchctl only, mirroring the sibling pipecat-local-stt-server justfile.
# This is the cross-agent "operate the listed servers" surface.
#
# Transport divergence from stt: the stt agents bind a Unix socket; the tts
# agents bind a loopback **TCP port** (one backend = one process = one port). The
# `_resolve` map below yields (label, host, port) — NOT (label, socket, backend)
# — and the per-backend lifecycle recipes delegate to scripts/install_tts_agent.sh
# + scripts/render_tts_plist.py.
#
# The backend -> (label, host, port) map below is the single source of truth that
# the README "Per-backend port convention" table and render_tts_plist.py defaults
# must agree with. A drift test (tests/test_justfile_recipes.py) parses the README
# table and asserts this map equals it, so drift fails CI.
#
# The Unix socket stays the DEFAULT for a single ad-hoc server / README
# quick-start (`pipecat.tts-server` -> `tts.sock`); ports are the multi-backend
# convention. `dia` is reserved and intentionally NOT in this map (no --backend
# choice until its own plan lands — adding it here would turn the drift test red).
#
# tts-disable vs tts-uninstall: the rendered plist sets RunAtLoad=True +
# KeepAlive=True. So `tts-disable` (launchctl bootout, plist kept) takes the agent
# down only until the next login — launchd reloads it from the on-disk plist.
# `tts-uninstall` removes the plist, so it stays gone.

set shell := ["bash", "-uc"]

# cache_dir / la_dir derive from $HOME via env_var(), evaluated when the recipe
# runs (not at parse time) so tests can point them at a temp HOME. Overridable on
# the command line (e.g. `just la_dir=/tmp/x tts-list`).
cache_dir := env_var('HOME') / "Library/Caches/pipecat-tts"
la_dir := env_var('HOME') / "Library/LaunchAgents"
# Overridable so tests can point install/uninstall delegation at a stub.
script := justfile_directory() / "scripts/install_tts_agent.sh"

# Default: show the recipe list.
default:
    @just --list

# Resolve a backend name to LABEL / HOST / PORT on three separate lines (one
# field per line so the reads stay bash-3.2-compatible — macOS system bash has
# no `mapfile`); fail fast on unknown. `quote()` shell-escapes the interpolated
# arg so it can never break out of the `case` — the `case` arms are the
# allowlist. This is the canonical port map (must match README + renderer).
# `dia` is reserved and deliberately absent.
_resolve backend:
    #!/usr/bin/env bash
    backend={{quote(backend)}}
    case "$backend" in
      tone)        printf '%s\n' "pipecat.tts-server.tone"        "127.0.0.1" "8665" ;;
      kokoro)      printf '%s\n' "pipecat.tts-server.kokoro"      "127.0.0.1" "8765" ;;
      voxtral_tts) printf '%s\n' "pipecat.tts-server.voxtral_tts" "127.0.0.1" "8865" ;;
      pocket_tts)  printf '%s\n' "pipecat.tts-server.pocket_tts"  "127.0.0.1" "8965" ;;
      *) echo "error: unknown backend '$backend' (valid: tone, kokoro, voxtral_tts, pocket_tts)" >&2; exit 1 ;;
    esac

# Extract the serve endpoint from an installed agent's plist ProgramArguments.
# Emits FOUR lines — host, port, socket-path, auth-token-file — each empty when
# the flag is absent. The plist render_tts_plist.py wrote is the source of truth,
# so tts-list never re-encodes the _resolve map and stays correct for any label
# or transport. Auth-aware: a secured agent's plist carries --auth-token-file, so
# the status probe can authenticate instead of getting a 401. Its own recipe so
# the extraction is unit-testable (see tests/test_justfile_recipes.py).
_plist_endpoint plist:
    #!/usr/bin/env bash
    set -uo pipefail
    plist={{quote(plist)}}
    host=""; port=""; sock=""; authfile=""; prev=""
    while IFS= read -r s; do
      case "$prev" in
        --host)            host="$s" ;;
        --port)            port="$s" ;;
        --socket-path)     sock="$s" ;;
        --auth-token-file) authfile="$s" ;;
      esac
      prev="$s"
    done < <(sed -n 's/.*<string>\(.*\)<\/string>.*/\1/p' "$plist")
    printf '%s\n' "$host" "$port" "$sock" "$authfile"

# List every pipecat.tts-server* agent with state, pid, and live backend.
tts-list:
    #!/usr/bin/env bash
    set -uo pipefail
    shopt -s nullglob
    uid=$(id -u)
    found=0
    for plist in "{{la_dir}}"/pipecat.tts-server*.plist; do
      found=1
      label=$(basename "$plist" .plist)
      target="gui/$uid/$label"
      # launchctl print exits non-zero when the agent is not loaded; reuse the
      # same fields the stt recipe greps (state|pid).
      if info=$(launchctl print "$target" 2>/dev/null); then
        pid=$(grep -m1 -E '^[[:space:]]*pid = ' <<<"$info" | grep -oE '[0-9]+' | head -1)
        state=$(grep -m1 -E '^[[:space:]]*state = ' <<<"$info" | sed -E 's/.*state = //')
        printf 'running  %-32s pid=%-7s state=%s\n' "$label" "${pid:-?}" "${state:-?}"
      else
        printf 'stopped  %-32s (plist present, not loaded)\n' "$label"
      fi
      # Live backend probe. Read the endpoint straight from the agent's OWN plist
      # via _plist_endpoint (four lines: host/port/socket/auth-token-file) instead
      # of a hardcoded per-label map — never drifts from _resolve, works for ANY
      # label/transport, and stays auth-aware.
      { read -r host; read -r port; read -r sock; read -r authfile; } < <(just _plist_endpoint "$plist")
      # A secured agent's plist carries --auth-token-file; forward it so the probe
      # authenticates instead of getting a 401 and being mislabeled unreachable.
      # Empty-safe array expansion for bash 3.2 under `set -u`.
      auth=()
      [[ -n "$authfile" ]] && auth=(--auth-token-file "$authfile")
      # status raises SystemExit(1) on a stopped/absent endpoint and never prints
      # "stopped"/"unreachable" itself, so the recipe owns that display. The
      # backend line is `backend: <name> (model: <m>)`, so capture only the first
      # token after `backend:` — never the `(model: ...)` suffix.
      if [[ -n "$sock" ]]; then
        printf '         socket: %s\n' "${sock/#$HOME/~}"
        if live=$(uv run python -m tts_server status --socket-path "$sock" "${auth[@]+"${auth[@]}"}" 2>/dev/null); then
          backend=$(grep -m1 -E '^[[:space:]]*backend:' <<<"$live" | sed -E 's/.*backend:[[:space:]]*([^[:space:]]+).*/\1/')
          printf '         live: %s\n' "${backend:-?}"
        else
          printf '         live: stopped/unreachable\n'
        fi
      elif [[ -n "$host" && -n "$port" ]]; then
        printf '         endpoint: %s:%s\n' "$host" "$port"
        if live=$(uv run python -m tts_server status --host "$host" --port "$port" "${auth[@]+"${auth[@]}"}" 2>/dev/null); then
          backend=$(grep -m1 -E '^[[:space:]]*backend:' <<<"$live" | sed -E 's/.*backend:[[:space:]]*([^[:space:]]+).*/\1/')
          printf '         live: %s\n' "${backend:-?}"
        else
          printf '         live: stopped/unreachable\n'
        fi
      else
        printf '         endpoint: (no serve endpoint found in plist)\n'
      fi
    done
    if [[ "$found" -eq 0 ]]; then
      echo "no pipecat.tts-server* agents found in {{la_dir}}"
      # No launchd install path yet; probe the canonical ad-hoc socket too so a
      # server started by hand (README quick-start) still shows up.
      sock="{{cache_dir}}/tts.sock"
      if [[ -S "$sock" ]]; then
        printf 'running  %-32s (ad-hoc, no plist)\n' "pipecat.tts-server"
        printf '         socket: %s\n' "${sock/#$HOME/~}"
        if live=$(uv run python -m tts_server status --socket-path "$sock" 2>/dev/null); then
          backend=$(grep -m1 -E '^[[:space:]]*backend:' <<<"$live" | sed -E 's/.*backend:[[:space:]]*([^[:space:]]+).*/\1/')
          printf '         live: %s\n' "${backend:-?}"
        else
          printf '         live: stopped/unreachable\n'
        fi
      fi
    fi
    # Deliberate: this recipe is a read-only status sweep. Per-agent probe
    # failures (stopped socket, unloaded agent) are already absorbed into display
    # lines above, so the recipe as a whole always succeeds.
    exit 0

# Wire status probe for one server (exits with the probe's own status).
#
# With NO argument, probes the canonical ad-hoc Unix socket (the README
# quick-start default). With a known backend name (tone/kokoro/voxtral_tts/
# pocket_tts) it resolves that backend's canonical --host/--port from the
# _resolve map and probes the port. Any other value is treated as a literal
# socket path (the previous override behaviour is preserved as a fallback).
tts-status target=(cache_dir / "tts.sock"):
    #!/usr/bin/env bash
    set -uo pipefail
    target={{quote(target)}}
    # A value that looks like a path (contains '/', or is an existing socket
    # file) is ALWAYS a literal --socket-path, so a socket file that happens to
    # share a backend's name is never silently reinterpreted as a TCP port. Only
    # a bare backend name resolves to its canonical host:port.
    if [[ "$target" == */* || -S "$target" ]]; then
      exec uv run python -m tts_server status --socket-path "$target"
    fi
    case "$target" in
      tone|kokoro|voxtral_tts|pocket_tts)
        resolved=$(just _resolve "$target") || exit 1
        # One field per line; three reads keep this bash-3.2-compatible.
        { read -r label; read -r host; read -r port; } <<<"$resolved"
        exec uv run python -m tts_server status --host "$host" --port "$port"
        ;;
      *)
        # A bare non-backend token that is not path-like: treat as a socket path.
        exec uv run python -m tts_server status --socket-path "$target"
        ;;
    esac

# --- launchd lifecycle (one TCP-port-bound agent per backend) ---------------
# Each recipe resolves (label, host, port) from the canonical _resolve map, then
# delegates state changes to launchctl / scripts/install_tts_agent.sh. set -uo
# pipefail does NOT abort on a failed simple command, so each state change is
# guarded explicitly — otherwise a success echo would mask a launchctl failure.

# Install an agent — delegates to install_tts_agent.sh (no plist reimplementation).
tts-install backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    PIPECAT_TTS_LABEL="$label" PIPECAT_TTS_BACKEND="$backend" \
      PIPECAT_TTS_HOST="$host" PIPECAT_TTS_PORT="$port" \
      "{{script}}" install

# Uninstall an agent (removes the plist) — delegates to install_tts_agent.sh.
tts-uninstall backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    PIPECAT_TTS_LABEL="$label" PIPECAT_TTS_BACKEND="$backend" \
      PIPECAT_TTS_HOST="$host" PIPECAT_TTS_PORT="$port" \
      "{{script}}" uninstall

# Re-load + start an agent from its existing plist (no re-render).
tts-enable backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    uid=$(id -u)
    plist="{{la_dir}}/$label.plist"
    if [[ ! -e "$plist" ]]; then
      echo "tts-enable: no plist at $plist — run 'just tts-install $backend' first" >&2
      exit 1
    fi
    # Idempotent: unload first if already loaded (mirrors install_tts_agent.sh),
    # so re-running tts-enable on a loaded agent re-bootstraps cleanly instead of
    # erroring with "service already bootstrapped".
    launchctl bootout "gui/$uid/$label" 2>/dev/null || true
    if ! launchctl bootstrap "gui/$uid" "$plist"; then
      echo "tts-enable: launchctl bootstrap failed for $label" >&2
      exit 1
    fi
    if ! launchctl enable "gui/$uid/$label"; then
      echo "tts-enable: launchctl enable failed for $label" >&2
      exit 1
    fi
    if ! launchctl kickstart "gui/$uid/$label"; then
      echo "tts-enable: launchctl kickstart failed for $label" >&2
      exit 1
    fi
    echo "tts-enable: bootstrapped + kickstarted $label"

# Stop an agent until next login (launchctl bootout; plist kept). Idempotent.
tts-disable backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    uid=$(id -u)
    if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      echo "tts-disable: $label not loaded — nothing to do"
      exit 0
    fi
    if ! launchctl bootout "gui/$uid/$label"; then
      echo "tts-disable: launchctl bootout failed for $label" >&2
      exit 1
    fi
    echo "tts-disable: booted out $label (plist kept; reloads at next login)."
    echo "             Use 'just tts-uninstall $backend' to remove it durably."

# Force-restart a loaded agent (launchctl kickstart -k).
tts-start backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    uid=$(id -u)
    if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      echo "tts-start: $label not loaded — run 'just tts-install $backend' first" >&2
      exit 1
    fi
    if ! launchctl kickstart -k "gui/$uid/$label"; then
      echo "tts-start: launchctl kickstart failed for $label" >&2
      exit 1
    fi
    echo "tts-start: kickstarted $label"

# Send SIGTERM to a loaded agent (KeepAlive will restart it; use tts-disable to
# take it down until next login, tts-uninstall to remove durably).
tts-stop backend:
    #!/usr/bin/env bash
    set -uo pipefail
    backend={{quote(backend)}}
    resolved=$(just _resolve "$backend") || exit 1
    { read -r label; read -r host; read -r port; } <<<"$resolved"
    uid=$(id -u)
    if ! launchctl print "gui/$uid/$label" >/dev/null 2>&1; then
      echo "tts-stop: $label not loaded — nothing to do"
      exit 0
    fi
    if ! launchctl kill SIGTERM "gui/$uid/$label"; then
      echo "tts-stop: launchctl kill failed for $label" >&2
      exit 1
    fi
    echo "tts-stop: sent SIGTERM to $label (KeepAlive restarts it; use tts-disable to keep it down)"

# --- Live smoke tests (start a real server on an isolated socket) -----------
# See tests/smoke/README.md. These never touch the canonical operator socket.

# Tone backend end-to-end (no model; fast). Verifies the protocol + rate contract.
smoke-tone *args:
    tests/smoke/run_smoke.sh --backend tone {{args}}

# Kokoro backend, English. Auto-syncs the kokoro extra if missing.
smoke-kokoro *args:
    tests/smoke/run_smoke.sh --backend kokoro {{args}}

# Kokoro, one utterance per supported language (ja/zh report SKIP — see README).
smoke-multilingual *args:
    tests/smoke/run_smoke.sh --backend kokoro --multilingual {{args}}

# Voxtral TTS backend (streaming:true). WAV round-trip + TTFB/cadence assertion.
# Auto-syncs the voxtral_tts extra if missing (CC-BY-NC weights; see README).
smoke-voxtral_tts *args:
    tests/smoke/run_smoke.sh --backend voxtral_tts {{args}}

# Pocket TTS backend (streaming:true, fast). WAV round-trip + TTFB/cadence.
# Auto-syncs the pocket_tts extra if missing (CC-BY-4.0 weights; see README).
smoke-pocket_tts *args:
    tests/smoke/run_smoke.sh --backend pocket_tts {{args}}

# Two clients interleaving through one backend: fairness + max-buffer + 429/BUSY.
smoke-multiconn *args:
    tests/smoke/run_multiconn.sh {{args}}

# Multi-connection concurrency against the streaming voxtral_tts backend.
smoke-multiconn-voxtral_tts *args:
    tests/smoke/run_multiconn.sh --backend voxtral_tts {{args}}

# Multi-connection concurrency against the streaming pocket_tts backend.
smoke-multiconn-pocket_tts *args:
    tests/smoke/run_multiconn.sh --backend pocket_tts {{args}}

# Crash-restart-reconnect: SIGKILL the server, restart, client reconnects w/ backoff.
smoke-reconnect *args:
    tests/smoke/run_reconnect.sh {{args}}
