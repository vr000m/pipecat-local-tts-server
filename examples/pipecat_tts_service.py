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
            await client.cancel(response_id=self._current_response_id)
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

        try:
            await client.append(text)
            await client.commit(extras=self._params.to_extras() or None)
        except Exception as exc:  # send-side failure before any audio
            yield ErrorFrame(error=f"tts_server commit failed: {exc}")
            yield TTSStoppedFrame(context_id=context_id)
            return

        await self.start_tts_usage_metrics(text)

        started_audio = False
        try:
            async for ev in client.events():
                kind = ev.get("type")
                if kind == P.EVT_RESPONSE_CREATED:
                    self._current_response_id = ev.get("response_id")
                elif kind == P.EVT_TEXT_COMMITTED:
                    self._current_response_id = ev.get("response_id", self._current_response_id)
                elif kind == P.EVT_RESPONSE_AUDIO_DELTA:
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
                elif kind in (P.EVT_ERROR, P.EVT_RESPONSE_FAILED):
                    yield ErrorFrame(error=f"tts_server {kind}: {ev!r}")
                    break
                # Ignore other event types (session.*, server.status).
        except asyncio.CancelledError:
            # Pipeline cancelled the run_tts task (interruption). Tell the server
            # to stop synthesizing so it does not pin the model lock.
            await self._send_cancel()
            raise
        finally:
            self._current_response_id = None

        yield TTSStoppedFrame(context_id=context_id)
