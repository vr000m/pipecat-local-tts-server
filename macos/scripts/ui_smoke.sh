#!/usr/bin/env bash
# Unattended UI smoke for "Pipecat Service Toolbar": what can be checked without
# granting this terminal Accessibility or Screen Recording.
#
#   macos/scripts/ui_smoke.sh             # build if missing, then all checks
#   macos/scripts/ui_smoke.sh --build     # rebuild the bundle first (build_app.sh)
#
# 1. Render: the debug binary's `--snapshot` mode draws every scripted panel
#    state (light + dark) and the menu bar icon; each PNG must exist and be non-empty.
#    It renders fixed states only: it cannot click, drive transitions or read text.
# 2. Launch: the built bundle starts as a menu bar (UIElement) app, stays up,
#    and logs a finished bootstrap (tools found in the bundle, every service's phase).
# 3. Quit: `quit app id` (applicationShouldTerminate -> shutdownAll) exits within
#    the grace period and leaves no process the app started (uv, python, lsof...).
# 4. SIGTERM: a second launch killed with SIGTERM also leaves no child behind.
#
# Not covered (needs Accessibility, see macos/README.md "Manual UI checklist"):
# opening the panel, clicking Install/Start, and the port a started service opens.
# A launch uses your real ~/Library/{Application Support,Logs}/Pipecat Service Toolbar
# (it installs nothing); it refuses to run while another copy is running.
set -euo pipefail

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
MACOS_DIR="$(dirname "$SCRIPTS")"
APP="${APP:-$MACOS_DIR/build/Pipecat Service Toolbar.app}"
EXE_NAME=PipecatServiceToolbar
LAUNCH_WAIT="${LAUNCH_WAIT:-30}"   # seconds for the bootstrap to log its end
QUIT_WAIT="${QUIT_WAIT:-20}"       # seconds for a quit to finish
WORK="$(mktemp -d "${TMPDIR:-/tmp}/toolbar-ui-smoke.XXXXXX")"
LOG_PID=""
APP_PID=""

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

cleanup() {
    [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null || true
    [[ -n "$APP_PID" ]] && kill -9 "$APP_PID" 2>/dev/null || true
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "${1:-}" == "--build" || ! -x "$APP/Contents/MacOS/$EXE_NAME" ]]; then
    step "Building the bundle"
    "$SCRIPTS/build_app.sh" >"$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; fail "build_app.sh"; }
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
EXE="$APP/Contents/MacOS/$EXE_NAME"

if pgrep -f "/Contents/MacOS/$EXE_NAME" >/dev/null; then
    fail "a copy of the app is already running (quit it first): $(pgrep -fl "/Contents/MacOS/$EXE_NAME" | head -1)"
fi

# --- 1. Render ---------------------------------------------------------------
step "Render (--snapshot, debug binary)"
swift build --package-path "$MACOS_DIR" --product "$EXE_NAME" >"$WORK/swift-build.log" 2>&1 \
    || { tail -20 "$WORK/swift-build.log"; fail "swift build"; }
