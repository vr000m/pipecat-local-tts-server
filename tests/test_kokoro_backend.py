"""Kokoro backend tests (MLX-GATED -- Apple Silicon + cached weights required).

These are NOT on the lean allow-list. They are skipped when ``mlx_audio`` is
unavailable via a module-top ``pytest.importorskip`` -- a belt-and-suspenders
gate so the full job (and any accidental local run) never explodes at collection
on a lean base. On the lean CI job they are simply never invoked (not on the
allow-list), so the skip marker is the safety net, not the primary mechanism.

Run on this machine with:

    uv run --extra client --extra kokoro pytest tests/test_kokoro_backend.py -q

Coverage (Phase 2 checklist / R3 / R7):
- synthesize "GOAL!" -> non-empty, int16-aligned PCM16 at the advertised rate;
- pre-warmup rate invariant: ``sample_rate`` == 24000 after ``start()`` with no
  ``generate()`` driven by the test (read from ``model.sample_rate``);
- ``capabilities()["extras"] == ["speed"]`` exactly; unsupported kwargs excluded;
  voice/language shape (voice_count > 0, languages non-empty incl. "en");
- language mapping: ISO -> Kokoro lang_code BEFORE generate() (e.g. ja->j, es->e);
- long single-segment cancellation probe: cancel mid-synthesis, assert NO deltas
  after cancel, and RECORD the measured no-more-delta latency (not hard-bounded).
"""

from __future__ import annotations

import asyncio
import time

import pytest

# Belt-and-suspenders gate: skip the whole module if the heavy extra is absent.
# (On lean CI this file is simply not on the allow-list, so it is never invoked.)
pytest.importorskip("mlx_audio")

from tts_server.backend import AudioEvent  # noqa: E402
from tts_server.backends.kokoro import (  # noqa: E402
    _ISO_TO_LANG_CODE,
    KokoroBackend,
)

pytestmark = pytest.mark.asyncio

ADVERTISED_RATE = 24000


# A single unbroken line (no "\n") so Kokoro produces exactly ONE segment -- the
# worst case for cancel promptness. Kokoro yields a single segment's audio only
# at the END of generate(), so the bridge's cancel flag (checked at the
# ``for result in gen`` boundary) cannot interrupt a single-segment synth until
# generate() completes. Measured on this machine: a one-sentence segment takes
# ~20-25 s and yields ONE delta at the end. We keep the phrase to ~one sentence
# so the test runs in well under a minute while still exercising the worst-case
# (single-segment) cancel path. A much longer single segment also trips an
# mlx-audio 0.4.4 internal broadcast_shapes bug (~542 k samples), unrelated to
# cancellation -- another reason to keep the probe to a single sentence.
_LONG_SINGLE_SEGMENT = "The quick brown fox jumps over the lazy dog near the river."


@pytest.fixture(scope="module")
async def started_backend():
    """A started Kokoro backend shared across the module (load is expensive)."""
    backend = KokoroBackend()
    await backend.start()
    try:
        yield backend
    finally:
        await backend.close()


async def _drain(stream) -> bytes:
    """Collect all PCM bytes from a stream's events until ``completed``."""
    chunks: list[bytes] = []
    async for ev in stream.events():
        assert isinstance(ev, AudioEvent)
        if ev.kind == "delta":
            chunks.append(ev.pcm)
        elif ev.kind == "completed":
            break
    return b"".join(chunks)


# ---------------------------------------------------------------------------
# Pre-warmup rate invariant (R3) -- assert WITHOUT this test driving generate().
# ---------------------------------------------------------------------------


async def test_rate_populated_pre_warmup_from_model_sample_rate():
    """``sample_rate`` is read from ``model.sample_rate`` immediately after
    ``load()`` -- the test drives no ``generate()`` itself. Asserts it equals
    24000 (R3's pre-warmup rate-discovery invariant)."""
    backend = KokoroBackend()
    assert backend.sample_rate == 0  # not started yet
    await backend.start()
    try:
        # The rate is populated by start() from the loaded model's config
        # property -- the test has not called generate(). (start()'s internal
        # best-effort warmup is decoupled from rate discovery per R3; the rate
        # was set before warmup ran and would hold even if warmup were skipped.)
        assert backend.sample_rate == ADVERTISED_RATE
        # And it is the model's own config property, readable pre-synth.
        assert int(backend._loaded_model.sample_rate) == ADVERTISED_RATE
    finally:
        await backend.close()


