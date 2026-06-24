"""WebSocket server runtime for the local TTS service.

Lifecycle summary:

- TCP or Unix-socket listener, accepting one WebSocket per synthesis session.
- On connect: complete ``backend.start()`` (model load) FIRST so the rate is
  known, then send ``server.hello`` (connect -> load -> hello), then mint
  ``session_id`` and send ``session.created``. The load-before-hello ordering is
  a dependency edge stt does not have: TTS rate comes from the loaded model.
- Text frames parsed as JSON control events. (TTS has no binary client path in
  v1 — text in, audio out.)
- ``input_text.commit`` allocates a ``response_id``, emits
  ``input_text.committed`` + ``response.created``, and runs the **drain loop in a
  tracked asyncio task** (NOT inline in the recv loop) so ``response.cancel`` /
  ``session.*`` stay serviceable while synthesis runs.
- The drain loop emits each segment's audio as it lands (steady streaming, R4),
  re-chunked to fixed 20 ms wire frames. ``seq`` starts at 0 and increments by 1
  with no gaps per ``response_id``.
- ``response.cancel`` sets a cancel flag, cancels the stream, and emits
  ``response.cancelled``; no further ``delta`` follows.

**This streaming seam is net-new, not an stt mirror.** stt blocks ``end()``
until full synthesis and replays a stored result; that is the anti-pattern here.

Deferred to Phase 3 (architected for, not built here): auth enforcement,
resource-limit caps, and synthesis-backlog backpressure caps (``BUSY``).
"""

from __future__ import annotations

import asyncio
import base64
import json
import logging
import os
import signal
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Awaitable, Callable

import websockets
from websockets.asyncio.server import (
    Server,
    ServerConnection,
    serve as ws_serve,
    unix_serve as ws_unix_serve,
)

from . import protocol as P
from .backend import TTSBackend, TTSStream, ToneBackend
from .env import is_loopback_host

logger = logging.getLogger("tts_server")


def _event_id() -> str:
    return f"evt_{uuid.uuid4().hex[:16]}"


def _session_id() -> str:
    return f"session_{uuid.uuid4().hex[:16]}"


def _response_id() -> str:
    return f"resp_{uuid.uuid4().hex[:16]}"


@dataclass
class ServerConfig:
    """Transport and policy configuration for ``TTSServer``."""

    socket_path: str | None = None
    host: str | None = None
    port: int | None = None
    auth_token: str | None = None
    reject_browser_origins: bool = True
    send_queue_high_water_bytes: int = P.SEND_QUEUE_HIGH_WATER_BYTES
    drain_timeout_seconds: float = P.SHUTDOWN_DRAIN_TIMEOUT_SECONDS
    # chmod applied to the UDS after bind. 0o600 restricts connect to the owning
    # user; the UDS is the v1 trust boundary.
    unix_socket_mode: int | None = 0o600

    def __post_init__(self) -> None:
        if self.socket_path is None and (self.host is None or self.port is None):
            raise ValueError("ServerConfig requires socket_path or host+port")


@dataclass
class _Response:
    """One in-flight (or just-finished) synthesis response."""

    response_id: str
    stream: TTSStream | None = None
    task: asyncio.Task | None = None
    cancelled: bool = False


@dataclass
class _SessionState:
    """Per-connection state. No shared mutable session state lives outside this
    object — one connection's text/synthesis can never pollute another's
    (mirrors stt's per-connection isolation, R4)."""

    session_id: str
    # voice/language/extras config set via ``session.update``.
    config: dict = field(default_factory=dict)
    # Uncommitted text buffer (consumed by a commit).
    buffer: str = ""
    # The active response. v1 K=1: at most one active/queued response per
    # connection, which keeps ``response.cancel`` unambiguous without a
    # ``response_id``.
    response: _Response | None = None
    session_created_sent: bool = False
    closed: bool = False
    started_monotonic: float = field(default_factory=time.monotonic)
    # Serializes ALL outbound writes: the recv loop and the drain task both
    # produce frames, so a single lock keeps a single component touching the
    # socket at a time.
    write_lock: asyncio.Lock = field(default_factory=asyncio.Lock)


