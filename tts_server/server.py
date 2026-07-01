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
import hmac
import json
import logging
import os
import signal
import socket
import stat
import time
import uuid
from collections import OrderedDict, deque
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
from .backend import (
    SupportsExtrasValidation,
    SupportsVoices,
    SupportsWaitClosed,
    TTSBackend,
    TTSStream,
)
from .backends import make_backend
from .env import is_loopback_host

logger = logging.getLogger("tts_server")


def _event_id() -> str:
    return f"evt_{uuid.uuid4().hex[:16]}"


def _session_id() -> str:
    return f"session_{uuid.uuid4().hex[:16]}"


def _response_id() -> str:
    return f"resp_{uuid.uuid4().hex[:16]}"


def _clear_stale_unix_socket(path: Path) -> None:
    """Make ``path`` bindable, handling a socket left behind by a crashed server.

    ``unix_serve`` (the documented local mode) cannot bind a path that already
    exists, so after a crash or ``SIGKILL`` the stale ``tts.sock`` would make the
    very next ``serve`` fail with ``OSError: Address already in use`` until an
    operator removed it by hand. We resolve the safe cases and refuse the unsafe
    ones:

    - **Non-socket file** at the path: refuse. A regular file / directory there is
      not ours to delete — surface it instead of clobbering operator data.
    - **Live socket** (something is listening): refuse. Never steal another
      server instance's socket; that path is genuinely in use.
    - **Stale socket** (a socket file with no listener — connect is refused):
      unlink it. This is the crash-restart case.
    - **Dangling symlink**: unlink it (``exists()`` is False through a broken
      link, but ``bind`` would still fail).
    """
    if path.is_symlink() and not path.exists():
        path.unlink()  # broken symlink: bind() would fail on it
        return
    if not path.exists():
        return
    if not path.is_socket():
        raise RuntimeError(
            f"refusing to bind: {path} exists and is not a socket; "
            "remove it or choose a different --socket-path"
        )
    # A socket file is present. Probe whether a server is actually listening:
    # a successful connect means a live instance owns it; a refused connect means
    # the listener is gone and the file is a stale leftover we can safely remove.
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    probe.settimeout(0.5)
    try:
        probe.connect(str(path))
    except (ConnectionRefusedError, FileNotFoundError):
        path.unlink(missing_ok=True)  # stale socket from a crash — safe to clear
        logger.warning("tts_server: removed stale socket at %s", path)
        return
    except OSError as exc:
        raise RuntimeError(f"cannot probe existing socket {path}: {exc}") from exc
    finally:
        probe.close()
    # connect() succeeded: a live server owns this socket.
    raise RuntimeError(f"address already in use: a server is already listening on {path}")


def _assert_parent_dir_safe(path: Path) -> None:
    """Refuse to bind a UDS under a directory other local users can write to.

    The socket inode is created 0600 (umask), but 0600 protects the *inode*,
    not the *name*. If the parent directory is group/world-writable, another
    local user can ``unlink`` our socket and ``bind`` their own at the same
    path; clients then resolve the name to an impostor. The 0600 mode does not
    defend against that — the parent directory's write permission does.

    Accept exactly two safe shapes:

    - parent writable only by its owner (e.g. ``0700`` — the dir we create), or
    - world/group-writable **with the sticky bit** (``/tmp`` semantics, where
      only a file's owner may unlink it, so the swap is blocked).

    Anything else (group/world-writable, not sticky) is refused at bind time —
    the symmetric server-side mirror of a client-side parent-dir check, closing
    the plant/swap vector at the source rather than via a TOCTOU inode check.
    """
    parent = path.parent
    mode = parent.stat().st_mode
    other_writable = mode & (stat.S_IWGRP | stat.S_IWOTH)
    sticky = mode & stat.S_ISVTX
    if other_writable and not sticky:
        raise RuntimeError(
            f"refusing to bind: socket parent dir {parent} is group/world-writable "
            f"(mode {oct(mode & 0o7777)}) without the sticky bit; another local user "
            "could replace the socket. Use a directory writable only by you (0700) "
            "or one with the sticky bit set."
        )


def _error_object(code: P.ErrorCode, message: str) -> dict[str, Any]:
    """The OpenAI-shaped ``{type, code, message}`` error object, single-sourced.

    Used by both the top-level ``error`` event (``_error``) and the nested
    ``error`` of ``response.failed`` so the two never drift. Uses ``.get`` with a
    fallback type so an unmapped ``ErrorCode`` degrades instead of ``KeyError``.
    """
    return {
        "type": P.ERROR_TYPE_FOR_CODE.get(code, "server_error"),
        "code": code.value,
        "message": message,
    }


