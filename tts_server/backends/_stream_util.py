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
# is parked on a full queue. ALL puts (audio chunks AND the terminal EOF) re-poll
# ``cancel`` at this granularity, so no put is ever truly pinned: the consumer's
# ``finally: cancel.set()`` (run on break, exception, ``aclose``, or async-gen
# finalization) releases a parked producer within one timeout. This is why the
# EOF put can stay unbounded without risking a hung worker.
_PUT_TIMEOUT_SECONDS = 0.5

# How a result's audio is extracted. mlx-audio ``GenerationResult`` exposes
# ``.audio`` as a float32 mono ``mx.array``. It MUST be bulk-materialized to
# Python floats in one transfer before the stdlib converter walks it — see the
# sync-per-element trap in ``_audio_to_pcm``. Kept here so a backend yields raw
# ``GenerationResult``s and the bridge owns conversion.


def _audio_to_pcm(result: Any) -> bytes:
    """Convert one ``GenerationResult`` (or a raw float sequence) to int16-LE PCM.

    Accepts either an object with an ``.audio`` attribute (the mlx-audio shape)
    or a bare iterable of floats (so tests can drive the bridge without mlx).
    """
    audio = getattr(result, "audio", result)
    # CRITICAL: ``audio`` is an ``mx.array`` (float32 mono). Iterating it
    # element-by-element (which ``float_to_pcm16`` does) forces a device->host
    # sync PER element — O(samples) syncs, ~500x slower (a 3 s utterance took
    # ~40 s). Materialize it to a Python list in ONE bulk transfer first.
    # ``.tolist()`` exists on ``mx.array`` / numpy arrays; a bare list/iterable
    # (tests) has none and passes through unchanged. Duck-typed, so this stays
    # numpy/mlx-free at import time.
    if hasattr(audio, "tolist"):
        audio = audio.tolist()
    return float_to_pcm16(audio)


async def stream_generate(
    gen_factory: Callable[[], Iterator[Any]],
    *,
    loop: asyncio.AbstractEventLoop,
    metal_lock: threading.Lock,
    cancel: threading.Event,
    maxsize: int,
    worker_done: "threading.Event | None" = None,
) -> AsyncIterator[bytes]:
    """Drive a blocking ``model.generate()`` generator on a daemon thread and
    yield int16-LE PCM chunks with producer-side backpressure.

    ``gen_factory`` builds the (blocking) generator on the worker thread so the
    Metal lock is held for the whole drain. Iteration ends when the worker
    enqueues the EOF sentinel from its ``finally`` (generator exhaustion, cancel,
    or error). On a worker error the exception is re-raised in the consumer.

    ``worker_done`` (if supplied) is **set as the worker's final act**, after the
    Metal lock has been released and EOF enqueued. It lets a caller wait for the
    worker to fully exit — and thus the process-wide lock to be free — even on the
    cancel path where the consumer stops reading early (the async generator is
    abandoned and its ``finally`` may not run until GC). ``worker_done`` set
    therefore guarantees the lock is released.
    """
    queue: asyncio.Queue = asyncio.Queue(maxsize=maxsize)
    error_box: dict[str, BaseException] = {}

    def _put_blocking(item: object) -> bool:
        """Put ``item`` onto the async queue from the worker thread, applying
        backpressure. Returns False if cancelled while waiting (so the worker
        breaks out and releases the lock).

        Retries until the consumer drains a slot or ``cancel`` is set — the
        backpressure contract, used for both audio chunks and the terminal EOF.
        It re-polls ``cancel`` every ``_PUT_TIMEOUT_SECONDS``, so a parked
        producer is never pinned: the consumer's ``finally: cancel.set()``
        releases it on any teardown (break / exception / ``aclose`` / async-gen
        finalization).
        """
        while not cancel.is_set():
            fut = asyncio.run_coroutine_threadsafe(queue.put(item), loop)
            try:
                fut.result(timeout=_PUT_TIMEOUT_SECONDS)
                return True
            except TimeoutError:
                # Queue still full after the timeout. Try to cancel the pending
                # put before re-checking the cancel flag. ``fut.cancel()``
                # returns True only if the put had NOT completed — then the item
                # was not enqueued and it is safe to loop and retry. If it
                # returns False the put has already completed (or is completing)
                # on the loop, so the item IS enqueued exactly once; blindly
                # retrying here would put a DUPLICATE chunk (audible glitch /
                # wrong duration accounting). In that case wait out the put and
                # report success instead of re-enqueueing.
                if fut.cancel():
                    continue
                try:
                    fut.result()
                    return True
                except (RuntimeError, asyncio.CancelledError):
                    return False
                except Exception:
                    # The put itself failed; surface via the worker's handler.
                    raise
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
            # GPU/Metal work is finished once the generator is drained or broke
            # out; release the lock BEFORE the EOF enqueue so a slow consumer
            # cannot extend the lock hold and stall other connections' synthesis.
            metal_lock.release()
            # EOF is ALWAYS enqueued (exhaustion/error/cancel) — never keyed off
            # ``.is_final_chunk``. The PATH matters:
            #  - NORMAL exhaustion / worker error: the consumer is STILL draining,
            #    so EOF goes in WITH backpressure (unbounded ``_put_blocking``). A
            #    full queue must WAIT for a slot — dropping a buffered chunk here
            #    would silently truncate the tail of the audio, however SLOW the
            #    consumer is. The put is not pinned: ``_put_blocking`` re-polls
            #    ``cancel`` every ``_PUT_TIMEOUT_SECONDS`` and the consumer's
            #    ``finally: cancel.set()`` releases it on any teardown.
            #  - CANCEL (consumer has stopped reading), or cancel set WHILE the
            #    EOF put is parked: fall back to the non-blocking ``_put_eof``,
            #    which drops one now-dead buffered item if the queue is full so
            #    teardown can never block on a queue that nobody is draining.
            try:
                if cancel.is_set() or not _put_blocking(_EOF):
                    try:
                        loop.call_soon_threadsafe(_put_eof, queue)
                    except RuntimeError:
                        # Loop already closed (consumer fully torn down) — there
                        # is nothing left to signal.
                        pass
            except Exception:  # noqa: BLE001 - teardown must never raise out of the worker
                logger.exception("tts_server: EOF enqueue failed during worker teardown")
            finally:
                # The worker's last act: signal full exit. The Metal lock is
                # already released above, so an observer that sees this set can
                # rely on the lock being free (the slot is genuinely idle).
                if worker_done is not None:
                    worker_done.set()

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
