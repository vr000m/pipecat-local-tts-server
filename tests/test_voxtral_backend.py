"""Voxtral backend tests (MLX-GATED — Apple Silicon + cached weights required).

NOT on the lean allow-list. Skipped when ``mlx_audio`` is unavailable via a
module-top ``pytest.importorskip`` (belt-and-suspenders). The model is ~4B bf16
(CC-BY-NC weights, downloaded on first run); these load it once per module.

Run on this machine with:

    uv run --no-sync pytest tests/test_voxtral_backend.py -q
    # (after: uv sync --extra client --extra voxtral_tts)

Coverage (Phase 5a checklist / R1 / R3 / R7):
- ``sample_rate`` discovery: read from ``model.sample_rate`` after ``start()``
  with no synth driven by the test, and the server advertises THAT in
  ``hello.audio.rate`` (asserted EQUAL to the loaded model's rate, not a literal
  — a wrong constant would satisfy both sides);
- capabilities() shape after start: ``streaming:true``, extras ==
  ``[temperature, top_k, top_p]``, voice_count > 0, languages incl. "en";
- sub-segment streaming at the NATIVE boundary: ≥2 native chunks for a SINGLE
  no-newline sentence (the structural difference from Kokoro's one-per-segment);
- no-NaN / no-clipping sanity on a decoded chunk.
"""

from __future__ import annotations


import pytest

# Belt-and-suspenders gate: skip the whole module if the heavy extra is absent.
pytest.importorskip("mlx_audio")

from tts_server.backends.voxtral_tts import VoxtralBackend  # noqa: E402

from ._helpers import connected_client, running_server  # noqa: E402

pytestmark = pytest.mark.asyncio

# A single unbroken line (NO "\n") — the explicit precondition for the native
# ≥2-chunks assertion. With a newline a Kokoro-style multi-segment yield could
# pass falsely and mask a non-streaming regression. Voxtral must yield ≥2
# sub-segment chunks for THIS one sentence purely from stream/streaming_interval.
_NO_NEWLINE_SENTENCE = (
    "The quick brown fox jumps over the lazy dog and then keeps on running for a while."
)


@pytest.fixture(scope="module")
async def started_backend():
    """Load the model once (start() ~70s incl. first-run download) and reuse it."""
    backend = VoxtralBackend()
    await backend.start()
    try:
        yield backend
    finally:
        await backend.close()


async def test_no_newline_precondition():
    """Guard the precondition itself so the ≥2-chunks test can rely on it."""
    assert "\n" not in _NO_NEWLINE_SENTENCE


async def test_sample_rate_from_model_pre_synth(started_backend):
    """R1/R3: the advertised rate is read from ``model.sample_rate`` after load,
    BEFORE any synth — and equals the loaded model's own rate (read from the
    model object here, NOT a backend literal, so a wrong constant can't satisfy
    both sides of the equality)."""
    model_rate = int(started_backend._loaded_model.sample_rate)
    assert started_backend.sample_rate == model_rate
    assert model_rate > 0


async def test_hello_advertises_model_rate():
    """The server advertises the backend's discovered rate in hello.audio.rate.

    Uses its OWN backend (NOT the module fixture): ``running_server`` drives the
    full server lifecycle, which calls ``backend.start()`` on start and
    ``backend.close()`` on shutdown — sharing the module backend here would null
    its ``_loaded_model`` and poison later tests."""
    backend = VoxtralBackend()
    async with running_server(backend) as srv:
        async with connected_client(srv) as (_client, hello):
            # The server has started the backend (connect -> load -> hello), so
            # the rate is readable from the loaded model — compare to that, not a
            # literal (a wrong constant would satisfy both sides).
            model_rate = int(backend._loaded_model.sample_rate)
            assert hello["audio"]["rate"] == model_rate
            assert hello["capabilities"]["streaming"] is True


async def test_capabilities_shape_after_start(started_backend):
    caps = started_backend.capabilities()
    assert caps["streaming"] is True
    assert caps["extras"] == ["temperature", "top_k", "top_p"]
    assert "streaming_interval" not in caps["extras"]
    assert caps["voice_count"] > 0
    assert "en" in caps["languages"]


async def test_native_sub_segment_streaming_ge_2_chunks(started_backend):
    """Sub-segment streaming proven at the NATIVE chunk boundary (NOT the wire):
    drive the stream's ``events()`` directly and count ``delta`` AudioEvents —
    each is one native bridge chunk (one ``GenerationResult``), BEFORE the
    server's 20 ms re-chunker. A no-newline sentence MUST yield ≥2 native chunks
    (the structural difference from Kokoro, which yields once per ``\\n+``)."""
    stream = await started_backend.open_stream(voice=None, language=None, extras=None)
    await stream.feed(_NO_NEWLINE_SENTENCE)
    await stream.end()
    native_chunks = 0
    async for ev in stream.events():
        if ev.kind == "delta" and ev.pcm:
            native_chunks += 1
    assert native_chunks >= 2, f"expected >=2 native chunks, got {native_chunks}"


async def test_no_nan_no_clip_on_decoded_chunk(started_backend):
    """no-NaN / no-clipping sanity on a decoded native chunk: the model's float
    audio must contain no NaN/inf and stay within [-1, 1] (peak < 1.0) so the
    R3 clip+map does not saturate. Checked on the raw model output (the honest
    place — the bridge clips, which would HIDE an out-of-range value)."""
    model = started_backend._loaded_model
    import math

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
