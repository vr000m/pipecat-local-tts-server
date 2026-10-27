#!/usr/bin/env bash
# Install a pipecat.tts-server LaunchAgent so the synthesis server runs at login
# and is auto-restarted by launchd on crash.
#
# Unlike the sibling stt agent (which binds a Unix socket), the tts agent binds a
# loopback **TCP port** — one backend = one process = one port. The port map
# lives in the justfile `_resolve` recipe + the README "Per-backend port
# convention" table; this installer is the env-keyed mechanism those recipes
# delegate to.
#
# Usage:
#   scripts/install_tts_agent.sh [install|uninstall|start|stop|restart|status|logs]
#
# Environment overrides:
#   PIPECAT_TTS_LABEL    launchd label / plist filename (default: pipecat.tts-server)
#   PIPECAT_TTS_BACKEND  backend name: tone|kokoro|voxtral_tts|pocket_tts|dia|qwen3_tts|fish_tts|phonon (default: tone)
#   PIPECAT_TTS_HOST     loopback host to bind (default: 127.0.0.1)
#   PIPECAT_TTS_PORT     TCP port to bind (default: 8665 — the tone agent port)
#   PIPECAT_TTS_MODEL    model id (optional; backend-aware fallback applies when unset;
#                        phonon also takes the aliases phonon|phonon-q8|phonon-q4)
#   PIPECAT_TTS_AUTH_TOKEN_FILE  path to a file with the bearer token (REQUIRED for a
#                        non-loopback host — the renderer is fail-closed). This is the
#                        ONLY supported way to give a launchd agent auth: launchd does
#                        not inherit your shell env, so PIPECAT_TTS_AUTH_TOKEN (the
#                        env-based server token) is NOT carried into the agent — the
#                        renderer rejects an install where it is set without the file.
#                        The file is validated before anything is written: an absolute path to a
#                        regular file (not a symlink) you own with no group/other mode bits, in
#                        directories only you or root can write, holding one visible-ASCII token
#                        (an empty file would silently disable auth, so it is refused).
#   PIPECAT_TTS_KOKORO_EXTRA_LANGS  comma-separated ISO codes (e.g. ja,zh); baked into
#                        the agent's plist EnvironmentVariables so it survives launchd.
#   PIPECAT_TTS_PHONON_VOICES  comma-separated Phonon catalog slugs (e.g. zoey,juniper);
#                        baked into the plist (phonon backend only; ignored with a
#                        warning otherwise). List with: python -m tts_server voices
#   TTS_WS_PING_INTERVAL / TTS_WS_PING_TIMEOUT  websocket keepalive overrides (seconds);
#                        baked into the plist EnvironmentVariables so they survive
#                        launchd. Unset → the server's 120s pong-timeout default applies.
#   PIPECAT_TTS_LOG_DIR  log directory (default: $HOME/Library/Logs/pipecat-tts)
#
# Operational constraint: this script manages exactly ONE agent per invocation,
# identified by PIPECAT_TTS_LABEL (+ its host/port). To manage a non-default
# agent with any subcommand you MUST re-export its PIPECAT_TTS_* env. The `just`
# tts-* recipes do this for you from the canonical port map.
set -euo pipefail

LABEL="${PIPECAT_TTS_LABEL:-pipecat.tts-server}"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RENDER_PY="$REPO_ROOT/scripts/render_tts_plist.py"
PLIST_DST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG_DIR="${PIPECAT_TTS_LOG_DIR:-$HOME/Library/Logs/pipecat-tts}"
BACKEND="${PIPECAT_TTS_BACKEND:-tone}"
HOST="${PIPECAT_TTS_HOST:-127.0.0.1}"
PORT="${PIPECAT_TTS_PORT:-8665}"
MODEL="${PIPECAT_TTS_MODEL:-}"
AUTH_TOKEN_FILE="${PIPECAT_TTS_AUTH_TOKEN_FILE:-}"

# Resolve the python interpreter from the project venv.
PYTHON="$REPO_ROOT/.venv/bin/python"
if [[ ! -x "$PYTHON" ]]; then
    echo "error: $PYTHON not found — run 'uv sync' first" >&2
    exit 1
fi

cmd="${1:-install}"

# Refuse a token file the server would refuse or that others could read or swap:
# the content rules are the server's own (`serve --auth-token-file` runs
# tts_server.env.read_token_file(strict=True) at every start, so an agent this
# accepts is one the server starts), and the file/directory policy is
# tts_server.env.check_token_file_policy (absolute path, not a symlink, a regular
# file you own with no group/other bits, in a directory chain only you or root
# can write). Runs before anything is written or loaded.
validate_token_file() {
    local f="$1"
    if ! "$PYTHON" -I -c '
import sys
from tts_server.env import ConfigError, check_token_file_policy, read_token_file
try:
    check_token_file_policy(sys.argv[1], uid=int(sys.argv[2]))
    read_token_file(sys.argv[1], strict=True)
except ConfigError as exc:
    print(f"error: PIPECAT_TTS_AUTH_TOKEN_FILE: {exc}", file=sys.stderr)
    sys.exit(1)
' "$f" "$(id -u)"; then
        exit 1
    fi
}

