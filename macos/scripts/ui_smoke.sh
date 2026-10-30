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
# 3. Quit: `quit app id` reaches applicationShouldTerminate, where QuitGuardPolicy.decide
#    skips the prompt (no client is connected) and beginDrain runs the shutdown. The app
#    exits within QUIT_WAIT (seconds, default 20) and leaves no process the app started
#    (uv, python, lsof...). LAUNCH_WAIT (seconds, default 30) bounds each launch's bootstrap.
# 4. SIGTERM: a second launch killed with SIGTERM also leaves no child behind.
# 5. External: a tone server started OUT OF PROCESS on its canonical loopback port
#    (8665) is adopted at launch (the bootstrap log line says `external(`) and is
#    still alive after Quit. Skipped when 8665 is held, a tone LaunchAgent is loaded
#    or the repo .venv cannot import tts_server. The script never starts or stops anything on 8965 or
#    9565-9865 (real LaunchAgents run there); the app's own discovery does probe them,
#    read-only, at every launch.
# 6. Restore: with that server still up, a launch whose persisted wanted set names tone
#    (`restore.wanted` = tone, `restoreOnLaunch` = YES) shows tone External, logs no
#    `restore: starting` and has no `tts_server`/`stt_server` process of its own. Every other
#    launch has restore off and an empty wanted set.
#
# Isolation: the bundle runs under the operator's real bundle id, so no launch may read or write
# the operator's `restore.wanted` / `restoreOnLaunch`. Every launch (a) passes both as launch
# arguments (the argument domain heads every search list, the suite's included, so the app READS
# these values from the arguments) and (b) sets PIPECAT_TOOLBAR_DEFAULTS_SUITE to a throwaway suite
# the script seeds and deletes, where the app WRITES them (`PreferencesDomain`; launch arguments
# never shadow writes, so a write is not read back during the run). The script also compares the real
# domain's `restore.wanted` before and after and fails if it changed.
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
SUITE=""          # the throwaway UserDefaults suite every launch uses (set below, deleted by cleanup)
EXT_PID=""        # the out-of-process server this script started (step 5), nothing else
EXT_LISTEN_PID="" # whatever pid listens on its port once it is up
EXT_PORT=8665     # tone's canonical port (ServiceCatalog / justfile _resolve); not a real agent's
EXT_MATCH=""      # the command line EXT_PID must still be running (set when it starts)

pass() { printf '  \033[32mok\033[0m   %s\n' "$*"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$*"; exit 1; }
step() { printf '\033[1m==> %s\033[0m\n' "$*"; }

# True only while EXT_PID is still the server this script started: alive, a child of this
# shell, and running the command line it was started with. `kill -0` alone is not proof:
# once the child exits and the shell reaps it, the kernel can hand its pid to an unrelated
# process. A read-only check (the start and "still running after Quit" assertions); it never
# guards a signal, since the pid could change hands between the check and the kill.
ext_is_ours() {
    [[ -n "$EXT_PID" && -n "$EXT_MATCH" ]] || return 1
    local ppid cmd
    ppid="$(ps -o ppid= -p "$EXT_PID" 2>/dev/null | tr -d ' ' || true)"
    cmd="$(ps -o command= -p "$EXT_PID" 2>/dev/null || true)"
    [[ "$ppid" == "$$" && "$cmd" == *"$EXT_MATCH"* ]]
}

# The job number of this shell's background job whose pid is $1 (empty: none).
job_of() {
    jobs -l | awk -v pid="$1" '$2 == pid { gsub(/[^0-9]/, "", $1); print $1 }'
}

# True while this shell's background job whose pid is $1 is still running.
job_running() {
    jobs -l | awk -v pid="$1" '$2 == pid && $3 == "Running" { found = 1 } END { exit !found }'
}

# Send signal $1 to this shell's background job whose pid is $2, by job spec: the shell resolves
# "%N" from its own job table and skips a process it has already reaped, so a pid the kernel has
# since reused is never hit (a check-then-`kill $pid` can race that reuse). The job number is
# looked up from the pid here, at signal time, never cached: the shell hands a reaped job's
# number to the next job (bash 3.2 does), so a number saved earlier can name another job. Every
# signal this script sends to a process it started goes through here.
signal_job() {
    local job
    job="$(job_of "$2")"
    [[ -n "$job" ]] || return 0
    kill "-$1" "%$job" 2>/dev/null || true
}

# Stop this shell's background job whose pid is $1 and reap it before returning, so it cannot
# outlive the step that started it: SIGTERM, up to 5s to exit, SIGKILL if it ignored SIGTERM,
# then `wait` (bounded: the job has exited by then, and a pid that is not this shell's child
# returns at once). Signals only through signal_job; nothing after `wait`.
stop_job() {
    signal_job TERM "$1"
    for _ in $(seq 1 20); do job_running "$1" || break; sleep 0.25; done
    signal_job KILL "$1"
    wait "$1" 2>/dev/null || true
}

# Stop the server this script started (stop_job) and forget it.
stop_ext() {
    [[ -n "$EXT_PID" ]] || return 0
    stop_job "$EXT_PID"
    EXT_PID=""; EXT_LISTEN_PID=""
}

cleanup() {
    [[ -z "$LOG_PID" ]] || stop_job "$LOG_PID"
    if [[ -n "$APP_PID" ]]; then
        signal_job KILL "$APP_PID"
        wait "$APP_PID" 2>/dev/null || true
    fi
    # Only the job this script started, through signal_job (never the lsof listener, never a
    # pid, never a pattern kill).
    stop_ext
    if [[ -n "$SUITE" ]]; then
        defaults delete "$SUITE" >/dev/null 2>&1 || true
        rm -f "$HOME/Library/Preferences/$SUITE.plist"  # `defaults delete` leaves an empty plist behind
    fi
    rm -rf "$WORK"
}
trap cleanup EXIT

if [[ "${1:-}" == "--build" || ! -x "$APP/Contents/MacOS/$EXE_NAME" ]]; then
    step "Building the bundle"
    "$SCRIPTS/build_app.sh" >"$WORK/build.log" 2>&1 || { tail -20 "$WORK/build.log"; fail "build_app.sh"; }
fi
BUNDLE_ID="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$APP/Contents/Info.plist")"
EXE="$APP/Contents/MacOS/$EXE_NAME"
# The app reads and writes its wanted set and restore preference in this suite, never in $BUNDLE_ID's
# own domain (the operator's). Set before anything can launch the app.
SUITE="$BUNDLE_ID.smoke.$$"
# This read-only comparison is the isolation check, and the only touch of the real domain. Only a
# hash is kept, so the operator's value is never printed.
# (A missing key is a normal state: stderr carries a timestamped NSLog line that differs on every
# call, so it is discarded and absence is recorded from the exit status instead.)
real_wanted_hash() { { defaults read "$BUNDLE_ID" restore.wanted 2>/dev/null || echo '<absent>'; } | shasum -a 256 | cut -d' ' -f1; }
REAL_WANTED_BEFORE="$(real_wanted_hash)"

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

