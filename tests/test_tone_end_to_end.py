"""Tone end-to-end synthesis, seq monotonicity, rate exactness, and the 20 ms
re-chunker (all lean CI on ToneBackend, no mlx).

Covers:
- connect -> hello -> append -> commit -> delta(s) -> done; PCM reassembled by seq.
- seq starts at 0, +1 with no gaps across a multi-segment utterance, resets per
  new response_id.
- every delta frame's implied rate matches hello.audio.rate and is constant.
- 20 ms re-chunker uniform framing from single-chunk and multi-chunk backends,
  with the short-tail policy (last frame may be short, no padding, duration_ms
  from the original sample count).
- EOF without is_final_chunk (ToneBackend never sets the flag; done fires on
  generator exhaustion).
"""

from __future__ import annotations

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import (
    collect_response,
    connected_client,
    running_server,
    synthesize_once,
)

pytestmark = pytest.mark.asyncio


def _bytes_per_frame(rate: int) -> int:
    return int(rate * P.FRAME_DURATION_MS / 1000) * P.AUDIO_SAMPLE_WIDTH_BYTES


# --- end to end -------------------------------------------------------------


async def test_tone_end_to_end_reassembles_pcm():
    rate = 24000
    # 3 segments * 100 ms; no delay so the test is fast. 100 ms is a clean
    # multiple of 20 ms, so every frame is full.
    backend = ToneBackend(sample_rate=rate, segment_count=3, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            assert hello["audio"]["rate"] == rate
            resp = await synthesize_once(client, "hello world")
            assert resp.done is not None
            assert resp.response_id is not None
            assert resp.deltas, "expected at least one audio delta"
            # 300 ms total of audio = 300 ms / 20 ms = 15 frames.
            expected_samples = 3 * int(rate * 100 / 1000)
            assert len(resp.pcm) == expected_samples * P.AUDIO_SAMPLE_WIDTH_BYTES
            # done.duration_ms from the original sample count.
            assert resp.done["duration_ms"] == int(expected_samples * 1000 / rate)


async def test_seq_starts_at_zero_increments_no_gaps():
    backend = ToneBackend(segment_count=3, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            resp = await synthesize_once(client, "abc")
            assert resp.seqs == list(range(len(resp.seqs)))
            assert resp.seqs[0] == 0


async def test_seq_resets_per_new_response_id():
    backend = ToneBackend(segment_count=2, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            first = await synthesize_once(client, "one")
            second = await synthesize_once(client, "two")
            assert first.response_id != second.response_id
            assert first.seqs[0] == 0
            assert second.seqs[0] == 0
            assert second.seqs == list(range(len(second.seqs)))


# --- rate exactness ---------------------------------------------------------


@pytest.mark.parametrize("rate", [16000, 22050, 24000])
async def test_rate_exactness_across_multi_segment(rate: int):
    """Every delta frame's implied rate matches hello.audio.rate and is constant.

    For a fixed-rate backend, "implied rate" reduces to: every full frame is
    exactly 20 ms worth of samples at the advertised rate (so reassembled by the
    client at that rate, playback is at the right speed/pitch).
    """
    backend = ToneBackend(sample_rate=rate, segment_count=3, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            assert hello["audio"]["rate"] == rate
            resp = await synthesize_once(client, "x")
            bpf = _bytes_per_frame(rate)
            lengths = resp.frame_byte_lengths
            # Every frame except possibly the last is exactly one 20 ms frame.
            for ln in lengths[:-1]:
                assert ln == bpf
            assert lengths[-1] <= bpf
            # Constant: total reassembled samples imply the advertised rate over
            # the reported duration.
            total_samples = len(resp.pcm) // P.AUDIO_SAMPLE_WIDTH_BYTES
            assert resp.done["duration_ms"] == int(total_samples * 1000 / rate)


# --- 20 ms re-chunker -------------------------------------------------------


async def test_rechunker_uniform_frames_single_chunk_backend():
    """A single-chunk (one segment) backend still gets sliced into 20 ms frames."""
    rate = 24000
    backend = ToneBackend(sample_rate=rate, segment_count=1, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            resp = await synthesize_once(client, "single")
            bpf = _bytes_per_frame(rate)
            # 100 ms / 20 ms = 5 full frames, no short tail.
            assert resp.frame_byte_lengths == [bpf] * 5


async def test_rechunker_uniform_frames_multi_chunk_backend():
    """A multi-chunk (streaming) backend produces the same uniform framing."""
    rate = 24000
    backend = ToneBackend(sample_rate=rate, segment_count=4, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            resp = await synthesize_once(client, "multi")
            bpf = _bytes_per_frame(rate)
            assert resp.frame_byte_lengths == [bpf] * 20  # 400 ms / 20 ms


async def test_rechunker_short_tail_no_padding():
    """A total PCM length that is NOT a multiple of 20 ms: every frame except the
    last is exactly 20 ms, the last MAY be short, NO silence padding, and
    duration_ms equals the original sample count (not frames * 20 ms)."""
    rate = 24000
    # 50 ms per segment, 1 segment -> 50 ms total. 50 ms = 20 + 20 + 10.
    backend = ToneBackend(sample_rate=rate, segment_count=1, segment_ms=50, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            resp = await synthesize_once(client, "tail")
            bpf = _bytes_per_frame(rate)
            lengths = resp.frame_byte_lengths
            # All but the last are full 20 ms frames.
            assert all(ln == bpf for ln in lengths[:-1])
            # The last is short (50 ms is not a multiple of 20 ms).
            assert 0 < lengths[-1] < bpf
            # NO silence padding: total emitted bytes == original sample count.
            original_samples = int(rate * 50 / 1000)
            assert len(resp.pcm) == original_samples * P.AUDIO_SAMPLE_WIDTH_BYTES
            # duration_ms from the original sample count, NOT frames * 20 ms.
            assert resp.done["duration_ms"] == int(original_samples * 1000 / rate)
            # sanity: frames * 20 ms would be a different (larger) number.
            assert resp.done["duration_ms"] != len(lengths) * P.FRAME_DURATION_MS


async def test_rechunker_reframes_full_response_not_per_segment():
    """Segments whose length is NOT a multiple of 20 ms must not each emit a short
    frame mid-response -- only the response's LAST frame may be short.

    Two 30 ms segments = 60 ms total = 3 full 20 ms frames, even though each
    30 ms segment alone is 20 + 10 (a per-segment chunker would emit a short
    frame after the first segment)."""
    rate = 24000
    backend = ToneBackend(sample_rate=rate, segment_count=2, segment_ms=30, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            resp = await synthesize_once(client, "carry")
            bpf = _bytes_per_frame(rate)
            # 60 ms / 20 ms = exactly 3 full frames, no short tail.
            assert resp.frame_byte_lengths == [bpf] * 3


# --- EOF without is_final_chunk --------------------------------------------


async def test_done_fires_on_generator_exhaustion_without_final_flag():
    """ToneBackend never sets an is_final_chunk flag (Kokoro shape). done must
    still fire on generator exhaustion."""
    backend = ToneBackend(segment_count=3, segment_ms=100, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("eof check")
            await client.commit()
            resp = await collect_response(client)
            assert resp.done is not None
            assert resp.cancelled is None
            assert resp.failed is None
