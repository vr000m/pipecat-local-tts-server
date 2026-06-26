#!/usr/bin/env python3
"""Where does Kokoro's ~12x RTF go? Acoustic-model vs istftnet-vocoder split.

Context: on this M4 Max, mlx-audio 0.4.4 Kokoro-82M-bf16 synthesises at ~12x
realtime (measured by rtf_benchmark.py, independently confirmed by the gamealerts
client). We proved it is NOT CPU fallback (device=GPU), NOT slow bf16 kernels
(bf16 matmul == fp16), and NOT our vocoder length-fix shim (a cheap slice). This
script answers the remaining question: is the time in the ACOUSTIC model
(ALBERT + ProsodyPredictor + TextEncoder) or the istftnet VOCODER (Decoder)? —
which tells us whether Kokoro is rescuable or simply the wrong engine for live.

How it works (hooks mlx-audio 0.4.4 internals — version-pinned, guarded):
  - ``kokoro.Model.__call__``  : the full per-segment forward; it already ends
    with ``mx.eval(audio, pred_dur)``, so wall time across it is the real total.
  - ``istftnet.Decoder.__call__`` (the vocoder): on entry we ``mx.eval`` the
    decoder's inputs (asr/F0/N/s) to force the ACOUSTIC graph to materialise —
    time so far = acoustic; then ``mx.eval`` the decoder output = vocoder.
MLX is lazy, so these forced evals add sync points that would not occur in a
normal run — an accepted profiling distortion that buys a faithful split.
total ≈ acoustic + vocoder (+ small framing overhead).

If upstream restructures these symbols, the hooks no-op with a clear warning
(re-check against the installed mlx-audio; pin is 0.4.4).

Usage (run with the GPU otherwise idle — see rtf_benchmark.py GPU note):
  uv run --extra kokoro python scripts/profiling/kokoro_generate_split.py --voice af_heart
"""

from __future__ import annotations

import argparse
import asyncio
import sys
import time

from tts_server.backends.kokoro import KokoroBackend

PHRASES = [
    ("1-sentence (live)", "Goal! The home team scores in the final minute."),
    (
        "2-sentence (1 seg)",
        "Goal! The home team scores in the final minute. The keeper had no chance on that strike.",
    ),
]


class _Split:
    """Accumulates acoustic vs vocoder wall time across all forward calls."""

    def __init__(self) -> None:
        self.acoustic = 0.0
        self.vocoder = 0.0
        self.total = 0.0
        self._fwd_t0: float | None = None

    def reset(self) -> None:
        self.__init__()


def _install_hooks(split: _Split):
    """Monkeypatch Model.__call__ and Decoder.__call__ to time the split.

    Returns a restore() callable, or None if the symbols could not be located.
    """
    import mlx.core as mx

    try:
        from mlx_audio.tts.models.kokoro import istftnet, kokoro
    except Exception as exc:  # noqa: BLE001
        print(f"WARNING: could not import mlx-audio kokoro internals: {exc}")
        return None

    Model = getattr(kokoro, "Model", None)
    Decoder = getattr(istftnet, "Decoder", None)
    if Model is None or Decoder is None or not hasattr(Decoder, "__call__"):
        print("WARNING: kokoro.Model / istftnet.Decoder not found — hooks NOT installed.")
        return None

    orig_model_call = Model.__call__
    orig_decoder_call = Decoder.__call__

    def model_call(self, *a, **k):
        split._fwd_t0 = time.perf_counter()
        out = orig_model_call(self, *a, **k)  # ends with mx.eval(audio, pred_dur)
        split.total += time.perf_counter() - split._fwd_t0
        return out

    def decoder_call(self, asr, F0_curve, N, s, *a, **k):
        # Force the ACOUSTIC graph (decoder inputs) to materialise: time to here
        # since forward start = acoustic.
        mx.eval(asr, F0_curve, N, s)
        if split._fwd_t0 is not None:
            split.acoustic += time.perf_counter() - split._fwd_t0
        t_voc = time.perf_counter()
        out = orig_decoder_call(self, asr, F0_curve, N, s, *a, **k)
        mx.eval(out)  # force the vocoder
        split.vocoder += time.perf_counter() - t_voc
        return out

    Model.__call__ = model_call
    Decoder.__call__ = decoder_call

    def restore() -> None:
        Model.__call__ = orig_model_call
        Decoder.__call__ = orig_decoder_call

    return restore


async def _drain(backend: KokoroBackend, text: str, voice: str | None) -> float:
    stream = await backend.open_stream(voice=voice)
    await stream.feed(text)
    await stream.end()
    pcm = 0
    async for ev in stream.events():
        if ev.kind == "delta":
            pcm += len(ev.pcm)
        elif ev.kind == "completed":
            break
    return pcm / 2 / backend.sample_rate


async def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--voice", default="af_heart")
    ap.add_argument("--warm", type=int, default=2)
    args = ap.parse_args()

    backend = KokoroBackend(model="mlx-community/Kokoro-82M-bf16")
    await backend.start()  # applies our vocoder shim + warms JIT
    split = _Split()
    restore = _install_hooks(split)
    if restore is None:
        print("Hooks unavailable; aborting (cannot produce the split).")
        return 1

    print(f"backend rate: {backend.sample_rate} Hz  voice: {args.voice}\n")
    hdr = f"{'phrase':22} {'run':8} {'audio_s':>8} {'acoustic':>9} {'vocoder':>9} {'total':>8} {'voc%':>6} {'RTF':>7}"
    print(hdr)
    print("-" * len(hdr))
    try:
        for label, text in PHRASES:
            for i in range(args.warm + 1):
                split.reset()
                t0 = time.perf_counter()
                audio_s = await _drain(backend, text, args.voice)
                wall = time.perf_counter() - t0
                voc_pct = 100 * split.vocoder / split.total if split.total else float("nan")
                rtf = wall / audio_s if audio_s else float("nan")
                tag = "warm1st" if i == 0 else f"warm{i}"
                print(
                    f"{label:22} {tag:8} {audio_s:8.2f} {split.acoustic:9.2f} "
                    f"{split.vocoder:9.2f} {split.total:8.2f} {voc_pct:6.0f} {rtf:7.2f}"
                )
    finally:
        restore()
        await backend.close()

    print(
        "\nRead: if voc%% dominates, the istftnet vocoder is the bottleneck (FFT/sine/"
        "conv ops, not matmul) — a candidate for an MLX-optimised vocoder or a different\n"
        "backend. If acoustic dominates, the ALBERT/predictor path is the cost. Either way,\n"
        "RTF ~12x means Kokoro is unsuited to live commentary regardless of the split."
    )
    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
