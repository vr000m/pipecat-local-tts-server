"""Regression guard: the bridge must BULK-materialize mlx audio, never iterate it.

mlx-audio yields ``GenerationResult.audio`` as a float32 mono ``mx.array``.
Iterating an mx.array element-by-element forces a device->host sync PER element
(O(samples) syncs) — a ~500x slowdown that made a 3 s utterance take ~40 s
(RTF ~12x). ``_audio_to_pcm`` must call ``.tolist()`` (one bulk transfer) before
the stdlib converter walks the data. These are LEAN tests (no mlx): a fake
array-like stands in for mx.array and raises if iterated.
"""

from __future__ import annotations

import struct

from tts_server.backends._stream_util import _audio_to_pcm


class _FakeMxArray:
    """Mimics an ``mx.array``: ``.tolist()`` is the cheap bulk transfer; element
    iteration is the catastrophic per-element-sync path the bridge must NEVER take."""

    def __init__(self, vals: list[float]) -> None:
        self._vals = vals

    def tolist(self) -> list[float]:
        return list(self._vals)

    def __iter__(self):
        raise AssertionError(
            "_audio_to_pcm iterated the audio array element-by-element instead of "
            "bulk-materializing via .tolist() — the ~500x device-sync trap (RTF ~12x)"
        )


class _Result:
    def __init__(self, audio) -> None:
        self.audio = audio


def test_audio_to_pcm_bulk_materializes_not_per_element():
    # If the bridge iterates the array, _FakeMxArray.__iter__ raises and this fails.
    pcm = _audio_to_pcm(_Result(_FakeMxArray([0.0, 0.5, -0.5, 1.0, -1.0])))
    vals = struct.unpack("<5h", pcm)
    # Conversion math must still be the asymmetric full-range mapping (R3).
    assert vals[3] == 32767, "1.0 -> +32767"
    assert vals[4] == -32768, "-1.0 -> -32768"
    assert vals[0] == 0


def test_audio_to_pcm_accepts_bare_list():
    # Non-mlx path (tests / ToneBackend): a plain list has no .tolist and must
    # pass straight through the converter unchanged.
    pcm = _audio_to_pcm([0.0, 1.0])
    assert len(pcm) == 4  # two int16 samples
    assert struct.unpack("<2h", pcm)[1] == 32767
