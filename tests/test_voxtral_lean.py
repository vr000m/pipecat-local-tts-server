"""Voxtral backend LEAN tests (no mlx) — Phase 5a.

On the lean allow-list. Covers everything provable WITHOUT loading the 4B model:
- backend-unit: ``streaming_interval`` is backend config (NOT an advertised
  extra); the locked ``_STREAMING_INTERVAL`` value; ``streaming:true`` caps;
- the ``voice=None``-OMIT rule + extras filtering/coercion via an ``open_stream``
  spy on a FAKE model (no mlx);
- the extras coercers (pure functions);
- lazy-import / ``make_backend`` / argparse-choice wiring (the dual-wire);
- the bridge ``is_final_chunk=True`` EOF contract (EOF comes from generator
  exhaustion, the flag is advisory) — driven through ``stream_generate``
  directly, the only layer that ever sees the flag.

The mlx-gated synthesis assertions live in ``tests/test_voxtral_backend.py``.
"""

from __future__ import annotations

import asyncio
import struct
import subprocess
import sys
import threading
from pathlib import Path

import pytest

from tts_server.backends import voxtral_tts as V
from tts_server.backends._stream_util import stream_generate

_REPO_ROOT = Path(__file__).resolve().parent.parent


# --- backend-unit: capabilities / locked streaming_interval -------------------


def test_streaming_interval_not_in_advertised_extras():
    """``streaming_interval`` is per-backend CONFIG, never a client knob — it
    MUST NOT appear in ``capabilities()["extras"]`` (advertising it would let a
    client inflate TTFB). The advertised set is exactly the verified effective
    sampling tunables."""
    backend = V.VoxtralBackend()
    extras = backend.capabilities()["extras"]
    assert "streaming_interval" not in extras
    assert extras == ["temperature", "top_k", "top_p"]


def test_streaming_interval_locked_value():
    """The cadence default is LOCKED to the single measured value (## Findings →
    Phase 5a). Equality to that one value, never a range — if a re-measurement
    moves it, this test moves with the Findings, not a band."""
    assert V._STREAMING_INTERVAL == 0.3


def test_capabilities_streaming_true():
    """Voxtral is a genuine sub-segment streamer (native stream/streaming_interval)."""
    assert V.VoxtralBackend().capabilities()["streaming"] is True


def test_capabilities_shape_lean():
    """The static parts of capabilities() are available pre-start (rate/voices
    are not — those need the model). Languages/voice_count are 0/empty until
    ``start()`` discovers them; the shape and constant fields are still asserted."""
    caps = V.VoxtralBackend().capabilities()
    assert caps["binary_audio"] is False
    assert caps["text_formats"] == ["plain"]
    assert caps["ideal_words"] == 40
    assert caps["max_text_chars"] == 2000


# --- voice=None omit + extras filtering via an open_stream spy (fake model) ----


class _SpyModel:
    """A fake mlx model: ``generate`` records the kwargs it is called with and
    returns an empty generator, so the backend's ``_gen_factory`` can be driven
    WITHOUT mlx. ``sample_rate`` is set so the backend looks loaded."""

    sample_rate = 24000

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def generate(self, text, **kwargs):
        self.calls.append({"text": text, **kwargs})
        return iter(())


async def _gen_kwargs(*, voice, extras):
    """Open a stream on a spy-model backend and return the kwargs that
    ``_gen_factory`` would pass to ``model.generate`` (positional text excluded)."""
    backend = V.VoxtralBackend()
    spy = _SpyModel()
    backend._loaded_model = spy  # bypass start(); no mlx needed
    stream = await backend.open_stream(voice=voice, language=None, extras=extras)
    stream._text = "hello world"
    list(stream._gen_factory())  # drive the (empty) generator to record the call
    assert len(spy.calls) == 1
    return spy.calls[0]


