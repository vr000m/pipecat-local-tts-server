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

import base64

import pytest

pytest.importorskip("pipecat", reason="reference adapter requires the examples extra (pipecat-ai)")

from pipecat.frames.frames import (  # noqa: E402
    ErrorFrame,
    TTSAudioRawFrame,
    TTSStartedFrame,
    TTSStoppedFrame,
)

from examples.pipecat_tts_service import LocalTTSService  # noqa: E402
from tts_server import protocol as P  # noqa: E402

pytestmark = pytest.mark.asyncio


# Sentinel ``previous_event_id`` on a scripted ``input_text.committed``: the fake
# client rewrites it to the real commit event_id captured at ``commit()`` time, so
# a test can mark exactly which committed ack correlates to the commit just sent
# (the adapter generates the id internally, so the test cannot hard-code it).
_MATCH = "__MATCH_COMMIT_EVENT_ID__"


class _FakeClient:
    """Minimal stand-in exposing only ``events()`` over a scripted sequence."""

    def __init__(self, events: list[dict]) -> None:
        self._events = events
        self.cancels: list[str | None] = []
        self.commit_event_id: str | None = None

    async def events(self):
        for ev in self._events:
            ev = dict(ev)
            if ev.get("previous_event_id") == _MATCH:
                # Correlate to the commit the adapter actually sent.
                ev["previous_event_id"] = self.commit_event_id
            yield ev

    async def append(self, text: str, **kwargs) -> None:
        pass

    async def commit(self, *, event_id: str | None = None, **kwargs) -> None:
        self.commit_event_id = event_id

    async def cancel(self, *, response_id: str | None = None) -> None:
        self.cancels.append(response_id)


def _committed(rid: str, *, correlated: bool = True, previous_event_id: str | None = None) -> dict:
    """A scripted ``input_text.committed``. ``correlated`` marks it as the ack for
    the commit just sent (its ``previous_event_id`` is rewritten to the real id);
    otherwise it carries an unrelated/stale ``previous_event_id``."""
    ev: dict = {"type": P.EVT_TEXT_COMMITTED, "response_id": rid}
    ev["previous_event_id"] = _MATCH if correlated else previous_event_id
    return ev


def _service() -> LocalTTSService:
    # __init__ does not connect; it only stores kwargs.
    return LocalTTSService(socket_path="/tmp/does-not-connect.sock")


def _wire_for_run_tts(svc: LocalTTSService, client: _FakeClient) -> None:
    """Attach a fake client + rate and stub the base-class metric coroutines so
    ``run_tts`` can be driven without a live Pipeline/clock."""
    svc._client = client
    svc._server_rate = 24000

    async def _noop(*args, **kwargs):
        return None

    svc.start_ttfb_metrics = _noop  # type: ignore[method-assign]
    svc.stop_ttfb_metrics = _noop  # type: ignore[method-assign]
    svc.start_tts_usage_metrics = _noop  # type: ignore[method-assign]


def _audio_delta(rid: str, pcm: bytes = b"\x01\x00") -> dict:
    return {
        "type": P.EVT_RESPONSE_AUDIO_DELTA,
        "response_id": rid,
        "audio": base64.b64encode(pcm).decode("ascii"),
    }


async def _drain_run_tts(svc: LocalTTSService, context_id: str = "ctx") -> list:
    return [f async for f in svc.run_tts("hello world", context_id)]


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


# --- response_id gating (adversarial-review: stale cancel ack) ----------------
# On a persistent connection, a cancelled response can leave its
# ``response.cancelled`` ack (or trailing audio) buffered on the socket. Those
# frames carry the PRIOR response_id and arrive before the new commit's
# ``input_text.committed`` / ``response.created``. ``run_tts`` must gate every
# response-scoped event by response_id so a stale ack cannot terminate the new
# utterance and leave the new commit synthesizing with no reader.


