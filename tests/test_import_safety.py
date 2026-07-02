"""Lean-base import-safety for ``tts_server`` (Phase 0).

The lean install pins **only** ``websockets`` — no ``mlx_audio``, no ``numpy``.
Heavy model deps live behind the ``kokoro`` extra and must be lazy-imported by
the backends, never pulled in at package/module import time. ``numpy`` is a
dev-only dependency (verification scripts), so runtime package code must not
drag it in either.

This test enforces that lean-base invariant: importing the package and every
public submodule must succeed and must NOT populate ``sys.modules`` with
``mlx_audio`` or ``numpy``. It does NOT construct ``ToneBackend`` — that backend
first exists in Phase 1; Phase 0 asserts import-safety only.
"""

from __future__ import annotations

import importlib

import pytest

from ._helpers import lean_import_offenders


# Every public module that must import cleanly on the lean base. ``backends`` is
# the package; ``backends._stream_util`` ships as a stdlib-only stub in Phase 0.
_TTS_MODULES = [
    "tts_server",
    "tts_server.protocol",
    "tts_server.backend",
    "tts_server.client",
    "tts_server.server",
    "tts_server.env",
    "tts_server.__main__",
    "tts_server.backends",
    "tts_server.backends._stream_util",
    # dia.py must import with only the lean base — ``mlx_audio`` lazy (Phase 1).
    # Listed explicitly because ``_TTS_MODULES`` imports submodules, not just the
    # ``backends`` package, so the no-mlx-at-module-load invariant covers dia.py
    # from the commit that introduces it (review 2026-06-30, moved from Phase 2).
    "tts_server.backends.dia",
]

# Top-level package names that must NEVER appear in ``sys.modules`` as a side
# effect of importing the lean base. Submodules (e.g. ``numpy.linalg``) imply
# the parent loaded, so checking the roots is sufficient.
_FORBIDDEN_AT_IMPORT = ("mlx_audio", "numpy")


def test_import_tts_server_succeeds():
    """The package root imports on the lean base (no mlx, no numpy)."""
    import tts_server  # noqa: F401


@pytest.mark.parametrize("module_name", _TTS_MODULES)
def test_public_module_imports(module_name):
    """Each public submodule imports cleanly with only the lean base installed."""
    assert importlib.import_module(module_name) is not None


@pytest.mark.parametrize("forbidden", _FORBIDDEN_AT_IMPORT)
def test_lean_base_does_not_pull_heavy_dep(forbidden):
    """Importing the package + every submodule must not load ``mlx_audio``/``numpy``.

    Guards the lean-base invariant: a wrong import (e.g. a non-lazy
    ``import mlx_audio`` at module scope, or ``ToneBackend``/the pcm16 converter
    reaching for ``numpy``) would surface here as the forbidden root appearing
    in ``sys.modules`` after import.
    """
    setup = "import importlib\n" + "\n".join(
        f"importlib.import_module({m!r})" for m in _TTS_MODULES
    )
    offenders = lean_import_offenders(setup, forbidden=(forbidden,))
    assert not offenders, (
        f"lean base must not import {forbidden!r}; found in sys.modules: {offenders}"
    )


# ---------------------------------------------------------------------------
# Phase 1: ToneBackend construction with no mlx present (moved here from the
# Phase-0 import-safety bullet -- ToneBackend first exists in Phase 1).
# ---------------------------------------------------------------------------


def test_tone_backend_constructs_without_mlx():
    """Constructing ToneBackend must not pull mlx_audio or numpy (lean CI)."""
    from tts_server.backend import ToneBackend

    backend = ToneBackend()
    assert backend.backend_name == "tone"
    assert backend.model is None
    assert backend.sample_rate == 24000
    caps = backend.capabilities()
    assert caps["text_formats"] == ["plain"]
    # Construction did not drag a heavy dep into sys.modules. This invariant is
    # process-global, so verify it in a fresh interpreter -- an in-process
    # ``sys.modules`` check is contaminated once another test imports a heavy dep.
    offenders = lean_import_offenders(
        "from tts_server.backend import ToneBackend\nb = ToneBackend()\nb.capabilities()",
        forbidden=_FORBIDDEN_AT_IMPORT,
    )
    assert not offenders, f"constructing ToneBackend must not import a heavy dep; found {offenders}"
