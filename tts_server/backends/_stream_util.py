"""Shared daemon-thread -> ``asyncio.Queue`` streaming bridge.

The single bridge every streaming-capable backend uses (Kokoro in Phase 2,
``voxtral_tts``/``pocket_tts`` in Phase 5) so "backend-agnostic" is enforced,
not aspirational. It is the one boundary stt's ``_thread_util`` does **not**
cross: ``_thread_util`` marshals a single Future per call (commit-then-drain),
whereas TTS streams need a per-chunk queue so audio reaches the client as each
``GenerationResult`` lands.

Invariants (R3 / Streaming-bridge spec / Architecture & Call Flow):

- A daemon thread acquires ``metal_lock`` (process-wide; Metal is not
  concurrency-safe) and holds it for the WHOLE generator-drain — the commit is
  the unit of GPU-lock holding.
- Each yielded result's ``.audio`` (float32 mono) is clipped+mapped to int16-LE
  PCM via the shared converter (R3) and pushed with **producer-side
  backpressure**: a full bridge blocks or cancels the producer, it never drops
  chunks and never schedules unbounded callbacks. Bare
  ``loop.call_soon_threadsafe`` is insufficient (it returns without applying
  backpressure), so the put goes through
  ``asyncio.run_coroutine_threadsafe(queue.put(pcm), loop).result(timeout=...)``.
- ``cancel`` (a ``threading.Event``) breaks the generator out so a cancelled
  response does not pin the lock.
- **EOF is enqueued on generator exhaustion in a ``finally``**, never keyed off
  ``.is_final_chunk`` (Kokoro never sets that field; it is advisory only).

This module stays stdlib-only so it imports on the lean base. The converter is
shared with ``ToneBackend`` via ``tts_server._audio``; the float->PCM mapping is
single-sourced there.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any, AsyncIterator, Callable, Iterator

from .._audio import float_to_pcm16

logger = logging.getLogger("tts_server.backends._stream_util")

# Sentinel enqueued on generator exhaustion / error to terminate iteration.
_EOF = object()


def _put_eof(queue: "asyncio.Queue") -> None:
    """Enqueue the EOF sentinel from inside a loop callback without backpressure.

    Runs on the event loop via ``call_soon_threadsafe``. A plain
    ``put_nowait(_EOF)`` raises ``QueueFull`` when the consumer broke out early
    (cancel) and left the bounded queue full — a spurious unhandled exception in
    the loop. Since the consumer has stopped reading, a buffered item is dead
    data: drain one slot to make room, then put. The post-drain put is wrapped in
    a final ``QueueFull`` swallow as a belt-and-suspenders guard (the queue has a
    single producer, so a slot freed here cannot be re-taken before the put).
    """
    try:
        queue.put_nowait(_EOF)
        return
    except asyncio.QueueFull:
        pass
    # Queue full: drop one buffered chunk (consumer is gone) and retry.
    try:
        queue.get_nowait()
    except asyncio.QueueEmpty:
        pass
    try:
        queue.put_nowait(_EOF)
    except asyncio.QueueFull:
        # Should not happen (single producer), but never let teardown raise.
        pass


# How long a producer put blocks before re-checking the cancel flag. Bounds the
# window between ``cancel`` being set and the producer thread noticing while it
# is parked on a full queue.
_PUT_TIMEOUT_SECONDS = 0.5

# How a result's audio is extracted. mlx-audio ``GenerationResult`` exposes
# ``.audio`` as a float32 mono ``mx.array``; ``list(...)`` materializes Python
# floats so the stdlib converter (no numpy/mlx) can map them. Kept here so a
# backend yields raw ``GenerationResult``s and the bridge owns conversion.


def _audio_to_pcm(result: Any) -> bytes:
    """Convert one ``GenerationResult`` (or a raw float sequence) to int16-LE PCM.

    Accepts either an object with an ``.audio`` attribute (the mlx-audio shape)
    or a bare iterable of floats (so tests can drive the bridge without mlx).
    """
    audio = getattr(result, "audio", result)
    # An mx.array / numpy array is iterable into Python scalars; ``list`` keeps
    # this module numpy-free at import time (we never import numpy/mlx here).
    return float_to_pcm16(list(audio))


async def stream_generate(
    gen_factory: Callable[[], Iterator[Any]],
    *,
    loop: asyncio.AbstractEventLoop,
    metal_lock: threading.Lock,
    cancel: threading.Event,
    maxsize: int,
) -> AsyncIterator[bytes]:
    """Drive a blocking ``model.generate()`` generator on a daemon thread and
    yield int16-LE PCM chunks with producer-side backpressure.

    ``gen_factory`` builds the (blocking) generator on the worker thread so the
    Metal lock is held for the whole drain. Iteration ends when the worker
    enqueues the EOF sentinel from its ``finally`` (generator exhaustion, cancel,
    or error). On a worker error the exception is re-raised in the consumer.
    """
    queue: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
    error_box: dict[str, BaseException] = {}

    def _put_blocking(item: object) -> bool:
        """Put ``item`` onto the async queue from the worker thread, applying
        backpressure. Returns False if cancelled while waiting (so the worker
        breaks out and releases the lock)."""
        while not cancel.is_set():
            fut = asyncio.run_coroutine_threadsafe(queue.put(item), loop)
            try:
                fut.result(timeout=_PUT_TIMEOUT_SECONDS)
                return True
            except TimeoutError:
                # Queue still full; cancel the pending put and re-check cancel.
                fut.cancel()
                continue
            except RuntimeError:
                # Event loop is gone (consumer torn down). Stop the worker.
                return False
        return False

    def _worker() -> None:
        # Acquire the process-wide Metal lock for the WHOLE drain. Independent
        # workers must not race for the lock; the caller serializes admission.
        metal_lock.acquire()
        try:
            gen = gen_factory()
            for result in gen:
                if cancel.is_set():
                    break
                pcm = _audio_to_pcm(result)
                if not pcm:
                    continue
                if not _put_blocking(pcm):
                    break
        except BaseException as exc:  # noqa: BLE001 - surfaced to the consumer
            error_box["error"] = exc
            logger.exception("tts_server: synthesis worker failed")
        finally:
            # EOF is ALWAYS enqueued on exhaustion/error/cancel — never keyed
            # off ``.is_final_chunk``. The sentinel must never apply
            # backpressure (teardown cannot block on a full queue), so it is
            # scheduled on the loop. But a bare ``queue.put_nowait`` inside the
            # callback raises ``QueueFull`` when the consumer broke out early
            # (cancel) leaving a full queue — that surfaces as a spurious
            # unhandled ``QueueFull`` in the loop. ``_put_eof`` drains one slot
            # if needed (the consumer is gone, so dropped data is irrelevant)
            # and swallows the residual full case, so EOF lands without noise.
            try:
                loop.call_soon_threadsafe(_put_eof, queue)
            except RuntimeError:
                # Event loop already closed (consumer fully torn down). The
                # consumer is no longer reading, so there is nothing to signal.
                pass
            metal_lock.release()

    thread = threading.Thread(target=_worker, name="tts-synth", daemon=True)
    thread.start()
    try:
        while True:
            item = await queue.get()
            if item is _EOF:
                break
            yield item
    finally:
        # Ensure the worker can break out and release the lock if the consumer
        # stops early (cancel / exception upstream).
        cancel.set()
    if "error" in error_box:
        raise error_box["error"]
