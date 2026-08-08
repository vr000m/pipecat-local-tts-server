"""Shared ``TTSStream`` base class for backends that drain one utterance
through the ``_stream_util`` bridge.

Every backend's stream adapter shares the same ``feed()``/``end()``/
``cancel()``/``wait_closed()``/``events()`` implementation; only
``_gen_factory`` (what actually gets passed to ``model.generate()``) and each
backend's own extra constructor state differ. See ``BridgedStream`` below for
the full lifecycle contract — this module docstring intentionally does not
enumerate subclasses, since that list drifts every time a new backend adopts
this base.

The per-backend streaming-bridge queue depth (``bridge_maxsize``) is a
constructor parameter, stored as ``self._bridge_maxsize`` and threaded into
``stream_generate(maxsize=...)`` — each subclass passes its own value, so
per-backend queue depths are unaffected by sharing this base.

Stdlib-only on purpose (same rule as the other ``_*_util`` siblings):
backends import this at module load, and the lean-import tests forbid
heavyweight roots (``mlx_audio``/``numpy``) at import time.
"""

from __future__ import annotations

import asyncio
import threading
from collections.abc import AsyncGenerator, Iterator
from typing import Any

from ..backend import AudioEvent
from ._stream_util import stream_generate


class BridgedStream:
    """Base ``TTSStream`` adapter for a segment-level (non sub-segment-
    streaming) backend that drains a plain ``model.generate(text, **extras)``
    generator through the shared ``_stream_util`` bridge.

    Subclasses call ``super().__init__(metal_lock=..., bridge_maxsize=...)``
    from their own ``__init__`` (existing subclasses do this first, but
    nothing here requires that ordering — ``__init__`` only sets plain
    instance attributes, none of which subclass state setup depends on), and
    MUST override ``_gen_factory`` — the base implementation raises
    ``NotImplementedError``.

    Attribute names below are load-bearing: existing tests reach into
    ``_metal_lock``, ``_text``, ``_cancel``, ``_external_cancel``,
    ``_worker_done``, and ``_worker_started`` directly.
    """

    def __init__(self, *, metal_lock: threading.Lock, bridge_maxsize: int) -> None:
        self._metal_lock = metal_lock
        self._bridge_maxsize = bridge_maxsize
        self._text = ""
        self._cancel = threading.Event()
        self._external_cancel = False
        # Set by the bridge worker as its final act (lock released + EOF
        # enqueued). ``wait_closed()`` awaits it so the server can hold a
        # commit's scheduler slot until the worker has truly exited and the
        # Metal lock is free — segments can be long, so this is load-bearing
        # for the cancel/Metal-lock semantics (dia.py's original rationale).
        self._worker_done = threading.Event()
        self._worker_started = False

    async def feed(self, text: str) -> None:
        if self._external_cancel:
            return
        self._text += text

    async def end(self) -> None:
        # Non-blocking end-of-input marker; synthesis runs lazily in events().
        return None

    async def cancel(self) -> None:
        self._external_cancel = True
        self._cancel.set()

    async def wait_closed(self, timeout: float | None = None) -> None:
        """Block (up to ``timeout`` seconds) until the synthesis worker has
        exited and released the Metal lock. Segments can be long, so a
        cancelled commit's ``generate()`` runs to its yield boundary before
        the lock frees; the server awaits this before freeing the slot so
        admission / ``queue_depth`` does not advertise free capacity while
        the next commit blocks on the still-held lock. ``None`` waits
        indefinitely; a finite timeout degrades (the next commit serializes
        on the lock) rather than hanging the dispatcher."""
        if not self._worker_started:
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._worker_done.wait, timeout)

    def _gen_factory(self) -> Iterator[Any]:
        raise NotImplementedError

    def _preflight_check(self) -> None:
        """Hook for a subclass to validate the committed ``self._text`` (and
        any other pre-synthesis state) before the worker thread starts and
        ``_gen_factory`` is invoked. No-op by default; a subclass overrides
        this to raise on an input shape known to trip a backend-specific
        failure mode (e.g. fish_tts's truncation-risk pre-flight guard). A
        raise here propagates out of ``events()`` before any Metal-lock work
        begins, so a rejected commit costs nothing beyond the check itself."""
        return

    async def events(self) -> AsyncGenerator[AudioEvent, None]:
        if self._external_cancel:
            return
        self._preflight_check()
        loop = asyncio.get_running_loop()
        self._worker_started = True
        async for pcm in stream_generate(
            self._gen_factory,
            loop=loop,
            metal_lock=self._metal_lock,
            cancel=self._cancel,
            maxsize=self._bridge_maxsize,
            worker_done=self._worker_done,
        ):
            if self._external_cancel:
                return
            yield AudioEvent(kind="delta", pcm=pcm)
        if self._external_cancel:
            return
        # EOF from generator exhaustion (NOT ``.is_final_chunk``).
        yield AudioEvent(kind="completed", pcm=b"")
