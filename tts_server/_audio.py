"""Stdlib-only float32 -> int16-LE PCM conversion (R3).

This is the single shared converter used by the streaming bridge
(``backends/_stream_util.py``) and ``ToneBackend``. It is deliberately a clean
standalone function importable **without** ``mlx_audio`` or ``numpy`` — only
``array``/``struct``/``math`` from the stdlib — so the lean base (and Phase 2's
lean-CI clip-invariant unit test) never pull a dev-only dependency.

float -> int16 mapping (asymmetric, full-range), per R3 / docs/protocol.md §2:

- clip each sample to ``[-1.0, 1.0]`` (the ``[-1,1]`` range is *observed* for
  Kokoro on one sample, not a decoder-guaranteed bound — clipping prevents
  int16 overflow/clicks on an outlier);
- map **negative** samples by ``×32768`` and **non-negative** by ``×32767`` so
  ``-1.0 -> -32768`` and ``+1.0 -> +32767`` (the full signed-int16 range).

The asymmetric scale is why a naive symmetric ``round(x * 32767)`` is wrong: it
would never reach ``-32768`` and would clip the negative rail one LSB early.
"""

from __future__ import annotations

import array
import math
from typing import Iterable

_INT16_MIN = -32768
_INT16_MAX = 32767


def float_to_pcm16(samples: Iterable[float]) -> bytes:
    """Convert a sequence of Python floats to int16-LE mono PCM bytes.

    Saturates (does not wrap) out-of-range inputs: ``+1.5 -> +32767``,
    ``-1.5 -> -32768``. NaN maps to silence (0).
    """
    out = array.array("h")
    for x in samples:
        # NaN compares False against everything; treat as silence rather than
        # letting int() raise.
        if x != x:  # NaN
            out.append(0)
            continue
        if x >= 1.0:
            out.append(_INT16_MAX)
        elif x <= -1.0:
            out.append(_INT16_MIN)
        elif x < 0.0:
            # Negative samples scale by 32768. floor() so e.g. a sample just
            # below 0 stays within range and the rail is reachable.
            v = int(math.floor(x * 32768.0))
            if v < _INT16_MIN:
                v = _INT16_MIN
            out.append(v)
        else:
            # Non-negative samples scale by 32767.
            v = int(x * 32767.0 + 0.5)
            if v > _INT16_MAX:
                v = _INT16_MAX
            out.append(v)
    # ``array('h')`` is host-endian; force little-endian on the wire.
    if _is_big_endian():
        out.byteswap()
    return out.tobytes()


def _is_big_endian() -> bool:
    import sys

    return sys.byteorder == "big"
