# Upstream report: Kokoro `SineGen._f02sine` is not length-preserving → `broadcast_shapes` failure on most utterances

**Target project:** [`Blaizzy/mlx-audio`](https://github.com/Blaizzy/mlx-audio)
**Affected version:** `0.4.4` (latest PyPI) and `main` as of 2026-06-24
**File:** `mlx_audio/tts/models/kokoro/istftnet.py`
**Severity:** High — Kokoro TTS synthesis raises for the majority of inputs.

## Summary

`SineGen._f02sine()` does not preserve its input's time-axis length. For most
inputs it returns a tensor one `upsample_scale` hop (300 samples at 24 kHz)
longer than its input. In `SineGen.__call__`, `sine_waves` (from `_f02sine`) is
then longer than `uv`/`noise_amp` (derived from `_f02uv(f0)`, which keep the
original length), so:

```python
noise = noise_amp * mx.random.normal(sine_waves.shape)
```

multiplies `(1, T, 1)` by `(1, T+300, 9)` and MLX (correctly) refuses to
broadcast:

```
ValueError: [broadcast_shapes] Shapes (1,36600,1) and (1,36900,9) cannot be broadcast.
```

The failure is deterministic by audio length: only inputs whose length is a
fixed point of the `_f02sine` interpolate round-trip succeed.

## Reproduction

```python
from mlx_audio.tts.utils import load
m = load("mlx-community/Kokoro-82M-bf16", lazy=False, strict=True)

def synth(text):
    try:
        n = sum(1 for _ in m.generate(text, voice="af_heart", lang_code="a"))
        print("OK  ", repr(text))
    except Exception as e:
        print("FAIL", repr(text), "->", e)

synth("GOAL!")          # OK   (length happens to align)
synth("Hello there.")   # FAIL -> [broadcast_shapes] (1,36600,1) and (1,36900,9)
synth("Warm up")        # FAIL -> (1,33600,1) and (1,33900,9)
synth("Hello world.")   # FAIL -> (1,37800,1) and (1,38100,9)
synth("The cat sat.")   # FAIL -> (1,36600,1) and (1,36900,9)
```

Every failure is off by exactly **300** samples (one `upsample_scale` hop).

## Root cause

`_f02sine` reconstructs its time axis with a downsample → cumsum → upsample
round-trip:

```python
rad_values = interpolate(rad_values.transpose(0, 2, 1),
                         scale_factor=1 / self.upsample_scale, mode="linear").transpose(0, 2, 1)
phase = mx.cumsum(rad_values, axis=1) * 2 * mx.pi
phase = interpolate(phase.transpose(0, 2, 1) * self.upsample_scale,
                    scale_factor=self.upsample_scale, mode="linear").transpose(0, 2, 1)
sines = mx.sin(phase)
```

`interpolate(1/S)` then `interpolate(S)` does **not** recover the original
length unless the length is an exact fixed point of the two roundings — so the
output is generally one hop longer than the input. `_f02uv(f0)` (a plain
threshold) keeps the original length, so the two branches diverge.

## Proposed fix

Enforce `_f02sine`'s length contract — its output length should equal its input
length. Truncating to the input length is a no-op when they already match:

```python
def _f02sine(self, f0_values):
    ...
    sines = mx.sin(phase)
    # Length-preserving guard: the interpolate round-trip above can emit one
    # extra upsample_scale hop; trim back to the input length so the harmonic
    # branch stays aligned with uv/noise_amp in __call__.
    if sines.shape[1] != f0_values.shape[1]:
        sines = sines[:, :f0_values.shape[1], :]
    return sines
```

Equivalently, align in `__call__` before the multiply:

```python
T = min(sine_waves.shape[1], uv.shape[1])
sine_waves, uv = sine_waves[:, :T, :], uv[:, :T, :]
noise_amp = uv * self.noise_std + (1 - uv) * self.sine_amp / 3
noise = noise_amp * mx.random.normal(sine_waves.shape)
```

## Verification

With the guard applied, all previously-failing phrases synthesize with correct
lengths and intelligible audio:

```
OK  'GOAL!'        : 32400 samples (1.35s)   # unchanged
OK  'Hello there.' : 36600 samples (1.52s)
OK  'Warm up'      : 33600 samples (1.40s)
OK  'Hello world.' : 37800 samples (1.57s)
OK  'The cat sat.' : 36600 samples (1.52s)
OK  'The quick brown fox ...' : 97800 samples (4.08s)
```

## Environment

- `mlx-audio==0.4.4`, `mlx==0.31.2`, `mlx-metal==0.31.2`, `mlx-lm==0.31.3`
- Apple Silicon (arm64), macOS, Python 3.12
- Model: `mlx-community/Kokoro-82M-bf16`