DEBUG_BIN="$(swift build --package-path "$MACOS_DIR" --show-bin-path)/$EXE_NAME"
"$DEBUG_BIN" --snapshot "$WORK/shots" >"$WORK/snapshot.log" 2>&1 || { cat "$WORK/snapshot.log"; fail "--snapshot exited non-zero"; }
shots=("$WORK"/shots/*.png)
[[ -e "${shots[0]}" ]] || fail "--snapshot wrote no PNGs"
for png in "${shots[@]}"; do
    [[ -s "$png" ]] || fail "empty snapshot: $(basename "$png")"
done
[[ -s "$WORK/shots/menubar.png" ]] || fail "no menu bar icon snapshot (menubar.png)"
pass "${#shots[@]} non-empty PNGs (panel states, menu bar icon, copy strip)"

# --- helpers -----------------------------------------------------------------
# Every descendant of $1 (children reparent to launchd once the app exits, so
# they are recorded while it runs).
descendants() {
    local kids
    kids="$(pgrep -P "$1" 2>/dev/null || true)"
    for k in $kids; do
        echo "$k"
        descendants "$k"
    done
}

launch() {
    : >"$WORK/app.log"
    /usr/bin/log stream --level info --style compact \
        --predicate "subsystem == \"$BUNDLE_ID\" OR subsystem == \"ai.pipecat.ServiceToolbar\"" >"$WORK/app.log" 2>&1 &
    LOG_PID=$!
    sleep 1
    "$EXE" >"$WORK/stdout.log" 2>&1 &
    APP_PID=$!
    local deadline=$((SECONDS + LAUNCH_WAIT))
    SEEN=""
    while ((SECONDS < deadline)); do
        kill -0 "$APP_PID" 2>/dev/null || { cat "$WORK/stdout.log"; fail "the app exited during launch"; }
        SEEN="$SEEN $(descendants "$APP_PID")"
        if grep -q "tools from" "$WORK/app.log" && [[ "$(grep -cE ': (notInstalled|installed|unavailable|running|installing)' "$WORK/app.log")" -gt 0 ]]; then
            break
        fi
        sleep 0.5
    done
    grep -q "tools from bundle" "$WORK/app.log" || { tail -20 "$WORK/app.log"; fail "no 'tools from bundle' bootstrap log within ${LAUNCH_WAIT}s"; }
    grep -q "tool lookup failed" "$WORK/app.log" && fail "bootstrap: $(grep 'tool lookup failed' "$WORK/app.log" | head -1)"
    sleep 2  # let the post-bootstrap work (cache probes, size lookups) start
    SEEN="$SEEN $(descendants "$APP_PID")"
    kill -0 "$APP_PID" 2>/dev/null || fail "the app exited after bootstrap"
}

# The app must be gone and nothing it started may outlive it.
assert_clean_exit() {
    local how="$1" deadline=$((SECONDS + QUIT_WAIT))
    while kill -0 "$APP_PID" 2>/dev/null; do
        ((SECONDS < deadline)) || fail "$how: still running after ${QUIT_WAIT}s"
        SEEN="$SEEN $(descendants "$APP_PID")"
        sleep 0.25
    done
    wait "$APP_PID" 2>/dev/null || true
    APP_PID=""
    local left=""
    for p in $SEEN; do
        kill -0 "$p" 2>/dev/null && left="$left $(ps -o pid=,command= -p "$p")"
    done
    [[ -z "$left" ]] || fail "$how left children running:$left"
    local stray
    stray="$(pgrep -fl "$APP/Contents" || true)"
    [[ -z "$stray" ]] || fail "$how left processes from the bundle: $stray"
    kill "$LOG_PID" 2>/dev/null || true
    LOG_PID=""
    local n
    n="$(echo "$SEEN" | tr ' ' '\n' | sort -u | grep -c . || true)"
    pass "$how: exited, no leftovers ($n child process(es) seen while it ran)"
}

# --- 2 + 3. Launch, then quit -------------------------------------------------
step "Launch the bundle"
launch
kind="$(lsappinfo info -only ApplicationType "$APP_PID" 2>/dev/null || true)"
[[ "$kind" == *UIElement* ]] || fail "not a menu bar (UIElement) app: ${kind:-not registered with LaunchServices}"
pass "running as a UIElement app (pid $APP_PID)"
pass "bootstrap finished: $(grep -o 'tools from [a-z]*' "$WORK/app.log" | head -1); $(grep -cE ': (notInstalled|installed|unavailable|running|installing)' "$WORK/app.log") service phase line(s)"

step "Quit (Apple Event, as the menu's Quit does)"
osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
quitter=$!
assert_clean_exit "quit"
kill "$quitter" 2>/dev/null || true

# --- 4. SIGTERM ---------------------------------------------------------------
step "Launch again, then SIGTERM"
launch
kill -TERM "$APP_PID"
assert_clean_exit "SIGTERM"

step "UI smoke passed"
