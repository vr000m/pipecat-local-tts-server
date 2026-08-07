"""Shared segment-level ``TTSStream`` base class.

``_DiaStream``, ``_Qwen3Stream``, and ``_FishStream`` all adapt one utterance
to the ``TTSStream`` protocol over the SAME shared ``_stream_util`` bridge:
``feed()``/``end()``/``cancel()``/``wait_closed()``/``events()`` are
byte-identical across all three (verified by direct read of the three
pre-extraction sources — not merely assumed from a paraphrase). Only
``_gen_factory`` (what actually gets passed to ``model.generate()``) and each
backend's own extra constructor state (dia: none; qwen3: voice + lang_code;
fish: none but keeps its own truncation-tripwire wrapper) differ.

The one non-identical piece folded into the constructor is the per-backend
streaming-bridge queue depth (dia/fish: 8, qwen3: 32) — previously a bare
module-level ``_BRIDGE_MAXSIZE`` constant read directly inside ``events()``.
Since the base class lives in a module shared by all three backends, that
constant becomes a constructor parameter (``bridge_maxsize``) stored as
``self._bridge_maxsize`` and threaded into ``stream_generate(maxsize=...)`` —
each subclass still passes its OWN value, so the effective queue depths are
unchanged (dia=8, qwen3=32, fish=8); this is a mechanical parameterization,
not a behavior change.

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


class SegmentStream:
    """Base ``TTSStream`` adapter for a segment-level (non sub-segment-
    streaming) backend that drains a plain ``model.generate(text, **extras)``
    generator through the shared ``_stream_util`` bridge.

    Subclasses MUST call ``super().__init__(metal_lock=..., bridge_maxsize=...)``
    from their own ``__init__`` before setting any additional state (model,
    extras, voice, ...), and MUST override ``_gen_factory`` — the base
    implementation raises ``NotImplementedError``.

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

    async def events(self) -> AsyncGenerator[AudioEvent, None]:
        if self._external_cancel:
            return
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
