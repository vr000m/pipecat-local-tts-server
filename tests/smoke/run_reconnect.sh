#!/usr/bin/env bash
#
# Live single-endpoint reconnect smoke test. Drives reconnect_smoke.py, which
# owns the server lifecycle: start -> synthesize -> SIGKILL (stale socket) ->
# restart -> client reconnect-with-backoff -> synthesize again, comparing the
# audio returned before the kill vs. after. See tests/smoke/README.md.
#
# Usage:
#   tests/smoke/run_reconnect.sh [--backend tone|kokoro] [--keep] [-- <driver args>]
#
# Defaults to tone (fast; the stale-socket reclaim is backend-agnostic). Run with
# --backend kokoro to verify real voice samples survive the restart, and to catch
# reload-logic errors specific to a backend's implementation.
set -uo pipefail

BACKEND=tone
DRIVER_ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --keep) DRIVER_ARGS+=(--keep); shift ;;
    --) shift; DRIVER_ARGS+=("$@"); break ;;
    -h|--help) sed -n '2,14p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

# A plain `uv run` re-syncs and strips the kokoro extra mid-run; pin --no-sync.
UV_RUN=(uv run)
if [[ "$BACKEND" == "kokoro" ]]; then
  if ! uv run --no-sync python -c "import mlx_audio" 2>/dev/null; then
    echo "kokoro extra not installed — running 'uv sync --extra kokoro'..."
    uv sync --extra kokoro >/dev/null
  fi
  UV_RUN=(uv run --no-sync)
fi

exec "${UV_RUN[@]}" python tests/smoke/reconnect_smoke.py --backend "$BACKEND" \
  ${DRIVER_ARGS[@]+"${DRIVER_ARGS[@]}"}
