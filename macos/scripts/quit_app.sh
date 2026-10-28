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
# QUIT_WAIT_SECS (default 30, whole seconds) is one deadline for the whole run: the
# running check, the quit request and the wait for the exit. Every osascript call is
# stopped at that deadline (stop_child: SIGTERM, 0.3s grace, then SIGKILL, so one that
# ignores SIGTERM still ends), so a hung Apple event cannot stall the caller. The script
# gives up at least QUIT_WAIT_SECS in and at most about a second and a half later: bash's
# SECONDS ticks in whole seconds, the last poll finishes after the deadline, and each of
# the two pending osascript calls may take its grace.
#
# Every exit path (exit 0-3, a set -e abort, INT/TERM) runs the EXIT trap, which stops and
# reaps any osascript still pending (the running check and the quit request) and removes
# the temp dir: nothing this script started outlives it. A child is signalled only by its
# job spec while it is still a running job of this shell (live_job): once bash has reaped
# it, its pid may name an unrelated process, so it is only waited for.
#
# Exit 0: not running, or exited within the wait. Exit 1: still running, or no answer,
# after QUIT_WAIT_SECS. Exit 2: usage, or QUIT_WAIT_SECS is not a whole number. Exit 3:
# osascript failed or gave an answer other than true/false, so whether the app runs is
# unknown (never read as "not running", or the caller would open or replace the bundle
# under a live copy). The one osascript error read as "not running" is -1728, no
# application with that id. Both callers run under set -e and stop on any non-zero exit
# alike; the codes and messages are diagnostic.
set -euo pipefail

id="${1:-}"
[[ -n "$id" ]] || { echo "usage: quit_app.sh <bundle-id>" >&2; exit 2; }
wait_secs="${QUIT_WAIT_SECS:-30}"
[[ "$wait_secs" =~ ^[0-9]+$ ]] || { echo "error: QUIT_WAIT_SECS must be whole seconds, got '$wait_secs'" >&2; exit 2; }
wait_secs=$((10#$wait_secs)) # decimal: "010" is ten seconds (not octal eight), "08" is eight

# Bounded by the clock, not by a poll count: each poll spawns osascript, which takes a
# noticeable fraction of a second on its own. SECONDS is bash's own elapsed-seconds counter
# and ticks on whole-second boundaries, so the +1 keeps the wait from ending up to 1s early.
deadline=$((SECONDS + wait_secs + 1))

# Children still pending (empty once reaped).
probe_pid=""
quit_pid=""
quit_err=""
tmp=""
live=""

# Set $live to the job number of this shell's background job whose pid is $1 while it is still
# running; empty once bash has reaped it (its pid may then belong to an unrelated process).
# Looked up at signal time, never cached: bash 3.2 hands a reaped job's number to the next job.
# No subshell or pipe (`jobs` runs in this shell, its listing goes through $tmp), so the 20 Hz
# polls in bounded() cost no fork. Once listed, a finished job leaves the table; `wait` on its
# pid still returns its status.
live_job() {
    local spec pid state _
    live=""
    [[ -n "$tmp" ]] || return 0
    jobs -l >"$tmp/jobs" 2>/dev/null || return 0
    while read -r spec pid state _; do
        if [[ "$pid" == "$1" && "$state" == Running ]]; then
            live="${spec//[^0-9]/}"
            return 0
        fi
    done <"$tmp/jobs"
}

# Stop this shell's child $1 and reap it: SIGTERM, up to 0.3s grace, then SIGKILL (an
# osascript that ignores SIGTERM must not hang the wait). Each signal names the job spec
# while live_job still lists it, never the bare pid; an already reaped child is only waited
# for. stderr is dropped so bash's "Terminated"/"Killed" job notices stay out of the output.
stop_child() {
    local _
    live_job "$1"
    if [[ -n "$live" ]]; then
        kill -TERM "%$live" || true
        for _ in 1 2 3; do
            sleep 0.1
            live_job "$1"
            [[ -n "$live" ]] || break
        done
        [[ -z "$live" ]] || kill -KILL "%$live" || true
    fi
    wait "$1" || true
} 2>/dev/null

# Stop the quit request if it is still pending, reap it, and keep osascript's complaint
# (e.g. Automation access denied) for the failure message. Idempotent.
stop_quit() {
    [[ -n "$quit_pid" ]] || return 0
    live_job "$quit_pid"
    if [[ -n "$live" ]]; then
        stop_child "$quit_pid"
        quit_err="the quit request got no answer"
    else
        wait "$quit_pid" 2>/dev/null || true
        quit_err="$(cat "$tmp/quit-err" 2>/dev/null || true)"
    fi
    quit_pid=""
}

cleanup() {
    set +e # the EXIT trap runs every step, even after one fails
    if [[ -n "$probe_pid" ]]; then
        stop_child "$probe_pid"
        probe_pid=""
    fi
    stop_quit
    [[ -z "$tmp" ]] || rm -rf "$tmp"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

tmp="$(mktemp -d "${TMPDIR:-/tmp}/quit_app.XXXXXX")"

# Run "$@" (stdout to $tmp/out, stderr to $tmp/err), stopped at the deadline. Returns its
# status, or 124 when it was killed. bash 3.2 has no `timeout`, hence the background poll.
bounded() {
    local rc=0
    "$@" >"$tmp/out" 2>"$tmp/err" &
    probe_pid=$!
    while live_job "$probe_pid" && [[ -n "$live" ]]; do
        if ((SECONDS >= deadline)); then
            stop_child "$probe_pid"
            probe_pid=""
            return 124
        fi
        sleep 0.05
    done
    wait "$probe_pid" || rc=$?
    probe_pid=""
    return "$rc"
}

# Is the app running? 0 yes, 1 no, 124 no answer before the deadline. Anything else exits 3.
running() {
    local rc=0 out
    bounded osascript -e "application id \"$id\" is running" || rc=$?
    ((rc != 124)) || return 124
    out="$(cat "$tmp/out")"
    # -1728 "Can't get application id": LaunchServices knows no app with that id (a fresh
    # build is not registered until it is opened), and a running app is always known to it.
    if ((rc != 0)) && grep -qF -- '(-1728)' "$tmp/err"; then
        return 1
    fi
    if ((rc != 0)); then
        echo "error: could not tell whether $id is running (osascript exit $rc: $(cat "$tmp/err"))" >&2
        exit 3
    fi
    case "$out" in
        true) return 0 ;;
        false) return 1 ;;
    esac
    echo "error: could not tell whether $id is running (osascript answered '$out')" >&2
    exit 3
}

rc=0
running || rc=$?
((rc != 1)) || exit 0
if ((rc == 124)); then
    echo "error: osascript did not say within ${wait_secs}s whether $id is running" >&2
    exit 1
fi
# The quit request runs beside the polls, so a quit event that never returns still ends at
# the deadline, and an app that exits while it is pending still counts as quit. Once it is
# started, the EXIT trap reaps it on every way out.
osascript -e "quit app id \"$id\"" >/dev/null 2>"$tmp/quit-err" &
quit_pid=$!
while ((SECONDS < deadline)); do
    rc=0
    running || rc=$?
    ((rc != 1)) || exit 0
    sleep 0.1
done
stop_quit
echo "error: $id did not quit within ${wait_secs}s; quit it and re-run${quit_err:+ ($quit_err)}" >&2
exit 1
