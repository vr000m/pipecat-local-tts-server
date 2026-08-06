"""fish_tts backend tests (MLX-GATED — Apple Silicon + cached weights required).

NOT on the lean allow-list. Skipped when ``mlx_audio`` is unavailable via a
module-top ``pytest.importorskip`` (belt-and-suspenders). Loads
``mlx-community/fish-audio-s2-pro`` (Fish Audio Research License — non-
commercial; see ``## Findings`` Q6) once per module.

Run on this machine with:

    uv run --extra dia pytest tests/test_fish_backend.py -v

(``--extra dia`` supplies mlx-audio 0.4.4 without needing the ``fish_tts``
extra to exist yet — the extra is created in Phase 2; see the plan's Phase 1
test-command correction re: extras-preserving invocation.)

Coverage (Phase 1 checklist, mirrors test_qwen3_backend.py / test_pocket_backend.py
— NOT test_dia_backend.py, which does not exist):
- ``sample_rate`` discovery: read from ``model.sample_rate`` after ``start()``,
  and the server advertises THAT in ``hello.audio.rate``;
- capabilities() shape after start: ``streaming:false``, extras ==
  ``["temperature", "top_k", "top_p", "instruct"]``, ``voice_count:0``;
- segment-level (non-streaming) generation: a plain-prose commit produces
  exactly the ``GenerationResult`` sequence ``generate(stream=False)`` yields,
  drained through the shared bridge, non-empty PCM;
- an ``instruct``-present smoke case: generation succeeds cleanly with a short
  ``instruct`` string supplied (Phase 0 Q4: no-op-safe default, short strings
  generate cleanly);
- no-NaN / no-clipping sanity on a decoded chunk.

Imports ``FishBackend`` DIRECTLY (not via ``make_backend``), so this suite
stays green before the Phase-2 registry branch exists.

Cancel-mid-stream / bridge teardown / ``wait_closed`` slot accounting are
covered by the backend-agnostic ``tests/test_streaming_and_cancel.py`` suite
(session-loop layer) and by the direct ``_FishStream`` spy test in
``tests/test_fish_lean.py`` (backend layer) — not duplicated here.
"""

from __future__ import annotations

import math

import pytest

# Belt-and-suspenders gate: skip the whole module if the heavy extra is absent.
pytest.importorskip("mlx_audio")

from tts_server.backends.fish_tts import FishBackend

from ._helpers import connected_client, running_server

pytestmark = pytest.mark.asyncio

# Kept short — non-streaming Fish is RTF~1.6-1.7 (Phase 0 Q2), so the module
# loads the real model and every test here pays real wall-clock synthesis time.
_SHORT_SENTENCE = "The quick brown fox jumps over the lazy dog."

# A ~24-word sentence, deliberately longer than _SHORT_SENTENCE, for the
# instruct smoke case specifically. Found by an independent conductor-run
# repro (2026-08-06): _SHORT_SENTENCE (10 input tokens -> a
# max(32, 10*12)=120-token per-batch ceiling, per fish_tts.py's
# _check_truncation) combined with `instruct` and the model's DEFAULT
# (non-greedy) sampling occasionally needs slightly more than 120 decode
# steps to reach EOS -- Phase 0's Q4 gate only tested this combination
# under temperature=0.0 (greedy), which is far more token-efficient and
# never hit this. This is real, intermittent mlx-audio 0.4.4 behavior for
# very-short-input + instruct under stochastic sampling, not a bug in the
# tripwire (which correctly detects when mlx-audio's own internal budget
# is exhausted) -- see the plan's Findings for the full analysis. A longer
# sentence gives the same 12x-multiplier formula a proportionally larger
# absolute ceiling, giving real headroom against ordinary sampling
# variance without weakening the tripwire itself.
_INSTRUCT_SMOKE_SENTENCE = (
    "The quick brown fox jumps over the lazy dog near the old wooden fence "
    "by the river, then trots away happily into the evening light."
)


@pytest.fixture(scope="module")
async def started_backend():
    """Load the model once (start() incl. first-run download) and reuse it."""
    backend = FishBackend()
    await backend.start()
    try:
        yield backend
    finally:
        await backend.close()


