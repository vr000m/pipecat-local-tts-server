#!/usr/bin/env python3
"""Backend-agnostic synthesis RTF benchmark (in-process, no socket).

Measures realtime-factor (RTF = wall_seconds / audio_seconds) for ANY backend
that ``make_backend`` can build, by driving the ``TTSBackend`` /``TTSStream``
protocol directly (no server, no UDS) so it never collides with a running
``tts_server`` on the canonical socket.

  RTF < ~1  : faster than realtime (viable for live/streaming use)
  RTF > 1   : slower than realtime — for live commentary this is unusable

Reusable across all backends:
``--backend tone|kokoro|voxtral_tts|pocket_tts|dia|qwen3_tts`` — run the same
command per backend to compare response times (cross-backend results live in
this directory's README).

GPU note (Apple-Silicon MLX backends): all MLX processes share ONE Metal device
and our process-wide synthesis lock does NOT span processes. For a clean reading
stop any other MLX process (the sibling ``stt_server``, other ``tts_server``
instances, reconnect-test loops). This script prints any it detects up front.

Usage:
  uv run --extra kokoro python scripts/profiling/rtf_benchmark.py --backend kokoro --voice af_heart
  uv run python scripts/profiling/rtf_benchmark.py --backend tone
  uv run --extra fish_tts python scripts/profiling/rtf_benchmark.py --backend fish_tts --save-audio /tmp/fish_samples
  # inline [tag] variant (prepended to every phrase's text):
  uv run --extra fish_tts python scripts/profiling/rtf_benchmark.py --backend fish_tts --prepend "[excited] "
  # extras-kwarg variant (any backend's advertised extras, e.g. fish's instruct):
  uv run --extra fish_tts python scripts/profiling/rtf_benchmark.py --backend fish_tts --extras '{"instruct": "excited sports commentary"}'
"""

from __future__ import annotations

import argparse
import asyncio
import json
import re
import subprocess
import sys
import time
import wave
from pathlib import Path

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


def _slug(label: str) -> str:
    """Filesystem-safe stem for a phrase label, e.g. "1-sentence (live)" ->
    "1-sentence-live"."""
    return re.sub(r"[^a-z0-9]+", "-", label.lower()).strip("-")


def _other_gpu_procs() -> list[str]:
    """Best-effort: list other tts/stt/mlx processes that would contend for the GPU."""
    try:
        out = subprocess.run(
            ["ps", "axo", "pid,command"], capture_output=True, text=True, timeout=5, check=True
        ).stdout
    except Exception:  # noqa: BLE001
        # Best-effort diagnostic (missing `ps`, non-zero exit, timeout, etc.);
        # never let profiling instrumentation crash the benchmark run.
        return []
    hits = []
    for line in out.splitlines():
        low = line.lower()
        if (
            "tts_server serve" in low or "stt_server" in low or "mlx_audio" in low
        ) and "rtf_benchmark" not in low:
            hits.append(line.strip()[:110])
    return hits


async def _synth_once(
    backend,
    text: str,
    voice: str | None,
    *,
    extras: dict | None = None,
    collect_audio: bool = False,
) -> tuple[float, float, float, bytes]:
    """Return (audio_s, ttfb_s, wall_s, pcm_bytes) for one full utterance.

    ``pcm_bytes`` is empty unless ``collect_audio`` is set — audio is
    discarded by default so the RTF-only path (the common case) pays no
    extra memory/copy cost. ``extras`` is forwarded to ``open_stream``
    unchanged (every backend's ``open_stream`` accepts it; a backend that
    doesn't advertise a given key silently drops it, same as the server
    path) — lets a caller compare, e.g., fish's ``instruct`` kwarg against
    plain/inline-tag text on identical phrases."""
    stream = await backend.open_stream(voice=voice, extras=extras)
    await stream.feed(text)
    await stream.end()
    pcm = bytearray() if collect_audio else None
    pcm_bytes = 0
    ttfb = None
    t0 = time.perf_counter()
    async for ev in stream.events():
        if ev.kind == "delta":
            if ttfb is None:
                ttfb = time.perf_counter() - t0
            pcm_bytes += len(ev.pcm)
            if pcm is not None:
                pcm.extend(ev.pcm)
        elif ev.kind == "completed":
            break
    wall = time.perf_counter() - t0
    audio_s = pcm_bytes / 2 / backend.sample_rate  # int16 mono
    return audio_s, (ttfb if ttfb is not None else wall), wall, bytes(pcm) if pcm else b""


