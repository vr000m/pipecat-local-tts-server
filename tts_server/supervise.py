"""Machine-readable lifecycle channel for a supervising parent process.

Used by ``serve --supervised`` and ``prefetch --json`` so a GUI (the macOS menu
bar app under ``macos/``) can drive the CLI without scraping log text:

- **stdout is reserved for JSON lines** (one compact object per line, flushed).
  While :func:`json_channel` is active, ``sys.stdout`` is pointed at stderr so a
  stray ``print()`` from a model library cannot corrupt the event stream. (A
  C-level write straight to fd 1 bypasses that redirect; consumers should skip
  any stdout line that does not parse as a JSON object.)
- **stdin EOF means "the supervisor is gone"**: :func:`watch_stdin_eof` fires a
  callback when the parent closes its end of the pipe or dies, so a server never
  outlives the app that started it.
- :func:`classify_startup_error` maps a fatal exception to a stable ``code``.
- :func:`run_supervised` owns the ``serve --supervised`` process policy: the
  ``ready`` line (:func:`emit_ready`), ``error`` lines and exit codes, and the
  stdin-EOF stop including the hard exit when the supervisor leaves mid-startup
  (:class:`StdinEofLifecycle`). ``tts_server.server`` exposes only the abstract
  ``ServeLifecycle`` hook and never imports this module.

Stdlib-only and lean at import (no ``huggingface_hub`` / ``mlx``): download
errors are recognised by their exception's module name instead of by type.
"""

from __future__ import annotations

import contextlib
import errno
import json
import logging
import os
import sys
import threading
from collections.abc import Callable, Iterator
from typing import Any, TextIO

logger = logging.getLogger("tts_server")

# Stable ``code`` values for ``{"event": "error"}`` lines. Part of the
# supervised-mode contract: the app switches on these.
CODE_MODULE_NOT_FOUND = "ModuleNotFoundError"
CODE_ADDR_IN_USE = "EADDRINUSE"
CODE_ACCESS_DENIED = "EACCES"
CODE_SOCKET_PATH_CONFLICT = "SocketPathConflict"
CODE_MODEL_DOWNLOAD = "ModelDownloadError"
CODE_CONFIG = "ConfigError"
CODE_BACKEND_START = "BackendStartError"

# Exception modules that mean "fetching weights failed" (network, hub, xet).
_DOWNLOAD_MODULE_PREFIXES = ("huggingface_hub", "requests", "urllib3", "hf_xet", "httpx")

_channel: TextIO | None = None


@contextlib.contextmanager
def json_channel() -> Iterator[None]:
    """Reserve the current ``sys.stdout`` for :func:`emit`; route prints to stderr.

    Restores both on exit so in-process callers (tests) are left untouched.
    """
    global _channel
    prev_channel, prev_stdout = _channel, sys.stdout
    _channel = sys.stdout
    sys.stdout = sys.stderr
    try:
        yield
    finally:
        sys.stdout = prev_stdout
        _channel = prev_channel


def emit(event: dict[str, Any]) -> None:
    """Write one compact JSON object as a single stdout line and flush it."""
    out = _channel if _channel is not None else sys.stdout
    out.write(json.dumps(event, separators=(",", ":")) + "\n")
    out.flush()


def watch_stdin_eof(loop: Any, on_eof: Callable[[], None]) -> None:
    """Call ``on_eof`` on ``loop`` once stdin reaches EOF.

    A daemon thread blocks in ``os.read`` rather than using
    ``loop.connect_read_pipe``, which rejects a TTY stdin on macOS. Whatever the
    parent writes is discarded; only EOF matters.
    """
    stream = sys.stdin
    if stream is None:
        logger.warning("tts_server: --supervised without a stdin; parent-exit detection disabled")
        return
    try:
        fd = stream.fileno()
    except (OSError, ValueError):
        logger.warning("tts_server: stdin has no file descriptor; parent-exit detection disabled")
        return

    def _run() -> None:
        while True:
            try:
                chunk = os.read(fd, 4096)
            except InterruptedError:
                continue
            except OSError:
                chunk = b""
            if not chunk:
                break
        logger.info("tts_server: stdin closed (supervisor gone); stopping")
        try:
            loop.call_soon_threadsafe(on_eof)
        except RuntimeError:
            # Loop already closed: the server is shutting down anyway.
            pass

    threading.Thread(target=_run, name="tts-stdin-watch", daemon=True).start()


