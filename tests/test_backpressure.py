"""Synthesis-backlog backpressure caps (Phase 3, R4).

Lean-CI on ``ToneBackend``. Two distinct caps live in the scheduler:

- a bounded GLOBAL synthesis backlog (``SYNTHESIS_QUEUE_MAX``): once full, a new
  ``commit`` is REJECTED (not enqueued) with ``error {code: BUSY,
  retry_after_ms}``; ``retry_after_ms`` MUST be a positive bounded integer so a
  client backs off rather than hot-loops, and the rejected text is NOT
  synthesized.
- a per-connection in-flight cap (K=1): a connection's 2nd queued commit is
  rejected while OTHER connections still get served.
- cancel frees the in-flight slot: fill a connection to K, cancel, and a new
  commit is accepted again (guards a barge-in-heavy client from self-DoSing into
  permanent BUSY).
- bridge backpressure: a full backend->session bridge blocks/cancels the
  producer rather than dropping chunks or scheduling unbounded callbacks.

The backend is paced with a per-segment delay so commits stay in-flight long
enough to fill the queue deterministically.
"""

from __future__ import annotations

import asyncio

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend
from tts_server.client import TTSClient
from tts_server.server import TTSServer

from ._helpers import connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio


def _slow_backend() -> ToneBackend:
    # A single long-ish segment so a committed response stays in flight while we
    # pile up more commits behind it. No need for huge audio — the delay holds
    # the in-flight slot, not the byte volume.
    return ToneBackend(segment_count=1, segment_ms=20, segment_delay_ms=1500)


async def _connect(srv: TTSServer) -> tuple[TTSClient, dict]:
    port = srv.listening_port()
    assert port is not None
    c = TTSClient(host="127.0.0.1", port=port)
    hello = await c.connect()
    return c, hello


# --- per-connection in-flight cap (K=1) ------------------------------------


async def test_per_connection_inflight_cap_rejects_second_commit():
    assert P.PER_CONNECTION_INFLIGHT_MAX == 1
    async with running_server(_slow_backend()) as srv:
        async with connected_client(srv) as (client, _hello):
            # First commit is admitted and starts synthesizing (held by delay).
            await client.append("first")
            await client.commit()
            await next_event(client, P.EVT_RESPONSE_CREATED)
            # Second commit while the first is in flight → BUSY (K=1).
            await client.append("second")
            await client.commit()
            err = await next_event(client, P.EVT_ERROR)
            assert err["error"]["code"] == P.ErrorCode.BUSY.value


async def test_other_connections_still_served_while_one_is_capped():
    async with running_server(_slow_backend()) as srv:
        a, _ = await _connect(srv)
        b, _ = await _connect(srv)
        try:
            # A holds its single in-flight slot.
            await a.append("aaa")
            await a.commit()
            await next_event(a, P.EVT_RESPONSE_CREATED)
            # A's second commit is rejected (its own cap), but B — a different
            # connection — is still admitted.
            await a.append("aaa2")
            await a.commit()
            err = await next_event(a, P.EVT_ERROR)
            assert err["error"]["code"] == P.ErrorCode.BUSY.value

            await b.append("bbb")
            await b.commit()
            created = await next_event(b, P.EVT_RESPONSE_CREATED)
            assert created["type"] == P.EVT_RESPONSE_CREATED
        finally:
            await a.close()
            await b.close()


# --- global synthesis-queue cap → BUSY -------------------------------------


