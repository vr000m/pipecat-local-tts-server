"""Reference Pipecat adapter — session.update ack ordering (adversarial-review #1).

``_connect()`` must consume the ``session.update`` ack synchronously, BEFORE any
commit is sent. Otherwise ``run_tts`` sends append+commit first and only then
reads events, so a stale config error surfaces AFTER a commit is already
synthesizing — the adapter yields ``ErrorFrame`` and breaks, abandoning a live
response (no drain, no cancel) and pinning the backend/Metal lock.

The adapter requires the Pipecat framework (the ``examples`` extra). When it is
not installed these tests skip.
"""

from __future__ import annotations

import pytest

pytest.importorskip("pipecat", reason="reference adapter requires the examples extra (pipecat-ai)")

from examples.pipecat_tts_service import LocalTTSService  # noqa: E402
from tts_server import protocol as P  # noqa: E402

pytestmark = pytest.mark.asyncio


class _FakeClient:
    """Minimal stand-in exposing only ``events()`` over a scripted sequence."""

    def __init__(self, events: list[dict]) -> None:
        self._events = events

    async def events(self):
        for ev in self._events:
            yield ev


def _service() -> LocalTTSService:
    # __init__ does not connect; it only stores kwargs.
    return LocalTTSService(socket_path="/tmp/does-not-connect.sock")


async def test_await_update_ack_accepts_session_updated():
    svc = _service()
    await svc._await_update_ack(_FakeClient([{"type": P.EVT_SESSION_UPDATED}]))


async def test_await_update_ack_accepts_session_created():
    svc = _service()
    await svc._await_update_ack(_FakeClient([{"type": P.EVT_SESSION_CREATED}]))


async def test_await_update_ack_raises_on_error():
    svc = _service()
    bad = {"type": P.EVT_ERROR, "error": {"code": "invalid_config", "message": "bad voice"}}
    with pytest.raises(RuntimeError, match="rejected session.update"):
        await svc._await_update_ack(_FakeClient([bad]))


async def test_await_update_ack_raises_when_closed_before_ack():
    svc = _service()
    with pytest.raises(RuntimeError, match="closed before"):
        await svc._await_update_ack(_FakeClient([]))
