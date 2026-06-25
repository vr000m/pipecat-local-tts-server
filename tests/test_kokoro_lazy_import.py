"""Kokoro lazy-import lean test (no mlx).

The **lean-base invariant** (R3 / R8): importing ``tts_server.backends.kokoro``
and resolving the backend via ``make_backend("kokoro", ...)`` must succeed with
the ``kokoro`` extra absent, and must NOT pull ``mlx_audio`` into the process.
``mlx_audio`` enters only when the backend's ``start()`` runs (the mlx-gated
suite covers that), never at module load or construction.

This file is LEAN (on the lean allow-list): it runs on the lean base where
``mlx_audio`` is not installed, which is what makes the "absent" assertion real.
"""

from __future__ import annotations

import importlib
import sys


def _mlx_offenders() -> list[str]:
    return [name for name in sys.modules if name == "mlx_audio" or name.startswith("mlx_audio.")]


def test_import_kokoro_module_does_not_pull_mlx():
    """Importing the kokoro backend module must not load ``mlx_audio``."""
    importlib.import_module("tts_server.backends.kokoro")
    assert not _mlx_offenders(), (
        f"importing kokoro backend must not import mlx_audio; found {_mlx_offenders()}"
    )


def test_make_backend_resolves_kokoro_without_mlx():
    """``make_backend('kokoro')`` constructs the backend (lazy resolution) without
    pulling ``mlx_audio`` -- start() is NOT called here, so the heavy dep stays
    out of the process."""
    from tts_server.backends import make_backend

    backend = make_backend("kokoro")
    assert backend.backend_name == "kokoro"
    # Constructed but not started: rate is unknown (0) and mlx is still absent.
    assert backend.sample_rate == 0
    assert not _mlx_offenders(), (
        f"resolving/constructing kokoro must not import mlx_audio; found {_mlx_offenders()}"
    )


def test_default_model_constant_importable_lean():
    """The CLI's backend-aware --model default imports the constant from the
    module; that import must also stay lean."""
    from tts_server.backends.kokoro import DEFAULT_KOKORO_MODEL

    assert isinstance(DEFAULT_KOKORO_MODEL, str) and DEFAULT_KOKORO_MODEL
    assert not _mlx_offenders()


def test_make_backend_unknown_name_raises_valueerror():
    """``make_backend`` is a library-level resolver: an unknown name must raise
    ``ValueError`` (not ``SystemExit``), so callers outside the CLI are not
    terminated. The CLI translates this to a clean exit itself."""
    import pytest

    from tts_server.backends import make_backend

    with pytest.raises(ValueError):
        make_backend("nope")


def test_coerce_speed_clamps_and_rejects_non_finite():
    """``speed`` is forwarded to generate() under the Metal lock, so it is
    clamped to a safe range and non-finite/non-numeric values are rejected (a
    DoS guard). Pure function — importable without mlx."""
    import math

    import pytest

    from tts_server.backends.kokoro import _SPEED_MAX, _SPEED_MIN, _coerce_speed

    # In-range values pass through unchanged.
    assert _coerce_speed(1.0) == 1.0
    assert _coerce_speed("1.25") == 1.25
    # Out-of-range finite values clamp to the bounds (no DoS via speed=0/huge).
    assert _coerce_speed(0) == _SPEED_MIN
    assert _coerce_speed(-3) == _SPEED_MIN
    assert _coerce_speed(1000) == _SPEED_MAX
    # Non-finite and non-numeric are rejected outright.
    for bad in (float("nan"), float("inf"), float("-inf")):
        with pytest.raises(ValueError):
            _coerce_speed(bad)
    with pytest.raises(ValueError):
        _coerce_speed("fast")
    assert math.isfinite(_SPEED_MIN) and math.isfinite(_SPEED_MAX)