@dataclass
class ServerConfig:
    """Transport and policy configuration for ``TTSServer``."""

    socket_path: str | None = None
    host: str | None = None
    port: int | None = None
    auth_token: str | None = None
    reject_browser_origins: bool = True
    send_queue_high_water_bytes: int = P.SEND_QUEUE_HIGH_WATER_BYTES
    send_timeout_seconds: float = P.SEND_TIMEOUT_SECONDS
    drain_timeout_seconds: float = P.SHUTDOWN_DRAIN_TIMEOUT_SECONDS
    # Websocket keepalive. ``ping_interval_seconds=None`` disables pings entirely;
    # ``ping_timeout_seconds=None`` keeps the periodic ping but never closes the
    # connection on a slow pong (the default — see ``protocol`` for the rationale:
    # GIL-holding Metal compute must not trip a 20s pong timeout mid-generation).
    ping_interval_seconds: float | None = P.KEEPALIVE_PING_INTERVAL_SECONDS
    ping_timeout_seconds: float | None = P.KEEPALIVE_PING_TIMEOUT_SECONDS
    # chmod applied to the UDS after bind. 0o600 restricts connect to the owning
    # user; the UDS is the v1 trust boundary.
    unix_socket_mode: int | None = 0o600

    def __post_init__(self) -> None:
        if self.socket_path is None and (self.host is None or self.port is None):
            raise ValueError("ServerConfig requires socket_path or host+port")


@dataclass
class _Response:
    """One admitted (queued, in-flight, or just-finished) synthesis response."""

    response_id: str
    # Drain parameters captured at admission so the single dispatcher can run
    # the synthesis later, round-robin across connections.
    # INVARIANT: ``ws`` IS ``state``'s connection and is never reassigned (v1 has
    # no reconnect/session-migration). The drain reaches the socket via ``ws`` and
    # the write lock via ``state.write_lock``; they stay in step only because of
    # this invariant. Do not set ``ws`` to anything other than the connection that
    # owns ``state``.
    ws: ServerConnection
    state: "_SessionState"
    text: str
    voice: str | None
    language: str | None
    extras: dict
    # Connection key the scheduler uses for round-robin fairness.
    conn_key: int = 0
    stream: TTSStream | None = None
    # The stream that ran this commit's synthesis, retained AFTER the drain ends
    # (``stream`` above is cleared in ``_run_drain``'s finally). The dispatcher
    # awaits its ``wait_closed`` before freeing the scheduler slot so a cancelled
    # backend worker's still-held GPU lock is reflected in admission/queue_depth.
    synth_stream: TTSStream | None = None
    task: asyncio.Task | None = None
    cancelled: bool = False
    # Set once a TERMINAL frame (done / failed / cancelled) has been emitted for
    # this response. A ``response.cancel`` can race the ``response.audio.done``
    # send (the recv loop runs during the done ``await``, before the drain's
    # ``finally`` clears ``state.response``); without this guard it would emit a
    # SECOND terminal — two terminals for one ``response_id``.
    terminal_sent: bool = False
    # Set False until the dispatcher selects this commit and starts its drain.
    # Used so cancel can distinguish "queued, never started" (drop from the
    # backlog) from "in-flight" (cancel the running drain).
    started: bool = False
    # Set when the dispatcher selects this commit and its drain begins. Lets
    # ``session.close`` wait out the queue (head-of-line) phase WITHOUT spending
    # the drain budget on it, so the drain timeout covers the actual synthesis
    # rather than time spent waiting behind other connections' commits.
    start_event: asyncio.Event = field(default_factory=asyncio.Event)
    # Resolves when the drain task finishes (or the commit is dropped while
    # still queued) so ``session.close`` can wait on it.
    done: asyncio.Event = field(default_factory=asyncio.Event)


