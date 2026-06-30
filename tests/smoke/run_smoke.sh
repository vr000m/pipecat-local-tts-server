#!/usr/bin/env bash
#
# Live end-to-end smoke test for the pipecat-local-tts-server.
#
# Starts a real server on an isolated Unix socket, drives it with the reference
# client (examples/reference_client.py), verifies each synthesis round-trip
# (status probe + non-empty WAV at the advertised rate), then tears the server
# down. This is the "does the whole wire path actually work end-to-end" check
# that the pytest suite (which mocks the model) deliberately does not cover.
#
# Usage:
#   tests/smoke/run_smoke.sh [--backend tone|kokoro] [--multilingual]
#                            [--include-cjk] [--play] [--keep] [--timeout N]
#
#   --backend       tone (default; no model, fast) or kokoro (real model).
#   --multilingual  kokoro only: synthesize one utterance per language.
#   --include-cjk   also attempt ja/zh (KNOWN to fail unless misaki[ja]/[zh]
#                   are installed — the `kokoro` extra ships only misaki[en]).
#                   See tests/smoke/README.md.
#   --play          play each WAV through the speakers (macOS `afplay`).
#   --keep          keep the temp WAVs/socket dir instead of cleaning up.
#   --timeout N     per-utterance client timeout in seconds (default: tone 30,
#                   kokoro 180 — first-call espeak G2P warmup is slow).
#
# Endpoint: an isolated socket under a mktemp dir, so this never clobbers a
# running operator/launchd server on the canonical ~/Library/Caches socket.
#
# Exit code: 0 only if every REQUIRED case succeeded. Expected-fail cases
# (ja/zh without their misaki extra) are reported as SKIP, not failure.
set -uo pipefail

# --- args -------------------------------------------------------------------
BACKEND=tone
MULTILINGUAL=0
INCLUDE_CJK=0
PLAY=0
KEEP=0
TIMEOUT=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --backend) BACKEND="$2"; shift 2 ;;
    --multilingual) MULTILINGUAL=1; shift ;;
    --include-cjk) INCLUDE_CJK=1; shift ;;
    --play) PLAY=1; shift ;;
    --keep) KEEP=1; shift ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done

if [[ "$BACKEND" != "tone" && "$BACKEND" != "kokoro" && "$BACKEND" != "voxtral_tts" && "$BACKEND" != "pocket_tts" && "$BACKEND" != "dia" ]]; then
  echo "--backend must be tone, kokoro, voxtral_tts, pocket_tts, or dia (got '$BACKEND')" >&2; exit 2
fi
# mlx-backed backends need a longer first-call timeout (model load/JIT/first-run
# download); tone is fast.
IS_MLX=0
[[ "$BACKEND" == "kokoro" || "$BACKEND" == "voxtral_tts" || "$BACKEND" == "pocket_tts" || "$BACKEND" == "dia" ]] && IS_MLX=1
[[ -z "$TIMEOUT" ]] && { [[ "$IS_MLX" -eq 1 ]] && TIMEOUT=180 || TIMEOUT=30; }

# --- locate repo + run dir --------------------------------------------------
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
CLIENT="examples/reference_client.py"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/tts-smoke.XXXXXX")"
SOCK="$RUN_DIR/tts.sock"
LOG="$RUN_DIR/server.log"

PASS=0; FAIL=0; SKIP=0
cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
  if [[ "$KEEP" -eq 1 ]]; then
    echo "kept artifacts in $RUN_DIR"
  else
    rm -rf "$RUN_DIR"
  fi
}
trap cleanup EXIT

# A plain `uv run` re-syncs the venv to the base deps and STRIPS the kokoro
# extra mid-run. After ensuring the extra once, every uv call uses --no-sync.
UV_RUN=(uv run)
if [[ "$IS_MLX" -eq 1 ]]; then
  # The extra name matches the backend name (kokoro / voxtral_tts). Ensure it is
  # installed once, then pin --no-sync so a later `uv run` cannot strip it.
  if ! uv run --no-sync python -c "import mlx_audio" 2>/dev/null; then
    echo "$BACKEND extra not installed — running 'uv sync --extra $BACKEND'..."
    uv sync --extra "$BACKEND" >/dev/null
  fi
  UV_RUN=(uv run --no-sync)