class StdinEofLifecycle:
    """``serve()`` lifecycle for ``--supervised`` (``tts_server.server.ServeLifecycle``).

    stdin EOF stops the server exactly like SIGTERM once it is listening. If EOF
    arrives while the backend is still loading (the supervisor quit
    mid-download), the process exits 0 immediately: the load runs in an executor
    thread that cannot be cancelled, and Hugging Face downloads resume from their
    ``.incomplete`` blobs next time.
    """

    def attach(self, loop: Any, request_stop: Callable[[], None]) -> None:
        watch_stdin_eof(loop, request_stop)

    def startup_abandoned(self) -> None:
        logger.warning("tts_server: supervisor went away during startup; exiting")
        logging.shutdown()
        os._exit(0)


async def emit_ready(server: Any) -> None:
    """``serve(ready=...)`` callback: one ``ready`` JSON line, with the real port."""
    cfg = server.config
    backend = server.backend
    port = None if cfg.socket_path else (server.listening_port() or cfg.port)
    emit(
        {
            "event": "ready",
            "backend": backend.backend_name,
            "model": backend.model,
            "host": None if cfg.socket_path else cfg.host,
            "port": port,
            "socket_path": cfg.socket_path,
            "rate": backend.sample_rate,
            "pid": os.getpid(),
        }
    )


def run_supervised(run: Callable[..., None]) -> None:
    """Run a server under the supervised-mode contract.

    ``run(ready=..., lifecycle=...)`` must start the server (forwarding both to
    ``serve()``) and return once it has stopped. Inside :func:`json_channel`: a
    clean stop returns (exit 0); a config ``SystemExit("...")`` becomes an
    ``error{code: ConfigError}`` line and is re-raised; any other exception is
    logged, becomes ``error{code}`` (:func:`classify_startup_error`) and exits 1.
    """
    with json_channel():
        try:
            run(ready=emit_ready, lifecycle=StdinEofLifecycle())
        except KeyboardInterrupt:
            raise
        except SystemExit as exc:
            # Config errors raise ``SystemExit("tts_server: ...")``; surface them
            # as an event too so the app can show the message.
            if isinstance(exc.code, str):
                emit(
                    {
                        "event": "error",
                        "code": CODE_CONFIG,
                        "message": exc.code,
                        "exc_type": "SystemExit",
                    }
                )
            raise
        except Exception as exc:
            logger.error("tts_server: fatal error", exc_info=exc)
            code, message = classify_startup_error(exc)
            emit(
                {
                    "event": "error",
                    "code": code,
                    "message": message,
                    "exc_type": type(exc).__name__,
                }
            )
            raise SystemExit(1) from None


def _walk(exc: BaseException) -> Iterator[BaseException]:
    """``exc`` then its ``__cause__``/``__context__`` chain (cycle-safe)."""
    seen: set[int] = set()
    cur: BaseException | None = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        yield cur
        cur = cur.__cause__ or cur.__context__


def classify_startup_error(exc: BaseException) -> tuple[str, str]:
    """Map a fatal startup exception to ``(code, human message)``.

    Checked in priority order across the exception's cause chain, so a wrapped
    ``OSError(EADDRINUSE)`` still classifies as a busy port.
    """
    # Imported lazily so ``prefetch --json`` (which uses this module) does not load
    # the websocket server. The dependency is one-way: server never imports supervise.
    from .server import SocketInUseError, SocketPathConflictError

    chain = list(_walk(exc))
    message = str(exc) or type(exc).__name__
    for e in chain:
        if isinstance(e, ModuleNotFoundError):
            missing = f" ({e.name})" if e.name else ""
            return CODE_MODULE_NOT_FOUND, f"a backend dependency is not installed{missing}: {e}"
    for e in chain:
        if isinstance(e, SocketInUseError) or (
            isinstance(e, OSError) and e.errno == errno.EADDRINUSE
        ):
            return CODE_ADDR_IN_USE, f"address already in use: {e}"
    for e in chain:
        if isinstance(e, OSError) and e.errno == errno.EACCES:
            return CODE_ACCESS_DENIED, f"permission denied: {e}"
    for e in chain:
        if isinstance(e, SocketPathConflictError):
            return CODE_SOCKET_PATH_CONFLICT, str(e)
    for e in chain:
        module = type(e).__module__ or ""
        if module.startswith(_DOWNLOAD_MODULE_PREFIXES) or isinstance(
            e, (ConnectionError, TimeoutError)
        ):
            return CODE_MODEL_DOWNLOAD, f"model download failed: {e}"
    return CODE_BACKEND_START, message
