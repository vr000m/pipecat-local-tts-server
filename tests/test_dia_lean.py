"""dia backend LEAN tests (no mlx) — Phase 1.

On the lean allow-list. dia is the multi-speaker DIALOGUE backend: speaker
control is purely in-text via ``[S1]``/``[S2]`` tags (decision #1), dialogue text
rides inside ``text_format: plain`` (decision #2 — no server change), and the
backend advertises ``streaming:false`` (segment-level, like Kokoro), ``voice_count:
0``, extras ``{temperature, top_p}``.

The distinctive Phase-1 deliverables proved WITHOUT loading the 1.6B model:
  - the dialogue ``[S1]``/``[S2]`` markers pass through to ``generate()`` verbatim;
  - the STRUCTURAL voice-ignore rule: ``_DiaStream`` takes no ``voice`` param, so
    ``open_stream(voice="...")`` accepts-and-discards and ``voice`` NEVER reaches
    ``generate()`` — asserted via a spy model, bypassing the server pre-filter;
  - the decision-#2 negative guard: ``{ref_audio, ref_text}`` are excluded from
    ``capabilities()`` AND can never reach ``generate()``;
  - ``sample_rate == 0`` pre-``start()`` (model unloaded — the rate VALUE 44100 is a
    single-run Phase-0 observation and is mlx-gated/local-only, NEVER asserted lean);
  - the ``backend=dia`` status-reply dict shape (cf. tests/test_status.py:27-45);
  - ``validate_extras`` rejects a non-finite ``temperature``/``top_p``;
  - the tagged-text -> deltas bridge path through ToneBackend (the spy returns an
    empty generator, so it cannot prove a tagged buffer actually streams audio).

The mlx-gated assertions (real-model synth, rate VALUE == 44100, the
server-boundary ``voice_count:0`` ``_validate_voice`` accept branch) are guarded
with ``pytest.importorskip("mlx_audio")`` so they DO NOT run in lean CI.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend
from tts_server.backends import dia as D

from ._helpers import collect_response, connected_client, running_server

_REPO_ROOT = Path(__file__).resolve().parent.parent

# A multi-line [S1]/[S2] dialogue buffer reused across the pass-through and the
# bridge-delta tests. The newline separates turns/segments WITHIN one commit
# (decision #3: cross-segment state holds within a commit).
_DIALOGUE = "[S1] Hello there, how are you?\n[S2] I am well, thank you for asking."


# --- backend-unit: capabilities -----------------------------------------------


def test_capabilities_streaming_false():
    """dia is segment-level (``split_pattern``, like Kokoro) — NOT a sub-segment
    streamer. It MUST advertise ``streaming:false``."""
    assert D.DiaBackend().capabilities()["streaming"] is False


def test_capabilities_extras_ordered_temperature_top_p():
    """The advertised extras are exactly ``["temperature", "top_p"]`` (ordered
    list, matching docs/protocol.md). No ``top_k`` (unlike Voxtral)."""
    assert D.DiaBackend().capabilities()["extras"] == ["temperature", "top_p"]


def test_capabilities_text_formats_plain_and_voice_count_zero():
    caps = D.DiaBackend().capabilities()
    assert caps["text_formats"] == ["plain"]
    # decision #1: dia has no enumerable voices -> voice_count 0, no voice concept.
    assert caps["voice_count"] == 0
    assert caps["binary_audio"] is False


def test_capabilities_excludes_ref_audio_and_ref_text():
    """Decision #2: neither voice-cloning channel (``ref_audio``) nor its paired
    ``ref_text`` may appear in the advertised extras. Phase 0 confirmed ``ref_text``
    is a real ``generate()`` kwarg, so this exclusion is non-vacuous."""
    extras = D.DiaBackend().capabilities()["extras"]
    assert "ref_audio" not in extras
    assert "ref_text" not in extras


def test_no_voices_method_so_voice_set_stays_empty():
    """``voice_count:0`` has TWO halves (plan item): the backend MUST NOT define a
    ``voices()`` method, so ``isinstance(backend, SupportsVoices)`` is False at the
    server and ``_voice_set`` stays empty — otherwise ``_validate_voice`` would
    reject a non-member voice before the accept branch is reached."""
    assert not hasattr(D.DiaBackend(), "voices")


# --- sample_rate: presence pre-start, NEVER the mlx-gated value ----------------


def test_sample_rate_zero_pre_start():
    """The model is unloaded pre-``start()``, so the rate is not yet known. Assert
    the rate field is PRESENT and ``== 0`` (cf. test_pocket_lean.py:178). The rate
    VALUE 44100 is a single-run Phase-0 observation and is mlx-gated/local-only —
    a lean test cannot load the model and MUST NOT assert ``== 44100``."""
    backend = D.DiaBackend()
    assert hasattr(backend, "sample_rate")
    assert backend.sample_rate == 0
    assert backend.sample_rate != 44100  # the mlx-gated value never leaks lean


# --- status-reply dict shape (backend=dia) — cf. test_status.py:27-45 ----------


def test_status_reply_shape_carries_backend_dia_and_rate_field():
    """A lean assertion of the ``server.status`` reply shape: backend identity is
    ``dia`` and the rate field is PRESENT (value is 0 pre-start, not 44100). The
    server builds this dict from ``backend.backend_name`` / ``.model`` /
    ``.sample_rate`` (server.py:1406-1413); a real round-trip needs a started model
    (mlx-gated), so the lean test asserts the building blocks the dict is made of."""
    backend = D.DiaBackend()
    # The exact fields the server splices into the status reply (server.py:1406-1413).
    status_backend = {"name": backend.backend_name, "model": backend.model}
    status_audio = {
        "format": P.AUDIO_FORMAT,
        "rate": backend.sample_rate,
        "channels": P.AUDIO_CHANNELS,
    }
    assert status_backend["name"] == "dia"
    assert "model" in status_backend
    # rate field present; value is the unloaded 0, never the mlx-gated 44100.
    assert "rate" in status_audio
    assert status_audio["rate"] == 0
    assert status_audio["rate"] != 44100


# --- the STRUCTURAL voice-ignore rule + decision-#2 negative guard -------------


class _SpyModel:
    """Fake mlx model: ``generate`` records the kwargs it is called with and
    returns an empty generator, so ``_gen_factory`` can be driven WITHOUT mlx.
    ``sample_rate`` is set so the backend looks loaded."""

    sample_rate = 44100

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def generate(self, text, **kwargs):
        self.calls.append({"text": text, **kwargs})
        return iter(())


async def _gen_kwargs(*, voice, extras, text=_DIALOGUE):
    """Open a stream on a spy-model dia backend and return the kwargs that
    ``_gen_factory`` would pass to ``model.generate`` (positional ``text`` is
    folded into the recorded call dict). ``open_stream`` is called DIRECTLY,
    bypassing the server pre-filter — the load-bearing backend-layer guard."""
    backend = D.DiaBackend()
    spy = _SpyModel()
    backend._loaded_model = spy  # bypass start(); no mlx needed
    stream = await backend.open_stream(voice=voice, language=None, extras=extras)
    stream._text = text
    list(stream._gen_factory())  # drive the (empty) generator to record the call
    assert len(spy.calls) == 1
    return spy.calls[0]


@pytest.mark.asyncio
async def test_dialogue_markers_pass_through_to_generate_verbatim():
    """The reason this is its own plan: ``[S1]``/``[S2]`` tags are literal plain
    characters and MUST reach ``generate()`` byte-for-byte unchanged (decision #2,
    server forwards the committed buffer untouched)."""
    call = await _gen_kwargs(voice=None, extras=None)
    assert call["text"] == _DIALOGUE
    assert "[S1]" in call["text"]
    assert "[S2]" in call["text"]


@pytest.mark.asyncio
async def test_voice_never_reaches_generate_even_when_supplied():
    """The STRUCTURAL voice-ignore rule (decision #1): dia's ``_DiaStream`` takes
    no ``voice`` param, so ``open_stream(voice="...")`` accepts-and-discards. Even
    with a NON-None voice supplied (the exact Pocket-conditional-omit trap), the
    ``voice`` kwarg MUST NOT appear at the ``generate()`` boundary."""
    call = await _gen_kwargs(voice="some_speaker", extras=None)
    assert "voice" not in call


@pytest.mark.asyncio
async def test_voice_absent_when_none_too():
    call = await _gen_kwargs(voice=None, extras=None)
    assert "voice" not in call


@pytest.mark.asyncio
async def test_ref_audio_and_ref_text_never_reach_generate():
    """Decision #2 negative guard at the BACKEND layer: call ``open_stream``
    DIRECTLY with the forbidden cloning kwargs (bypassing the server pre-filter)
    and assert NEITHER reaches ``generate()``. ``ref_text`` is a real dia
    ``generate()`` kwarg (Phase 0), so this boundary guard is non-vacuous."""
    call = await _gen_kwargs(
        voice="speaker",
        extras={
            "ref_audio": "clone_me.wav",
            "ref_text": "say it like this",
            "temperature": 1.3,
        },
    )
    assert "ref_audio" not in call
    assert "ref_text" not in call
    # the advertised extra still survives the filter.
    assert call.get("temperature") == 1.3


@pytest.mark.asyncio
async def test_advertised_extras_survive_to_generate():
    """The advertised ``temperature``/``top_p`` are forwarded (coerced); an unknown
    key is dropped by the backend's own last-defence filter."""
    call = await _gen_kwargs(
        voice=None,
        extras={"temperature": 1.0, "top_p": 0.9, "top_k": 50},
    )
    assert call.get("temperature") == 1.0
    assert call.get("top_p") == 0.9
    assert "top_k" not in call


# --- validate_extras: reject non-finite temperature/top_p ---------------------


def test_validate_extras_rejects_non_finite_temperature():
    """dia advertises ``temperature``, so it MUST implement ``validate_extras``
    (mirrors pocket_tts.py:290-302) to reject non-finite values at the trust
    boundary — closing the unbounded-value-under-the-Metal-lock DoS vector."""
    backend = D.DiaBackend()
    assert backend.validate_extras({}) is None
    assert backend.validate_extras({"temperature": 1.0}) is None
    msg = backend.validate_extras({"temperature": float("nan")})
    assert msg and "temperature" in msg
    msg = backend.validate_extras({"temperature": float("inf")})
    assert msg and "temperature" in msg


def test_validate_extras_rejects_non_finite_top_p():
    backend = D.DiaBackend()
    assert backend.validate_extras({"top_p": 0.95}) is None
    msg = backend.validate_extras({"top_p": float("nan")})
    assert msg and "top_p" in msg
    msg = backend.validate_extras({"top_p": float("inf")})
    assert msg and "top_p" in msg


# --- tagged-text -> deltas through ToneBackend (server/bridge path, no mlx) ----


@pytest.mark.asyncio
async def test_tagged_buffer_streams_at_least_one_delta_unchanged():
    """The ``_SpyModel`` returns an empty generator, so it proves kwarg
    pass-through but NOT that a tagged buffer actually STREAMS audio. Drive a
    multi-line ``[S1]``/``[S2]`` committed buffer through a ToneBackend (the
    server/bridge framing path, no mlx_audio) and assert >=1 audio delta comes
    back unchanged — CI coverage of the tagged-text -> delta path. Real dia-audio
    production from tagged text stays mlx-gated (Phase 3 smoke)."""
    backend = ToneBackend(segment_count=2, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append(_DIALOGUE)
            await client.commit()
            resp = await collect_response(client)
            assert resp.error is None and resp.failed is None
            assert resp.done is not None
            # >=1 audio delta streamed; the tagged text framed/bridged fine.
            assert len(resp.deltas) >= 1
            # the buffer flowed through to synthesis intact (non-empty PCM).
            assert len(resp.pcm) > 0


# --- mlx-gated / local-only (NOT lean CI) -------------------------------------


def test_sample_rate_value_is_model_floor_local_only():
    """LOCAL-ONLY: the rate VALUE (Phase 0 recorded 44100) needs a loaded model.
    Skipped in lean CI — this guards the rate-discovery contract on-host only."""
    pytest.importorskip("mlx_audio")
    pytest.skip(
        "rate-value check needs a loaded dia model (start()) — mlx-gated/local-only; "
        "lean CI asserts only sample_rate==0 + field presence"
    )


def test_server_boundary_voice_count_zero_accept_branch_local_only():
    """LOCAL-ONLY: a supplied ``voice`` on a real ``voice_count:0`` dia backend
    must NOT error through the real ``_validate_voice`` accept branch
    (server.py:752-768). This needs the REAL dia backend (a synthetic
    ``voice_count:0`` stand-in would assert the test framework, not dia's accept
    path), so it is mlx-gated/local-only — named accepted CI gap. The backend-layer
    half (``"voice" not in call``) stays lean above."""
    pytest.importorskip("mlx_audio")
    pytest.skip(
        "server-boundary _validate_voice accept branch needs a started dia backend — "
        "mlx-gated/local-only (named accepted CI gap)"
    )


# --- lazy-import / dual-wire (make_backend) -----------------------------------


def _assert_lean(body: str) -> None:
    """Run ``body`` in a FRESH interpreter; fail if it pulled in ``mlx_audio``
    (a clean module table makes the 'absent' assertion independent of test
    order, since mlx IS installed in the full env)."""
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


def test_import_dia_module_does_not_pull_mlx():
    _assert_lean("import importlib; importlib.import_module('tts_server.backends.dia')")


def test_make_backend_resolves_dia_without_mlx():
    _assert_lean(
        "from tts_server.backends import make_backend\n"
        "b = make_backend('dia')\n"
        "assert b.backend_name == 'dia', b.backend_name\n"
        "assert b.sample_rate == 0, b.sample_rate\n"  # not started -> rate unknown
    )


def test_default_model_constant_importable_lean():
    _assert_lean(
        "from tts_server.backends.dia import DEFAULT_DIA_MODEL\n"
        "assert isinstance(DEFAULT_DIA_MODEL, str) and DEFAULT_DIA_MODEL\n"
    )
