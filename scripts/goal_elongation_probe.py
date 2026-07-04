"""Elongated-vowel ("GOOOOAL") probe — creation + analysis, all backends.

Measures how each TTS backend renders grapheme elongation (the Spanish-
commentator sustained vowel): writes per-variant WAVs and reports total vs
VOICED duration so babble/silence tails don't masquerade as sustain.

Findings from the 2026-07-04 run (see dev-plan follow-ups):

- kokoro   — deterministic, scales with O-count (30 O's ≈ 2.6 s, 60 ≈ 4.7 s
             voiced). The only backend where a duration assertion won't flake.
             60 O's also exercises the sinegen vocoder patch hard (unpatched
             upstream crashes with a broadcast_shapes error).
- qwen3    — sampled and NON-monotonic (30 O's came out shorter than 10);
             60 O's gave ~12 s but quality is a lottery.
- pocket   — clean but compresses elongation (60 O's ≈ 2.4 s).
- dia      — dialogue model, goes full drama (25 s takes at RTF ≈ 2).
- voxtral  — near-silence for elongated graphemes; effectively refuses.

Usage (one backend per process — model globals don't cohabit):

    uv run --extra kokoro      python scripts/goal_elongation_probe.py kokoro  /tmp/goal_wavs
    uv run --extra qwen3_tts   python scripts/goal_elongation_probe.py qwen3   /tmp/goal_wavs
    uv run --extra pocket_tts  python scripts/goal_elongation_probe.py pocket  /tmp/goal_wavs
    uv run --extra dia         python scripts/goal_elongation_probe.py dia     /tmp/goal_wavs
    uv run --extra voxtral_tts python scripts/goal_elongation_probe.py voxtral /tmp/goal_wavs

Analysis only (re-measure existing WAVs, no model load):

    uv run python scripts/goal_elongation_probe.py analyze /tmp/goal_wavs
"""

from __future__ import annotations

import sys
import time
import wave
from pathlib import Path

import numpy as np

VARIANTS = {
    "goal_plain": "Goal!",
    "goal_10o": "G" + "O" * 10 + "AL!",
    "goal_30o": "G" + "O" * 30 + "AL!",
    "goal_60o": "G" + "O" * 60 + "AL!",
    "goal_context": "And he shoots... G" + "O" * 40 + "AL! What a strike!",
}

# Per-backend generate() shape, mirroring each backend's _gen_factory kwargs.
# (model_id, gen_kwargs, needs_disable_compile)
BACKENDS = {
    "kokoro": (
        "mlx-community/Kokoro-82M-bf16",
        {"voice": "af_heart", "lang_code": "a"},
        False,
    ),
    "voxtral": (
        "mlx-community/Voxtral-4B-TTS-2603-mlx-bf16",
        {"stream": True, "streaming_interval": 0.3, "voice": "casual_male"},
        False,
    ),
    "pocket": (
        "mlx-community/pocket-tts",
        {"stream": True, "streaming_interval": 0.3, "voice": "alba"},
        False,
    ),
    "dia": ("mlx-community/Dia-1.6B-fp16", {}, False),
    "qwen3": (
        "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16",
        {"stream": True, "streaming_interval": 0.4, "voice": "ryan"},
        True,  # same CompilerCache crash guard the backend applies
    ),
}


def write_wav(path: Path, audio: np.ndarray, rate: int) -> None:
    """Asymmetric x32768/x32767 clip+map — the wire mapping (tts_server/_audio.py)."""
    clipped = np.clip(audio, -1.0, 1.0)
    pcm = np.where(clipped < 0, clipped * 32768.0, clipped * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())


def voiced_span_seconds(x: np.ndarray, rate: int) -> float:
    """First-to-last voiced 20 ms frame (RMS > 2% full scale) — trims silence
    and hallucinated quiet tails that inflate total duration."""
    n = int(rate * 0.02)
    if len(x) < n:
        return 0.0
    frames = x[: len(x) // n * n].reshape(-1, n)
    rms = np.sqrt((frames**2).mean(axis=1))
    idx = np.where(rms > 0.02)[0]
    return float((idx[-1] - idx[0] + 1) * 0.02) if len(idx) else 0.0


def analyze(wav_dir: Path) -> None:
    for f in sorted(wav_dir.glob("*.wav")):
        with wave.open(str(f)) as w:
            rate = w.getframerate()
            x = np.frombuffer(w.readframes(w.getnframes()), dtype=np.int16)
        x = x.astype(np.float32) / 32768.0
        total = len(x) / rate
        print(f"{f.stem:24s} total={total:6.2f}s voiced={voiced_span_seconds(x, rate):6.2f}s")


def synthesize(backend: str, out_dir: Path) -> None:
    model_id, gen_kwargs, disable_compile = BACKENDS[backend]
    import mlx.core as mx
    from mlx_audio.tts.utils import load

    if disable_compile:
        mx.disable_compile()
    if backend == "kokoro":
        # Upstream sinegen broadcast bug crashes on long generations (60 O's
        # reproduces it); apply the same runtime patch the backend uses.
        from tts_server.backends.kokoro import _apply_kokoro_vocoder_fix

        _apply_kokoro_vocoder_fix()

    model = load(model_id, lazy=False, strict=True)
    rate = int(getattr(model, "sample_rate", 24000))
    print(f"[{backend}] loaded {model_id}, rate={rate}")

    for name, text in VARIANTS.items():
        if backend == "dia":
            text = "[S1] " + text  # dia is dialogue-tagged
        t0 = time.monotonic()
        chunks: list[np.ndarray] = []
        try:
            for res in model.generate(text, **gen_kwargs):
                chunks.append(np.asarray(res.audio.tolist(), dtype=np.float32))
        except Exception as exc:  # noqa: BLE001 - probe reports, never aborts the matrix
            print(f"[{backend}] {name:14s} FAILED: {exc}")
            continue
        wall = time.monotonic() - t0
        audio = np.concatenate(chunks) if chunks else np.zeros(1, dtype=np.float32)
        write_wav(out_dir / f"{backend}_{name}.wav", audio, rate)
        print(
            f"[{backend}] {name:14s} audio={len(audio) / rate:6.2f}s "
            f"voiced={voiced_span_seconds(audio, rate):6.2f}s wall={wall:6.2f}s"
        )


def main() -> None:
    if len(sys.argv) != 3 or (sys.argv[1] != "analyze" and sys.argv[1] not in BACKENDS):
        names = ", ".join(BACKENDS)
        sys.exit(f"usage: goal_elongation_probe.py <{names}|analyze> <wav_dir>")
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)
    if sys.argv[1] == "analyze":
        analyze(out_dir)
    else:
        synthesize(sys.argv[1], out_dir)


if __name__ == "__main__":
    main()
