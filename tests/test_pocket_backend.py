"""Pocket backend tests (MLX-GATED — Apple Silicon + cached weights required).

NOT on the lean allow-list. Skipped when ``mlx_audio`` is unavailable. Loads
``mlx-community/pocket-tts`` (CC-BY-4.0) once per module.

Run on this machine with:

    uv run --no-sync pytest tests/test_pocket_backend.py -q
    # (after: uv sync --extra client --extra pocket_tts)

Coverage (Phase 5b checklist / R1 / R3 / R7 / decision #2):
- sample_rate read from model.sample_rate, advertised in hello before synth;
- capabilities() shape: streaming:true, extras == ["temperature"] (no ref_audio /
  frames_after_eos / top_k), voice_count > 0;
- sub-segment streaming at the NATIVE boundary: >=2 native chunks for a single
  no-newline sentence;
- no-NaN / no-clipping sanity on a decoded chunk.
"""

from __future__ import annotations

import math

import pytest

pytest.importorskip("mlx_audio")

from tts_server.backends.pocket_tts import PocketBackend  # noqa: E402

from ._helpers import connected_client, running_server  # noqa: E402

pytestmark = pytest.mark.asyncio

_NO_NEWLINE_SENTENCE = (
    "The quick brown fox jumps over the lazy dog and then keeps on running for a while."
)


@pytest.fixture(scope="module")
async def started_backend():
    backend = PocketBackend()
    await backend.start()
    try:
        yield backend
    finally:
        await backend.close()


async def test_no_newline_precondition():
    assert "\n" not in _NO_NEWLINE_SENTENCE


async def test_sample_rate_from_model_pre_synth(started_backend):
    model_rate = int(started_backend._loaded_model.sample_rate)
    assert started_backend.sample_rate == model_rate
    assert model_rate > 0


async def test_hello_advertises_model_rate():
    """Own backend (not the module fixture) — running_server starts+closes it."""
    backend = PocketBackend()
    async with running_server(backend) as srv:
        async with connected_client(srv) as (_client, hello):
            model_rate = int(backend._loaded_model.sample_rate)
            assert hello["audio"]["rate"] == model_rate
            assert hello["capabilities"]["streaming"] is True


async def test_capabilities_shape_after_start(started_backend):
    caps = started_backend.capabilities()
    assert caps["streaming"] is True
    assert caps["extras"] == ["temperature"]
    assert "ref_audio" not in caps["extras"]
    assert "frames_after_eos" not in caps["extras"]
    assert caps["voice_count"] > 0


async def test_native_sub_segment_streaming_ge_2_chunks(started_backend):
    """>=2 native chunks for a no-newline sentence (counted at the stream's
    events() = native bridge chunks, BEFORE the 20 ms re-chunker)."""
    stream = await started_backend.open_stream(voice=None, language=None, extras=None)
    await stream.feed(_NO_NEWLINE_SENTENCE)
    await stream.end()
    native_chunks = 0
    async for ev in stream.events():
        if ev.kind == "delta" and ev.pcm:
            native_chunks += 1
    assert native_chunks >= 2, f"expected >=2 native chunks, got {native_chunks}"


async def test_no_nan_no_clip_on_decoded_chunk(started_backend):
    """no-NaN / no-clip on the raw model output (the bridge clips, which would
    hide an out-of-range value — so check the model's float audio directly)."""
    model = started_backend._loaded_model
    saw_chunk = False
    for result in model.generate(_NO_NEWLINE_SENTENCE, stream=True, streaming_interval=0.3):
        audio = result.audio
        vals = audio.tolist() if hasattr(audio, "tolist") else list(audio)
        if not vals:
            continue
        saw_chunk = True
        assert all(math.isfinite(v) for v in vals), "decoded chunk has NaN/inf"
        peak = max(abs(v) for v in vals)
        assert peak <= 1.0, f"decoded chunk clips (peak={peak})"
        break
    assert saw_chunk, "no non-empty chunk produced"
