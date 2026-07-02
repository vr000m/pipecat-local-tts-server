#!/usr/bin/env bash
#
# Live multi-connection smoke test. Starts a real server on an isolated socket,
# then runs multiconn_smoke.py — N clients interleaving their requests through
# one backend, with growing sentences (max-buffer guard) and a back-to-back
# commit (429/BUSY guard). See tests/smoke/README.md.
#
# Usage:
#   tests/smoke/run_multiconn.sh [--backend tone|kokoro] [--connections N]
#                                [--turns N] [--keep] [-- <driver args>]
#
# Defaults to the tone backend: the concurrency/backpressure machinery lives in
# the server scheduler (backend-agnostic), and tone is fast + deterministic.
set -uo pipefail

BACKEND=tone
KEEP=0
DRIVER_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --connections) DRIVER_ARGS+=(--connections "$2"); shift 2 ;;
    --turns) DRIVER_ARGS+=(--turns "$2"); shift 2 ;;
    --keep) KEEP=1; shift ;;
    --) shift; DRIVER_ARGS+=("$@"); break ;;
    -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tts-multiconn.XXXXXX")"
SOCK="$RUN_DIR/tts.sock"
LOG="$RUN_DIR/server.log"

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  if [[ "$KEEP" -eq 1 ]]; then echo "kept artifacts in $RUN_DIR"; else rm -rf "$RUN_DIR"; fi
}
trap cleanup EXIT

# A plain `uv run` re-syncs and strips the kokoro extra mid-run; pin --no-sync.
UV_RUN=(uv run)
if [[ "$BACKEND" == "kokoro" || "$BACKEND" == "voxtral_tts" || "$BACKEND" == "pocket_tts" || "$BACKEND" == "dia" ]]; then
  # The extra name matches the backend name (kokoro / voxtral_tts / pocket_tts / dia).
  if ! uv run --no-sync python -c "import mlx_audio" 2>/dev/null; then
    echo "$BACKEND extra not installed — running 'uv sync --extra $BACKEND'..."
    uv sync --extra "$BACKEND" >/dev/null
  fi
  UV_RUN=(uv run --no-sync)
fi

echo "== starting $BACKEND server on $SOCK =="
"${UV_RUN[@]}" python -m tts_server serve --backend "$BACKEND" --socket-path "$SOCK" \
  >"$LOG" 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 600); do
  [[ -S "$SOCK" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "server exited before listening; log tail:" >&2; tail -20 "$LOG" >&2; exit 1
  fi
  sleep 0.5
done
[[ -S "$SOCK" ]] || { echo "socket never appeared; log tail:" >&2; tail -20 "$LOG" >&2; exit 1; }

"${UV_RUN[@]}" python tests/smoke/multiconn_smoke.py --socket-path "$SOCK" \
  ${DRIVER_ARGS[@]+"${DRIVER_ARGS[@]}"}
