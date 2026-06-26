# Operator-convenience recipes for the pipecat TTS servers.
#
# macOS / launchctl only, mirroring the sibling pipecat-local-stt-server justfile.
# This is the cross-agent "operate the listed servers" surface.
#
# SCOPE NOTE — only the read-only recipes are present today. The stt justfile also
# carries stt-install / stt-enable / stt-disable / stt-uninstall, but those delegate
# to scripts/install_stt_agent.sh + a plist renderer. The TTS server has no launchd
# install path yet (no scripts/install_tts_agent.sh, no plist template), so adding
# those recipes would point at files that do not exist. They are intentionally
# omitted until that install path lands (tracked in the dev plan). `tts-list` and
# `tts-status` work today against any running server.
#
# The label -> socket map below mirrors the README quick-start convention
# (`~/Library/Caches/pipecat-tts/tts.sock`). When a launchd install path is added,
# extend this map (and add a mirror test) the same way stt does.

set shell := ["bash", "-uc"]

# cache_dir / la_dir derive from $HOME via env_var(), evaluated when the recipe
# runs (not at parse time) so tests can point them at a temp HOME. Overridable on
# the command line (e.g. `just la_dir=/tmp/x tts-list`).
cache_dir := env_var('HOME') / "Library/Caches/pipecat-tts"
la_dir := env_var('HOME') / "Library/LaunchAgents"

# Default: show the recipe list.
default:
    @just --list

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
      # Live backend probe — canonical sockets only (a custom label's socket is
      # not derivable from its label, so it gets no socket/live line by design).
      sock=""
      case "$label" in
        pipecat.tts-server) sock="{{cache_dir}}/tts.sock" ;;
      esac
      if [[ -n "$sock" ]]; then
        # Print the socket in the same ~-form the README quick-start uses, so an
        # operator can match a config line to an agent directly.
        printf '         socket: %s\n' "${sock/#$HOME/~}"
        # status raises SystemExit(1) on a stopped/absent socket and never prints
        # "stopped"/"unreachable" itself, so the recipe owns that display.
        if live=$(uv run python -m tts_server status --socket-path "$sock" 2>/dev/null); then
          backend=$(grep -m1 -E '^[[:space:]]*backend:' <<<"$live" | sed -E 's/.*backend:[[:space:]]*//')
          printf '         live: %s\n' "${backend:-?}"
        else
          printf '         live: stopped/unreachable\n'
        fi
      else
        printf '         socket: (custom label — not in the canonical map)\n'
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
          backend=$(grep -m1 -E '^[[:space:]]*backend:' <<<"$live" | sed -E 's/.*backend:[[:space:]]*//')
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
# Defaults to the canonical README socket; override for a custom socket/host.
tts-status socket=(cache_dir / "tts.sock"):
    #!/usr/bin/env bash
    set -uo pipefail
    exec uv run python -m tts_server status --socket-path {{quote(socket)}}

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

# Two clients interleaving through one backend: fairness + max-buffer + 429/BUSY.
smoke-multiconn *args:
    tests/smoke/run_multiconn.sh {{args}}

# Crash-restart-reconnect: SIGKILL the server, restart, client reconnects w/ backoff.
smoke-reconnect *args:
    tests/smoke/run_reconnect.sh {{args}}
