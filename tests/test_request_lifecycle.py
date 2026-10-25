"""The request lifecycle on one persistent connection (docs/protocol.md §3).

Server truth the app's Try it client (``macos/.../TTSRequestMachine.swift``)
is built on, over the whole state space:

- states: idle (empty buffer), appended, refused (every pre-admission refusal
  of an ``input_text.append`` or ``input_text.commit``), in flight, cancelled;
- frames: ``input_text.append`` / ``commit`` / ``clear`` and ``response.cancel``.

The contract pinned here:

1. Only an ADMITTED commit (``input_text.committed``) consumes the buffer.
2. Every refusal (``busy``, ``invalid_config`` for voice / language / unknown
   field / ``audio_format`` / extras / ``validate_text``, ``payload_too_large``
   on append, ``buffer_empty``) leaves the buffer exactly as it was, so a client
   can retry the same commit.
3. ``input_text.clear`` empties the buffer in every state and never touches a
   response in flight.
4. ``response.cancel`` targets a response, never the buffer: a cancel that
   reaches the server before its commit is a no-op, and that commit is then
   admitted and synthesized.

So a client that does NOT retry a refused commit must ``input_text.clear``
before its next request, and must send Stop's cancel after the commit it stops.
"""

from __future__ import annotations

import asyncio
import json

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import collect_response, connected_client, next_event, running_server


class _RecordingTone(ToneBackend):
    """Tone that keeps every stream, so a test can read the text it synthesized,
    and rejects any committed text starting with ``BAD`` (``validate_text``)."""

    def __init__(self, **kwargs) -> None:
        super().__init__(**kwargs)
        self.streams: list = []

    async def open_stream(self, **kwargs):
        stream = await super().open_stream(**kwargs)
        self.streams.append(stream)
        return stream

    def validate_text(self, text: str) -> str | None:
        return "text starts with BAD" if text.startswith("BAD") else None

    @property
    def last_text(self) -> str:
        return self.streams[-1]._text


async def _send(client, frame: dict) -> None:
    await client._ws.send(json.dumps(frame))


async def _speak(client, backend: _RecordingTone, text: str) -> str:
    """append ``text`` + commit (retrying the SAME commit on busy, which works
    because a refused commit keeps the buffer); returns what was synthesized."""
    await client.append(text)
    for _ in range(40):
        await client.commit()
        ev = await next_event(client, {P.EVT_TEXT_COMMITTED, "error"})
        if ev["type"] == P.EVT_TEXT_COMMITTED:
            break
        assert ev["error"]["code"] == P.ErrorCode.BUSY.value, ev
        await asyncio.sleep(0.05)
    else:
        raise AssertionError("commit never admitted")
    resp = await collect_response(client)
    assert resp.done is not None, resp
    return backend.last_text


async def _refuse_busy(client) -> None:
    # K=1: a commit while another is in flight is refused with busy.
    await client.append("first")
    await client.commit()
    await next_event(client, P.EVT_TEXT_COMMITTED)
    await client.append("old")
    await client.commit()
    err = await next_event(client, "error")
    assert err["error"]["code"] == P.ErrorCode.BUSY.value
    await client.cancel()
    await next_event(client, P.EVT_RESPONSE_CANCELLED)


def _commit_refusal(extra: dict, code: P.ErrorCode, text: str = "old"):
    async def refuse(client) -> None:
        await client.append(text)
        await _send(client, {"type": P.EVT_TEXT_COMMIT, **extra})
        err = await next_event(client, "error")
        assert err["error"]["code"] == code.value, err

    return refuse


async def _refuse_oversize_append(client) -> None:
    await client.append("old")
    await client.append("x" * 64)  # old + this > max_text_chars
    err = await next_event(client, "error")
    assert err["error"]["code"] == P.ErrorCode.PAYLOAD_TOO_LARGE.value


async def _refuse_empty_commit(client) -> None:
    await client.commit()
    err = await next_event(client, "error")
    assert err["error"]["code"] == P.ErrorCode.BUFFER_EMPTY.value


