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

import asyncio
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
        self.clears = 0
        self.commit_event_id: str | None = None

    async def events(self):
        for ev in self._events:
            ev = dict(ev)
            if ev.get("previous_event_id") == _MATCH:
                # Correlate to the commit the adapter actually sent.
                ev["previous_event_id"] = self.commit_event_id
            err = ev.get("error")
            if isinstance(err, dict) and err.get("event_id") == _MATCH:
                ev["error"] = {**err, "event_id": self.commit_event_id}
            yield ev

    async def append(self, text: str, **kwargs) -> None:
        pass

    async def commit(self, *, event_id: str | None = None, **kwargs) -> None:
        self.commit_event_id = event_id

    async def cancel(self, *, response_id: str | None = None) -> None:
        self.cancels.append(response_id)

    async def clear(self) -> None:
        self.clears += 1


class _CancelOnCommitClient(_FakeClient):
    """Raises CancelledError from commit() to model a barge-in that cancels the
    run_tts task during the commit, before any event is read."""

    async def commit(self, *, event_id: str | None = None, **kwargs) -> None:
        self.commit_event_id = event_id
        raise asyncio.CancelledError


def _committed(rid: str, *, correlated: bool = True, previous_event_id: str | None = None) -> dict:
    """A scripted ``input_text.committed``. ``correlated`` marks it as the ack for
    the commit just sent (its ``previous_event_id`` is rewritten to the real id);
    otherwise it carries an unrelated/stale ``previous_event_id``."""
    ev: dict = {"type": P.EVT_TEXT_COMMITTED, "response_id": rid}
    ev["previous_event_id"] = _MATCH if correlated else previous_event_id
    return ev


def _error_frame(
    *,
    correlated: bool = True,
    previous_event_id: str | None = None,
    nested: bool = False,
    code: str = "busy",
) -> dict:
    """A scripted top-level ``error``. ``correlated`` marks it as the reply to the
    commit just sent. ``nested=True`` puts the correlation id only in
    ``error.event_id`` (the older-server shape the adapter falls back to)."""
    err: dict = {"code": code, "message": "x"}
    ev: dict = {"type": P.EVT_ERROR, "error": err}
    if nested:
        err["event_id"] = _MATCH if correlated else previous_event_id
    else:
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


# --- error correlation (adversarial-review: stale error frame) ----------------
# A generic ``error`` is command-scoped. The adapter correlates it to the commit
# it sent (top-level ``previous_event_id``, falling back to nested
# ``error.event_id``). A stale error from a PRIOR command must not abort this
# utterance; an error for THIS command must surface.