# ---------------------------------------------------------------------------
# Synthesis: "GOAL!" -> non-empty PCM16 at the advertised rate.
# ---------------------------------------------------------------------------


async def test_synthesize_goal_yields_nonempty_pcm16(started_backend):
    backend = started_backend
    assert backend.sample_rate == ADVERTISED_RATE
    stream = await backend.open_stream(language="en")
    await stream.feed("GOAL!")
    await stream.end()
    pcm = await _drain(stream)
    assert pcm, "expected non-empty PCM16 for 'GOAL!'"
    # int16-aligned bytes (PCM16 mono).
    assert len(pcm) % 2 == 0
    # Sanity: at 24 kHz mono int16, even a tiny utterance is many samples.
    n_samples = len(pcm) // 2
    assert n_samples > 0


# ---------------------------------------------------------------------------
# Regression: the upstream mlx-audio SineGen length bug.
#
# Without ``_apply_kokoro_vocoder_fix`` (applied in ``start()``), this phrase
# fails inside mlx-audio's Kokoro vocoder with ``[broadcast_shapes] Shapes
# (1,T,1) and (1,T+300,9) cannot be broadcast`` — ``_f02sine``'s interpolate
# round-trip returns one extra upsample hop, so ``sine_waves`` is one hop longer
# than ``uv``/``noise_amp``. "Hello there." (the warmup phrase) is in the failing
# class; "GOAL!" happens to align, which is why the test above is NOT sufficient
# to catch the bug. This test fails fast if the fix regresses or stops applying.
# ---------------------------------------------------------------------------


async def test_synthesize_broadcast_bug_phrase_succeeds(started_backend):
    """A phrase that trips the upstream broadcast_shapes bug WITHOUT the fix must
    synthesize to non-empty PCM WITH it (the fix is applied in start())."""
    backend = started_backend
    stream = await backend.open_stream(language="en")
    await stream.feed("Hello there.")
    await stream.end()
    pcm = await _drain(stream)
    assert pcm, "expected non-empty PCM16 for 'Hello there.' (vocoder fix not applied?)"
    assert len(pcm) % 2 == 0
    assert len(pcm) // 2 > 0


# ---------------------------------------------------------------------------
# capabilities(): extras exact, unsupported kwargs excluded, voice/lang shape.
# ---------------------------------------------------------------------------


async def test_capabilities_extras_exact_and_shape(started_backend):
    caps = started_backend.capabilities()
    # Kokoro's effective extras set ONLY (R7).
    assert caps["extras"] == ["speed"]
    # Unsupported kwargs must NOT be advertised (they are swallowed by **kwargs
    # and ignored, so advertising them would lie to the client).
    for unsupported in ("temperature", "cfg_scale", "ddpm_steps"):
        assert unsupported not in caps["extras"]
    # Voice / language shape.
    assert caps["voice_count"] > 0
    assert caps["languages"], "languages must be non-empty"
    assert "en" in caps["languages"]
    # Non-streaming (no sub-segment streaming) + plain text only.
    assert caps["streaming"] is False
    assert caps["text_formats"] == ["plain"]


# ---------------------------------------------------------------------------
# Language mapping: ISO -> Kokoro lang_code BEFORE generate().
# ---------------------------------------------------------------------------


