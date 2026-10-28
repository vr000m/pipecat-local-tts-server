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

running() { [[ "$(osascript -e "application id \"$id\" is running" 2>/dev/null || true)" == true ]]; }

running || exit 0
osascript -e "quit app id \"$id\"" >/dev/null 2>&1 || true
# Poll in tenths of a second so the wait is bounded without float arithmetic (bash 3.2).
for _ in $(seq 1 $((wait_secs * 10))); do
    running || exit 0
    sleep 0.1
done
echo "error: $id did not quit within ${wait_secs}s; quit it and re-run" >&2
exit 1