# An old-style plist array of the arguments, as a launch argument is parsed: "(tone, kokoro)".
# Without the commas the value does not parse and lands as a string that shadows the suite's array.
plist_array() {
    local out="" v
    for v in "$@"; do out="${out:+$out, }$v"; done
    printf '(%s)' "$out"
}

launch() {
    : >"$WORK/app.log"
    /usr/bin/log stream --level info --style compact \
        --predicate "subsystem == \"$BUNDLE_ID\" OR subsystem == \"ai.pipecat.ServiceToolbar\"" >"$WORK/app.log" 2>&1 &
    LOG_PID=$!
    sleep 1
    # No launch restores unless the step asks (RESTORE=YES), and the wanted set is empty unless it
    # names services (WANTED="tone"). Both are seeded in the throwaway suite and also passed as
    # launch arguments. Arguments live in the argument domain, which heads every UserDefaults
    # search list including the suite's: the app's reads of these two keys return the arguments
    # (that is how step 6 seeds its wanted set), while its writes go to the suite. So in-run
    # wanted-set writes are not read back by the app, and the real domain is never touched.
    local restore_bool=false wanted_values=() wanted_arg
    [[ "${RESTORE:-NO}" != YES ]] || restore_bool=true
    # shellcheck disable=SC2206
    wanted_values=(${WANTED:-})
    defaults delete "$SUITE" >/dev/null 2>&1 || true
    defaults write "$SUITE" restoreOnLaunch -bool "$restore_bool"
    # The same values in both seeds (an empty array is unset under bash 3.2's `set -u`).
    if ((${#wanted_values[@]})); then
        defaults write "$SUITE" restore.wanted -array "${wanted_values[@]}"
        wanted_arg="$(plist_array "${wanted_values[@]}")"
    else
        defaults write "$SUITE" restore.wanted -array
        wanted_arg="$(plist_array)"
    fi
    PIPECAT_TOOLBAR_DEFAULTS_SUITE="$SUITE" "$EXE" \
        -restoreOnLaunch "${RESTORE:-NO}" -restore.wanted "$wanted_arg" >"$WORK/stdout.log" 2>&1 &
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
    stop_job "$LOG_PID"
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
stop_job "$quitter"

# --- 4. SIGTERM ---------------------------------------------------------------
step "Launch again, then SIGTERM"
launch
signal_job TERM "$APP_PID"
assert_clean_exit "SIGTERM"

# --- 5. External (out-of-process server) -------------------------------------
# The script cannot open the panel or read its text, so External is read from the
# phase line the bootstrap logs after its one discovery pass: `tone: external(8665, ...)`.
step "External: a server started outside the app is adopted and survives Quit"
REPO_ROOT="$(dirname "$MACOS_DIR")"
EXT_PY="$REPO_ROOT/.venv/bin/python"
if lsof -nP -iTCP:"$EXT_PORT" -sTCP:LISTEN >/dev/null 2>&1; then
    echo "  SKIP external: port $EXT_PORT is already held ($(lsof -nP -iTCP:"$EXT_PORT" -sTCP:LISTEN | awk 'NR==2{print $1" pid "$2}'))"
elif launchctl print "gui/$(id -u)/pipecat.tts-server.tone" >/dev/null 2>&1; then
    echo "  SKIP external: a pipecat.tts-server.tone LaunchAgent is loaded (it would race for $EXT_PORT)"
elif [[ ! -x "$EXT_PY" ]] || ! "$EXT_PY" -c 'import tts_server' >/dev/null 2>&1; then
    echo "  SKIP external: no usable $EXT_PY (run: uv sync --extra client)"
else
    EXT_MATCH="-m tts_server serve --backend tone --host 127.0.0.1 --port $EXT_PORT"
    "$EXT_PY" -m tts_server serve --backend tone --host 127.0.0.1 --port "$EXT_PORT" >"$WORK/external.log" 2>&1 &
    EXT_PID=$!
    # Fail fast if the shell cannot see its own job (signal_job would then be a no-op).
    [[ -n "$(job_of "$EXT_PID")" ]] || fail "the external tone server (pid $EXT_PID) is not in this shell's job table"
    deadline=$((SECONDS + 20))
    while ((SECONDS < deadline)); do
        # Liveness only (no signal): until the child has exec'd python its command line is still bash's.
        kill -0 "$EXT_PID" 2>/dev/null || { cat "$WORK/external.log"; fail "the external tone server exited at start"; }
        # Accept the listener only if it is the process we started ($! is the python itself).
        EXT_LISTEN_PID="$(lsof -nP -tiTCP:"$EXT_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)"
        [[ "$EXT_LISTEN_PID" == "$EXT_PID" ]] && ext_is_ours && break
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
    stop_job "$quitter"
    ext_is_ours || fail "Quit stopped the external server (pid $EXT_PID)"
    [[ "$(lsof -nP -tiTCP:"$EXT_PORT" -sTCP:LISTEN 2>/dev/null | head -1 || true)" == "$EXT_PID" ]] \
        || fail "the server we started no longer listens on $EXT_PORT after Quit"
    pass "external server (pid $EXT_PID) still running after Quit"

    # --- 6. Restore skips a service that is already External ---
    step "Restore: a wanted service that is External is not started again"
    RESTORE=YES WANTED=tone launch
    grep -qE "tone: external\($EXT_PORT" "$WORK/app.log" \
        || { grep -E 'tone' "$WORK/app.log" | head -5; fail "restore launch did not report tone as external($EXT_PORT"; }
    grep -q "restore: starting" "$WORK/app.log" && fail "restore started a service: $(grep 'restore: starting' "$WORK/app.log" | head -1)"
    grep -qE "restore: skipping tone: external" "$WORK/app.log" \
        || { grep -E 'restore' "$WORK/app.log" | head -5; fail "restore did not log tone as skipped (external)"; }
    # No server of its own. Not "no children at all": the bootstrap's cache probes and discovery's
    # lsof/launchctl lookups are normal descendants.
    for p in $SEEN; do
        cmd="$(ps -ww -o command= -p "$p" 2>/dev/null || true)"
        # `serve` only: the bootstrap's `-m tts_server prefetch --check` probes are normal.
        [[ "$cmd" != *"-m tts_server serve"* && "$cmd" != *"-m stt_server serve"* ]] \
            || fail "restore launch started a server: pid $p: $cmd"
    done
    osascript -e "quit app id \"$BUNDLE_ID\"" >/dev/null 2>&1 &
    quitter=$!
    assert_clean_exit "restore launch with an external server"
    stop_job "$quitter"
    ext_is_ours || fail "the restore launch's Quit stopped the external server (pid $EXT_PID)"
    pass "restore skipped the External tone and started nothing"

    # Stop what this script started; cleanup() repeats it if we fail before here.
    stop_ext
fi

step "Isolation: the operator's own wanted set is untouched"
[[ "$(real_wanted_hash)" == "$REAL_WANTED_BEFORE" ]] \
    || fail "the smoke changed $BUNDLE_ID restore.wanted (changed; values not printed)"
pass "$BUNDLE_ID restore.wanted unchanged; every launch used the throwaway suite $SUITE"

step "UI smoke passed"