# (refusal, text it leaves buffered)
REFUSALS = {
    "busy": (_refuse_busy, "old"),
    "invalid_voice": (_commit_refusal({"voice": "nope"}, P.ErrorCode.INVALID_CONFIG), "old"),
    "invalid_language": (_commit_refusal({"language": "xx"}, P.ErrorCode.INVALID_CONFIG), "old"),
    "unknown_field": (_commit_refusal({"bogus": 1}, P.ErrorCode.INVALID_CONFIG), "old"),
    "audio_format": (_commit_refusal({"audio_format": "pcm16"}, P.ErrorCode.INVALID_CONFIG), "old"),
    "invalid_extras": (_commit_refusal({"extras": "x"}, P.ErrorCode.INVALID_CONFIG), "old"),
    "validate_text": (
        _commit_refusal({}, P.ErrorCode.INVALID_CONFIG, text="BAD old"),
        "BAD old",
    ),
    "oversize_append": (_refuse_oversize_append, "old"),
    "buffer_empty": (_refuse_empty_commit, ""),
}


def _backend() -> _RecordingTone:
    return _RecordingTone(max_text_chars=40, segment_delay_ms=150)


@pytest.mark.parametrize("refusal", sorted(REFUSALS))
async def test_a_refusal_keeps_the_buffer_and_clear_drops_it(refusal):
    refuse, retained = REFUSALS[refusal]
    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        await refuse(client)
        if retained.startswith("BAD"):
            # The retained text is refused again (see the test below).
            await client.append(" new")
            await client.commit()
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value
        else:
            # Without a clear, the next request speaks the retained text first:
            # the stale-text bug a non-retrying client hits.
            assert await _speak(client, backend, " new") == retained + " new"

    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        await refuse(client)
        await client.clear()
        await next_event(client, P.EVT_TEXT_CLEARED)
        assert await _speak(client, backend, "new") == "new"


async def test_validate_text_refusal_keeps_the_buffer():
    """The ``validate_text`` row above, observed directly: a retry of the same
    commit is refused again, because the refused text is still buffered."""
    async with running_server(_backend()) as srv, connected_client(srv) as (client, _hello):
        await _commit_refusal({}, P.ErrorCode.INVALID_CONFIG, text="BAD old")(client)
        await client.commit()
        err = await next_event(client, "error")
        assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_an_admitted_commit_consumes_the_buffer():
    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        assert await _speak(client, backend, "one") == "one"
        assert await _speak(client, backend, "two") == "two"


async def test_clear_while_in_flight_keeps_the_response():
    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        await client.append("one")
        await client.commit()
        await next_event(client, P.EVT_TEXT_COMMITTED)
        await client.clear()
        await next_event(client, P.EVT_TEXT_CLEARED)
        resp = await collect_response(client)
        assert resp.done is not None and backend.last_text == "one"


async def test_clear_on_an_empty_buffer_is_acknowledged():
    async with running_server(_backend()) as srv, connected_client(srv) as (client, _hello):
        await client.clear()
        await next_event(client, P.EVT_TEXT_CLEARED)


async def test_a_cancel_before_its_commit_does_not_stop_it():
    """Why Stop's cancel must reach the server after the commit it stops: a
    cancel with no response in flight is a no-op, and the buffer is untouched."""
    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        await client.append("stopped")
        await client.cancel()
        await client.commit()
        resp = await collect_response(client)
        assert resp.cancelled is None and resp.done is not None
        assert backend.last_text == "stopped"


async def test_a_cancel_after_its_commit_frees_the_connection():
    """append, commit, cancel (Stop ordered after the commit): the response is
    cancelled, the buffer is empty, and the next request is admitted (K=1 is not
    stranded)."""
    backend = _backend()
    async with running_server(backend) as srv, connected_client(srv) as (client, _hello):
        await client.append("stopped")
        await client.commit()
        await client.cancel()
        resp = await collect_response(client)
        assert resp.cancelled is not None
        await client.clear()  # what the app sends first anyway; a no-op here
        await next_event(client, P.EVT_TEXT_CLEARED)
        assert await _speak(client, backend, "next") == "next"
