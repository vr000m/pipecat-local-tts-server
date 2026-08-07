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
from collections.abc import Callable, Mapping
from typing import Any

TEMPERATURE_MIN = 0.0
TEMPERATURE_MAX = 2.0
TOP_K_MIN = 1
TOP_K_MAX = 500
TOP_P_MIN = 0.0  # exclusive lower bound enforced in coerce_top_p
TOP_P_MAX = 1.0


def coerce_temperature(raw: Any) -> float:
    """Validate + clamp a client-supplied ``temperature`` before generate()."""
    if isinstance(raw, bool):  # bool is coercible to float; reject it explicitly.
        # ValueError (not TypeError) is deliberate: validate_extras() catches
        # ValueError uniformly across every coercion failure in this module.
        raise ValueError(f"temperature must be a number, got {raw!r}")  # noqa: TRY004
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
        # ValueError (not TypeError) is deliberate: validate_extras() catches
        # ValueError uniformly across every coercion failure in this module.
        raise ValueError(f"top_k must be an integer, got {raw!r}")  # noqa: TRY004
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
        # ValueError (not TypeError) is deliberate: validate_extras() catches
        # ValueError uniformly across every coercion failure in this module.
        raise ValueError(f"top_p must be a number, got {raw!r}")  # noqa: TRY004
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


def coerce_instruct(raw: Any, max_len: int) -> str | None:
    """Validate a client-supplied ``instruct`` string (net-new: the first
    string-typed advertised extra — see ``fish_tts.py``).

    Generic checks only: ``raw`` must be a ``str`` (this alone rejects
    ``bool``/``bytes``/numbers — neither ``bool`` nor ``bytes`` is an
    ``isinstance`` match for ``str``, unlike the numeric coercers' need for an
    explicit ``bool`` guard). Leading/trailing whitespace is stripped.

    Unlike ``coerce_temperature``/``coerce_top_k``/``coerce_top_p`` (which
    CLAMP an out-of-bound value — any in-range sample knob is still valid), an
    oversized ``instruct`` is REJECTED, not truncated: silently cutting an
    instruction changes what the client actually told the model to do. The
    length bound (``max_len``) is a parameter, not a module constant — each
    backend that advertises ``instruct`` supplies its own calibrated bound
    (e.g. ``fish_tts.py``'s ``_INSTRUCT_MAX_LEN``); this module stays a
    generic, cross-backend DoS/correctness bound library and must not silently
    hand a fish-calibrated number to some future second ``instruct``-advertising
    backend.

    Returns ``None`` for a valid-but-empty-after-strip string — the sibling
    convention that an unset extra is omitted from the forwarded ``generate()``
    kwargs, never forwarded as ``""``/``None``. This is a deliberate departure
    from the numeric coercers' return contract (they always return a
    forwardable value or raise): **callers must skip a ``None`` result rather
    than assign it** — ``validate_extras`` already skips a ``None`` *raw*
    value via ``.get()`` before ever calling a coercer, but that guard does not
    cover a coercer that itself PRODUCES ``None``, which only ``coerce_instruct``
    does.
    """
    if not isinstance(raw, str):
        # ValueError (not TypeError) is deliberate: validate_extras() catches
        # ValueError uniformly across every coercion failure in this module.
        raise ValueError(f"instruct must be a string, got {raw!r}")  # noqa: TRY004
    stripped = raw.strip()
    if not stripped:
        return None
    if len(stripped) > max_len:
        raise ValueError(
            f"instruct must be at most {max_len} characters, got {len(stripped)} after stripping"
        )
    return stripped


def merge_extras(
    coercers: Mapping[str, Callable[[Any], Any]], extras: Mapping[str, Any] | None
) -> dict[str, Any]:
    """Shared ``open_stream`` filter/coerce loop: walk ``extras`` through the
    backend's own ``coercers`` allowlist (the same dict ``validate_extras``
    walks) and return only the coerced, forwardable values.

    Two independent ``None``-skip guards, for two different reasons:

    - A ``None`` (or absent) *raw* value means the client did not send that
      extra — skipped before the coercer ever runs, same as
      ``validate_extras``.
    - A coercer that itself *returns* ``None`` (today, only
      ``coerce_instruct`` — a valid-but-empty-after-strip string) means "this
      extra ended up unset after validation" — its result is skipped too,
      rather than forwarding ``effective[key] = None`` into ``generate()``.
      This guard is a no-op for the purely-numeric coercers elsewhere
      (``coerce_temperature``/``coerce_top_k``/``coerce_top_p`` never return
      ``None`` — they always return a forwardable value or raise), so sharing
      it here costs those backends nothing.
    """
    effective: dict[str, Any] = {}
    if not extras:
        return effective
    for key, coerce in coercers.items():
        raw = extras.get(key)
        if raw is None:
            continue
        coerced = coerce(raw)
        if coerced is not None:
            effective[key] = coerced
    return effective


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