async def test_global_queue_full_rejects_with_busy_and_bounded_retry():
    # Fill the GLOBAL backlog to SYNTHESIS_QUEUE_MAX using that many distinct
    # connections (each at K=1), then a one-more connection's commit is rejected
    # with BUSY and is NOT synthesized.
    cap = P.SYNTHESIS_QUEUE_MAX
    async with running_server(_slow_backend()) as srv:
        clients: list[TTSClient] = []
        try:
            for i in range(cap):
                c, _ = await _connect(srv)
                clients.append(c)
                await c.append(f"fill-{i}")
                await c.commit()
                # Each fills one global slot (admitted; created or queued).
                await next_event(c, {P.EVT_RESPONSE_CREATED, P.EVT_TEXT_COMMITTED})

            # One more connection: global backlog is full → BUSY.
            overflow, _ = await _connect(srv)
            clients.append(overflow)
            await overflow.append("overflow")
            await overflow.commit()
            err = await next_event(overflow, P.EVT_ERROR)
            assert err["error"]["code"] == P.ErrorCode.BUSY.value

            # retry_after_ms is a positive, bounded integer (not 0/absurd).
            retry = err["error"].get("retry_after_ms", err.get("retry_after_ms"))
            assert isinstance(retry, int)
            assert 0 < retry <= 60_000

            # The rejected commit was NOT synthesized: no response.* for it. The
            # buffer is left intact so a later retry can resend the same text.
            with pytest.raises(asyncio.TimeoutError):
                await next_event(
                    overflow,
                    {P.EVT_RESPONSE_CREATED, P.EVT_RESPONSE_AUDIO_DELTA},
                    timeout=0.5,
                )
        finally:
            for c in clients:
                await c.close()


# --- cancel frees the in-flight slot ---------------------------------------


async def test_cancel_frees_inflight_slot_so_new_commit_is_accepted():
    async with running_server(_slow_backend()) as srv:
        async with connected_client(srv) as (client, _hello):
            # Fill to K=1.
            await client.append("first")
            await client.commit()
            await next_event(client, P.EVT_RESPONSE_CREATED)
            # Confirm we are at the cap (2nd commit is BUSY).
            await client.append("blocked")
            await client.commit()
            busy = await next_event(client, P.EVT_ERROR)
            assert busy["error"]["code"] == P.ErrorCode.BUSY.value

            # Cancel the in-flight response → frees the slot.
            await client.cancel()
            await next_event(client, P.EVT_RESPONSE_CANCELLED)

            # A NEW commit is now accepted (no permanent self-DoS into BUSY).
            await client.append("after cancel")
            await client.commit()
            created = await next_event(client, {P.EVT_RESPONSE_CREATED})
            assert created["type"] == P.EVT_RESPONSE_CREATED


# --- bridge backpressure ----------------------------------------------------


async def test_bridge_producer_blocks_rather_than_dropping_chunks():
    """The backend->session bridge is bounded: a slow consumer must make the
    producer block/cooperate, never drop chunks or schedule unbounded callbacks.

    With ToneBackend the bridge is the ``_ToneStream.events()`` async generator;
    its segments are produced one at a time and only as the consumer pulls. We
    assert end-to-end integrity under a slow reader: every emitted segment is
    delivered intact (no gaps in ``seq``, no lost PCM) even when the consumer
    drains slowly — which can only hold if the producer applied backpressure
    instead of dropping. This is distinct from the high-water *close* test (that
    one is a stalled reader; here the reader is merely slow).
    """
    backend = ToneBackend(segment_count=5, segment_ms=40, segment_delay_ms=0, sample_rate=24000)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            rate = hello["audio"]["rate"]
            await client.append("bridge")
            await client.commit()

            deltas: list[dict] = []
            done = None
            async for ev in client.events():
                t = ev.get("type")
                if t == P.EVT_RESPONSE_AUDIO_DELTA:
                    deltas.append(ev)
                    # Drain slowly: yield control so the server-side producer
                    # must wait on the bounded bridge between chunks.
                    await asyncio.sleep(0.01)
                elif t == P.EVT_RESPONSE_AUDIO_DONE:
                    done = ev
                    break

            assert done is not None
            # seq is gapless and monotonic from 0 — no chunk was dropped.
            seqs = [d["seq"] for d in deltas]
            assert seqs == list(range(len(seqs)))
            # Total PCM equals 5 segments x 40 ms at the advertised rate (the
            # producer blocked and delivered everything, nothing dropped).
            expected_samples = 5 * int(rate * 40 / 1000)
            assert done["duration_ms"] == int(expected_samples * 1000 / rate)
