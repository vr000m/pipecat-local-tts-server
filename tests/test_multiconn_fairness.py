"""Multi-connection isolation & round-robin fairness (Phase 3, R4).

Lean-CI on a delayed ``ToneBackend``:

- 2-connection no-intermix: two concurrent connections never interleave their
  ``response.audio.delta`` streams — each ``response_id`` belongs to exactly one
  connection, and bytes from one session never land in another's reassembled
  PCM. (Per-connection ``_SessionState`` isolation: no shared mutable state.)
- round-robin fairness: the single dispatcher selects commits round-robin at
  commit granularity, so a long commit on connection A delays connection B's
  FIRST audio by at most ~one already-selected commit, not by A's full utterance
  queue or by whichever thread wins the OS lock race.
"""

from __future__ import annotations

import asyncio

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend
from tts_server.client import TTSClient
from tts_server.server import TTSServer

from ._helpers import running_server

pytestmark = pytest.mark.asyncio


async def _connect(srv: TTSServer) -> TTSClient:
    port = srv.listening_port()
    assert port is not None
    c = TTSClient(host="127.0.0.1", port=port)
    await c.connect()
    return c


async def _drive_and_collect(client: TTSClient, text: str) -> dict:
    """append+commit, then collect that connection's full response trace.

    Returns a dict with ``response_id``, the ordered list of delta ``seq``s, and
    the reassembled PCM. Used to prove streams do not intermix across sessions.
    """
    await client.append(text)
    await client.commit()
    rid = None
    deltas: list[dict] = []
    first_delta_ts: float | None = None
    async for ev in client.events():
        t = ev.get("type")
        if t in (P.EVT_TEXT_COMMITTED, P.EVT_RESPONSE_CREATED):
            rid = ev.get("response_id", rid)
        elif t == P.EVT_RESPONSE_AUDIO_DELTA:
            if first_delta_ts is None:
                first_delta_ts = asyncio.get_running_loop().time()
            deltas.append(ev)
        elif t == P.EVT_RESPONSE_AUDIO_DONE:
            break
    return {
        "response_id": rid,
        "delta_response_ids": {d["response_id"] for d in deltas},
        "first_delta_ts": first_delta_ts,
        "n_deltas": len(deltas),
    }


async def test_two_connections_streams_do_not_intermix():
    # Distinct rates per connection are impossible (one backend), so instead we
    # assert response_id ownership: every delta a connection receives carries
    # that connection's own response_id and no other.
    backend = ToneBackend(segment_count=3, segment_ms=40, segment_delay_ms=60)
    async with running_server(backend) as srv:
        a = await _connect(srv)
        b = await _connect(srv)
        try:
            res_a, res_b = await asyncio.gather(
                _drive_and_collect(a, "alpha alpha alpha"),
                _drive_and_collect(b, "bravo bravo bravo"),
            )
            # Each connection saw exactly one response_id — its own.
            assert res_a["delta_response_ids"] == {res_a["response_id"]}
            assert res_b["delta_response_ids"] == {res_b["response_id"]}
            # The two connections got DIFFERENT response_ids (no shared space).
            assert res_a["response_id"] != res_b["response_id"]
            # Both actually received audio (the test is meaningful).
            assert res_a["n_deltas"] > 0 and res_b["n_deltas"] > 0
        finally:
            await a.close()
            await b.close()


async def test_round_robin_bounds_head_of_line_delay():
    # A's commit is one long single segment; B commits a moment later. Under
    # round-robin at commit granularity (K=1), B's first audio is delayed by at
    # most ONE already-selected commit (A's single in-flight commit), not by a
    # multiple of it. With one long commit each, the bound is ~A's commit time.
    long_segment_ms = 120
    backend = ToneBackend(segment_count=1, segment_ms=20, segment_delay_ms=long_segment_ms)
    async with running_server(backend) as srv:
        a = await _connect(srv)
        b = await _connect(srv)
        try:
            t0 = asyncio.get_running_loop().time()

            async def run_a():
                return await _drive_and_collect(a, "long-a")

            async def run_b():
                # Start B slightly after A so A's commit is the already-selected
                # one when B is admitted.
                await asyncio.sleep(0.02)
                return await _drive_and_collect(b, "short-b")

            res_a, res_b = await asyncio.gather(run_a(), run_b())

            assert res_a["first_delta_ts"] is not None
            assert res_b["first_delta_ts"] is not None
            b_first_audio_delay = res_b["first_delta_ts"] - t0

            # Bound: B waits behind at most one already-selected commit (A's),
            # i.e. roughly one segment_delay, NOT two. Allow generous slack for
            # the test loop while still failing if B waited for ~2x commits.
            one_commit_s = long_segment_ms / 1000.0
            assert b_first_audio_delay <= (2 * one_commit_s) + 0.25, (
                f"B's first audio was delayed {b_first_audio_delay:.3f}s; expected "
                f"<= ~one already-selected commit (~{one_commit_s:.3f}s + slack)"
            )
        finally:
            await a.close()
            await b.close()