class _SynthScheduler:
    """Global synthesis backlog + single round-robin dispatcher (R4).

    Two backpressure caps live here: a bounded GLOBAL backlog shared across all
    connections, and a per-connection in-flight cap (K). A single dispatcher
    selects the next commit round-robin across non-empty per-connection queues,
    so fairness is owned by the scheduler — NOT by daemon threads racing for the
    Metal lock. Only the selected commit's drain runs at a time, which is what
    serializes access to the shared model/Metal lock at commit granularity.

    Intentionally **internal to** ``TTSServer``: ``run_drain`` is injected (it is
    ``TTSServer._run_drain`` in production) so the scheduling policy here can be
    unit-tested with any coroutine callback, but the scheduler is not a
    standalone public component — its lifecycle is owned by the server.
    """

    def __init__(
        self,
        *,
        run_drain: Callable[[_Response], Awaitable[None]],
        queue_max: int = P.SYNTHESIS_QUEUE_MAX,
        per_connection_max: int = P.PER_CONNECTION_INFLIGHT_MAX,
    ) -> None:
        self._run_drain = run_drain
        self._queue_max = queue_max
        self._per_connection_max = per_connection_max
        # Insertion-ordered per-connection FIFO queues of admitted-but-not-yet-
        # started commits. ``OrderedDict`` gives a stable round-robin order.
        self._queues: "OrderedDict[int, deque[_Response]]" = OrderedDict()
        # Count of admitted commits NOT yet finished (queued + in-flight). This
        # is the global backlog depth the cap is measured against.
        self._admitted = 0
        # Per-connection count of admitted-not-finished commits (the K cap).
        self._per_conn: dict[int, int] = {}
        self._wake = asyncio.Event()
        self._dispatcher: asyncio.Task | None = None
        self._stopped = False

    @property
    def depth(self) -> int:
        """Current global backlog depth in commits (queued + in-flight)."""
        return self._admitted

    def start(self) -> None:
        if self._dispatcher is None:
            self._dispatcher = asyncio.create_task(self._dispatch_loop())

    async def stop(self) -> None:
        self._stopped = True
        self._wake.set()
        if self._dispatcher is not None:
            self._dispatcher.cancel()
            try:
                await self._dispatcher
            except (asyncio.CancelledError, Exception):
                pass
            self._dispatcher = None

    def admit(self, response: _Response) -> bool:
        """Try to admit a commit. Returns False (caller emits BUSY) when the
        global backlog is full or the connection is at its in-flight cap."""
        key = response.conn_key
        if self._per_conn.get(key, 0) >= self._per_connection_max:
            return False
        if self._admitted >= self._queue_max:
            return False
        self._admitted += 1
        self._per_conn[key] = self._per_conn.get(key, 0) + 1
        self._queues.setdefault(key, deque()).append(response)
        self._wake.set()
        return True

    def discard_if_queued(self, response: _Response) -> bool:
        """Remove a still-queued (never-started) commit from the backlog and
        free its slot. Returns True if it was queued (and thus removed here).

        A STARTED commit is owned by the dispatcher loop, which frees its slot
        in ``_finish`` when the drain returns — so this is a no-op for those
        (returns False), avoiding a double-decrement. Used by cancel: a queued
        commit is dropped here; an in-flight one is cancelled via its task and
        accounted by the dispatcher.
        """
        key = response.conn_key
        q = self._queues.get(key)
        if q is None or response not in q:
            return False
        q.remove(response)
        if not q:
            self._queues.pop(key, None)
        self._admitted = max(0, self._admitted - 1)
        self._per_conn[key] = max(0, self._per_conn.get(key, 0) - 1)
        if self._per_conn.get(key, 0) == 0:
            self._per_conn.pop(key, None)
        response.done.set()
        self._wake.set()
        return True

    async def _dispatch_loop(self) -> None:
        while not self._stopped:
            nxt = self._next()
            if nxt is None:
                self._wake.clear()
                # Re-check after clearing to avoid a lost wakeup race.
                if self._next() is None:
                    await self._wake.wait()
                continue
            nxt.started = True
            # Signal that synthesis is starting so a waiting ``session.close``
            # can begin its bounded drain wait from here (not from enqueue time).
            nxt.start_event.set()
            try:
                await self._run_drain(nxt)
            except Exception:
                # Defense-in-depth: ``_run_drain`` already handles its own backend
                # errors, but the SINGLE dispatcher must survive ANY stray
                # exception from the drain path — otherwise no future commit is
                # ever dispatched and every connection wedges permanently.
                # ``CancelledError`` (the shutdown stop signal) is a BaseException,
                # so it is NOT caught here and still ends the loop on ``stop()``.
                logger.exception("tts_server: dispatcher drain raised; continuing")
            finally:
                # The drain marks completion; ensure the slot is freed exactly
                # once even if the drain raised.
                self._finish(nxt)

    def _next(self) -> _Response | None:
        """Round-robin across non-empty per-connection queues. Rotating the
        OrderedDict after each selection bounds head-of-line blocking to one
        already-selected commit (R4 fairness)."""
        for key in list(self._queues.keys()):
            q = self._queues.get(key)
            if not q:
                self._queues.pop(key, None)
                continue
            response = q.popleft()
            if not q:
                self._queues.pop(key, None)
            else:
                # Rotate this connection to the back so the next selection
                # prefers a different connection (fairness).
                self._queues.move_to_end(key)
            return response
        return None

    def _finish(self, response: _Response) -> None:
        """A started drain finished: free its slot once."""
        if response.started:
            key = response.conn_key
            self._admitted = max(0, self._admitted - 1)
            self._per_conn[key] = max(0, self._per_conn.get(key, 0) - 1)
            if self._per_conn.get(key, 0) == 0:
                self._per_conn.pop(key, None)
            response.started = False
            response.done.set()
            self._wake.set()


