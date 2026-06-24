"""Evidence for the 'never split mid-sentence' rule.

Synthesize a sentence (a) whole and (b) split at a NON-boundary (no punctuation at
the cut), then compare total duration and trailing silence per chunk. If the split
version is materially longer and each mid-phrase chunk carries terminal silence,
that is concrete evidence that mid-sentence commits degrade prosody.
"""

import numpy as np
from mlx_audio.tts.utils import load

SR = 24000
model = load("mlx-community/Kokoro-82M-bf16")


def synth(text: str) -> np.ndarray:
    chunks = [np.array(r.audio, copy=False) for r in model.generate(text, voice="af_heart")]
    return np.concatenate(chunks).astype(np.float32)


def trailing_silence_ms(a: np.ndarray, thresh: float = 0.01) -> float:
    loud = np.where(np.abs(a) > thresh)[0]
    if len(loud) == 0:
        return len(a) / SR * 1000
    return (len(a) - loud[-1] - 1) / SR * 1000


def stats(label: str, a: np.ndarray) -> None:
    print(
        f"  {label:<26} dur={len(a) / SR * 1000:7.1f}ms  "
        f"peak={np.abs(a).max():.3f}  trail_sil={trailing_silence_ms(a):6.1f}ms"
    )


whole = synth("The quick brown fox jumps over the lazy dog.")
part_a = synth("The quick brown fox")  # mid-sentence cut, no punctuation
part_b = synth("jumps over the lazy dog.")
split_total_ms = (len(part_a) + len(part_b)) / SR * 1000
whole_ms = len(whole) / SR * 1000

print("== whole sentence ==")
stats("whole", whole)
print("== split at a non-boundary (the bad case) ==")
stats("part A 'fox' (mid)", part_a)
stats("part B 'jumps..dog.'", part_b)
print("== comparison ==")
print(f"  whole = {whole_ms:.1f}ms   split A+B = {split_total_ms:.1f}ms")
print(
    f"  split is {split_total_ms - whole_ms:+.1f}ms ({(split_total_ms / whole_ms - 1) * 100:+.1f}%) vs whole"
)
print(
    f"  mid-phrase chunk 'part A' trailing silence = {trailing_silence_ms(part_a):.1f}ms "
    f"(terminal-intonation/pause injected mid-sentence if large)"
)
