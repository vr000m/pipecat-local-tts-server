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
# 5. External: a tone server started OUT OF PROCESS on its canonical loopback port
#    (8665) is adopted at launch (the bootstrap log line says `external(`) and is
#    still alive after Quit. Skipped when 8665 is held, a tone LaunchAgent is loaded
#    or the repo .venv is missing. The script never starts or stops anything on 8965 or
#    9565-9865 (real LaunchAgents run there); the app's own discovery does probe them,
#    read-only, at every launch.
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
EXT_PID=""        # the out-of-process server this script started (step 5), nothing else
EXT_LISTEN_PID="" # whatever pid listens on its port once it is up

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

cleanup() {
    [[ -n "$LOG_PID" ]] && kill "$LOG_PID" 2>/dev/null || true
    [[ -n "$APP_PID" ]] && kill -9 "$APP_PID" 2>/dev/null || true
    # Only the pid this script started (never the lsof listener, never a pattern kill).
    [[ -n "$EXT_PID" ]] && kill "$EXT_PID" 2>/dev/null || true
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
        if grep -q "tools from" "$WORK/app.log" && [[ "$(grep -cE ': (notInstalled|installed|unavailable|running|installing|external\()' "$WORK/app.log")" -gt 0 ]]; then
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
pass "bootstrap finished: $(grep -o 'tools from [a-z]*' "$WORK/app.log" | head -1); $(grep -cE ': (notInstalled|installed|unavailable|running|installing|external\()' "$WORK/app.log") service phase line(s)"

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

# --- 5. External (out-of-process server) -------------------------------------
# The script cannot open the panel or read its text, so External is read from the
# phase line the bootstrap logs after its one discovery pass: `tone: external(8665, ...)`.
step "External: a server started outside the app is adopted and survives Quit"
EXT_PORT=8665   # tone's canonical port (ServiceCatalog / justfile _resolve); not a real agent's
REPO_ROOT="$(dirname "$MACOS_DIR")"
EXT_PY="$REPO_ROOT/.venv/bin/python"
if lsof -nP -iTCP:"$EXT_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  SKIP external: port $EXT_PORT is already held ($(lsof -nP -iTCP:"$EXT_PORT" -sTCP:LISTEN | awk 'NR==2{print $1" pid "$2}'))"
elif launchctl print "gui/$(id -u)/pipecat.tts-server.tone" >/dev/null 2>&1; then
    echo "  SKIP external: a pipecat.tts-server.tone LaunchAgent is loaded (it would race for $EXT_PORT)"
elif [[ ! -x "$EXT_PY" ]] || ! "$EXT_PY" -c 'import tts_server' >/dev/null 2>&1; then
    echo "  SKIP external: no usable $EXT_PY (run: uv sync --extra client)"
else
    "$EXT_PY" -m tts_server serve --backend tone --host 127.0.0.1 --port "$EXT_PORT" >"$WORK/external.log" 2>&1 &
    EXT_PID=$!
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        kill -0 "$EXT_PID" 2>/dev/null || { cat "$WORK/external.log"; fail "the external tone server exited at start"; }
        # Accept the listener only if it is the process we started ($! is the python itself).
        EXT_LISTEN_PID="$(lsof -nP -tiTCP:"$EXT_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
        [[ "$EXT_LISTEN_PID" == "$EXT_PID" ]] && break
        EXT_LISTEN_PID=""
        sleep 0.25
    done
    [[ -n "$EXT_LISTEN_PID" ]] || { cat "$WORK/external.log"; fail "the external tone server we started never listened on $EXT_PORT"; }
    pass "external tone server up on 127.0.0.1:$EXT_PORT (pid $EXT_PID)"

    launch
    grep -qE "tone: external\($EXT_PORT" "$WORK/app.log" \
        || { grep -E 'tone' "$WORK/app.log" | head -5; fail "bootstrap did not report tone as external($EXT_PORT"; }
    pass "bootstrap adopted tone as External: $(grep -oE "tone: external\($EXT_PORT" "$WORK/app.log" | head -1)"

    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
    quitter=$!
    assert_clean_exit "quit with an external server"
    kill "$quitter" 2>/dev/null || true
    kill -0 "$EXT_PID" 2>/dev/null || fail "Quit stopped the external server (pid $EXT_PID)"
    lsof -nP -iTCP:"$EXT_PORT" -sTCP:LISTEN >/dev/null 2>&1 || fail "nothing listens on $EXT_PORT after Quit"
    pass "external server (pid $EXT_PID) still running after Quit"

    # Stop what this script started; cleanup() repeats it if we fail before here.
    kill "$EXT_PID" 2>/dev/null || true
    for _ in $(seq 1 20); do kill -0 "$EXT_PID" 2>/dev/null || break; sleep 0.25; done
    kill -9 "$EXT_PID" 2>/dev/null || true   # still ours: only if SIGTERM was ignored
    wait "$EXT_PID" 2>/dev/null || true
    EXT_PID=""; EXT_LISTEN_PID=""
fi

step "UI smoke passed"