@dataclass
class _SessionState:
    """Per-connection state. No shared mutable session state lives outside this
    object — one connection's text/synthesis can never pollute another's
    (mirrors stt's per-connection isolation, R4)."""

    session_id: str
    # Stable key for scheduler round-robin fairness (one per connection).
    conn_key: int = 0
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
        # Backend capabilities are static after ``start()`` (the plan's
        # contract), so snapshot them once instead of rebuilding the dict on
        # every hello/commit/append/status. Populated in ``start()``.
        self._caps: dict[str, Any] = {}
        # Advertised voices as a frozenset, cached once in ``start()`` so the
        # security ``_validate_voice`` check is O(1) on the per-commit hot path
        # (the set is fixed post-start). Empty until ``start()``.
        self._voice_set: frozenset[str] = frozenset()
        self._server: Server | None = None
        self._active_handlers: set[asyncio.Task] = set()
        self._active_drains: set[asyncio.Task] = set()
        self._shutdown_event = asyncio.Event()
        self._started = False
        # Monotonic per-connection key source for scheduler fairness.
        self._next_conn_key = 0
        # Global synthesis scheduler: bounded backlog + single round-robin
        # dispatcher. Built here, started in ``start()`` (it needs a running
        # loop).
        self._scheduler = _SynthScheduler(run_drain=self._dispatch_drain)

    # --- lifecycle ---
    async def start(self) -> None:
        if self._started:
            return
        # connect -> load -> hello: the backend must be loaded before the first
        # ``server.hello`` because the rate comes from the loaded model.
        await self._backend.start()
        # Snapshot capabilities once (static post-start); hot paths read this.
        self._caps = self._backend.capabilities()
        # Cache the advertised voices as a frozenset for O(1) validation. Fixed
        # after ``start()`` — the backend has finished voice discovery.
        self._voice_set = frozenset(self._backend_voices())
        if self._config.socket_path:
            socket_path = Path(self._config.socket_path)
            # Set the umask BEFORE mkdir so a parent dir we create is 0700, not
            # the process default (~0755). Hold it through ws_unix_serve so the
            # socket inode is born 0600. The parent-dir guard covers the
            # exist_ok=True case where the dir already existed with loose perms.
            prior_umask = os.umask(0o077)
            try:
                socket_path.parent.mkdir(parents=True, exist_ok=True)
                _assert_parent_dir_safe(socket_path)
                _clear_stale_unix_socket(socket_path)
                self._server = await ws_unix_serve(
                    self._handle_connection,
                    path=str(socket_path),
                    process_request=self._process_request,
                    ping_interval=self._config.ping_interval_seconds,
                    ping_timeout=self._config.ping_timeout_seconds,
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
                ping_interval=self._config.ping_interval_seconds,
                ping_timeout=self._config.ping_timeout_seconds,
            )
        self._scheduler.start()
        self._started = True
        logger.info(
            "tts_server listening on %s (backend=%s model=%s rate=%s)",
            self._config.socket_path or f"{self._config.host}:{self._config.port}",
            self._backend.backend_name,
            self._backend.model,
            self._backend.sample_rate,
        )
        # Cleartext-remote guard (mirror stt): a token-less TCP listener bound to
        # a non-loopback address is reachable in the clear. A UDS is protected by
        # its 0o600 mode + local trust boundary; a non-loopback TCP listener is
        # not. The COMPLEMENTARY guard — a bearer token sent over cleartext ws://
        # to a remote host — lives client-side (``client.py`` connect and the
        # ``status`` probe in ``__main__.py``), because only the sender knows
        # whether TLS is terminated in front (a reverse proxy may add it), so a
        # server-side warn on token+non-loopback would be a false positive.
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
        await self._scheduler.stop()
        if self._server is not None:
            await self._server.wait_closed()
        await self._backend.close()
        self._started = False

    # --- connection handling ---
    async def _process_request(self, connection, request):
        # Reject unexpected browser Origin headers for non-browser-focused v1,
        # and enforce optional bearer auth in one place (mirror stt).
        headers = request.headers
        origin = headers.get("Origin")
        if self._config.reject_browser_origins and origin:
            return connection.respond(403, "origin not permitted\n")
        if self._config.auth_token:
            provided = headers.get("Authorization", "") or ""
            expected = f"Bearer {self._config.auth_token}"
            # Constant-time compare so a loopback attacker cannot recover the
            # token byte-by-byte via response-timing signals.
            if not hmac.compare_digest(provided.encode("utf-8"), expected.encode("utf-8")):
                return connection.respond(401, "unauthorized\n")
        return None

    async def _handle_connection(self, ws: ServerConnection) -> None:
        task = asyncio.current_task()
        assert task is not None
        self._active_handlers.add(task)
        self._next_conn_key += 1
        state = _SessionState(session_id=_session_id(), conn_key=self._next_conn_key)
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
                    "capabilities": self._caps,
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
        accepted = set(self._caps.get("extras", []))
        fixed = {"voice", "language", "text", "lang_code"}
        validated: dict = {}
        for key, value in extras.items():
            if key in fixed:
                return {}, f"extra {key!r} collides with a fixed parameter"
            if key not in accepted:
                logger.debug("tts_server: dropping unknown extra %r", key)
                continue
            validated[key] = value
        # Value-level validation at the trust boundary (optional backend hook):
        # reject e.g. a non-numeric / non-finite ``speed`` HERE as INVALID_CONFIG,
        # so it never reaches ``open_stream`` and surfaces as a misleading
        # BACKEND_ERROR after the commit has already consumed a scheduler slot.
        backend = self._backend
        if isinstance(backend, SupportsExtrasValidation):
            value_err = backend.validate_extras(validated)
            if value_err is not None:
                return {}, value_err
        return validated, None

    def _validate_language(self, language: Any) -> str | None:
        """Reject a ``language`` not in the backend's advertised list.

        Returns an error message, or ``None`` if the language is unset or
        advertised. Backends map an accepted ISO code to their own code, but an
        UN-advertised code must error here rather than silently degrade (e.g.
        Kokoro's ``lang_code`` fallback would otherwise return English audio for
        an unsupported language — a contract violation vs ``capabilities.languages``).
        """
        if language is None:
            return None
        if not isinstance(language, str):
            return "language must be a string"
        advertised = self._caps.get("languages") or []
        if advertised and language.lower() not in {code.lower() for code in advertised}:
            return f"unsupported language {language!r}; supported: {', '.join(advertised)}"
        return None

    def _validate_voice(self, voice: Any) -> str | None:
        """Reject a ``voice`` not in the backend's advertised voice set.

        Returns an error message, or ``None`` if the voice is unset or
        advertised. This is a SECURITY boundary, not just UX: an unvalidated
        voice string is forwarded to the backend's ``open_stream`` and, for
        Kokoro, into mlx-audio's voice loader, which treats a ``*.safetensors``
        value as a direct filesystem path (arbitrary-file load) and otherwise
        falls through to a Hugging Face ``snapshot_download`` (client-driven
        network egress). Restricting ``voice`` to the advertised set closes both
        vectors at the trust boundary — mirroring ``_validate_language``.

        When the advertised set is empty there are two DISTINCT cases, and the
        boundary must FAIL CLOSED for the dangerous one:

        - The backend has voices but could not enumerate them (``voice_count`` >
          0 — e.g. Kokoro's discovery fallback returns ``54`` while leaving the
          name list empty). We cannot verify a client voice is one of the model's
          own, so an unverified string would reach the loader unchecked. REJECT
          any client-supplied voice; the client must omit it and take the server
          default. (Skipping the check here is the fail-OPEN bug this guards.)
        - The backend has no voice concept at all (``voice_count`` falsy / no
          ``SupportsVoices``): there is nothing to validate, so accept.

        Membership is checked against ``self._voice_set`` — a ``frozenset`` cached
        once after ``start()`` so this per-commit/per-update call is O(1) and
        allocation-free rather than rebuilding+scanning the list each time.
        """
        if voice is None:
            return None
        if not isinstance(voice, str):
            return "voice must be a string"
        if self._voice_set:
            if voice not in self._voice_set:
                return f"unsupported voice {voice!r}; query server.status for the advertised voices"
            return None
        # No enumerable voice set. Fail closed if the backend nonetheless HAS
        # voices (count > 0); accept only when the backend has no voice concept.
        voice_count = self._caps.get("voice_count")
        if isinstance(voice_count, int) and voice_count > 0:
            return (
                "voice cannot be validated (the backend could not enumerate its "
                "voices); omit voice to use the server default"
            )
        return None

    def _validate_model(self, model: Any) -> str | None:
        """Reject a ``model`` this server cannot actually honor.

        v1 loads exactly ONE model at process start (advertised as
        ``server.hello.backend.model``) and every commit synthesizes with it —
        the backend ``open_stream`` contract has no per-request model parameter,
        so there is no per-session model switching. ``model`` stays in the
        protocol schema for a future multi-model server, but accepting an
        arbitrary value here would be a SILENT wrong-model failure: the client
        gets ``session.updated`` echoing the requested model while all audio
        still comes from the loaded one. So accept ``model`` only when it names
        the loaded model (a harmless no-op); reject anything else loudly with
        ``invalid_config`` instead of acking a switch that never happens.

        Returns an error message, or ``None`` if ``model`` is unset or matches.
        """
        if model is None:
            return None
        if not isinstance(model, str):
            return "model must be a string"
        loaded = self._backend.model
        if model == loaded:
            return None
        # Fail closed for every mismatch, including a backend with no selectable
        # model (``loaded is None``): a client-supplied model can never be
        # honored there either, so it must not be silently acked.
        if loaded is None:
            return f"unsupported model {model!r}; this backend has no selectable model (omit model)"
        return (
            f"unsupported model {model!r}; this server loaded {loaded!r} and "
            "does not support per-session model switching"
        )

    async def _on_session_update(
        self,
        ws: ServerConnection,
        state: _SessionState,
        msg: dict,
        client_event_id: str | None,
    ) -> None:
        # Reject unknown top-level fields: a typo'd config key (e.g. ``pitch``)
        # must not be silently ignored — the client would otherwise believe an
        # unsupported setting was applied. (Mirrors commit's unknown-field rule.)
        allowed = {"type", "event_id", "voice", "model", "language", "audio_format", "extras"}
        unknown = sorted(k for k in msg if k not in allowed)
        if unknown:
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_CONFIG,
                f"unknown session.update field(s): {', '.join(unknown)}",
                client_event_id=client_event_id,
            )
            return

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

        lang_err = self._validate_language(msg.get("language"))
        if lang_err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, lang_err, client_event_id=client_event_id
            )
            return

        voice_err = self._validate_voice(msg.get("voice"))
        if voice_err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, voice_err, client_event_id=client_event_id
            )
            return

        model_err = self._validate_model(msg.get("model"))
        if model_err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, model_err, client_event_id=client_event_id
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
        max_chars = self._caps.get("max_text_chars")
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
        # Reject any other unknown top-level field for the same reason
        # session.update does (a silently-ignored key misleads the client).
        allowed = {"type", "event_id", "voice", "language", "extras"}
        unknown = sorted(k for k in msg if k not in allowed)
        if unknown:
            await self._error(
                ws,
                state,
                P.ErrorCode.INVALID_CONFIG,
                f"unknown input_text.commit field(s): {', '.join(unknown)}",
                client_event_id=client_event_id,
            )
            return
        lang_err = self._validate_language(msg.get("language"))
        if lang_err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, lang_err, client_event_id=client_event_id
            )
            return
        voice_err = self._validate_voice(msg.get("voice"))
        if voice_err is not None:
            await self._error(
                ws, state, P.ErrorCode.INVALID_CONFIG, voice_err, client_event_id=client_event_id
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
        # Hard server cap: reject a committed buffer over ``max_text_chars``
        # (the soft ``ideal_words`` chunking is the client's job; this is the
        # backstop the server enforces regardless of client behavior).
        max_chars = self._caps.get("max_text_chars")
        if isinstance(max_chars, int) and len(state.buffer) > max_chars:
            await self._error(
                ws,
                state,
                P.ErrorCode.PAYLOAD_TOO_LARGE,
                f"committed text exceeds max_text_chars ({max_chars})",
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
        rid = _response_id()
        response = _Response(
            response_id=rid,
            ws=ws,
            state=state,
            text=text,
            voice=voice,
            language=language,
            extras=extras,
            conn_key=state.conn_key,
        )

        # Backpressure admission control (R4): the scheduler rejects when the
        # GLOBAL synthesis backlog is full OR this connection is at its
        # per-connection in-flight cap (K). A rejected commit is NOT enqueued and
        # gets ``error {code: BUSY, retry_after_ms}`` — the buffer is left intact
        # so the client can retry the same text after backing off. With K=1 this
        # also subsumes the old "commit while a response is in flight" guard.
        if not self._scheduler.admit(response):
            await self._error(
                ws,
                state,
                P.ErrorCode.BUSY,
                "synthesis backlog full; retry after backoff",
                client_event_id=client_event_id,
                retry_after_ms=P.BUSY_RETRY_AFTER_MS,
            )
            return

        # Admitted: consume the buffer and register the response for cancel.
        state.buffer = ""
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
        # The single scheduler dispatcher runs the drain round-robin; it does NOT
        # start inline here, so cross-connection fairness is owned by the
        # scheduler, not by whichever drain task the OS happens to schedule.

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

    async def _dispatch_drain(self, response: _Response) -> None:
        """Scheduler callback: run one selected commit's drain as a TRACKED TASK
        (so ``response.cancel`` / ``session.*`` can target ``response.task``
        while it runs) and await its completion before the dispatcher selects the
        next commit. The await is what serializes synthesis at commit granularity
        across all connections."""
        if response.cancelled:
            # Cancelled while still queued — nothing to synthesize.
            return
        drain = asyncio.create_task(self._run_drain(response))
        response.task = drain
        self._active_drains.add(drain)
        drain.add_done_callback(self._active_drains.discard)
        try:
            await drain
        except asyncio.CancelledError:
            # The drain was cancelled (barge-in / teardown); the slot is still
            # freed by the scheduler's finally. Do not propagate into the
            # dispatcher loop.
            pass
        finally:
            # Do NOT let the scheduler free this slot (the caller's ``_finish``,
            # which runs once this returns) until the backend worker has actually
            # exited and released the process-wide GPU lock. On barge-in the
            # drain task is cancelled promptly (the client already saw
            # ``response.cancelled``), but ``stream.cancel()`` only *requests* a
            # break — a long single-segment Kokoro ``generate`` keeps the Metal
            # lock until its next yield boundary. Awaiting here means
            # admission/``queue_depth`` never report free capacity while the next
            # commit would still block on that held lock. No-op for backends
            # without a worker/lock (Tone) or that omit ``wait_closed``.
            await self._await_worker_release(response)

    async def _await_worker_release(self, response: _Response) -> None:
        """Block (BOUNDED) until ``response``'s backend worker has exited (GPU
        lock free).

        Optional capability (``SupportsWaitClosed``): a backend stream that does
        not implement ``wait_closed`` has no worker/lock to wait on.

        This runs inside the SINGLE dispatcher's per-commit path, so an UNBOUNDED
        wait here would wedge every other connection's commit if a worker never
        released (a wedged native ``generate`` that never reaches a yield). Bound
        it by ``drain_timeout_seconds`` — the same "degrade, never hang" budget
        ``session.close`` uses. On timeout the slot is freed anyway; the next
        commit then serializes on the still-held lock (correct, just not
        pre-counted) instead of hanging the dispatcher.
        """
        stream = response.synth_stream
        if not isinstance(stream, SupportsWaitClosed):
            return
        try:
            await stream.wait_closed(timeout=self._config.drain_timeout_seconds)
        except Exception:
            logger.exception("tts_server: wait_closed failed during slot release")

    async def _run_drain(self, response: _Response) -> None:
        """The synthesis drain loop (the steady-stream contract, R4).

        Emits each segment's audio as it lands, re-chunked to fixed 20 ms wire
        frames. EOF comes from generator exhaustion (the ``completed`` event),
        never a flag. On exhaustion: flush the short tail, then
        ``response.audio.done`` with ``duration_ms`` from the ORIGINAL total
        sample count.
        """
        ws = response.ws
        state = response.state
        text = response.text
        voice = response.voice
        language = response.language
        extras = response.extras
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
            # Retained past the drain so the dispatcher can await worker exit
            # (lock release) before freeing the slot — see ``_dispatch_drain``.
            response.synth_stream = stream
            await stream.feed(text)
            # Non-blocking: signals end-of-input and kicks the worker. It must
            # NOT block until synthesis completes (the anti-pattern).
            await stream.end()
            async for ev in stream.events():
                # ``state.closed`` covers the send-queue high-water close: a slow
                # reader tripped it (no ``response.cancelled``), and continuing
                # would pin the Metal lock synthesizing for a dead socket and
                # starve every other connection's commit. Stop and free the lock.
                if response.cancelled or state.closed:
                    break
                if ev.kind == "delta" and ev.pcm:
                    total_samples += len(ev.pcm) // P.AUDIO_SAMPLE_WIDTH_BYTES
                    carry.extend(ev.pcm)
                    # Re-frame the FULL per-response stream so only the last
                    # frame is short — slice off whole 20 ms frames as they fill.
                    while len(carry) >= bytes_per_frame:
                        frame = bytes(carry[:bytes_per_frame])
                        del carry[:bytes_per_frame]
                        if response.cancelled or state.closed:
                            break
                        await self._emit_delta(ws, state, rid, seq, frame)
                        seq += 1
                # ev.kind == "completed" is the EOF signal (generator exhaustion).
            if response.cancelled or state.closed:
                # On a high-water close the stream was never cancelled by
                # ``_cancel_response`` — do it here so the backend worker breaks
                # out of ``generate()`` and releases the Metal lock promptly.
                if state.closed and stream is not None and not response.cancelled:
                    try:
                        await stream.cancel()
                    except Exception:
                        pass
                return
            # Flush the short tail (NO silence padding).
            if carry:
                await self._emit_delta(ws, state, rid, seq, bytes(carry))
                seq += 1
            duration_ms = int(total_samples * 1000 / rate) if rate else 0
            # Mark terminal BEFORE the await: a ``response.cancel`` arriving while
            # this send is in flight must see the response as already-terminal and
            # no-op, not emit a second terminal frame.
            response.terminal_sent = True
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
                response.terminal_sent = True
                await self._send(
                    ws,
                    state,
                    {
                        "type": P.EVT_RESPONSE_FAILED,
                        "event_id": _event_id(),
                        "response_id": rid,
                        "error": _error_object(
                            P.ErrorCode.BACKEND_ERROR, "backend synthesis failed"
                        ),
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
        # Only emit ``response.cancelled`` when an active response actually
        # matches: either no id was given (K=1 ⇒ unambiguous) or the id names the
        # in-flight response. If nothing matches (no active response, or a stale/
        # mismatched id — e.g. a barge-in cancel that races a just-finished
        # response), it is a NO-OP. The previous code acked with
        # ``target or (... else None)``, which sent a malformed
        # ``response.cancelled`` with ``response_id: null`` for a bare cancel on
        # an idle session.
        if (
            response is None
            or response.terminal_sent
            or (target is not None and target != response.response_id)
        ):
            logger.debug(
                "tts_server: response.cancel no-op (no active response matches target=%r "
                "or it already reached a terminal frame)",
                target,
            )
            return
        response.terminal_sent = True
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
        # If the commit is still QUEUED (the dispatcher has not selected it yet),
        # drop it from the backlog here — this frees the in-flight slot so a new
        # ``commit`` is immediately admissible (guards a barge-in-heavy client
        # from self-DoSing into permanent BUSY). An in-flight commit's slot is
        # freed by the dispatcher when its drain returns below.
        self._scheduler.discard_if_queued(response)
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
        # Drain the active/queued response to completion (bounded). ``done`` is
        # set when the scheduler frees its slot — whether it ran to completion,
        # was dropped while queued, or was cancelled — so this covers both the
        # in-flight and the queued-but-not-yet-dispatched cases (the dispatcher
        # may not have selected it yet under load).
        if response is not None and not response.done.is_set():
            if self._shutdown_event.is_set():
                await self._cancel_response(response)
            else:
                # Two-phase bounded wait so the drain timeout covers the actual
                # SYNTHESIS in full, not time this commit spent queued behind
                # other connections' commits (a "drain" request asked to let this
                # response finish, not to be cut short by queue waiting):
                #   1. Wait for the dispatcher to START this commit (``start_event``),
                #      bounded by the drain timeout. NOTE this is a patience bound,
                #      not a correctness guarantee that the commit WILL start: under
                #      round-robin across N busy connections this commit can sit
                #      behind up to one commit per other connection, so the wait may
                #      legitimately exceed one synthesis. If the timeout elapses
                #      first we cancel (we will not wait unboundedly in the queue).
                #      While we wait, only the dispatcher can complete the response,
                #      and it sets ``start_event`` before doing so — so ``done`` is
                #      never set without ``start_event``.
                #   2. Once started, wait for completion (``done``) within a fresh
                #      drain timeout covering the actual synthesis.
                # Each phase gets its OWN ``drain_timeout_seconds`` budget (so a
                # commit that waited a long time to start still gets a full
                # synthesis budget) — hence the worst-case TOTAL close latency is
                # up to 2x ``drain_timeout_seconds``, by design. A timeout in
                # either phase cancels (degrade, never hang).
                timeout = self._config.drain_timeout_seconds
                try:
                    if not response.start_event.is_set():
                        await asyncio.wait_for(response.start_event.wait(), timeout=timeout)
                    if not response.done.is_set():
                        await asyncio.wait_for(response.done.wait(), timeout=timeout)
                except asyncio.TimeoutError:
                    await self._cancel_response(response)
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
        caps = self._caps
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
                # Global synthesis backlog depth (commits queued + in-flight
                # across all connections) — the operationally meaningful load
                # figure for a health probe.
                "queue_depth": self._scheduler.depth,
                # Decided default #4: the COUNT goes in ``server.hello``; the
                # FULL list is exposed here via ``server.status``.
                "voice_count": caps.get("voice_count"),
                "voices": self._backend_voices(),
                "buffered_chars": len(state.buffer),
                "uptime_seconds": time.monotonic() - state.started_monotonic,
                "pid": os.getpid(),
            },
        )

    def _backend_voices(self) -> list[str]:
        """Full voice list for ``server.status`` (decided default #4) and the
        source of truth for ``_validate_voice``. Optional capability
        (``SupportsVoices``): a backend that cannot enumerate voices returns an
        empty list (and voice validation is skipped for it)."""
        if not isinstance(self._backend, SupportsVoices):
            return []
        try:
            result = self._backend.voices()
        except Exception:
            return []
        return list(result) if result else []

    async def _teardown_session(self, state: _SessionState) -> None:
        if state.response is not None:
            await self._cancel_response(state.response)
        state.closed = True

    # --- helpers ---
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
    async def _drop_session(self, ws: ServerConnection, state: _SessionState, reason: str) -> None:
        """Shared stalled-reader teardown for ``_send``. Both drop paths (the
        pre-send high-water overflow guard and a mid-flight send that exceeds
        ``send_timeout_seconds``) must mark the session closed and close the
        socket (1011) in lockstep: the drain loop sees ``state.closed`` on its
        next iteration, breaks, and cancels the stream so the backend worker
        releases the process-wide synthesis lock."""
        state.closed = True
        try:
            await ws.close(code=1011, reason=reason)
        except Exception:
            pass

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
                    await self._drop_session(ws, state, "send_queue_overflow")
                    return
            try:
                await asyncio.wait_for(
                    ws.send(json.dumps(payload)),
                    timeout=self._config.send_timeout_seconds,
                )
            except websockets.exceptions.ConnectionClosed:
                pass
            except asyncio.TimeoutError:
                # The high-water guard above samples pending bytes BEFORE this
                # send; a send that wedges mid-flight (the reader stops draining
                # and the socket write buffer fills WHILE we await) never trips it.
                # Unbounded, the drain loop parks here, stops consuming the bounded
                # backend->session bridge, and the backend worker stays parked
                # behind a full queue holding the process-wide synthesis lock —
                # stalling every other session. Bound the send and, on timeout,
                # drop the session: mark it closed (the drain loop sees
                # ``state.closed`` on its next iteration, breaks, and cancels the
                # stream so the worker releases the lock) and close the socket.
                logger.warning(
                    "tts_server: outbound send exceeded %.1fs (stalled reader), closing session %s",
                    self._config.send_timeout_seconds,
                    state.session_id,
                )
                await self._drop_session(ws, state, "send_timeout")

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
        error_obj: dict[str, Any] = _error_object(code, message)
        if client_event_id:
            error_obj["event_id"] = client_event_id
        payload: dict[str, Any] = {
            "type": P.EVT_ERROR,
            "event_id": _event_id(),
            "error": error_obj,
        }
        # Carry the request correlation at the TOP level too, exactly like every
        # other correlated reply (session.updated, input_text.committed/cleared).
        # Without this an error is indistinguishable from a stale error left by an
        # earlier command on a persistent connection, so a client correlating by
        # ``previous_event_id`` could let a stale BUSY/invalid_config error abort a
        # freshly-committed response. The nested ``error.event_id`` is kept for
        # OpenAI-shaped readers.
        if client_event_id:
            payload["previous_event_id"] = client_event_id
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
    ping_interval_seconds: float | None = P.KEEPALIVE_PING_INTERVAL_SECONDS,
    ping_timeout_seconds: float | None = P.KEEPALIVE_PING_TIMEOUT_SECONDS,
    install_signal_handlers: bool = True,
    ready: Callable[[TTSServer], Awaitable[None]] | None = None,
) -> None:
    """Start the server, wait for a shutdown signal, then drain and exit."""
    cfg = ServerConfig(
        socket_path=socket_path,
        host=host,
        port=port,
        auth_token=auth_token,
        ping_interval_seconds=ping_interval_seconds,
        ping_timeout_seconds=ping_timeout_seconds,
    )
    # Default backend is built through the same lazy resolver as every other
    # backend (``make_backend``) so the server depends only on the abstract
    # protocol types, never on a concrete backend class.
    server = TTSServer(backend or make_backend("tone"), cfg)
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
