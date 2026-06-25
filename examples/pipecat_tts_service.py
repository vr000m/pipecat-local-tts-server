#!/usr/bin/env python3
"""Reference Pipecat-framework TTS service adapter for pipecat-local-tts-server.

This wraps the packaged async :class:`tts_server.client.TTSClient` (R5) and exposes
it as a Pipecat :class:`~pipecat.services.tts_service.TTSService` so a bot pipeline
can speak through a *local* WebSocket TTS server (text in, audio out) instead of a
cloud TTS provider. It is the framework-aware sibling of the stdlib oracle
``examples/reference_client.py``: that one is for protocol smoke-tests with no
Pipecat dependency; this one drops into a real ``Pipeline``.

What it does, mapped onto the wire protocol (``docs/protocol.md``):

- ``run_tts(text, context_id)`` runs one ``input_text.append`` + ``input_text.commit``
  cycle and drains the resulting ``response.audio.delta`` frames, yielding each as a
  :class:`~pipecat.frames.frames.TTSAudioRawFrame` (int16-LE mono PCM) wrapped between
  :class:`~pipecat.frames.frames.TTSStartedFrame` / ``TTSStoppedFrame``.
- **Barge-in** (an upstream :class:`~pipecat.frames.frames.InterruptionFrame`, or a
  pipeline ``CancelFrame``) sends ``response.cancel`` to the server so a cancelled
  response stops pinning the model's GPU lock.

**The rate contract (R1).** The server advertises its true model rate in
``server.hello.audio.rate`` (Kokoro = 24000) and every ``response.audio.delta`` is
int16-LE mono PCM at *exactly* that rate. This adapter surfaces that exact rate to
Pipecat by reading the handshake at connect time and configuring the base
``TTSService`` sample rate from it — Pipecat's output transport resamples downstream
to the device rate. Do NOT hard-code a different rate; a wrong rate pitch/speed-distorts
playback.

**Kokoro cancellation caveat.** Kokoro is ``streaming: false`` and yields one segment
per ``\\n+`` boundary, so cancel only takes effect at the next segment yield. A *long
single-segment* commit cannot be cancelled until ``generate()`` finishes (measured
~tens of seconds on Apple Silicon). For prompt barge-in, let Pipecat's sentence
aggregation feed sentence-sized text (the default ``TextAggregationMode.SENTENCE``), or
chunk at newlines upstream. The server's hard guarantee is only "no more audio after
``response.cancelled``".

Requires the Pipecat framework (not a dependency of this repo's server or lean client)::

    pip install pipecat-ai
    # or, from this repo, the optional examples extra:
    uv sync --extra examples

Usage (sketch — drop into a bot pipeline)::

    from examples.pipecat_tts_service import LocalTTSService

    tts = LocalTTSService(
        socket_path="~/Library/Caches/pipecat-tts/tts.sock",
        voice="af_heart",          # optional; server default otherwise
        language="en",             # optional ISO code
        params=LocalTTSService.InputParams(speed=1.1),  # Kokoro 'speed' extra
    )
    pipeline = Pipeline([..., llm, tts, transport.output(), ...])

The endpoint is selected exactly like ``TTSClient``: ``uri`` > ``socket_path`` >
``host`` + ``port``. A bearer token (``$TTS_WS_TOKEN`` or ``auth_token=``) is forwarded
when the server requires auth.
"""

from __future__ import annotations

import asyncio
import base64
import uuid
from dataclasses import dataclass
from typing import Any, AsyncGenerator

from pipecat.frames.frames import (
    CancelFrame,
    EndFrame,
    ErrorFrame,
    Frame,
    InterruptionFrame,
    StartFrame,
    TTSAudioRawFrame,
    TTSStartedFrame,
    TTSStoppedFrame,
)
from pipecat.processors.frame_processor import FrameDirection
from pipecat.services.tts_service import TTSService

from tts_server import protocol as P
from tts_server.client import TTSClient