async def test_stale_cancelled_does_not_terminate_new_utterance():
    # The killer interleaving: a leftover response.cancelled for the OLD response
    # (rid "old") is the FIRST frame the new run_tts reads, before its own
    # committed/created. It must be ignored, and the new response (rid "new")
    # must drain fully to audio.done.
    client = _FakeClient(
        [
            {"type": P.EVT_RESPONSE_CANCELLED, "response_id": "old"},
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert any(isinstance(f, TTSStartedFrame) for f in frames)
    audio = [f for f in frames if isinstance(f, TTSAudioRawFrame)]
    assert len(audio) == 1, "stale response.cancelled must not have terminated the new utterance"
    assert audio[0].sample_rate == 24000
    assert any(isinstance(f, TTSStoppedFrame) for f in frames)
    assert not any(isinstance(f, ErrorFrame) for f in frames)


async def test_stale_audio_delta_is_ignored():
    # Trailing audio from the prior response (rid "old") that was already in
    # flight when the cancel landed must not be yielded for this utterance.
    client = _FakeClient(
        [
            _audio_delta("old", pcm=b"\xff\xff"),
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new", pcm=b"\x01\x00"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    audio = [f for f in frames if isinstance(f, TTSAudioRawFrame)]
    assert len(audio) == 1, "only the new response's audio should be yielded"
    assert audio[0].audio == b"\x01\x00"


async def test_matching_cancelled_still_terminates_response():
    # A cancelled ack for the CURRENT response (barge-in) is honored: the loop
    # breaks and no audio.done is required.
    client = _FakeClient(
        [
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new"),
            {"type": P.EVT_RESPONSE_CANCELLED, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert len([f for f in frames if isinstance(f, TTSAudioRawFrame)]) == 1
    assert any(isinstance(f, TTSStoppedFrame) for f in frames)
    assert not any(isinstance(f, ErrorFrame) for f in frames)


async def test_stale_response_failed_is_ignored():
    # A response.failed for the OLD response must not surface as an ErrorFrame on
    # the new utterance.
    client = _FakeClient(
        [
            {"type": P.EVT_RESPONSE_FAILED, "response_id": "old", "error": {"code": "x"}},
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert not any(isinstance(f, ErrorFrame) for f in frames)
    assert len([f for f in frames if isinstance(f, TTSAudioRawFrame)]) == 1


# --- per-commit correlation (adversarial-review round 2) ----------------------
# Gating by response_id is not enough on its own: a fully-buffered prior response
# (committed/created/cancelled, all for the OLD id) can precede this commit's ack.
# Without correlating the committed ack to the commit we just sent, the adapter
# would adopt the OLD id from the stale committed, then honor the stale cancel and
# abandon the new utterance. ``run_tts`` must learn its id ONLY from the committed
# whose ``previous_event_id`` matches the commit's ``event_id``.


async def test_stale_committed_created_cancelled_does_not_poison_gating():
    # The full poison sequence: an entire prior response (committed/created/
    # cancelled for "old"), with a *non-correlated* committed, precedes this
    # commit's correlated committed/created/audio for "new".
    client = _FakeClient(
        [
            _committed("old", correlated=False, previous_event_id="old-commit-evt"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "old"},
            {"type": P.EVT_RESPONSE_CANCELLED, "response_id": "old"},
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new", pcm=b"\x02\x00"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    audio = [f for f in frames if isinstance(f, TTSAudioRawFrame)]
    assert len(audio) == 1, "stale committed/created/cancelled(old) must not poison gating"
    assert audio[0].audio == b"\x02\x00"
    assert any(isinstance(f, TTSStoppedFrame) for f in frames)
    assert not any(isinstance(f, ErrorFrame) for f in frames)
    # The adapter must have adopted the NEW id, not the stale OLD one.
    assert svc._current_response_id in (None, "new")


async def test_uncorrelated_committed_alone_is_ignored():
    # A committed that never correlates (only a stale one arrives) leaves the id
    # unset, so a following cancelled for that stale id cannot terminate us.
    client = _FakeClient(
        [
            _committed("old", correlated=False, previous_event_id="old-commit-evt"),
            {"type": P.EVT_RESPONSE_CANCELLED, "response_id": "old"},
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new", pcm=b"\x03\x00"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    audio = [f for f in frames if isinstance(f, TTSAudioRawFrame)]
    assert len(audio) == 1
    assert audio[0].audio == b"\x03\x00"