fi

# --- start server -----------------------------------------------------------
echo "== starting $BACKEND server on $SOCK =="
"${UV_RUN[@]}" python -m tts_server serve --backend "$BACKEND" --socket-path "$SOCK" \
  >"$LOG" 2>&1 &
SERVER_PID=$!

# Wait for the socket (model load can take a while on first run).
for _ in $(seq 1 600); do
  [[ -S "$SOCK" ]] && break
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "server exited before listening; log tail:" >&2; tail -20 "$LOG" >&2; exit 1
  fi
  sleep 0.5
done
[[ -S "$SOCK" ]] || { echo "socket never appeared; log tail:" >&2; tail -20 "$LOG" >&2; exit 1; }

# --- status probe -----------------------------------------------------------
echo "== status probe =="
"${UV_RUN[@]}" python -m tts_server status --socket-path "$SOCK" || { echo "status probe failed" >&2; exit 1; }

# --- synthesis cases --------------------------------------------------------
# verify: run one round-trip, confirm exit 0 and a non-trivial WAV.
#   $1 label  $2 outfile  remaining args: passed to reference_client
verify() {
  local label="$1" out="$2"; shift 2
  echo "-- $label --"
  if "${UV_RUN[@]}" python "$CLIENT" --socket-path "$SOCK" --timeout "$TIMEOUT" \
       --out "$out" "$@" 2>&1 | grep -E "done:|wrote|error|protocol"; then :; fi
  if [[ -s "$out" ]] && "${UV_RUN[@]}" python - "$out" <<'PY'
import sys, wave
w = wave.open(sys.argv[1], "rb")
ok = w.getnframes() > 0 and w.getframerate() > 0 and w.getnchannels() == 1
sys.exit(0 if ok else 1)
PY
  then
    echo "   PASS ($label)"; PASS=$((PASS+1))
    [[ "$PLAY" -eq 1 ]] && command -v afplay >/dev/null && afplay "$out"
  else
    echo "   FAIL ($label)"; FAIL=$((FAIL+1))
  fi
}

# expected-fail: a case we know cannot pass without an extra dep. A failure is
# a SKIP (documented gap), a surprise success is reported but still counts pass.
expect_fail() {
  local label="$1" out="$2" reason="$3"; shift 3
  echo "-- $label (expected-fail: $reason) --"
  if "${UV_RUN[@]}" python "$CLIENT" --socket-path "$SOCK" --timeout "$TIMEOUT" \
       --out "$out" "$@" 2>&1 | grep -E "done:|wrote|error|protocol"; then :; fi
  if [[ -s "$out" ]]; then
    echo "   UNEXPECTED PASS ($label) — dep now present?"; PASS=$((PASS+1))
    [[ "$PLAY" -eq 1 ]] && command -v afplay >/dev/null && afplay "$out"
  else
    echo "   SKIP ($label) — $reason"; SKIP=$((SKIP+1))
  fi
}

# latency: run the TTFB / streaming-cadence assertion against a streaming-capable
# backend. Proves first audio is prompt AND deltas dribble out during synthesis
# (not buffer-then-flush) — the R4 steady-stream contract the WAV check can't see.
latency_check() {
  echo "-- latency / streaming cadence --"
  if "${UV_RUN[@]}" python tests/smoke/latency_smoke.py --socket-path "$SOCK" \
       --timeout "$TIMEOUT" "$@"; then
    echo "   PASS (latency)"; PASS=$((PASS+1))
  else
    echo "   FAIL (latency)"; FAIL=$((FAIL+1))
  fi
}

echo "== synthesis =="
if [[ "$BACKEND" == "tone" ]]; then
  verify "tone" "$RUN_DIR/tone.wav" --text "The quick brown fox jumps over the lazy dog."