render_plist() {
    if [[ -n "$AUTH_TOKEN_FILE" ]]; then
        validate_token_file "$AUTH_TOKEN_FILE"
    fi
    mkdir -p "$LOG_DIR" "$(dirname "$PLIST_DST")"
    # Delegate to plistlib (via render_tts_plist.py) so XML escaping +
    # allowlist validation handle hostile values instead of sed substitution
    # (which would allow <string> breakout + login-time RCE). The renderer is
    # also fail-closed on a non-loopback host with no auth token file.
    #
    # The env-prefix assignments re-export same-named shell vars into the
    # renderer subprocess; the command word "$PYTHON" uses the parent shell's
    # (identical) value, so SC2097/SC2098 are false positives here.
    #
    # PIPECAT_TTS_AUTH_TOKEN / PIPECAT_TTS_KOKORO_EXTRA_LANGS / PIPECAT_TTS_PHONON_VOICES / TTS_WS_PING_* are
    # forwarded explicitly (not left to implicit inheritance) so the renderer's
    # silent-drop guard + EnvironmentVariables pass-through act on the operator's
    # actual env.
    # shellcheck disable=SC2097,SC2098
    PYTHON="$PYTHON" REPO_ROOT="$REPO_ROOT" BACKEND="$BACKEND" \
        HOST="$HOST" PORT="$PORT" MODEL="$MODEL" \
        AUTH_TOKEN_FILE="$AUTH_TOKEN_FILE" HOME="$HOME" LOG_DIR="$LOG_DIR" \
        PLIST_DST="$PLIST_DST" PIPECAT_TTS_LABEL="$LABEL" \
        PIPECAT_TTS_AUTH_TOKEN="${PIPECAT_TTS_AUTH_TOKEN:-}" \
        PIPECAT_TTS_KOKORO_EXTRA_LANGS="${PIPECAT_TTS_KOKORO_EXTRA_LANGS:-}" \
        PIPECAT_TTS_PHONON_VOICES="${PIPECAT_TTS_PHONON_VOICES:-}" \
        TTS_WS_PING_INTERVAL="${TTS_WS_PING_INTERVAL:-}" \
        TTS_WS_PING_TIMEOUT="${TTS_WS_PING_TIMEOUT:-}" \
        "$PYTHON" "$RENDER_PY"
}

case "$cmd" in
install)
    render_plist
    # Bootstrap (idempotent: unload first if already loaded).
    launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_DST"
    launchctl enable "gui/$(id -u)/$LABEL"
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    echo "installed and started: $LABEL"
    echo "  endpoint: $HOST:$PORT"
    echo "  logs:     $LOG_DIR"
    ;;
uninstall)
    uid="$(id -u)"
    # Only tear down if the agent is currently loaded. If it IS loaded, a bootout
    # failure must NOT be swallowed: deleting the plist while the agent keeps
    # running would orphan a live listener (port stays bound, but the plist that
    # makes it discoverable/stoppable is gone). Leave the plist and fail loudly.
    if launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
        if ! launchctl bootout "gui/$uid/$LABEL"; then
            echo "error: launchctl bootout failed for $LABEL — the agent may still be running." >&2
            echo "       Left the plist in place ($PLIST_DST) so the agent stays discoverable;" >&2
            echo "       investigate with: launchctl print gui/$uid/$LABEL" >&2
            exit 1
        fi
        # Confirm it is actually gone before removing the plist.
        if launchctl print "gui/$uid/$LABEL" >/dev/null 2>&1; then
            echo "error: $LABEL still loaded after bootout — refusing to delete the plist." >&2
            exit 1
        fi
    fi
    rm -f "$PLIST_DST"
    echo "uninstalled: $LABEL"
    ;;
start)
    # Ensure running. ``launchctl kickstart`` without ``-k`` is a no-op when the
    # service is already running — which is what "start" should mean. Use
    # "restart" for a forced kick.
    if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        echo "$LABEL: not loaded. Run 'install' first." >&2
        exit 1
    fi
    launchctl kickstart "gui/$(id -u)/$LABEL"
    echo "started (or already running): $LABEL"
    ;;
stop)
    if ! launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
        echo "$LABEL: not loaded." >&2
        exit 0
    fi
    launchctl kill SIGTERM "gui/$(id -u)/$LABEL"
    echo "sent SIGTERM: $LABEL (KeepAlive will restart it — use 'uninstall' to disable)"
    ;;
restart)
    launchctl kickstart -k "gui/$(id -u)/$LABEL"
    echo "restarted: $LABEL"
    ;;
status)
    launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "state|last exit|pid" || \
        echo "$LABEL: not loaded"
    ;;
logs)
    # Read the exact log paths the renderer baked into the plist, rather than
    # recomputing the basename — keeps render_tts_plist.py's _log_basename() the
    # single source of truth (no shell copy to drift out of lockstep).
    if [[ ! -e "$PLIST_DST" ]]; then
        echo "$LABEL: no plist at $PLIST_DST — run 'install' first" >&2
        exit 1
    fi
    out="$(plutil -extract StandardOutPath raw -o - "$PLIST_DST")"
    err="$(plutil -extract StandardErrorPath raw -o - "$PLIST_DST")"
    tail -F "$out" "$err"
    ;;
*)
    echo "usage: $0 [install|uninstall|start|stop|restart|status|logs]" >&2
    exit 2
    ;;
esac
