#!/usr/bin/env python3
"""Backend-agnostic synthesis RTF benchmark (in-process, no socket).

Measures realtime-factor (RTF = wall_seconds / audio_seconds) for ANY backend
that ``make_backend`` can build, by driving the ``TTSBackend`` /``TTSStream``
protocol directly (no server, no UDS) so it never collides with a running
``tts_server`` on the canonical socket.

  RTF < ~1  : faster than realtime (viable for live/streaming use)
  RTF > 1   : slower than realtime — for live commentary this is unusable

Reusable across backends: ``--backend tone|kokoro`` today, and the Phase 5
streaming backends (``voxtral_tts``/``pocket_tts``) once they land — run the
same command with ``--backend voxtral_tts`` to compare response times.

GPU note (Apple-Silicon MLX backends): all MLX processes share ONE Metal device
and our process-wide synthesis lock does NOT span processes. For a clean reading
stop any other MLX process (the sibling ``stt_server``, other ``tts_server``
instances, reconnect-test loops). This script prints any it detects up front.

Usage:
  uv run --extra kokoro python scripts/profiling/rtf_benchmark.py --backend kokoro --voice af_heart
  uv run python scripts/profiling/rtf_benchmark.py --backend tone
"""

from __future__ import annotations

import argparse
import asyncio
import subprocess
import sys
import time

from tts_server.backends import make_backend

# (label, text). The single short sentence is the live-commentary case; the
# longer / multi-segment ones confirm whether RTF is flat/linear with length
# and whether per-segment streaming lowers time-to-first-byte (TTFB).
PHRASES = [
    ("1-sentence (live)", "Goal! The home team scores in the final minute."),
    (
        "2-sentence (1 seg)",
        "Goal! The home team scores in the final minute. The keeper had no chance on that strike.",
    ),
    (
        "3-seg (newlines)",
        "Goal!\nThe home team scores in the final minute.\nThe keeper had no chance on that strike.",
    ),
]


def _other_gpu_procs() -> list[str]:
    """Best-effort: list other tts/stt/mlx processes that would contend for the GPU."""
    try:
        out = subprocess.run(
            ["ps", "axo", "pid,command"], capture_output=True, text=True, timeout=5
        ).stdout
    except Exception:
        return []
    hits = []
    for line in out.splitlines():
        low = line.lower()
        if (
            "tts_server serve" in low or "stt_server" in low or "mlx_audio" in low
        ) and "rtf_benchmark" not in low:
            hits.append(line.strip()[:110])
    return hits


async def _synth_once(backend, text: str, voice: str | None) -> tuple[float, float, float]:
    """Return (audio_s, ttfb_s, wall_s) for one full utterance."""
    stream = await backend.open_stream(voice=voice)
    await stream.feed(text)
    await stream.end()
    pcm_bytes = 0
    ttfb = None
    t0 = time.perf_counter()
    async for ev in stream.events():
        if ev.kind == "delta":
            if ttfb is None:
                ttfb = time.perf_counter() - t0
            pcm_bytes += len(ev.pcm)
        elif ev.kind == "completed":
            break
    wall = time.perf_counter() - t0
    audio_s = pcm_bytes / 2 / backend.sample_rate  # int16 mono
    return audio_s, (ttfb if ttfb is not None else wall), wall


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="kokoro")
    ap.add_argument("--model", default=None, help="backend model override (else backend default)")
    ap.add_argument("--voice", default=None, help="voice name (e.g. af_heart for kokoro)")
    ap.add_argument("--warm", type=int, default=3, help="warm repeats per phrase")
    args = ap.parse_args()

    others = _other_gpu_procs()
    if others:
        print("\n*** WARNING: other tts/stt/mlx processes detected — GPU may be CONTENDED.")
        print("*** Check their %CPU (idle/0%% = negligible); stop them for a pristine reading:")
        for line in others:
            print(f"    {line}")
    else:
        print("isolation: no other tts/stt/mlx processes detected — clean run")
    print()

    backend = make_backend(args.backend, args.model)
    t0 = time.perf_counter()
    await backend.start()  # cold model load + (kokoro) JIT warmup
    print(
        f"backend={args.backend} model={getattr(backend, 'model', None)} rate={backend.sample_rate} Hz"
    )
    print(f"start() [cold load + warmup]: {time.perf_counter() - t0:.1f}s\n")

    hdr = f"{'phrase':22} {'run':8} {'audio_s':>8} {'ttfb_s':>8} {'wall_s':>8} {'RTF':>7}"
    print(hdr)
    print("-" * len(hdr))
    for label, text in PHRASES:
        for i in range(args.warm + 1):
            audio_s, ttfb, wall = await _synth_once(backend, text, args.voice)
            rtf = wall / audio_s if audio_s else float("nan")
            tag = "warm1st" if i == 0 else f"warm{i}"
            print(f"{label:22} {tag:8} {audio_s:8.2f} {ttfb:8.2f} {wall:8.2f} {rtf:7.2f}")

    await backend.close()
    print("\nRTF < ~1 = faster than realtime (live-viable); RTF > 1 = slower (live-unusable).")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
