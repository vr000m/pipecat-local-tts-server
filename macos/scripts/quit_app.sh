#!/usr/bin/env bash
# Quit a running app by bundle id and wait until it has exited.
#
#   macos/scripts/quit_app.sh ai.pipecat.ServiceToolbar
#
# Used by `just app-open` and `just app-install`. The quit is asynchronous (the
# toolbar stops its servers first) and can be refused, so a bare `osascript quit`
# followed by `open` or a bundle replacement can act while the old process is
# still alive: `open` then re-activates the old build instead of starting the new
# one. Does nothing when the app is not running (so it never launches it).
#
# Exit 0: not running, or exited within the wait. Exit 1: still running after
# QUIT_WAIT_SECS (default 30). Exit 2: usage.
set -euo pipefail

id="${1:-}"
[[ -n "$id" ]] || { echo "usage: quit_app.sh <bundle-id>" >&2; exit 2; }
wait_secs="${QUIT_WAIT_SECS:-30}"
[[ "$wait_secs" =~ ^[0-9]+$ ]] || { echo "error: QUIT_WAIT_SECS must be whole seconds, got '$wait_secs'" >&2; exit 2; }

running() { [[ "$(osascript -e "application id \"$id\" is running" 2>/dev/null || true)" == true ]]; }

running || exit 0
# Keep osascript's complaint (e.g. Automation access denied) for the failure message below.
quit_err="$(osascript -e "quit app id \"$id\"" 2>&1 >/dev/null || true)"
# Bounded by the clock, not by a poll count: each poll spawns osascript, which takes a
# noticeable fraction of a second on its own. SECONDS is bash's own elapsed-seconds counter.
deadline=$((SECONDS + wait_secs))
while ((SECONDS < deadline)); do
    running || exit 0
    sleep 0.1
done
running || exit 0
echo "error: $id did not quit within ${wait_secs}s; quit it and re-run${quit_err:+ ($quit_err)}" >&2
exit 1