async def test_sample_rate_from_model_pre_synth(started_backend):
    """The advertised rate is read from ``model.sample_rate`` after load,
    BEFORE any synth — and equals the loaded model's own rate (read from the
    model object here, NOT a backend literal). Phase 0 Q3 recorded 44100 on
    this machine, but the assertion below compares to the live model, not a
    hardcoded constant."""
    model_rate = int(started_backend._loaded_model.sample_rate)
    assert started_backend.sample_rate == model_rate
    assert model_rate > 0


async def test_hello_advertises_model_rate():
    """Own backend (NOT the module fixture): ``running_server`` drives the full
    server lifecycle (start()/close()); sharing the module backend would null
    its ``_loaded_model`` and poison later tests."""
    backend = FishBackend()
    async with running_server(backend) as srv, connected_client(srv) as (_client, hello):
        model_rate = int(backend._loaded_model.sample_rate)
        assert hello["audio"]["rate"] == model_rate
        assert hello["capabilities"]["streaming"] is False


async def test_capabilities_shape_after_start(started_backend):
    caps = started_backend.capabilities()
    assert caps["streaming"] is False
    assert caps["extras"] == ["temperature", "top_k", "top_p", "instruct"]
    assert caps["voice_count"] == 0
    assert caps["text_formats"] == ["plain"]
    assert "ref_audio" not in caps["extras"]
    assert "ref_text" not in caps["extras"]


async def test_segment_level_generation_produces_nonempty_pcm(started_backend):
    """Non-streaming (segment-level) generation: drive the stream's
    ``events()`` directly and assert at least one non-empty ``delta`` AudioEvent
    followed by a ``completed`` EOF — the shared ``_stream_util`` bridge path,
    same as dia, with no server-side change."""
    stream = await started_backend.open_stream(voice=None, language=None, extras=None)
    await stream.feed(_SHORT_SENTENCE)
    await stream.end()
    saw_delta = False
    saw_completed = False
    total_bytes = 0
    async for ev in stream.events():
        if ev.kind == "delta":
            saw_delta = True
            total_bytes += len(ev.pcm)
        elif ev.kind == "completed":
            saw_completed = True
    assert saw_delta, "expected at least one delta AudioEvent"
    assert saw_completed, "expected a completed AudioEvent (EOF)"
    assert total_bytes > 0


async def test_instruct_present_smoke_case(started_backend):
    """A short ``instruct`` string generates cleanly end-to-end through
    ``open_stream``'s extras path (Phase 0 Q4: instruct strings up to 1320
    chars generate without error on this model). Uses
    ``_INSTRUCT_SMOKE_SENTENCE`` (longer than ``_SHORT_SENTENCE``) — see
    that constant's docstring for why."""
    stream = await started_backend.open_stream(
        voice=None,
        language=None,
        extras={"instruct": "speak in a cheerful, upbeat tone"},
    )
    await stream.feed(_INSTRUCT_SMOKE_SENTENCE)
    await stream.end()
    total_bytes = 0
    async for ev in stream.events():
        if ev.kind == "delta":
            total_bytes += len(ev.pcm)
    assert total_bytes > 0


async def test_no_nan_no_clip_on_decoded_chunk(started_backend):
    """no-NaN / no-clipping sanity on a decoded native chunk: the model's float
    audio must contain no NaN/inf and stay within [-1, 1] (peak <= 1.0) so the
    bridge's clip+map does not saturate. Checked on the raw model output (the
    bridge clips, which would HIDE an out-of-range value)."""
    model = started_backend._loaded_model
    saw_chunk = False
    for result in model.generate(_SHORT_SENTENCE, stream=False):
        audio = result.audio
        vals = audio.tolist() if hasattr(audio, "tolist") else list(audio)
        if not vals:
            continue
        saw_chunk = True
        assert all(math.isfinite(v) for v in vals), "decoded chunk has NaN/inf"
        peak = max(abs(v) for v in vals)
        assert peak <= 1.0, f"decoded chunk clips (peak={peak})"
    assert saw_chunk, "no non-empty chunk produced"
