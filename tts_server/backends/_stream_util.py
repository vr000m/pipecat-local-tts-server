"""Shared daemon-thread -> ``asyncio.Queue`` streaming bridge (stub).

Phase 0 scaffolding — **stdlib-only** so the import-safety test stays green.
The real bridge lands in Phase 1.

Every streaming-capable backend (Kokoro, and later ``voxtral_tts`` /
``pocket_tts``) will share this one bridge so "backend-agnostic" is enforced,
not aspirational. The Phase 1 interface is::

    async def stream_generate(
        gen_factory: Callable[[], Iterator[GenerationResult]],
        *,
        loop: asyncio.AbstractEventLoop,
        metal_lock: threading.Lock,   # process-wide; held for the WHOLE drain
        cancel: threading.Event,      # set by TTSStream.cancel(); breaks out
        maxsize: int,                 # bounded queue; producer blocks when full
    ) -> AsyncIterator[bytes]: ...    # yields int16-LE PCM; EOF sentinel ends

A daemon thread acquires ``metal_lock``, runs ``gen_factory()``, converts each
yielded ``GenerationResult.audio`` (clipped/mapped per R3) to int16-LE PCM, and
performs a producer-side blocking/cooperative put into the bounded queue
(``call_soon_threadsafe`` alone does NOT apply backpressure). ``cancel`` breaks
the generator out (releasing the lock). EOF is enqueued on generator exhaustion
in a ``finally`` — NOT keyed off ``.is_final_chunk`` (Kokoro never sets it; it
is advisory only). This is the one boundary the stt ``_thread_util`` does not
cross (it marshals a single Future per call, not a per-chunk queue).
"""

from __future__ import annotations
