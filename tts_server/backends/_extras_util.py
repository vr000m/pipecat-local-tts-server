"""Shared coercion for the client-supplied sampling extras.

Single source of truth for the ``temperature``/``top_k``/``top_p`` validation
that every backend applies before splatting extras into ``generate()``. The
values are forwarded under the process-wide Metal lock, so unbounded values
are a denial-of-service / correctness vector: a degenerate ``top_p``/
``temperature`` can drive runaway or broken sampling that stalls every other
connection's commit. Finite values are CLAMPED; non-finite (NaN/inf),
non-numeric, and boolean values are rejected outright (``bool`` is an
``int``/``float``-coercible subclass — a client sending JSON ``true`` made a
config mistake and must hear about it, not get a silent 1.0).

Stdlib-only on purpose (same rule as ``_stream_util``): backends import this
at module load, and the lean-import tests forbid heavyweight roots
(``mlx_audio``/``numpy``) at import time.

Each backend keeps its OWN ``_EXTRA_COERCERS`` dict — that dict is the
backend's advertised-extras allowlist, which legitimately differs per model
(qwen3/voxtral take all three knobs, dia has no ``top_k``, pocket only
``temperature``). Only the coercer bodies and the ``validate_extras`` walk are
shared.
"""

from __future__ import annotations

import math
from typing import Any, Callable, Mapping

TEMPERATURE_MIN = 0.0
TEMPERATURE_MAX = 2.0
TOP_K_MIN = 1
TOP_K_MAX = 500
TOP_P_MIN = 0.0  # exclusive lower bound enforced in coerce_top_p
TOP_P_MAX = 1.0


def coerce_temperature(raw: Any) -> float:
    """Validate + clamp a client-supplied ``temperature`` before generate()."""
    if isinstance(raw, bool):  # bool is coercible to float; reject it explicitly.
        raise ValueError(f"temperature must be a number, got {raw!r}")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError(f"temperature must be a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise ValueError(f"temperature must be a finite number, got {raw!r}")
    if value < TEMPERATURE_MIN:
        return TEMPERATURE_MIN
    if value > TEMPERATURE_MAX:
        return TEMPERATURE_MAX
    return value


def coerce_top_k(raw: Any) -> int:
    """Validate + clamp a client-supplied ``top_k`` (a positive integer)."""
    if isinstance(raw, bool):  # bool is an int subclass; reject it explicitly.
        raise ValueError(f"top_k must be an integer, got {raw!r}")
    # Reject a non-integral float (e.g. 2.9) rather than silently truncating to 2
    # — the client should learn its value was not an integer, not get a quietly
    # different one. Integral floats (50.0) and int-valued strings ("40") are ok.
    if isinstance(raw, float) and not raw.is_integer():
        raise ValueError(f"top_k must be an integer, got {raw!r}")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ValueError(f"top_k must be an integer, got {raw!r}") from None
    if value < TOP_K_MIN:
        return TOP_K_MIN
    if value > TOP_K_MAX:
        return TOP_K_MAX
    return value


def coerce_top_p(raw: Any) -> float:
    """Validate + clamp a client-supplied ``top_p`` into ``(0, 1]``."""
    if isinstance(raw, bool):  # bool is coercible to float; reject it explicitly.
        raise ValueError(f"top_p must be a number, got {raw!r}")
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError(f"top_p must be a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise ValueError(f"top_p must be a finite number, got {raw!r}")
    if value <= TOP_P_MIN:
        # A non-positive top_p selects no tokens — reject rather than clamp to a
        # surprising tiny value, so the client learns its request was invalid.
        raise ValueError(f"top_p must be > 0 and <= 1, got {raw!r}")
    if value > TOP_P_MAX:
        return TOP_P_MAX
    return value


def validate_extras(
    coercers: Mapping[str, Callable[[Any], Any]], extras: Mapping[str, Any]
) -> str | None:
    """``SupportsExtrasValidation`` walk shared by every backend: run each
    advertised extra through its coercer and return the first error message,
    or ``None`` when everything present is valid. Values are validated, not
    collected — coercion for ``generate()`` happens later in ``open_stream``
    on the merged per-utterance extras."""
    for key, coerce in coercers.items():
        raw = extras.get(key)
        if raw is None:
            continue
        try:
            coerce(raw)
        except ValueError as exc:
            return str(exc)
    return None