elif [[ "$BACKEND" == "voxtral_tts" ]]; then
  # voxtral_tts is streaming:true — verify a WAV round-trip AND the streaming
  # cadence. Default voice (omitted) exercises the voice=None path.
  verify "voxtral_tts/default" "$RUN_DIR/voxtral.wav" \
    --text "The quick brown fox jumps over the lazy dog."
  latency_check --ttfb-bound 3.0
elif [[ "$BACKEND" == "pocket_tts" ]]; then
  # pocket_tts is streaming:true (and fast, RTF<<1). WAV round-trip + cadence.
  # Default voice (omitted) exercises the voice=None path.
  verify "pocket_tts/default" "$RUN_DIR/pocket.wav" \
    --text "The quick brown fox jumps over the lazy dog."
  latency_check --ttfb-bound 3.0
elif [[ "$BACKEND" == "dia" ]]; then
  # dia is a streaming:false DIALOGUE backend (voice_count:0). Speakers ride
  # in-text via [S1]/[S2] tags inside a plain payload; no --voice is passed
  # (voice is structurally ignored). This is a structural WAV round-trip; the
  # perceptual two-speaker check lives in dia_dialogue_smoke.py (listen-and-judge).
  # No latency_check here (unlike voxtral/pocket above): dia decodes at RTF≈2.0
  # (model floor) and TTFB scales with the first \n-segment's length, so no fixed
  # --ttfb-bound is meaningful. Latency is measured perceptually in
  # dia_dialogue_smoke.py instead (see dev plan Phase 3 live smoke run).
  verify "dia/dialogue" "$RUN_DIR/dia.wav" \
    --text "[S1] The quick brown fox jumps over the lazy dog. [S2] Indeed it does."
elif [[ "$MULTILINGUAL" -eq 0 ]]; then
  verify "en/af_heart" "$RUN_DIR/en.wav" \
    --voice af_heart --speed 1.1 --text "The quick brown fox jumps over the lazy dog."
else
  # (lang voice text) — es/fr/it/pt/hi route through Kokoro's espeak-ng G2P,
  # which ships with misaki[en]; en uses misaki[en] directly.
  verify "en/af_heart" "$RUN_DIR/en.wav" --voice af_heart \
    --language en --text "The quick brown fox jumps over the lazy dog."
  verify "es/em_alex"  "$RUN_DIR/es.wav" --voice em_alex \
    --language es --text "Hola, el rápido zorro marrón salta sobre el perro perezoso."
  verify "fr/ff_siwis" "$RUN_DIR/fr.wav" --voice ff_siwis \
    --language fr --text "Bonjour, le rapide renard brun saute par-dessus le chien paresseux."
  verify "it/if_sara"  "$RUN_DIR/it.wav" --voice if_sara \
    --language it --text "Ciao, la rapida volpe marrone salta sopra il cane pigro."
  verify "pt/pf_dora"  "$RUN_DIR/pt.wav" --voice pf_dora \
    --language pt --text "Olá, a rápida raposa marrom pula sobre o cão preguiçoso."
  verify "hi/hf_alpha" "$RUN_DIR/hi.wav" --voice hf_alpha \
    --language hi --text "नमस्ते, तेज़ भूरी लोमड़ी आलसी कुत्ते के ऊपर से कूदती है।"
  if [[ "$INCLUDE_CJK" -eq 1 ]]; then
    expect_fail "ja/jf_alpha" "$RUN_DIR/ja.wav" "needs misaki[ja] (pyopenjtalk)" \
      --voice jf_alpha --language ja \
      --text "こんにちは、すばしっこい茶色のキツネが怠け者の犬を飛び越えます。"
    expect_fail "zh/zf_xiaoxiao" "$RUN_DIR/zh.wav" "needs misaki[zh] (ordered_set)" \
      --voice zf_xiaoxiao --language zh --text "你好，敏捷的棕色狐狸跳过了懒狗。"
  fi
fi

# --- summary ----------------------------------------------------------------
echo "== summary: PASS=$PASS FAIL=$FAIL SKIP=$SKIP =="
[[ "$FAIL" -eq 0 ]]
