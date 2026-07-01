"""Minimal async Python client for the TTS server.

Transport-generic by design: a downstream consumer (e.g. a bot) wraps this in a
Pipecat ``TTSService`` adapter in a separate module (Phase 4
``examples/pipecat_tts_service.py``), so this client must not bake in
app-specific labels, frame types, or audio storage. It mirrors the sibling
``stt_server`` client shape, inverted for synthesis (text in, audio out).

stdlib + websockets only.
"""

from __future__ import annotations

import json
import logging
import os
from typing import Any, AsyncIterator

import websockets
from websockets.asyncio.client import (
    ClientConnection,
    connect as ws_connect,
    unix_connect as ws_unix_connect,
)

from . import protocol as P
from .env import format_host_for_uri, is_cleartext_remote, resolve_endpoint_from_env

logger = logging.getLogger("tts_server.client")

__all__ = [
    "TTSClient",
    "format_host_for_uri",
    "is_cleartext_remote",
    "resolve_endpoint_from_env",
]


class TTSClient:
    def __init__(
        self,
        *,
        socket_path: str | None = None,
        host: str | None = None,
        port: int | None = None,
        uri: str | None = None,
        auth_token: str | None = None,
        ping_interval: float | None = P.KEEPALIVE_PING_INTERVAL_SECONDS,
        ping_timeout: float | None = P.KEEPALIVE_PING_TIMEOUT_SECONDS,
    ) -> None:
        if uri is None and socket_path is None and (host is None or port is None):
            raise ValueError("Provide uri=, socket_path=, or host+port")
        self._socket_path = os.path.expanduser(socket_path) if socket_path else None
        self._host = host
        self._port = port
        self._uri = uri
        self._auth_token = auth_token
        # Keepalive knobs mirror the server's: keep the ping, but use a LARGE
        # FINITE pong timeout so a GIL-starved SERVER loop — which stops answering
        # the client's pings during a heavy generation — can't trip the CLIENT-side
        # keepalive and tear down an in-flight utterance, while a genuinely dead
        # server is still detected within the bound. Fixing only the server
        # direction is not enough. ``ping_timeout=None`` disables the timeout
        # entirely (opt-in).
        self._ping_interval = ping_interval
        self._ping_timeout = ping_timeout
        self._ws: ClientConnection | None = None
        self._closed = False

    # --- connection ---
    async def connect(self) -> dict:
        """Open the websocket and return the ``server.hello`` message."""
        headers: dict[str, str] = {}
        if self._auth_token:
            target = self._uri or (
                f"ws://{format_host_for_uri(self._host)}:{self._port}/"
                if self._host and self._port
                else None
            )
            if target and is_cleartext_remote(target):
                logger.warning(
                    "tts_server.client: attaching a bearer token to a cleartext "
                    "ws:// connection to a remote host (%s); the token is "
                    "observable on-path. Use a Unix socket or wss://.",
                    target,
                )
            headers["Authorization"] = f"Bearer {self._auth_token}"
        if self._uri:
            self._ws = await ws_connect(
                self._uri,
                additional_headers=headers or None,
                ping_interval=self._ping_interval,
                ping_timeout=self._ping_timeout,
            )
        elif self._socket_path:
            self._ws = await ws_unix_connect(
                self._socket_path,
                "ws://localhost/",
                additional_headers=headers or None,
                ping_interval=self._ping_interval,
                ping_timeout=self._ping_timeout,
            )
        else:
            host = format_host_for_uri(self._host)
            self._ws = await ws_connect(
                f"ws://{host}:{self._port}/",
                additional_headers=headers or None,
                ping_interval=self._ping_interval,
                ping_timeout=self._ping_timeout,
            )
        hello = await self._recv_json()
        if hello.get("type") != P.EVT_SERVER_HELLO:
            raise RuntimeError(f"expected server.hello, got {hello.get('type')}")
        # protocol.md §8 (Versioning): clients SHOULD check the server's
        # ``protocol_version``. Warn (rather than raise) on a mismatch so a newer
        # client still talks to an older server where it can, but the operator is
        # told the contract differs.
        server_version = hello.get("protocol_version")
        if server_version != P.PROTOCOL_VERSION:
            logger.warning(
                "tts_server.client: server protocol_version %r != client %r; "
                "wire contract may differ",
                server_version,
                P.PROTOCOL_VERSION,
            )
        return hello

    async def _recv_json(self) -> dict:
        assert self._ws is not None
        raw = await self._ws.recv()
        if isinstance(raw, (bytes, bytearray)):
            raise RuntimeError("unexpected binary frame")
        return json.loads(raw)

    # --- control events ---
    async def update(
        self,
        *,
        voice: str | None = None,
        model: str | None = None,
        language: str | None = None,
        audio_format: str | None = None,
        extras: dict | None = None,
    ) -> None:
        assert self._ws is not None
        msg: dict[str, Any] = {"type": P.EVT_SESSION_UPDATE}
        if voice is not None:
            msg["voice"] = voice
        if model is not None:
            msg["model"] = model
        if language is not None:
            msg["language"] = language
        if audio_format is not None:
            msg["audio_format"] = audio_format
        if extras is not None:
            msg["extras"] = extras
        await self._ws.send(json.dumps(msg))

    async def append(self, text: str, *, text_format: str | None = None) -> None:
        assert self._ws is not None
        msg: dict[str, Any] = {"type": P.EVT_TEXT_APPEND, "text": text}
        if text_format is not None:
            msg["text_format"] = text_format
        await self._ws.send(json.dumps(msg))

    async def commit(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
        event_id: str | None = None,
    ) -> None:
        assert self._ws is not None
        msg: dict[str, Any] = {"type": P.EVT_TEXT_COMMIT}
        if voice is not None:
            msg["voice"] = voice
        if language is not None:
            msg["language"] = language
        if extras is not None:
            msg["extras"] = extras
        # A caller-supplied ``event_id`` is echoed back by the server as
        # ``previous_event_id`` on this commit's ``input_text.committed`` (and on
        # any ``error`` that rejects the commit), letting the caller correlate the
        # ack to THIS commit rather than trusting whichever committed/created frame
        # happens to arrive first on a persistent connection.
        if event_id is not None:
            msg["event_id"] = event_id
        await self._ws.send(json.dumps(msg))

    async def clear(self) -> None:
        assert self._ws is not None
        await self._ws.send(json.dumps({"type": P.EVT_TEXT_CLEAR}))

    async def cancel(self, *, response_id: str | None = None) -> None:
        assert self._ws is not None
        msg: dict[str, Any] = {"type": P.EVT_RESPONSE_CANCEL}
        if response_id is not None:
            msg["response_id"] = response_id
        await self._ws.send(json.dumps(msg))

    async def status(self) -> None:
        assert self._ws is not None
        await self._ws.send(json.dumps({"type": P.EVT_SERVER_STATUS_REQ}))

    async def close_session(self) -> None:
        """Send ``session.close`` (graceful drain). Call ``close()`` to also tear
        down the socket."""
        assert self._ws is not None
        await self._ws.send(json.dumps({"type": P.EVT_SESSION_CLOSE}))

    async def cancel_session(self) -> None:
        """Send ``session.cancel`` (discard semantics)."""
        assert self._ws is not None
        await self._ws.send(json.dumps({"type": P.EVT_SESSION_CANCEL}))

    async def close(self) -> None:
        if self._closed:
            return
        self._closed = True
        if self._ws is not None:
            try:
                await self._ws.close()
            except Exception:
                pass

    # --- events iterator ---
    async def events(self) -> AsyncIterator[dict]:
        """Yield server events as dicts until the socket closes."""
        assert self._ws is not None
        try:
            async for raw in self._ws:
                if isinstance(raw, (bytes, bytearray)):
                    # v1 server never emits binary frames; skip defensively.
                    continue
                try:
                    yield json.loads(raw)
                except json.JSONDecodeError:
                    logger.warning("tts_server.client: dropping non-JSON text frame")
        except websockets.exceptions.ConnectionClosed:
            return

    # --- async context manager ---
    async def __aenter__(self) -> "TTSClient":
        await self.connect()
        return self

    async def __aexit__(self, exc_type, exc, tb) -> None:
        await self.close()
