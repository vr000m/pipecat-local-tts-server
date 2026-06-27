"""Clip-invariant unit test for the float32 -> int16-LE PCM converter (lean CI).

``tts_server._audio.float_to_pcm16`` is the single shared converter used by the
streaming bridge and ``ToneBackend``. Per R3 it MUST:

- be a standalone stdlib helper importable WITHOUT ``mlx_audio`` or ``numpy``;
- **saturate** out-of-range input (the [-1,1] range is *observed* for Kokoro on
  one sample, NOT a decoder-guaranteed bound) rather than wrap;
- use the asymmetric full-range map: ``-1.0 -> -32768``, ``+1.0 -> +32767``;
- emit int16-LE bytes.

This file is LEAN (on the lean allow-list): no mlx, no numpy.
"""

from __future__ import annotations

import struct

from tts_server._audio import float_to_pcm16

from ._helpers import lean_import_offenders


def _unpack_le_int16(pcm: bytes) -> list[int]:
    assert len(pcm) % 2 == 0, "PCM16 output must be int16-aligned (even byte count)"
    return list(struct.unpack("<" + "h" * (len(pcm) // 2), pcm))


def test_converter_importable_without_mlx_or_numpy():
    """The converter is a clean stdlib helper -- importing/using it must not pull
    ``mlx_audio`` or ``numpy`` into ``sys.modules`` (lean-base invariant).

    Checked in a fresh interpreter: ``sys.modules`` is process-global, so an
    in-process check fails spuriously once another test imports a heavy dep
    (test-ordering pollution). The child process exercises the function so any
    lazy import inside it would fire.
    """
    offenders = lean_import_offenders(
        "from tts_server._audio import float_to_pcm16\nfloat_to_pcm16([0.0, 0.5, -0.5])"
    )
    assert not offenders, f"float_to_pcm16 must not import a heavy dep; found {offenders}"


def test_saturates_positive_overshoot_does_not_wrap():
    """+1.5 saturates to +32767 (NOT wrap to a negative / overflowed value)."""
    (val,) = _unpack_le_int16(float_to_pcm16([1.5]))
    assert val == 32767


def test_saturates_negative_overshoot_does_not_wrap():
    """-1.5 saturates to -32768 (NOT wrap to a positive / overflowed value)."""
    (val,) = _unpack_le_int16(float_to_pcm16([-1.5]))
    assert val == -32768


def test_rail_values_full_range_asymmetric_map():
    """R3 asymmetric map: -1.0 -> -32768 and +1.0 -> +32767 (full int16 range)."""
    vals = _unpack_le_int16(float_to_pcm16([-1.0, +1.0]))
    assert vals == [-32768, 32767]


def test_zero_is_silence():
    (val,) = _unpack_le_int16(float_to_pcm16([0.0]))
    assert val == 0


def test_in_range_values_and_no_wrap_across_extremes():
    """A mix of in-range, rail, and overshoot values: every sample stays within
    [-32768, 32767] and the overshoots saturate to the rails (no wrap)."""
    samples = [-1.5, -1.0, -0.5, 0.0, 0.5, 1.0, 1.5]
    vals = _unpack_le_int16(float_to_pcm16(samples))
    assert len(vals) == len(samples)
    for v in vals:
        assert -32768 <= v <= 32767
    # Both overshoots and both rails land on the rails -- saturation, not wrap.
    assert vals[0] == -32768  # -1.5
    assert vals[1] == -32768  # -1.0
    assert vals[-1] == 32767  # +1.5
    assert vals[-2] == 32767  # +1.0
    # The zero sample in the middle is exactly silence.
    assert vals[3] == 0


def test_output_is_int16_le_bytes():
    """Output is little-endian int16: a known sample round-trips through '<h'."""
    pcm = float_to_pcm16([1.0])
    assert len(pcm) == 2
    # +32767 little-endian is 0xFF 0x7F.
    assert pcm == struct.pack("<h", 32767) == b"\xff\x7f"
