"""Session lifecycle round-trips and distinct cancel/close semantics (lean CI).

Covers:
- session.update -> session.created/updated round-trip.
- input_text.clear -> input_text.cleared round-trip (uncommitted text dropped).
- response.failed via a raising ToneBackend (carries {code, message}; session
  stays usable afterward).
- session.cancel vs session.close vs response.cancel -- distinct semantics
  (close = drain in-flight, cancel = discard, response.cancel = barge-in but
  keeps the session open).
"""

from __future__ import annotations

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import (
    collect_response,
    connected_client,
    next_event,
    running_server,
)

pytestmark = pytest.mark.asyncio


# --- session.update / input_text.clear round-trips --------------------------


async def test_session_update_acks_created_then_updated():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="af_heart")
            created = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED})
            assert created["type"] == P.EVT_SESSION_CREATED
            assert created["session"]["voice"] == "af_heart"

            await client.update(language="en")
            updated = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED})
            assert updated["type"] == P.EVT_SESSION_UPDATED
            assert updated["session"]["language"] == "en"
            # earlier voice preserved across updates
            assert updated["session"]["voice"] == "af_heart"


async def test_input_text_clear_round_trip_drops_buffer():
    async with running_server(ToneBackend(segment_count=1, segment_delay_ms=0)) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("discard me")
            await client.clear()
            cleared = await next_event(client, P.EVT_TEXT_CLEARED)
            assert cleared["type"] == P.EVT_TEXT_CLEARED
            # buffer is empty now: a commit fails with buffer_empty.
            await client.commit()
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.BUFFER_EMPTY.value


# --- response.failed --------------------------------------------------------


async def test_response_failed_carries_code_and_message_and_session_usable():
    """A raising backend surfaces response.failed with {code, message}; the
    session stays usable for a subsequent (non-raising) commit."""
    # First server: a raising backend to drive the failure path.
    async with running_server(ToneBackend(raises=True, segment_delay_ms=0)) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("boom")
            await client.commit()
            resp = await collect_response(client)
            assert resp.failed is not None
            err = resp.failed["error"]
            assert "code" in err and "message" in err
            assert err["code"] == P.ErrorCode.BACKEND_ERROR.value
            assert isinstance(err["message"], str) and err["message"]

            # Session stays usable: another commit gets through to a terminal
            # event (it will fail again because this backend always raises, but
            # the recv loop still services it -- proving the session survived).
            await client.append("again")
            await client.commit()
            resp2 = await collect_response(client)
            assert resp2.failed is not None


# --- session.cancel vs session.close vs response.cancel ---------------------


async def test_response_cancel_keeps_session_open():
    """response.cancel is barge-in: it cancels the response but the session stays
    open and a new commit can run."""
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=120)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("first")
            await client.commit()
            await next_event(client, "response.audio.delta", timeout=3.0)
            await client.cancel()
            cancelled = await next_event(client, "response.cancelled", timeout=2.0)
            assert cancelled["type"] == "response.cancelled"
            # Session still open: a new synthesis works.
            await client.append("second")
            await client.commit()
            done = await next_event(client, "response.audio.done", timeout=3.0)
            assert done["type"] == "response.audio.done"


async def test_session_cancel_discards_and_closes():
    """session.cancel = discard semantics: drop in-flight + buffer, then close
    the connection (distinct from response.cancel which keeps it open)."""
    backend = ToneBackend(segment_count=5, segment_ms=100, segment_delay_ms=120)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("to be discarded")
            await client.commit()
            await next_event(client, "response.audio.delta", timeout=3.0)
            await client.cancel_session()
            closed = await next_event(client, P.EVT_SESSION_CLOSED, timeout=2.0)
            assert closed["type"] == P.EVT_SESSION_CLOSED
            assert closed["reason"] == "client_cancel"


async def test_session_close_drains_then_closes():
    """session.close = drain semantics: the in-flight response finishes
    (response.audio.done) before the session.closed."""
    backend = ToneBackend(segment_count=2, segment_ms=100, segment_delay_ms=30)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("drain me")
            await client.commit()
            await next_event(client, "response.audio.delta", timeout=3.0)
            await client.close_session()
            # Drain: done arrives, then session.closed with reason client_close.
            ev = await next_event(
                client, {"response.audio.done", P.EVT_SESSION_CLOSED}, timeout=3.0
            )
            assert ev["type"] == "response.audio.done"
            closed = await next_event(client, P.EVT_SESSION_CLOSED, timeout=3.0)
            assert closed["reason"] == "client_close"


async def test_three_cancel_close_paths_are_distinct():
    """A compact assertion that the three teardown verbs map to distinct
    server behaviour: response.cancel -> response.cancelled (session open);
    session.cancel -> session.closed reason=client_cancel; session.close ->
    session.closed reason=client_close."""
    # response.cancel keeps session open (verified above); here verify the two
    # session-level verbs differ in reason and both close.
    async with running_server(
        ToneBackend(segment_count=1, segment_ms=20, segment_delay_ms=0)
    ) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.cancel_session()
            ev = await next_event(client, P.EVT_SESSION_CLOSED, timeout=2.0)
            assert ev["reason"] == "client_cancel"

    async with running_server(
        ToneBackend(segment_count=1, segment_ms=20, segment_delay_ms=0)
    ) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.close_session()
            ev = await next_event(client, P.EVT_SESSION_CLOSED, timeout=2.0)
            assert ev["reason"] == "client_close"
