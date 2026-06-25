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


async def test_bridge_enqueues_eof_without_dropping_tail_chunk():
    """Regression (Codex review #1): on NORMAL generator exhaustion with a full
    bridge queue and a slow consumer, EOF must be enqueued WITH backpressure —
    never by dropping a buffered chunk, which would silently truncate the tail.

    Drives the shared ``stream_generate`` bridge directly (the only place this
    path lives — ToneBackend does not use the bridge). A tiny ``maxsize=1`` queue
    plus a sleeping consumer keeps the queue full at EOF, which is exactly the
    state where the old ``_put_eof`` dropped a buffered chunk.
    """
    import threading

    from tts_server.backends._stream_util import stream_generate

    class _FakeResult:
        def __init__(self, audio: list[float]) -> None:
            self.audio = audio

    loop = asyncio.get_running_loop()
    metal_lock = threading.Lock()
    cancel = threading.Event()
    n = 4
    results = [_FakeResult([i / 10.0, i / 10.0]) for i in range(1, n + 1)]

    received: list[bytes] = []
    agen = stream_generate(
        (lambda: iter(results)),
        loop=loop,
        metal_lock=metal_lock,
        cancel=cancel,
        maxsize=1,  # tiny queue: stays full between the slow consumer's reads
    )
    async for pcm in agen:
        received.append(pcm)
        await asyncio.sleep(0.02)  # slow consumer keeps the bounded queue full

    assert len(received) == n, f"expected {n} chunks, got {len(received)} — tail dropped at EOF"
    # The process-wide Metal lock must be released after the drain (not leaked).
    assert metal_lock.acquire(blocking=False), "metal_lock leaked by the worker"
    metal_lock.release()


async def test_bare_cancel_on_idle_session_is_noop():
    """Regression (Codex review #4): response.cancel with nothing active must NOT
    emit a malformed response.cancelled with response_id: null — it is a no-op,
    and the session stays healthy."""
    backend = ToneBackend(segment_count=2, segment_ms=40, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.cancel()  # nothing in flight
            await client.status()
            # First event after the bare cancel must be the status reply — not a
            # (null-id) response.cancelled or an error.
            ev = await next_event(
                client, {"server.status", "response.cancelled", "error"}, timeout=2.0
            )
            assert ev["type"] == "server.status", f"bare cancel produced {ev['type']}: {ev}"


async def test_bridge_worker_done_set_after_lock_release():
    """Adversarial-review #2: the bridge exposes worker completion via
    ``worker_done``, set only AFTER the Metal lock is released. An observer that
    sees it set can rely on the lock being free."""
    import threading

    from tts_server.backends._stream_util import stream_generate

    class _FakeResult:
        def __init__(self, audio):
            self.audio = audio

    loop = asyncio.get_running_loop()
    metal_lock = threading.Lock()
    cancel = threading.Event()
    worker_done = threading.Event()
    results = [_FakeResult([0.1, 0.1]) for _ in range(3)]

    agen = stream_generate(
        (lambda: iter(results)),
        loop=loop,
        metal_lock=metal_lock,
        cancel=cancel,
        maxsize=4,
        worker_done=worker_done,
    )
    async for _pcm in agen:
        pass
    # worker_done is the worker's FINAL act (after the lock release + EOF enqueue),
    # so the consumer can observe EOF a hair before it is set — wait for it, exactly
    # as ``wait_closed`` does. Once set, the lock is guaranteed free.
    done = await loop.run_in_executor(None, worker_done.wait, 2.0)
    assert done, "worker_done must be set once the worker exits"
    assert metal_lock.acquire(blocking=False), "lock must be free when worker_done is set"
    metal_lock.release()


async def test_kokoro_stream_wait_closed_blocks_until_lock_released():
    """Adversarial-review #2: ``_KokoroStream.wait_closed`` must not return until
    the synthesis worker has exited and released the process-wide Metal lock —
    even after ``cancel()``, which only *requests* a break at the next yield. The
    server awaits this before freeing a commit's scheduler slot so admission can
    never advertise free capacity while the lock is still held."""
    import threading
    import time

    from tts_server.backends.kokoro import _KokoroStream

    class _FakeResult:
        def __init__(self, audio):
            self.audio = audio

    class _SlowModel:
        """Yields forever with a small per-segment sleep so the worker is still
        running (holding the lock) when we cancel."""

        def generate(self, text, *, voice=None, lang_code=None, **kwargs):
            while True:
                yield _FakeResult([0.2, 0.2])
                time.sleep(0.01)

    lock = threading.Lock()
    stream = _KokoroStream(
        model=_SlowModel(), voice="v", lang_code="a", speed=None, metal_lock=lock
    )
    await stream.feed("hello")
    await stream.end()

    gen = stream.events()
    first = await gen.__anext__()  # one delta: worker is now running and holds the lock
    assert first.kind == "delta"
    assert not lock.acquire(blocking=False), "worker should hold the Metal lock mid-synthesis"

    await stream.cancel()
    await stream.wait_closed()  # must block until the worker breaks out and frees the lock
    assert lock.acquire(blocking=False), "wait_closed returned while the lock was still held"
    lock.release()
    await gen.aclose()


async def test_kokoro_stream_wait_closed_noop_before_synthesis():
    """``wait_closed`` must return immediately when synthesis never started (a
    pre-synthesis cancel) — there is no worker and no held lock to wait on."""
    import threading

    from tts_server.backends.kokoro import _KokoroStream

    stream = _KokoroStream(
        model=object(), voice="v", lang_code="a", speed=None, metal_lock=threading.Lock()
    )
    await stream.wait_closed()  # returns immediately; would hang if it waited on a phantom worker