@pytest.mark.asyncio
async def test_voice_omitted_when_none():
    """The voice=None-OMIT rule (Kokoro's speed-omit applied to voice): when the
    resolved voice is None, the ``voice`` kwarg is OMITTED so the model's own
    default (``casual_male``) stands rather than forwarding ``voice=None``."""
    call = await _gen_kwargs(voice=None, extras=None)
    assert "voice" not in call
    # streaming is always driven; the locked interval is always passed.
    assert call["stream"] is True
    assert call["streaming_interval"] == V._STREAMING_INTERVAL


@pytest.mark.asyncio
async def test_voice_forwarded_when_set():
    call = await _gen_kwargs(voice="fr_male", extras=None)
    assert call["voice"] == "fr_male"


@pytest.mark.asyncio
async def test_extras_filtered_to_advertised_and_coerced():
    """Only advertised extras survive to ``generate()``; an unknown key (here a
    ``ref_audio`` lookalike) is DROPPED by the backend's own last-defense filter,
    and advertised values are coerced (clamped)."""
    call = await _gen_kwargs(
        voice=None,
        extras={"temperature": 0.5, "top_k": 30, "top_p": 0.9, "ref_audio": "x.wav"},
    )
    assert call["temperature"] == 0.5
    assert call["top_k"] == 30
    assert call["top_p"] == 0.9
    assert "ref_audio" not in call


@pytest.mark.asyncio
async def test_unset_extras_are_omitted_not_none():
    """Extras not supplied are OMITTED (not forwarded as None) so the model's own
    sampling defaults stand — same discipline as the voice omit."""
    call = await _gen_kwargs(voice=None, extras={"temperature": 0.7})
    assert call["temperature"] == 0.7
    assert "top_k" not in call
    assert "top_p" not in call


# --- extras coercers (pure functions) -----------------------------------------


def test_coerce_temperature_clamps_and_rejects():
    assert V._coerce_temperature(0.8) == 0.8
    assert V._coerce_temperature("1.0") == 1.0
    assert V._coerce_temperature(-1) == V._TEMPERATURE_MIN
    assert V._coerce_temperature(99) == V._TEMPERATURE_MAX
    for bad in (float("nan"), float("inf"), "hot"):
        with pytest.raises(ValueError):
            V._coerce_temperature(bad)


def test_coerce_top_k_clamps_and_rejects():
    assert V._coerce_top_k(50) == 50
    assert V._coerce_top_k("40") == 40
    assert V._coerce_top_k(0) == V._TOP_K_MIN
    assert V._coerce_top_k(10_000) == V._TOP_K_MAX
    # integral floats are accepted; non-integral floats are rejected (not
    # silently truncated 2.9 -> 2).
    assert V._coerce_top_k(50.0) == 50
    with pytest.raises(ValueError):
        V._coerce_top_k(2.9)
    # bool is an int subclass but is not a valid top_k.
    with pytest.raises(ValueError):
        V._coerce_top_k(True)
    with pytest.raises(ValueError):
        V._coerce_top_k("lots")


def test_coerce_top_p_range():
    assert V._coerce_top_p(0.95) == 0.95
    assert V._coerce_top_p(2.0) == V._TOP_P_MAX  # clamp down to 1.0
    for bad in (0, -0.5, float("nan"), float("inf"), "p"):
        with pytest.raises(ValueError):
            V._coerce_top_p(bad)


def test_validate_extras_reports_bad_value():
    backend = V.VoxtralBackend()
    assert backend.validate_extras({}) is None
    assert backend.validate_extras({"temperature": 0.5}) is None
    msg = backend.validate_extras({"top_p": 0})
    assert msg and "top_p" in msg


# --- lazy-import / dual-wire (make_backend + argparse choices) -----------------


def _assert_lean(body: str) -> None:
    """Run ``body`` in a FRESH interpreter; fail if it pulled in ``mlx_audio``
    (mirrors test_kokoro_lazy_import — a clean module table makes the 'absent'
    assertion independent of test order, since mlx IS installed in the full env)."""
    prog = (
        "import sys\n"
        + body
        + "\nbad = sorted(n for n in sys.modules if n=='mlx_audio' or n.startswith('mlx_audio.'))\n"
        "import sys as _s\n"
        "_s.exit(1) if bad else None\n"
    )
    result = subprocess.run(
        [sys.executable, "-c", prog], cwd=_REPO_ROOT, capture_output=True, text=True
    )
    assert result.returncode == 0, f"mlx_audio leaked or import failed:\n{result.stderr}"