async def test_language_mapping_before_generate(started_backend):
    """At least one non-default ISO language maps to the expected Kokoro
    single-letter ``lang_code`` -- exercised purely through the mapping path,
    with no ``generate()`` involved."""
    backend = started_backend
    # Direct table (single source of truth for the translation).
    assert _ISO_TO_LANG_CODE["ja"] == "j"
    assert _ISO_TO_LANG_CODE["es"] == "e"
    # The backend's translation method honours the same mapping (and the stream
    # it opens carries the translated lang_code -- still before any generate()).
    assert backend._lang_code_for("ja") == "j"
    assert backend._lang_code_for("es") == "e"
    # Default / unknown ISO degrades to American English ("a").
    assert backend._lang_code_for("en") == "a"
    assert backend._lang_code_for(None) == "a"
    assert backend._lang_code_for("xx") == "a"
    # open_stream wires the translated code onto the stream before generate runs.
    stream = await backend.open_stream(language="ja")
    assert stream._lang_code == "j"
    await stream.cancel()  # do not actually synthesize


# ---------------------------------------------------------------------------
# Long single-segment cancellation probe: assert no-more-delta after cancel and
# RECORD the measured acknowledgement latency (recorded, not hard-bounded).
# ---------------------------------------------------------------------------


async def test_long_segment_cancel_no_more_delta_and_record_latency(started_backend, capsys):
    """Synthesize a long SINGLE-segment input, cancel during synthesis, assert
    NO further deltas land after cancel, and record the measured no-more-delta
    latency. Per the plan: long-segment cancel latency is RECORDED, not strictly
    bounded -- the hard assertion is only 'no more delta after cancelled'."""
    backend = started_backend
    stream = await backend.open_stream(language="en")
    await stream.feed(_LONG_SINGLE_SEGMENT)
    await stream.end()

    deltas_before_cancel = 0
    deltas_after_cancel = 0
    cancel_requested_at: float | None = None
    last_event_at: float | None = None
    cancel_fired = False

    # Fire cancel shortly after kicking off synthesis -- early enough that the
    # single long segment is still being generated (worst case for promptness).
    async def _cancel_soon():
        nonlocal cancel_requested_at, cancel_fired
        await asyncio.sleep(0.25)
        cancel_requested_at = time.monotonic()
        cancel_fired = True
        await stream.cancel()

    cancel_task = asyncio.create_task(_cancel_soon())

    async for ev in stream.events():
        now = time.monotonic()
        if ev.kind == "completed":
            last_event_at = now
            break
        if not cancel_fired:
            deltas_before_cancel += 1
        else:
            deltas_after_cancel += 1
            last_event_at = now

    await cancel_task

    # HARD assertion: no deltas after the cancel was requested. (The stream gates
    # the terminal/extra events on its external-cancel flag, and the bridge
    # breaks the generator out at the yield boundary.)
    assert deltas_after_cancel == 0, (
        f"expected no response.audio.delta after cancel, saw {deltas_after_cancel}"
    )

    # RECORD the measured no-more-delta / acknowledgement latency. For a long
    # single segment Kokoro yields only at the segment boundary, so this can be
    # large -- the plan documents that as yield-boundary best effort; we record,
    # not bound it. A generous sanity ceiling guards against a true hang.
    if cancel_requested_at is not None and last_event_at is not None:
        measured_ms = (last_event_at - cancel_requested_at) * 1000.0
    else:
        # iteration ended without a post-cancel terminal observation; treat the
        # time from cancel request to loop exit as the measure.
        measured_ms = (
            (time.monotonic() - cancel_requested_at) * 1000.0
            if cancel_requested_at is not None
            else float("nan")
        )

    with capsys.disabled():
        print(
            f"\n[kokoro cancel probe] long-single-segment cancel "
            f"no-more-delta latency = {measured_ms:.1f} ms "
            f"(deltas before cancel={deltas_before_cancel}, after={deltas_after_cancel})"
        )

    # Generous ceiling: NOT the barge-in target. For a single segment cancel can
    # only take effect when generate() completes (the bridge checks the cancel
    # flag at the ``for result in gen`` boundary, and Kokoro yields a single
    # segment only at the end). So this latency tracks the remaining single-
    # segment synth time -- documented as yield-boundary best effort, recorded
    # not strictly bounded. The ceiling is purely a hang guard well above the
    # observed single-sentence synth time (~20-25 s on this machine).
    assert measured_ms < 180_000, (
        f"cancel acknowledgement took {measured_ms:.0f} ms -- looks like a hang"
    )