# int16-LE mono — pinned by the wire protocol (R1). The server NEVER emits any
# other format; the only variable is the rate, taken from the handshake.
_NUM_CHANNELS = 1


class LocalTTSService(TTSService):
    """Pipecat TTS service backed by a local ``pipecat-local-tts-server`` instance.

    Subclasses the standard :class:`~pipecat.services.tts_service.TTSService` (not the
    websocket-reconnect ``InterruptibleTTSService`` base, which is built for cloud
    providers with their own session lifecycle): here each ``run_tts`` call is one
    self-contained ``append`` + ``commit`` + drain over the persistent ``TTSClient``
    connection, and interruption is signalled to the server with ``response.cancel``.
    """

    @dataclass
    class InputParams:
        """Per-backend ``extras`` (validated server-side against
        ``capabilities.extras``; unknown keys are dropped, never errored). For
        Kokoro the only effective extra is ``speed``."""

        speed: float | None = None

        def to_extras(self) -> dict[str, Any]:
            return {k: v for k, v in {"speed": self.speed}.items() if v is not None}

    def __init__(
        self,
        *,
        socket_path: str | None = None,
        host: str | None = None,
        port: int | None = None,
        uri: str | None = None,
        auth_token: str | None = None,
        voice: str | None = None,
        language: str | None = None,
        params: "LocalTTSService.InputParams | None" = None,
        sample_rate: int | None = None,
        **kwargs: Any,
    ) -> None:
        # push_stop_frames lets the base class emit TTSStoppedFrame on idle, but we
        # also emit an explicit TTSStoppedFrame per response.audio.done so the
        # downstream knows the utterance ended even between commits.
        super().__init__(sample_rate=sample_rate, **kwargs)
        self._client_kwargs: dict[str, Any] = {
            "socket_path": socket_path,
            "host": host,
            "port": port,
            "uri": uri,
            "auth_token": auth_token,
        }
        self._voice = voice
        self._language = language
        self._params = params or self.InputParams()
        self._client: TTSClient | None = None
        # The rate the server actually advertised in server.hello (R1). Learned at
        # connect; surfaced to the base TTSService via _update_sample_rate.
        self._server_rate: int | None = None
        # response_id of the in-flight commit, so a barge-in cancels precisely.
        self._current_response_id: str | None = None

    def can_generate_metrics(self) -> bool:
        """This service reports TTFB and TTS usage metrics."""
        return True

    # --- pipeline lifecycle ------------------------------------------------
    async def start(self, frame: StartFrame) -> None:
        await super().start(frame)
        await self._connect()

    async def stop(self, frame: EndFrame) -> None:
        await super().stop(frame)
        await self._disconnect()

    async def cancel(self, frame: CancelFrame) -> None:
        await super().cancel(frame)
        await self._disconnect()

    async def _connect(self) -> None:
        if self._client is not None:
            return
        client = TTSClient(**self._client_kwargs)
        hello = await client.connect()
        self._client = client

        audio = hello.get("audio") or {}
        rate = int(audio.get("rate") or 0)
        if rate <= 0:
            raise RuntimeError(f"server.hello did not advertise a usable rate: {audio!r}")
        self._server_rate = rate
        # Surface the server's exact model rate to the base TTSService so the
        # output transport resamples off the correct value (the rate contract,
        # R1). The base class exposes the resolved rate as self.sample_rate.
        self._update_sample_rate(rate)

        # Apply session-level voice/language/extras once, if set.
        extras = self._params.to_extras()
        if self._voice is not None or self._language is not None or extras:
            await client.update(
                voice=self._voice,
                language=self._language,
                extras=extras or None,
            )
            # Synchronously consume the ack HERE, before any commit can be sent.
            # The server answers session.update with session.created/updated
            # (success) or an error (e.g. INVALID_CONFIG for a bad voice). If we
            # left it unread, run_tts would send append+commit first and only
            # then read events — surfacing a stale config error AFTER a commit is
            # already synthesizing, so the adapter would break and abandon a live
            # response (no drain, no cancel), pinning the backend/Metal lock.
            await self._await_update_ack(client)

    async def _await_update_ack(self, client: TTSClient) -> None:
        """Read events until the session.update ack (success) or an error.

        Raises ``RuntimeError`` on a rejected config so ``start()`` fails loudly
        instead of silently proceeding with an unapplied voice/language/extras.
        """
        async for ev in client.events():
            kind = ev.get("type")
            if kind in (P.EVT_SESSION_UPDATED, P.EVT_SESSION_CREATED):
                return
            if kind in (P.EVT_ERROR, P.EVT_RESPONSE_FAILED):
                raise RuntimeError(f"server rejected session.update: {ev!r}")
            # No other event precedes the ack on a fresh session; ignore defensively.
        raise RuntimeError("connection closed before session.update was acknowledged")

    async def _disconnect(self) -> None:
        client = self._client
        self._client = None
        self._current_response_id = None
        if client is not None:
            try:
                await client.close()
            except Exception:
                pass

    def _update_sample_rate(self, rate: int) -> None:
        """Point the base TTSService at the server-advertised rate.

        The base class stores the negotiated output rate in ``self._sample_rate``
        (exposed via the ``sample_rate`` property). We set it directly here because
        the rate is only known after the handshake, which happens after ``start()``
        has already resolved a provisional rate.
        """
        # FRAGILE: depends on a private attribute of pipecat's TTSService
        # (``self._sample_rate``), verified against pipecat-ai as tested for this
        # example. Pipecat could rename/relocate it without a semver bump — re-check
        # this assignment (and prefer a public set-rate hook if one is added) when
        # bumping the pipecat dependency.
        self._sample_rate = rate

    # --- interruption / barge-in ------------------------------------------
    async def process_frame(self, frame: Frame, direction: FrameDirection) -> None:
        await super().process_frame(frame, direction)
        if isinstance(frame, InterruptionFrame):
            await self._send_cancel()

    async def _send_cancel(self) -> None:
        client = self._client
        if client is None:
            return
        try:
            # K=1 in v1 → response_id is optional and unambiguous, but send it
            # when we have it so the intent is explicit.
            #
            # Timing note: an InterruptionFrame that arrives in the narrow window
            # between sending ``commit`` and reading the first
            # ``response.created``/``input_text.committed`` event finds
            # ``_current_response_id`` still None and sends a bare cancel. If the
            # server has not yet registered the response, that bare cancel is a
            # no-op and audio for this commit may still stream. This is an
            # accepted K=1 limitation: the pipeline's ``CancelledError`` path in
            # ``run_tts`` also issues a cancel, and a subsequent InterruptionFrame
            # will carry the now-known id. For prompt barge-in, feed
            # sentence-sized text (see the module docstring's cancellation caveat).
            await client.cancel(response_id=self._current_response_id)
        except Exception:
            pass

    async def _drop_buffer(self) -> None:
        """Best-effort ``input_text.clear`` of any uncommitted server-side text.

        Sent when a ``run_tts`` appended text that was never consumed by an
        *admitted* commit — cancelled before the commit, or a pre-admission
        rejection (e.g. ``BUSY``, ``payload_too_large``) where the server
        deliberately leaves the buffer intact for retry. ``response.cancel``
        cannot help here: it targets a *response*, and no response was registered,
        so the appended text would otherwise stay buffered on the persistent
        connection and be synthesized as part of the NEXT, unrelated utterance.

        Fire-and-forget: the server processes a connection's frames in order, so
        this clear is guaranteed to land before the next ``run_tts``'s
        ``input_text.append``; we needn't await the ``input_text.cleared`` ack
        (the next event loop ignores it as an unhandled type). Swallows errors —
        on a broken connection the session and its buffer are already gone.
        """
        client = self._client
        if client is None:
            return
        try:
            await client.clear()
        except Exception:
            pass

    # --- synthesis ---------------------------------------------------------
    async def run_tts(self, text: str, context_id: str) -> AsyncGenerator[Frame | None, None]:
        """Synthesize ``text`` as one commit and yield its audio frames.

        Yields ``TTSStartedFrame`` → ``TTSAudioRawFrame``* → ``TTSStoppedFrame`` for a
        normal response, or an ``ErrorFrame`` if the server reports ``error`` /
        ``response.failed``. Frames carry ``context_id`` so Pipecat's audio-context
        machinery can attribute and interrupt them.
        """
        if not text.strip():
            return
        if self._client is None:
            await self._connect()
        client = self._client
        assert client is not None
        assert self._server_rate is not None

        await self.start_ttfb_metrics()
        yield TTSStartedFrame(context_id=context_id)

        # Correlate THIS commit with its ack. The server echoes a client-supplied
        # ``event_id`` as ``previous_event_id`` on the matching
        # ``input_text.committed`` (and on any ``error`` that rejects the commit).
        # We learn ``_current_response_id`` ONLY from that correlated committed —
        # never from whichever committed/created frame happens to arrive first on
        # a persistent connection. See the gating comment below for why.
        commit_event_id = uuid.uuid4().hex
        started_audio = False
        # Whether the server admitted THIS commit (we read our correlated
        # ``input_text.committed``). False ⇔ the server buffer may still hold the
        # text we appended (commit not yet admitted, or rejected pre-admission),
        # which must be cleared on any exit so it cannot leak into the next commit.
        commit_admitted = False
        # ONE try spans the commit AND the drain so a cancellation anywhere from
        # the commit onward (barge-in / teardown) reaches the cancel handler. The
        # bare cancel it sends travels the SAME connection AFTER the commit, and the
        # server processes a connection's frames in order, so by then the response
        # is registered and gets cancelled (K=1 ⇒ unambiguous). Previously the
        # commit had its own try; a cancel raised during/just after it skipped
        # cleanup and exited without cancelling, leaving the registered response to
        # synthesize with no reader and pin the backend/Metal lock.
        try:
            try:
                await client.append(text)
                await client.commit(
                    extras=self._params.to_extras() or None,
                    event_id=commit_event_id,
                )
            except Exception as exc:  # send-side failure before any audio
                # ``append`` may have reached the server before ``commit`` failed,
                # leaving uncommitted text in the buffer. Best-effort clear so it
                # cannot leak into the next utterance; on a broken connection this
                # is a harmless no-op (the session and its buffer are already gone).
                await self._drop_buffer()
                yield ErrorFrame(error=f"tts_server commit failed: {exc}")
                yield TTSStoppedFrame(context_id=context_id)
                return

            await self.start_tts_usage_metrics(text)

            async for ev in client.events():
                kind = ev.get("type")
                if kind == P.EVT_TEXT_COMMITTED:
                    # Adopt the response id ONLY from the committed ack that
                    # correlates to the commit we just sent. A *prior* cancelled
                    # response can leave its own ``input_text.committed(old)`` /
                    # ``response.created(old)`` / ``response.cancelled(old)``
                    # buffered on the socket ahead of our ack. Trusting the first
                    # committed/created would set ``_current_response_id = old``,
                    # then the stale ``response.cancelled(old)`` would look current
                    # and terminate THIS utterance — leaving the new commit
                    # synthesizing with no reader (pinning the backend/Metal lock),
                    # the exact corruption this guard exists to prevent.
                    if ev.get("previous_event_id") == commit_event_id:
                        self._current_response_id = ev.get("response_id")
                        # Server consumed our buffer and registered the response;
                        # buffer is now empty, so no clear is owed on exit.
                        commit_admitted = True
                    # else: a stale committed for a prior response — ignore it.
                elif kind in (
                    P.EVT_RESPONSE_CREATED,
                    P.EVT_RESPONSE_AUDIO_DELTA,
                    P.EVT_RESPONSE_AUDIO_DONE,
                    P.EVT_RESPONSE_CANCELLED,
                    P.EVT_RESPONSE_FAILED,
                ):
                    # Gate every response-scoped event by response_id. Until our
                    # correlated committed has set ``_current_response_id``, ANY
                    # response frame is stale (it belongs to a prior response); once
                    # set, only frames carrying our id are ours. ``response.created``
                    # has no ``previous_event_id`` to correlate on, so it is gated
                    # the same way (and only confirms the id we already learned).
                    rid = ev.get("response_id")
                    if self._current_response_id is None or (
                        rid is not None and rid != self._current_response_id
                    ):
                        continue
                    if kind == P.EVT_RESPONSE_CREATED:
                        continue  # confirms our id; no action needed.
                    if kind == P.EVT_RESPONSE_AUDIO_DELTA:
                        pcm = base64.b64decode(ev["audio"])
                        if not pcm:
                            continue
                        if not started_audio:
                            await self.stop_ttfb_metrics()
                            started_audio = True
                        yield TTSAudioRawFrame(
                            audio=pcm,
                            sample_rate=self._server_rate,
                            num_channels=_NUM_CHANNELS,
                        )
                    elif kind == P.EVT_RESPONSE_AUDIO_DONE:
                        break
                    elif kind == P.EVT_RESPONSE_CANCELLED:
                        # Barge-in took effect; no further audio for this response.
                        break
                    else:  # EVT_RESPONSE_FAILED for THIS response — terminal.
                        yield ErrorFrame(error=f"tts_server {kind}: {ev!r}")
                        break
                elif kind == P.EVT_ERROR:
                    # A generic ``error`` is command-scoped, not response-scoped.
                    # If it correlates to a PRIOR command (its id is set and not
                    # ours), it is stale — skip it, else a stale BUSY/invalid_config
                    # error from an earlier commit on this persistent connection
                    # would abort our freshly-committed response. The correlation id
                    # is the top-level ``previous_event_id`` (newer servers); fall
                    # back to the nested ``error.event_id`` for older ones.
                    prev = ev.get("previous_event_id")
                    if prev is None and isinstance(ev.get("error"), dict):
                        prev = ev["error"].get("event_id")
                    if prev is not None and prev != commit_event_id:
                        continue
                    # Ours (or uncorrelated/connection-level), and not retried here.
                    # The cleanup depends on whether our commit was ever admitted:
                    #   - admitted (response in flight): an ``error`` is not
                    #     necessarily terminal server-side (unlike
                    #     ``response.failed``), so cancel before breaking — else we
                    #     stop draining while the server keeps synthesizing for a
                    #     reader that is gone, pinning the lock.
                    #   - NOT admitted (a pre-admission rejection such as ``BUSY``
                    #     or ``payload_too_large``): there is no response to cancel,
                    #     and the server left our appended text in the buffer for a
                    #     retry we will not make. Clear it so it cannot be
                    #     synthesized as part of the next utterance.
                    if commit_admitted:
                        await self._send_cancel()
                    else:
                        await self._drop_buffer()
                    yield ErrorFrame(error=f"tts_server {kind}: {ev!r}")
                    break
                # Ignore other event types (session.*, server.status).
        except asyncio.CancelledError:
            # Pipeline cancelled the run_tts task (interruption) — possibly during
            # the commit, before any event was read. Tell the server to stop
            # synthesizing so it does not pin the model lock; the cancel is ordered
            # after our commit on this connection, so it reliably targets the
            # registered response even when we never learned its id.
            await self._send_cancel()
            # If the commit was never admitted, the cancellation may have landed
            # after ``append`` but before (or without) an admitted commit, leaving
            # our text uncommitted in the server buffer. Drop it so it cannot be
            # synthesized into the next utterance. Ordered AFTER the cancel on this
            # connection: if the commit actually did land, the cancel still targets
            # the response and this clear is a no-op on the now-empty buffer.
            if not commit_admitted:
                await self._drop_buffer()
            raise
        finally:
            self._current_response_id = None

        yield TTSStoppedFrame(context_id=context_id)