def test_import_voxtral_module_does_not_pull_mlx():
    _assert_lean("import importlib; importlib.import_module('tts_server.backends.voxtral_tts')")


def test_make_backend_resolves_voxtral_without_mlx():
    _assert_lean(
        "from tts_server.backends import make_backend\n"
        "b = make_backend('voxtral_tts')\n"
        "assert b.backend_name == 'voxtral_tts', b.backend_name\n"
        "assert b.sample_rate == 0, b.sample_rate\n"  # not started -> rate unknown
    )


def test_default_model_constant_importable_lean():
    _assert_lean(
        "from tts_server.backends.voxtral_tts import DEFAULT_VOXTRAL_MODEL\n"
        "assert isinstance(DEFAULT_VOXTRAL_MODEL, str) and DEFAULT_VOXTRAL_MODEL\n"
    )


def test_voxtral_is_accepted_backend_choice():
    """The argparse ``--backend`` choices tuple half of the dual-wire: a passing
    ``make_backend`` is not enough — argparse must also accept the name, else
    ``--backend voxtral_tts`` dies before the resolver. Parse real argv."""
    from tts_server.__main__ import build_parser

    parser = build_parser()
    args = parser.parse_args(["serve", "--backend", "voxtral_tts"])
    assert args.backend == "voxtral_tts"


def test_argparse_rejects_unknown_backend():
    from tts_server.__main__ import build_parser

    parser = build_parser()
    with pytest.raises(SystemExit):
        parser.parse_args(["serve", "--backend", "nope"])


# --- bridge: is_final_chunk=True EOF is advisory; EOF is exhaustion-driven -----


class _FakeResult:
    """A fake GenerationResult: ``.audio`` is a plain float list (the bridge's
    ``_audio_to_pcm`` passes it through) and ``.is_final_chunk`` is carried so we
    can prove the bridge IGNORES it (Voxtral sets it True on the last chunk;
    Kokoro never sets it — EOF must work for both)."""

    def __init__(self, audio, is_final_chunk: bool) -> None:
        self.audio = audio
        self.is_final_chunk = is_final_chunk


@pytest.mark.asyncio
async def test_bridge_eof_from_exhaustion_not_is_final_chunk():
    """Drive ``stream_generate`` directly with three fake results whose LAST
    carries ``is_final_chunk=True``. EOF (end of async iteration) must come from
    generator EXHAUSTION, and ALL three chunks must be delivered first — the flag
    is advisory only. This CANNOT go through ToneBackend: ``AudioEvent`` is
    ``{kind, pcm}`` only, so the model flag never reaches it; the bridge is the
    only layer that sees it."""
    results = [
        _FakeResult([0.0, 0.1, 0.2], is_final_chunk=False),
        _FakeResult([0.3, 0.4, 0.5], is_final_chunk=False),
        _FakeResult([0.6, 0.7, 0.8], is_final_chunk=True),  # advisory flag set early-ish
    ]

    def gen_factory():
        return iter(results)

    chunks: list[bytes] = []
    async for pcm in stream_generate(
        gen_factory,
        loop=asyncio.get_running_loop(),
        metal_lock=threading.Lock(),
        cancel=threading.Event(),
        maxsize=8,
    ):
        chunks.append(pcm)

    # All three chunks delivered (the flag did not short-circuit the drain), and
    # iteration ended on exhaustion (the async-for completed normally).
    assert len(chunks) == 3
    # Each chunk is int16-LE PCM of its 3 samples (6 bytes); non-empty, aligned.
    for c in chunks:
        assert len(c) == 6 and len(c) % 2 == 0
    # Sanity: first sample of the first chunk is 0.
    assert struct.unpack("<h", chunks[0][:2])[0] == 0
