"""Shared helper functions for the fish/qwen3 Phase 0 verification gates.

Extracted from ``fish_phase0_gate.py``/``qwen3_phase0_gate.py`` after
diffing both scripts' copies byte-for-byte identical (2026-08-07). Both gate
scripts import from this module — the same-directory top-level import works
for standalone scripts (Python puts the script's directory on
``sys.path[0]``).

Lazy imports of ``numpy``/``mlx`` stay INSIDE each function body, not
hoisted to module top — deliberate, so a ``--only q6``-style partial gate
run does not require importing numpy/mlx just to import this module.

``dia_dialogue_smoke.py`` does NOT import from here for ``_write_wav``: its
own local helper writes already-quantized int16 PCM bytes from a websocket
client (a different signature/contract from this module's float32-array
``_write_wav``) — do not alias or replace it.
"""

from __future__ import annotations

import wave
from pathlib import Path


def _to_numpy(audio):
    """Materialise an mlx (or array-like) audio buffer as a float32 numpy array."""
    import numpy as np

    return np.asarray(audio, dtype=np.float32)


def _audio_sanity(label: str, audio_np, rate: int) -> None:
    """Audio-sanity record for a generated buffer: NaN count, max abs, duration."""
    import numpy as np

    nan_count = int(np.isnan(audio_np).sum())
    max_abs = float(np.max(np.abs(audio_np))) if audio_np.size else 0.0
    duration = audio_np.shape[0] / rate if rate else float("nan")
    clipped = " CLIPPED" if max_abs > 1.0 else ""
    print(
        f"   RECORD [{label}] audio-sanity: nan_count={nan_count} "
        f"max_abs={max_abs:.4f}{clipped} duration={duration:.2f}s samples={audio_np.shape[0]}"
    )


def _write_wav(path: Path, audio_np, rate: int) -> None:
    """Write a float32 [-1, 1] mono buffer as pcm16 WAV (clipped, not normalised)."""
    import numpy as np

    # Asymmetric x32768/x32767 map — the wire mapping (tts_server/_audio.py);
    # the naive symmetric x32767 never reaches -32768 and clips the negative
    # rail one LSB early. Inlined (numpy) to keep this script standalone.
    clipped = np.clip(audio_np, -1.0, 1.0)
    pcm = np.where(clipped < 0, clipped * 32768.0, clipped * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    print(f"   WAV written: {path}")


def _drain(gen) -> list:
    """Drain a generate() generator, returning the list of GenerationResults."""
    return list(gen)


def _concat_audio(results) -> object:
    import numpy as np

    parts = [_to_numpy(r.audio) for r in results if getattr(r, "audio", None) is not None]
    if not parts:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(parts)


def _array_equal(a, b) -> bool:
    import numpy as np

    a, b = np.asarray(a), np.asarray(b)
    return a.shape == b.shape and bool(np.array_equal(a, b))


def _max_abs_diff(a, b) -> float:
    import numpy as np

    a, b = np.asarray(a), np.asarray(b)
    if a.shape != b.shape:
        return float("inf")
    return float(np.max(np.abs(a - b))) if a.size else 0.0


def _reset_peak_memory() -> None:
    import mlx.core as mx

    reset = getattr(mx, "reset_peak_memory", None)
    if callable(reset):
        reset()