async def test_stale_error_does_not_terminate_new_utterance():
    client = _FakeClient(
        [
            _error_frame(correlated=False, previous_event_id="old-commit-evt", code="busy"),
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new", pcm=b"\x04\x00"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert not any(isinstance(f, ErrorFrame) for f in frames)
    audio = [f for f in frames if isinstance(f, TTSAudioRawFrame)]
    assert len(audio) == 1 and audio[0].audio == b"\x04\x00"
    assert client.cancels == [], "a stale error must not trigger a cancel"


async def test_stale_error_via_nested_event_id_is_ignored():
    # Older-server shape: correlation only in nested error.event_id. A stale one
    # must still be skipped via the fallback.
    client = _FakeClient(
        [
            _error_frame(correlated=False, previous_event_id="old-commit-evt", nested=True),
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new", pcm=b"\x05\x00"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert not any(isinstance(f, ErrorFrame) for f in frames)
    assert len([f for f in frames if isinstance(f, TTSAudioRawFrame)]) == 1


async def test_correlated_error_surfaces_and_cancels():
    # An error for THIS commit must surface as an ErrorFrame and cancel (the error
    # may be non-terminal server-side, so we stop the backend before breaking).
    client = _FakeClient(
        [
            _committed("new"),
            _error_frame(correlated=True, code="internal"),
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert any(isinstance(f, ErrorFrame) for f in frames)
    assert client.cancels, "a correlated error must cancel the in-flight response"


# --- cancellation during commit (adversarial-review finding #2) ---------------
# A barge-in that cancels the run_tts task DURING the commit (before any event is
# read) must still cancel the server-side response, not exit silently and leave it
# synthesizing with no reader.


async def test_cancel_during_commit_still_cancels_server_side():
    client = _CancelOnCommitClient(events=[])
    svc = _service()
    _wire_for_run_tts(svc, client)

    with pytest.raises(asyncio.CancelledError):
        await _drain_run_tts(svc)

    # The widened try routed the CancelledError through the cancel handler.
    assert client.cancels == [None], "cancel during commit must still send response.cancel"


# --- dirty-buffer cleanup (adversarial-review: stale text leak) ----------------
# The server consumes the text buffer ONLY when a commit is admitted. If a commit
# is rejected pre-admission (BUSY/payload_too_large), or the task is cancelled
# after ``append`` but before an admitted commit, the appended text stays buffered
# on the persistent connection. ``response.cancel`` targets a *response*, never the
# buffer, so the adapter must send ``input_text.clear`` on those paths — otherwise
# the orphaned text is synthesized as part of the NEXT, unrelated utterance.


async def test_busy_rejection_clears_dirty_buffer():
    # A pre-admission BUSY rejection: the server left our appended text in the
    # buffer for a retry the adapter will not make. The adapter must clear it, not
    # send a no-op response.cancel against a response that was never registered.
    client = _FakeClient([_error_frame(correlated=True, code="busy")])
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert any(isinstance(f, ErrorFrame) for f in frames)
    assert client.clears == 1, "a pre-admission rejection must clear the dirty buffer"
    assert client.cancels == [], "no response exists to cancel before admission"


async def test_cancel_before_commit_clears_dirty_buffer():
    # CancelledError raised from commit() models a barge-in after ``append`` reached
    # the server but before the commit was admitted: the buffer holds our text with
    # no response registered. The adapter must clear it (and still send the cancel,
    # which targets the response if the commit happened to land after all).
    client = _CancelOnCommitClient(events=[])
    svc = _service()
    _wire_for_run_tts(svc, client)

    with pytest.raises(asyncio.CancelledError):
        await _drain_run_tts(svc)

    assert client.cancels == [None], "cancel must still target any registered response"
    assert client.clears == 1, "uncommitted text must be cleared so it cannot leak"


async def test_admitted_error_cancels_not_clears():
    # An error AFTER our commit was admitted: a response is in flight and the buffer
    # is already empty server-side. The adapter must cancel the response (it may be
    # non-terminal server-side) and must NOT send a redundant clear.
    client = _FakeClient([_committed("new"), _error_frame(correlated=True, code="internal")])
    svc = _service()
    _wire_for_run_tts(svc, client)

    frames = await _drain_run_tts(svc)

    assert any(isinstance(f, ErrorFrame) for f in frames)
    assert client.cancels, "an admitted in-flight error must cancel the response"
    assert client.clears == 0, "buffer already consumed by admission; no clear owed"


async def test_successful_run_does_not_clear_buffer():
    # The happy path consumes the buffer via admission; no clear must be sent.
    client = _FakeClient(
        [
            _committed("new"),
            {"type": P.EVT_RESPONSE_CREATED, "response_id": "new"},
            _audio_delta("new"),
            {"type": P.EVT_RESPONSE_AUDIO_DONE, "response_id": "new"},
        ]
    )
    svc = _service()
    _wire_for_run_tts(svc, client)

    await _drain_run_tts(svc)

    assert client.clears == 0, "an admitted, fully-drained commit owes no buffer clear"


# --- private-attr rate override guard (adversarial-review: version skew) -------
# pipecat's TTSService.sample_rate is a read-only property; the adapter overrides
# the private ``_sample_rate`` backing field to apply the server-advertised rate.
# A future pipecat that renames/removes that field would make the write silently
# land on a dead attribute (wrong playback rate, no error). The override must fail
# LOUDLY instead — and must still work on the pinned/tested pipecat.


async def test_update_sample_rate_applies_on_supported_pipecat():
    svc = _service()
    svc._update_sample_rate(24000)
    assert svc.sample_rate == 24000, "override must drive the public sample_rate property"


async def test_update_sample_rate_raises_if_private_field_removed():
    svc = _service()
    # Simulate a pipecat version that no longer exposes the backing field.
    del svc._sample_rate
    with pytest.raises(RuntimeError, match="_sample_rate"):
        svc._update_sample_rate(24000)