def _write_wav(path: Path, pcm: bytes, sample_rate: int) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)  # int16 mono, matches _synth_once's audio_s math
        w.setframerate(sample_rate)
        w.writeframes(pcm)


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--backend", default="kokoro")
    ap.add_argument("--model", default=None, help="backend model override (else backend default)")
    ap.add_argument("--voice", default=None, help="voice name (e.g. af_heart for kokoro)")
    ap.add_argument("--warm", type=int, default=3, help="warm repeats per phrase")
    ap.add_argument(
        "--save-audio",
        default=None,
        metavar="DIR",
        help="write one .wav per phrase (final warm run only) to DIR for a listen-back check "
        "alongside the RTF numbers; omit to keep the default RTF-only, no-disk-write behavior",
    )
    ap.add_argument(
        "--prepend",
        default="",
        help="prepend this string to every PHRASES text before synthesis, e.g. an inline "
        "'[excited] ' style/emotion tag — lets a run be compared against a plain-text run "
        "on identical base phrases",
    )
    ap.add_argument(
        "--extras",
        default=None,
        metavar="JSON",
        help="JSON object forwarded to open_stream(extras=...) unchanged, e.g. "
        '\'{"instruct": "excited sports commentary"}\' for fish_tts — a backend that does '
        "not advertise a given key silently drops it",
    )
    args = ap.parse_args()
    extras = json.loads(args.extras) if args.extras else None
    if extras is not None and not isinstance(extras, dict):
        ap.error(
            f"--extras must decode to a JSON object, got {type(extras).__name__}: {args.extras!r}"
        )

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
    print(f"start() [cold load + warmup]: {time.perf_counter() - t0:.1f}s")
    if args.prepend:
        print(f"prepend: {args.prepend!r}")
    if extras:
        print(f"extras: {extras!r}")
    print()

    save_dir = Path(args.save_audio) if args.save_audio else None

    hdr = f"{'phrase':22} {'run':8} {'audio_s':>8} {'ttfb_s':>8} {'wall_s':>8} {'RTF':>7}"
    print(hdr)
    print("-" * len(hdr))
    for label, text in PHRASES:
        text = args.prepend + text
        for i in range(args.warm + 1):
            # Only the final warm run's audio is worth keeping — earlier
            # runs (esp. warm1st) are compile/cache outliers per the
            # profiling README's own convention, and collecting audio on
            # every run would multiply the pcm-copy cost for no benefit.
            collect = save_dir is not None and i == args.warm
            tag = "warm1st" if i == 0 else f"warm{i}"
            try:
                audio_s, ttfb, wall, pcm = await _synth_once(
                    backend, text, args.voice, extras=extras, collect_audio=collect
                )
            except Exception as exc:  # noqa: BLE001
                # A backend-level failure (e.g. fish_tts's truncation tripwire)
                # is itself a result worth seeing next to the other phrases'
                # numbers, not a reason to abort the whole comparison run.
                print(f"{label:22} {tag:8} FAILED: {exc}")
                continue
            rtf = wall / audio_s if audio_s else float("nan")
            print(f"{label:22} {tag:8} {audio_s:8.2f} {ttfb:8.2f} {wall:8.2f} {rtf:7.2f}")
            if collect and pcm:
                out = save_dir / f"{args.backend}_{_slug(label)}.wav"
                _write_wav(out, pcm, backend.sample_rate)
                print(f"    -> saved {out}")

    await backend.close()
    print("\nRTF < ~1 = faster than realtime (live-viable); RTF > 1 = slower (live-unusable).")
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
