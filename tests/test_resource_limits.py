"""Resource limits (Phase 3, R4): send-queue high-water close + max_text_chars.

Lean-CI on ``ToneBackend``:

- a stalled audio *reader* (a client that connects but never drains its socket)
  trips the per-connection outbound send-queue high-water mark, and the server
  CLOSES the connection rather than buffering unboundedly. A stalled reader is a
  client bug; the server protects itself.
- text over the hard ``max_text_chars`` cap is rejected (``PAYLOAD_TOO_LARGE``),
  both incrementally on append and on a single oversized commit.
"""

from __future__ import annotations


import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend
from tts_server.server import ServerConfig, TTSServer, _SessionState

from ._helpers import connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio


class _StalledConnection:
    """A minimal ``ServerConnection`` stand-in whose outbound transport reports
    a pending write buffer ABOVE the high-water mark — i.e. a stalled audio
    *reader* that is not draining its socket. The server's send-queue high-water
    guard must close it (1011) instead of buffering unboundedly.

    Driving the guard against a fake transport is deterministic; the real-socket
    path depends on kernel/asyncio loopback buffer timing (the guard samples the
    transport buffer between sends, and on loopback ``ws.send`` blocks inside a
    single large send before the next sample), so a live-socket assertion is
    flaky by construction. See coverage notes.
    """

    def __init__(self, pending: int) -> None:
        self._pending = pending
        self.sent: list[str] = []
        self.closed_code: int | None = None
        self.closed_reason: str | None = None
        self.transport = self  # _pending_write_bytes reads ws.transport

    def get_write_buffer_size(self) -> int:
        return self._pending

    async def send(self, data) -> None:
        self.sent.append(data)

    async def close(self, code: int = 1000, reason: str = "") -> None:
        self.closed_code = code
        self.closed_reason = reason


async def test_stalled_reader_trips_high_water_and_connection_closed():
    # high-water = 4 KiB; the stalled reader reports 1 MiB pending → the guard
    # must mark the session closed and close the socket with 1011, and NOT send
    # the audio frame (it is dropped, not buffered).
    high_water = 4096
    backend = ToneBackend()
    srv = TTSServer(
        backend,
        ServerConfig(
            host="127.0.0.1",
            port=0,
            reject_browser_origins=False,
            send_queue_high_water_bytes=high_water,
        ),
    )
    ws = _StalledConnection(pending=1024 * 1024)
    state = _SessionState(session_id="s-test")

    # A normal (non-force) delta send while the reader is stalled.
    await srv._send(ws, state, {"type": P.EVT_RESPONSE_AUDIO_DELTA, "seq": 0, "audio": "AAAA"})

    assert state.closed is True, "session must be marked closed on high-water overflow"
    assert ws.closed_code == 1011, f"expected 1011 close, got {ws.closed_code}"
    assert ws.closed_reason == "send_queue_overflow"
    assert ws.sent == [], "the overflowing frame must be dropped, not buffered/sent"


async def test_under_high_water_does_not_close():
    # A reader that IS keeping up (pending below the mark) must not be closed.
    high_water = 1024 * 1024
    srv = TTSServer(
        ToneBackend(),
        ServerConfig(
            host="127.0.0.1",
            port=0,
            reject_browser_origins=False,
            send_queue_high_water_bytes=high_water,
        ),
    )
    ws = _StalledConnection(pending=0)
    state = _SessionState(session_id="s-ok")
    await srv._send(ws, state, {"type": P.EVT_RESPONSE_AUDIO_DELTA, "seq": 0, "audio": "AAAA"})
    assert state.closed is False
    assert ws.closed_code is None
    assert len(ws.sent) == 1


async def test_max_text_chars_rejects_oversized_single_commit():
    backend = ToneBackend(max_text_chars=50)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            assert hello["capabilities"]["max_text_chars"] == 50
            await client.append("x" * 60)  # one append already over the cap
            err = await next_event(client, P.EVT_ERROR)
            assert err["error"]["code"] == P.ErrorCode.PAYLOAD_TOO_LARGE.value


async def test_max_text_chars_rejects_when_appends_accumulate_over_cap():
    backend = ToneBackend(max_text_chars=50)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            # Each append is under the cap, but together they exceed it: the
            # second append must be rejected (buffer + new > cap).
            await client.append("y" * 40)
            await client.append("z" * 40)
            err = await next_event(client, P.EVT_ERROR)
            assert err["error"]["code"] == P.ErrorCode.PAYLOAD_TOO_LARGE.value


async def test_under_cap_text_commits_normally():
    backend = ToneBackend(max_text_chars=2000, segment_count=1, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("a short utterance")
            await client.commit()
            done = await next_event(client, P.EVT_RESPONSE_AUDIO_DONE)
            assert done["type"] == P.EVT_RESPONSE_AUDIO_DONE
