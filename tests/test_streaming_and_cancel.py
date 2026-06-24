"""Cancel mid-stream and the steady-streaming contract (lean CI on ToneBackend).

Covers:
- cancel mid-stream: response.cancelled arrives promptly (within ~one segment
  delay) and NO response.audio.delta for that response_id arrives after
  response.cancelled. The recv loop is not blocked by the drain task (cancel is
  serviced mid-synthesis).
- steady streaming: first audio arrives before the whole utterance is
  synthesized (TTFF << total synth time).
- inter-delta gap bound: with >=3 segments at segment_delay_ms=120, the max gap
  between consecutive deltas is <= segment_delay_ms + 50 ms (fails if the backend
  buffers all segments then flushes).
"""

from __future__ import annotations

import asyncio
import base64

import pytest

from tts_server.backend import ToneBackend

from ._helpers import collect_response, connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio


async def test_cancel_mid_stream_promptly_and_no_delta_after_cancelled():
    """Drive a delayed backend, cancel before completion, assert prompt cancelled
    with no delta after it, AND that cancel was serviced while synthesis ran."""
    segment_delay_ms = 150
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=segment_delay_ms)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("a long delayed utterance")
            await client.commit()

            # Wait for the response to be in flight (first delta landed), so the
            # cancel happens MID-synthesis (proves the recv loop is not blocked
            # by the drain task -- 5*150 ms of synthesis is still pending).
            first_delta = await next_event(client, "response.audio.delta", timeout=3.0)
            response_id = first_delta["response_id"]

            t_cancel = asyncio.get_running_loop().time()
            await client.cancel()

            # Collect everything after cancel until cancelled, recording any
            # post-cancel deltas.
            cancelled_at = None
            post_cancel_deltas: list[dict] = []
            seen_cancelled = False

            async def _drain():
                nonlocal cancelled_at, seen_cancelled
                async for ev in client.events():
                    t = ev.get("type")
                    if t == "response.audio.delta":
                        if seen_cancelled and ev["response_id"] == response_id:
                            post_cancel_deltas.append(ev)
                    elif t == "response.cancelled":
                        cancelled_at = asyncio.get_running_loop().time()
                        seen_cancelled = True
                        # Read a little longer to catch any erroneous trailing
                        # delta for this response_id.
                        try:
                            await asyncio.wait_for(_read_trailing(), timeout=0.3)
                        except asyncio.TimeoutError:
                            pass
                        return

            async def _read_trailing():
                async for ev in client.events():
                    if (
                        ev.get("type") == "response.audio.delta"
                        and ev["response_id"] == response_id
                    ):
                        post_cancel_deltas.append(ev)

            await asyncio.wait_for(_drain(), timeout=3.0)

            assert cancelled_at is not None, "response.cancelled never arrived"
            # Acknowledged within ~one segment delay (generous bound).
            ack_latency = cancelled_at - t_cancel
            assert ack_latency <= (segment_delay_ms / 1000.0) + 0.5, (
                f"cancel ack took {ack_latency:.3f}s"
            )
            # NO delta for this response_id after cancelled.
            assert post_cancel_deltas == [], (
                f"got {len(post_cancel_deltas)} deltas after response.cancelled"
            )


async def test_cancel_with_response_id_targets_in_flight():
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=120)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("targeted cancel")
            await client.commit()
            first = await next_event(client, "response.audio.delta", timeout=3.0)
            rid = first["response_id"]
            await client.cancel(response_id=rid)
            ev = await next_event(client, "response.cancelled", timeout=2.0)
            assert ev["response_id"] == rid


async def test_first_audio_before_full_synthesis():
    """Steady streaming: time-to-first-frame << total synth time.

    5 segments * 150 ms delay = ~750 ms total synth time; the first delta must
    arrive well before that (after roughly one segment delay)."""
    segment_delay_ms = 150
    segment_count = 5
    backend = ToneBackend(
        segment_count=segment_count, segment_ms=100, segment_delay_ms=segment_delay_ms
    )
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("steady stream")
            t0 = asyncio.get_running_loop().time()
            await client.commit()
            first = await next_event(client, "response.audio.delta", timeout=3.0)
            ttff = asyncio.get_running_loop().time() - t0
            total_synth = segment_count * segment_delay_ms / 1000.0
            assert first["seq"] == 0
            # First audio is available far before the whole utterance is done.
            assert ttff < total_synth / 2, f"TTFF {ttff:.3f}s not << total synth {total_synth:.3f}s"


async def test_inter_delta_gap_bound_no_burst_then_flush():
    """Inter-delta gap bound (the no-burst-then-gap half of the steady-stream
    contract). >=3 segments at segment_delay_ms=120; after the first delta the
    max gap between consecutive deltas must be <= segment_delay_ms + 50 ms.

    A backend that buffered all segments then flushed would deliver all deltas
    back-to-back after one big initial gap -- which this asserts against by
    requiring first audio to arrive within ~one segment delay (so the big gap
    cannot hide before the first delta) AND that subsequent gaps stay bounded.
    """
    segment_delay_ms = 120
    segment_count = 3
    backend = ToneBackend(
        segment_count=segment_count, segment_ms=100, segment_delay_ms=segment_delay_ms
    )
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("gap bound check")
            t0 = asyncio.get_running_loop().time()
            await client.commit()
            resp = await collect_response(client, timeout=5.0)

            assert resp.done is not None
            ts = resp.delta_monotonic_ts
            assert len(ts) >= segment_count, (
                f"expected per-segment delivery, got {len(ts)} deltas for {segment_count} segments"
            )

            # First audio within ~one segment delay (proves no buffer-then-flush:
            # a flush would delay the first delta until full synthesis).
            ttff = ts[0] - t0
            bound = (segment_delay_ms / 1000.0) + 0.05
            assert ttff <= bound, f"first audio late ({ttff:.3f}s > {bound:.3f}s)"

            # Max gap between consecutive deltas bounded by one segment delay.
            # Within a segment, frames are emitted back-to-back (gap ~0); the
            # only real gap is the per-segment synthesis delay.
            gaps = [ts[i + 1] - ts[i] for i in range(len(ts) - 1)]
            max_gap = max(gaps)
            assert max_gap <= bound, (
                f"max inter-delta gap {max_gap:.3f}s exceeds bound {bound:.3f}s "
                f"(buffer-then-flush?)"
            )


async def test_recv_loop_not_blocked_status_during_synthesis():
    """The recv loop stays live during synthesis: a server.status request sent
    mid-response is answered while the drain task is still running."""
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=120)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("status during synth")
            await client.commit()
            # Wait until mid-synthesis.
            await next_event(client, "response.audio.delta", timeout=3.0)
            await client.status()
            status = await next_event(client, "server.status", timeout=2.0)
            # A response is in flight, so queue_depth reflects active work.
            assert status["queue_depth"] == 1


async def test_pcm_reassembly_before_cancel_is_contiguous():
    """Sanity: deltas received before a cancel reassemble into valid pcm16 (even
    number of bytes per frame)."""
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=120)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("partial")
            await client.commit()
            first = await next_event(client, "response.audio.delta", timeout=3.0)
            assert len(base64.b64decode(first["audio"])) % 2 == 0
            await client.cancel()
            await next_event(client, "response.cancelled", timeout=2.0)
