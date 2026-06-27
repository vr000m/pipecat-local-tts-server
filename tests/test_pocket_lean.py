"""Pocket backend LEAN tests (no mlx) — Phase 5b.

On the lean allow-list. The distinctive 5b deliverable is the **decision-#2
negative guard** at the BACKEND layer: Pocket's generate() exposes ``ref_audio``
(voice cloning) and ``frames_after_eos`` (undocumented), and this backend must
NEVER forward either. The guard is asserted two ways:
  1. ``capabilities()["extras"]`` excludes both keys;
  2. ``open_stream(extras={ref_audio, frames_after_eos, ...})`` called DIRECTLY
     (bypassing the server's pre-filter) drops both — spied on a fake model.
The second is the real "cannot reach generate()" invariant, robust to a future
unfiltered ``**extras`` refactor (a server-level e2e test proves nothing — the
server drops unadvertised keys before the backend).

Plus the same backend-unit / voice-omit / coercer / lazy-import coverage as
voxtral. The mlx-gated synthesis assertions live in tests/test_pocket_backend.py.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from tts_server.backends import pocket_tts as PK

_REPO_ROOT = Path(__file__).resolve().parent.parent


# --- backend-unit: capabilities / locked streaming_interval -------------------


def test_streaming_interval_not_in_advertised_extras():
    extras = PK.PocketBackend().capabilities()["extras"]
    assert "streaming_interval" not in extras
    assert extras == ["temperature"]  # Pocket's effective set ONLY (no top_k/top_p)


def test_streaming_interval_locked_value():
    """Locked to the single measured value (## Findings → Phase 5b). Equality,
    never a range."""
    assert PK._STREAMING_INTERVAL == 0.3


def test_capabilities_streaming_true():
    assert PK.PocketBackend().capabilities()["streaming"] is True


def test_capabilities_shape_lean():
    caps = PK.PocketBackend().capabilities()
    assert caps["binary_audio"] is False
    assert caps["text_formats"] == ["plain"]
    assert caps["ideal_words"] == 40
    assert caps["max_text_chars"] == 2000


# --- the decision-#2 negative guard (ref_audio + frames_after_eos) ------------


def test_capabilities_excludes_ref_audio_and_frames_after_eos():
    """Decision #2: the advertised extras must NOT include the cloning channel
    (``ref_audio``) or the undocumented ``frames_after_eos``."""
    extras = PK.PocketBackend().capabilities()["extras"]
    assert "ref_audio" not in extras
    assert "frames_after_eos" not in extras


class _SpyModel:
    """Fake mlx model: ``generate`` records kwargs, returns an empty generator."""

    sample_rate = 24000

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def generate(self, text, **kwargs):
        self.calls.append({"text": text, **kwargs})
        return iter(())


async def _gen_kwargs(*, voice, extras):
    backend = PK.PocketBackend()
    spy = _SpyModel()
    backend._loaded_model = spy
    stream = await backend.open_stream(voice=voice, language=None, extras=extras)
    stream._text = "hello world"
    list(stream._gen_factory())
    assert len(spy.calls) == 1
    return spy.calls[0]


@pytest.mark.asyncio
async def test_ref_audio_and_frames_after_eos_never_reach_generate():
    """The load-bearing backend-layer guard: call open_stream DIRECTLY with the
    forbidden kwargs (bypassing the server pre-filter) and assert neither reaches
    generate(). Only the advertised ``temperature`` survives."""
    call = await _gen_kwargs(
        voice="alba",
        extras={
            "ref_audio": "clone_me.wav",
            "frames_after_eos": 10,
            "temperature": 0.6,
            "top_k": 50,  # not a Pocket param either — also dropped
        },
    )
    assert "ref_audio" not in call
    assert "frames_after_eos" not in call
    assert "top_k" not in call
    assert call["temperature"] == 0.6
    assert call["voice"] == "alba"
    assert call["stream"] is True
    assert call["streaming_interval"] == PK._STREAMING_INTERVAL


@pytest.mark.asyncio
async def test_voice_omitted_when_none():
    call = await _gen_kwargs(voice=None, extras=None)
    assert "voice" not in call  # model default (None) stands
    assert call["stream"] is True


@pytest.mark.asyncio
async def test_unset_temperature_omitted():
    call = await _gen_kwargs(voice=None, extras={})
    assert "temperature" not in call  # model default stands


# --- coercer + validate_extras ------------------------------------------------


def test_coerce_temperature_clamps_and_rejects():
    assert PK._coerce_temperature(0.8) == 0.8
    assert PK._coerce_temperature("1.0") == 1.0
    assert PK._coerce_temperature(-1) == PK._TEMPERATURE_MIN
    assert PK._coerce_temperature(99) == PK._TEMPERATURE_MAX
    for bad in (float("nan"), float("inf"), "hot"):
        with pytest.raises(ValueError):
            PK._coerce_temperature(bad)


def test_validate_extras_reports_bad_value():
    backend = PK.PocketBackend()
    assert backend.validate_extras({}) is None
    assert backend.validate_extras({"temperature": 0.5}) is None
    msg = backend.validate_extras({"temperature": float("nan")})
    assert msg and "temperature" in msg
    # ref_audio is not an advertised key, so validate_extras ignores it (the
    # server drops it; the backend filter in open_stream is the real guard).
    assert backend.validate_extras({"ref_audio": "x"}) is None


# --- lazy-import / dual-wire --------------------------------------------------


def _assert_lean(body: str) -> None:
    prog = (
        "import sys\n"
        + body
        + "\nbad = sorted(n for n in sys.modules if n=='mlx_audio' or n.startswith('mlx_audio.'))\n"
        "sys.exit(1) if bad else None\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", prog], cwd=_REPO_ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, f"mlx_audio leaked or import failed:\n{result.stderr}"


def test_import_pocket_module_does_not_pull_mlx():
    _assert_lean("import importlib; importlib.import_module('tts_server.backends.pocket_tts')")


def test_make_backend_resolves_pocket_without_mlx():
    _assert_lean(
        "from tts_server.backends import make_backend\n"
        "b = make_backend('pocket_tts')\n"
        "assert b.backend_name == 'pocket_tts', b.backend_name\n"
        "assert b.sample_rate == 0, b.sample_rate\n"
    )


def test_default_model_constant_importable_lean():
    _assert_lean(
        "from tts_server.backends.pocket_tts import DEFAULT_POCKET_MODEL\n"
        "assert isinstance(DEFAULT_POCKET_MODEL, str) and DEFAULT_POCKET_MODEL\n"
    )


def test_pocket_is_accepted_backend_choice():
    from tts_server.__main__ import build_parser

    args = build_parser().parse_args(["serve", "--backend", "pocket_tts"])
    assert args.backend == "pocket_tts"