class TTSServer:
    """Owns the listener and lifecycle for in-process WebSocket sessions."""

    def __init__(self, backend: TTSBackend, config: ServerConfig) -> None:
        self._backend = backend
        self._config = config
        self._server: Server | None = None
        self._active_handlers: set[asyncio.Task] = set()
        self._active_drains: set[asyncio.Task] = set()
        self._shutdown_event = asyncio.Event()
        self._started = False

    # --- lifecycle ---
    async def start(self) -> None:
        if self._started:
            return
        # connect -> load -> hello: the backend must be loaded before the first
        # ``server.hello`` because the rate comes from the loaded model.
        await self._backend.start()
        if self._config.socket_path:
            socket_path = Path(self._config.socket_path)
            socket_path.parent.mkdir(parents=True, exist_ok=True)
            prior_umask = os.umask(0o077)
            try:
                self._server = await ws_unix_serve(
                    self._handle_connection,
                    path=str(socket_path),
                    process_request=self._process_request,
                )
            finally:
                os.umask(prior_umask)
            if self._config.unix_socket_mode is not None:
                try:
                    os.chmod(socket_path, self._config.unix_socket_mode)
                except OSError as exc:
                    logger.warning("tts_server: chmod on UDS failed: %s", exc)
        else:
            self._server = await ws_serve(
                self._handle_connection,
                host=self._config.host,
                port=self._config.port,
                process_request=self._process_request,
            )
        self._started = True
        logger.info(
            "tts_server listening on %s (backend=%s model=%s rate=%s)",
            self._config.socket_path or f"{self._config.host}:{self._config.port}",
            self._backend.backend_name,
            self._backend.model,
            self._backend.sample_rate,
        )
        # Cleartext-remote guard: a token-less TCP listener bound to a
        # non-loopback address is reachable in the clear. Make the gap loud.
        if (
            self._config.socket_path is None
            and not self._config.auth_token
            and not is_loopback_host(self._config.host)
        ):
            logger.warning(
                "tts_server: TCP listener bound to non-loopback %s:%s without an "
                "auth token; any host that can reach it can connect. Set "
                "PIPECAT_TTS_AUTH_TOKEN for any non-experimental deployment.",
                self._config.host,
                self._config.port,
            )

    @property
    def sockets_bound(self) -> list:
        if self._server is None:
            return []
        return list(self._server.sockets or [])

    def listening_port(self) -> int | None:
        for s in self.sockets_bound:
            try:
                return s.getsockname()[1]
            except Exception:
                continue
        return None

    async def wait_closed(self) -> None:
        if self._server is not None:
            await self._server.wait_closed()

    async def shutdown(self) -> None:
        if not self._started:
            return
        if self._shutdown_event.is_set():
            while self._started:
                await asyncio.sleep(0)
            return
        self._shutdown_event.set()
        if self._server is not None:
            self._server.close(close_connections=True)
        pending = list(self._active_handlers | self._active_drains)
        if pending:
            try:
                await asyncio.wait_for(
                    asyncio.gather(*pending, return_exceptions=True),
                    timeout=self._config.drain_timeout_seconds,
                )
            except asyncio.TimeoutError:
                for t in pending:
                    if not t.done():
                        t.cancel()
                await asyncio.gather(*pending, return_exceptions=True)
        if self._server is not None:
            await self._server.wait_closed()
        await self._backend.close()
        self._started = False

    # --- connection handling ---
    async def _process_request(self, connection, request):
        headers = request.headers
        origin = headers.get("Origin")
        if self._config.reject_browser_origins and origin:
            return connection.respond(403, "origin not permitted\n")
        # NOTE: auth *enforcement* is deferred to Phase 3 per the plan. The
        # cleartext-remote warning above is the Phase-1 deliverable.
        return None

    async def _handle_connection(self, ws: ServerConnection) -> None:
        task = asyncio.current_task()
        assert task is not None
        self._active_handlers.add(task)
        state = _SessionState(session_id=_session_id())
        try:
            await self._send(
                ws,
                state,
                {
                    "type": P.EVT_SERVER_HELLO,
                    "event_id": _event_id(),
                    "protocol_version": P.PROTOCOL_VERSION,
                    "backend": {
                        "name": self._backend.backend_name,
                        "model": self._backend.model,
                    },
                    "audio": {
                        "format": P.AUDIO_FORMAT,
                        "rate": self._backend.sample_rate,
                        "channels": P.AUDIO_CHANNELS,
                    },
                    "capabilities": self._backend.capabilities(),
                },
            )
            async for raw in ws:
                if state.closed:
                    break
                if isinstance(raw, (bytes, bytearray)):
                    # TTS has no binary client path in v1.
                    await self._error(
                        ws, state, P.ErrorCode.INVALID_EVENT, "binary frames are not supported"
                    )
                    continue
                try:
                    await self._handle_text(ws, state, raw)
                except Exception:
                    logger.exception("tts_server: error handling message")
                    await self._error(ws, state, P.ErrorCode.INTERNAL_ERROR, "internal error")
        except websockets.exceptions.ConnectionClosed:
            pass
        finally:
            await self._teardown_session(state)
            self._active_handlers.discard(task)

    # --- message handlers ---
    async def _handle_text(self, ws: ServerConnection, state: _SessionState, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except json.JSONDecodeError as exc:
            await self._error(ws, state, P.ErrorCode.INVALID_JSON, str(exc))
            return
        if not isinstance(msg, dict) or "type" not in msg:
            await self._error(ws, state, P.ErrorCode.INVALID_EVENT, "missing type")
            return
        t = msg["type"]
        client_event_id = msg.get("event_id") if isinstance(msg.get("event_id"), str) else None
        if t not in P.CLIENT_EVENT_TYPES:
            await self._error(
                ws,
                state,
                P.ErrorCode.UNSUPPORTED_EVENT,
                f"unknown event: {t}",
                client_event_id=client_event_id,
            )
            return

        if t == P.EVT_SESSION_UPDATE:
            await self._on_session_update(ws, state, msg, client_event_id)
        elif t == P.EVT_TEXT_APPEND:
            await self._on_text_append(ws, state, msg, client_event_id)
        elif t == P.EVT_TEXT_COMMIT:
            await self._on_commit(ws, state, msg, client_event_id)
        elif t == P.EVT_TEXT_CLEAR:
            await self._on_clear(ws, state, client_event_id)
        elif t == P.EVT_RESPONSE_CANCEL:
            await self._on_response_cancel(ws, state, msg, client_event_id)
        elif t == P.EVT_SESSION_CANCEL:
            await self._on_session_cancel(ws, state)
        elif t == P.EVT_SESSION_CLOSE:
            await self._on_session_close(ws, state)
        elif t == P.EVT_SERVER_STATUS_REQ:
            await self._on_status(ws, state)

    def _validate_extras(self, extras: Any) -> tuple[dict, str | None]:
        """Filter ``extras`` against the backend's advertised set.

        Returns ``(validated, error_message)``. Unknown keys are DROPPED
        (debug-logged), never errored. An extra colliding with a fixed param
        (``voice``/``language``) is REJECTED before the ``**extras`` call (it
        would otherwise raise ``TypeError`` at the call site). A non-dict
        ``extras`` is rejected.
        """
        if extras is None:
            return {}, None
        if not isinstance(extras, dict):
            return {}, "extras must be an object"
        accepted = set(self._backend.capabilities().get("extras", []))
        fixed = {"voice", "language", "text", "lang_code"}
        validated: dict = {}
        for key, value in extras.items():
            if key in fixed:
                return {}, f"extra {key!r} collides with a fixed parameter"
            if key not in accepted:
                logger.debug("tts_server: dropping unknown extra %r", key)
                continue
            validated[key] = value
        return validated, None

    async def _on_session_update(
        self,
        ws: ServerConnection,
        state: _SessionState,
        msg: dict,
        client_event_id: str | None,
    ) -> None:
        # audio_format is strict: only the advertised pcm16-at-rate is accepted.
        # The field stays in the schema so a later binary-audio optimization has
        # a home, but v1 enforces a single format.
        audio_format = msg.get("audio_format")
        if audio_format is not None and audio_format != P.AUDIO_FORMAT:
            await self._error(
                ws,
                state,
                P.ErrorCode.UNSUPPORTED_FORMAT,
                f"only {P.AUDIO_FORMAT!r} at {self._backend.sample_rate} Hz is supported",
                client_event_id=client_event_id,
            )
            return

        extras_in = msg.get("extras")
        validated, err = self._validate_extras(extras_in)
        if err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, err, client_event_id=client_event_id
            )
            return

        for key in ("voice", "model", "language"):
            if key in msg and msg[key] is not None:
                state.config[key] = msg[key]
        if validated:
            merged = dict(state.config.get("extras") or {})
            merged.update(validated)
            state.config["extras"] = merged

        evt_type = P.EVT_SESSION_UPDATED if state.session_created_sent else P.EVT_SESSION_CREATED
        state.session_created_sent = True
        payload: dict[str, Any] = {
            "type": evt_type,
            "event_id": _event_id(),
            "session": self._session_snapshot(state),
        }
        if client_event_id:
            payload["previous_event_id"] = client_event_id
        await self._send(ws, state, payload)

    async def _on_text_append(
        self,
        ws: ServerConnection,
        state: _SessionState,
        msg: dict,
        client_event_id: str | None,
    ) -> None:
        text = msg.get("text")
        if not isinstance(text, str):
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_CONFIG,
                "input_text.append missing text",
                client_event_id=client_event_id,
            )
            return
        text_format = msg.get("text_format", P.TEXT_FORMAT_PLAIN)
        if text_format not in P.SUPPORTED_TEXT_FORMATS:
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_CONFIG,
                f"unsupported text_format {text_format!r}; only "
                f"{list(P.SUPPORTED_TEXT_FORMATS)} are supported",
                client_event_id=client_event_id,
            )
            return
        max_chars = self._backend.capabilities().get("max_text_chars")
        if isinstance(max_chars, int) and len(state.buffer) + len(text) > max_chars:
            await self._error(
                ws,
                state,
                P.ErrorCode.PAYLOAD_TOO_LARGE,
                f"buffered text would exceed max_text_chars ({max_chars})",
                client_event_id=client_event_id,
            )
            return
        state.buffer += text

    async def _on_commit(
        self,
        ws: ServerConnection,
        state: _SessionState,
        msg: dict,
        client_event_id: str | None,
    ) -> None:
        # commit has NO audio_format field in v1; sending one is an unknown-field
        # protocol error, not a format negotiation path.
        if "audio_format" in msg:
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_CONFIG,
                "input_text.commit has no audio_format field in v1",
                client_event_id=client_event_id,
            )
            return
        if not state.buffer:
            await self._error(
                ws,
                state,
                P.ErrorCode.BUFFER_EMPTY,
                "commit on empty buffer",
                client_event_id=client_event_id,
            )
            return
        # v1 K=1: reject a commit while a response is active. (Backpressure
        # *caps* / BUSY are Phase 3; this in-flight guard keeps K=1 honest now.)
        if state.response is not None and self._response_active(state.response):
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_EVENT,
                "commit while a response is in flight",
                client_event_id=client_event_id,
            )
            return

        # Per-commit overrides (voice/language/extras) layer over session config.
        extras_in = msg.get("extras")
        validated, err = self._validate_extras(extras_in)
        if err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, err, client_event_id=client_event_id
            )
            return
        voice = msg.get("voice", state.config.get("voice"))
        language = msg.get("language", state.config.get("language"))
        extras = dict(state.config.get("extras") or {})
        extras.update(validated)

        text = state.buffer
        state.buffer = ""
        rid = _response_id()
        response = _Response(response_id=rid)
        state.response = response

        committed: dict[str, Any] = {
            "type": P.EVT_TEXT_COMMITTED,
            "event_id": _event_id(),
            "response_id": rid,
        }
        if client_event_id:
            committed["previous_event_id"] = client_event_id
        await self._send(ws, state, committed)
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_RESPONSE_CREATED,
                "event_id": _event_id(),
                "response_id": rid,
            },
        )

        # Drain loop runs in a TRACKED TASK (not inline) so cancel/session.* are
        # serviceable while synthesis runs.
        drain = asyncio.create_task(
            self._run_drain(ws, state, response, text, voice, language, extras)
        )
        response.task = drain
        self._active_drains.add(drain)
        drain.add_done_callback(self._active_drains.discard)

    async def _on_clear(
        self,
        ws: ServerConnection,
        state: _SessionState,
        client_event_id: str | None,
    ) -> None:
        state.buffer = ""
        payload: dict[str, Any] = {"type": P.EVT_TEXT_CLEARED, "event_id": _event_id()}
        if client_event_id:
            payload["previous_event_id"] = client_event_id
        await self._send(ws, state, payload)

    async def _run_drain(
        self,
        ws: ServerConnection,
        state: _SessionState,
        response: _Response,
        text: str,
        voice: str | None,
        language: str | None,
        extras: dict,
    ) -> None:
        """The synthesis drain loop (the steady-stream contract, R4).

        Emits each segment's audio as it lands, re-chunked to fixed 20 ms wire
        frames. EOF comes from generator exhaustion (the ``completed`` event),
        never a flag. On exhaustion: flush the short tail, then
        ``response.audio.done`` with ``duration_ms`` from the ORIGINAL total
        sample count.
        """
        rid = response.response_id
        rate = self._backend.sample_rate
        bytes_per_frame = int(rate * P.FRAME_DURATION_MS / 1000) * P.AUDIO_SAMPLE_WIDTH_BYTES
        carry = bytearray()  # leftover < one frame, re-framed across segments
        total_samples = 0
        seq = 0
        stream: TTSStream | None = None
        try:
            stream = await self._backend.open_stream(voice=voice, language=language, extras=extras)
            response.stream = stream
            await stream.feed(text)
            # Non-blocking: signals end-of-input and kicks the worker. It must
            # NOT block until synthesis completes (the anti-pattern).
            await stream.end()
            async for ev in stream.events():
                if response.cancelled:
                    break
                if ev.kind == "delta" and ev.pcm:
                    total_samples += len(ev.pcm) // P.AUDIO_SAMPLE_WIDTH_BYTES
                    carry.extend(ev.pcm)
                    # Re-frame the FULL per-response stream so only the last
                    # frame is short — slice off whole 20 ms frames as they fill.
                    while len(carry) >= bytes_per_frame:
                        frame = bytes(carry[:bytes_per_frame])
                        del carry[:bytes_per_frame]
                        if response.cancelled:
                            break
                        await self._emit_delta(ws, state, rid, seq, frame)
                        seq += 1
                # ev.kind == "completed" is the EOF signal (generator exhaustion).
            if response.cancelled:
                return
            # Flush the short tail (NO silence padding).
            if carry:
                await self._emit_delta(ws, state, rid, seq, bytes(carry))
                seq += 1
            duration_ms = int(total_samples * 1000 / rate) if rate else 0
            await self._send(
                ws,
                state,
                {
                    "type": P.EVT_RESPONSE_AUDIO_DONE,
                    "event_id": _event_id(),
                    "response_id": rid,
                    "duration_ms": duration_ms,
                },
            )
        except asyncio.CancelledError:
            if stream is not None:
                try:
                    await stream.cancel()
                except Exception:
                    pass
            raise
        except Exception as exc:
            logger.exception("tts_server: backend synthesis failed")
            if not response.cancelled:
                await self._send(
                    ws,
                    state,
                    {
                        "type": P.EVT_RESPONSE_FAILED,
                        "event_id": _event_id(),
                        "response_id": rid,
                        "error": {
                            "type": P.ERROR_TYPE_FOR_CODE[P.ErrorCode.BACKEND_ERROR],
                            "code": P.ErrorCode.BACKEND_ERROR.value,
                            "message": "backend synthesis failed",
                        },
                    },
                    force=True,
                )
            _ = exc  # detail logged above; not echoed to the client
        finally:
            response.stream = None
            if state.response is response:
                state.response = None

    async def _emit_delta(
        self, ws: ServerConnection, state: _SessionState, rid: str, seq: int, frame: bytes
    ) -> None:
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_RESPONSE_AUDIO_DELTA,
                "event_id": _event_id(),
                "response_id": rid,
                "seq": seq,
                "audio": base64.b64encode(frame).decode("ascii"),
            },
        )

    async def _on_response_cancel(
        self,
        ws: ServerConnection,
        state: _SessionState,
        msg: dict,
        client_event_id: str | None,
    ) -> None:
        response = state.response
        target = msg.get("response_id")
        if response is None or (target is not None and target != response.response_id):
            # Nothing to cancel (or a stale id). Idempotent ack of the target.
            await self._send(
                ws,
                state,
                {
                    "type": P.EVT_RESPONSE_CANCELLED,
                    "event_id": _event_id(),
                    "response_id": target or (response.response_id if response else None),
                },
            )
            return
        await self._cancel_response(response)
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_RESPONSE_CANCELLED,
                "event_id": _event_id(),
                "response_id": response.response_id,
            },
        )

    async def _cancel_response(self, response: _Response) -> None:
        # Set the flag FIRST so the drain loop stops emitting deltas, then stop
        # the stream and unwind the task. No further ``delta`` after this.
        response.cancelled = True
        if response.stream is not None:
            try:
                await response.stream.cancel()
            except Exception:
                pass
        if response.task is not None and not response.task.done():
            response.task.cancel()
            try:
                await response.task
            except (asyncio.CancelledError, Exception):
                pass

    async def _on_session_cancel(self, ws: ServerConnection, state: _SessionState) -> None:
        # Discard semantics: drop uncommitted text and the in-flight response,
        # then close.
        if state.closed:
            return
        state.buffer = ""
        if state.response is not None:
            await self._cancel_response(state.response)
        state.closed = True
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_SESSION_CLOSED,
                "event_id": _event_id(),
                "session_id": state.session_id,
                "reason": "client_cancel",
            },
            force=True,
        )
        await ws.close()

    async def _on_session_close(self, ws: ServerConnection, state: _SessionState) -> None:
        # Drain semantics: let the in-flight response finish (bounded), then
        # close.
        if state.closed:
            return
        response = state.response
        if response is not None and response.task is not None and not response.task.done():
            if self._shutdown_event.is_set():
                response.task.cancel()
            else:
                try:
                    await asyncio.wait_for(
                        asyncio.shield(response.task),
                        timeout=self._config.drain_timeout_seconds,
                    )
                except asyncio.TimeoutError:
                    response.task.cancel()
                    try:
                        await response.task
                    except (asyncio.CancelledError, Exception):
                        pass
        state.closed = True
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_SESSION_CLOSED,
                "event_id": _event_id(),
                "session_id": state.session_id,
                "reason": "client_close",
            },
            force=True,
        )
        await ws.close()

    async def _on_status(self, ws: ServerConnection, state: _SessionState) -> None:
        active = state.response is not None and self._response_active(state.response)
        await self._send(
            ws,
            state,
            {
                "type": P.EVT_SERVER_STATUS,
                "event_id": _event_id(),
                "session_id": state.session_id,
                "backend": {
                    "name": self._backend.backend_name,
                    "model": self._backend.model,
                },
                "audio": {
                    "format": P.AUDIO_FORMAT,
                    "rate": self._backend.sample_rate,
                    "channels": P.AUDIO_CHANNELS,
                },
                "queue_depth": 1 if active else 0,
                "buffered_chars": len(state.buffer),
                "uptime_seconds": time.monotonic() - state.started_monotonic,
                "pid": os.getpid(),
            },
        )

    async def _teardown_session(self, state: _SessionState) -> None:
        if state.response is not None:
            await self._cancel_response(state.response)
        state.closed = True

    # --- helpers ---
    @staticmethod
    def _response_active(response: _Response) -> bool:
        return response.task is not None and not response.task.done()

    def _session_snapshot(self, state: _SessionState) -> dict[str, Any]:
        return {
            "id": state.session_id,
            "voice": state.config.get("voice"),
            "model": state.config.get("model"),
            "language": state.config.get("language"),
            "extras": dict(state.config.get("extras") or {}),
            "audio_format": P.AUDIO_FORMAT,
        }

    # --- send helpers ---
    async def _send(
        self,
        ws: ServerConnection,
        state: _SessionState,
        payload: dict,
        *,
        force: bool = False,
    ) -> None:
        # Serialize ALL outbound writes through one lock: the recv loop and the
        # drain task both produce frames.
        async with state.write_lock:
            # Outbound send-queue high-water guard: a slow *reader* must not let
            # the drain loop buffer unboundedly. ``force`` bypasses the check for
            # terminal events so teardown can still flush.
            if not force and not state.closed:
                pending = _pending_write_bytes(ws)
                if pending is not None and pending > self._config.send_queue_high_water_bytes:
                    logger.warning(
                        "tts_server: send-queue overflow (%d bytes pending), closing session %s",
                        pending,
                        state.session_id,
                    )
                    state.closed = True
                    try:
                        await ws.close(code=1011, reason="send_queue_overflow")
                    except Exception:
                        pass
                    return
            try:
                await ws.send(json.dumps(payload))
            except websockets.exceptions.ConnectionClosed:
                pass

    async def _error(
        self,
        ws: ServerConnection,
        state: _SessionState,
        code: P.ErrorCode,
        message: str,
        *,
        client_event_id: str | None = None,
        retry_after_ms: int | None = None,
    ) -> None:
        error_obj: dict[str, Any] = {
            "type": P.ERROR_TYPE_FOR_CODE.get(code, "server_error"),
            "code": code.value,
            "message": message,
        }
        if client_event_id:
            error_obj["event_id"] = client_event_id
        payload: dict[str, Any] = {
            "type": P.EVT_ERROR,
            "event_id": _event_id(),
            "error": error_obj,
        }
        # ``retry_after_ms`` is carried at the top level when present (BUSY,
        # Phase 3). Mirror it inside the error object too for OpenAI-shaped
        # readers.
        if retry_after_ms is not None:
            payload["retry_after_ms"] = retry_after_ms
            error_obj["retry_after_ms"] = retry_after_ms
        await self._send(ws, state, payload, force=True)


