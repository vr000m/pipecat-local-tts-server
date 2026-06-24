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