def _pending_write_bytes(ws: ServerConnection) -> int | None:
    """Best-effort read of the socket's pending outbound byte count."""
    try:
        transport = ws.transport  # type: ignore[attr-defined]
    except AttributeError:
        return None
    if transport is None:
        return None
    try:
        return transport.get_write_buffer_size()
    except Exception:
        return None


async def serve(
    backend: TTSBackend | None = None,
    *,
    socket_path: str | None = None,
    host: str | None = None,
    port: int | None = None,
    auth_token: str | None = None,
    install_signal_handlers: bool = True,
    ready: Callable[[TTSServer], Awaitable[None]] | None = None,
) -> None:
    """Start the server, wait for a shutdown signal, then drain and exit."""
    cfg = ServerConfig(socket_path=socket_path, host=host, port=port, auth_token=auth_token)
    server = TTSServer(backend or ToneBackend(), cfg)
    await server.start()
    loop = asyncio.get_running_loop()
    stop = loop.create_future()
    if install_signal_handlers:

        def _request_stop() -> None:
            if not stop.done():
                stop.set_result(None)

        for sig in (signal.SIGINT, signal.SIGTERM):
            try:
                loop.add_signal_handler(sig, _request_stop)
            except NotImplementedError:
                pass
    if ready is not None:
        await ready(server)
    try:
        await stop
    finally:
        await server.shutdown()
