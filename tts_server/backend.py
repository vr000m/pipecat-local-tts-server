"""TTS backend abstraction and the dependency-free ``ToneBackend`` reference.

The server depends on this abstraction rather than on mlx-audio objects so
alternate backends (Kokoro, voxtral_tts, pocket_tts, dia) can be swapped without
touching protocol/session code.

**The streaming lifecycle here is net-new, NOT an stt mirror.** stt is
*commit-then-drain*: ``end()`` blocks until the full transcript and ``events()``
replays a stored result. That shape is the **anti-pattern** for TTS (it violates
the R1 rate and R4 steady-stream contracts). For TTS:

- ``end()`` returns BEFORE the first segment completes (it signals end-of-input
  and kicks the worker — it does not block on synthesis);
- ``events()`` yields an ``AudioEvent`` per segment **as audio lands**, then a
  ``completed`` event on generator exhaustion (NOT keyed off any
  ``is_final_chunk`` flag).

``ToneBackend`` is the *streaming* reference (unlike stt's one-shot
``EchoBackend``): it emits multiple segments with a configurable per-segment
delay so it drives the per-segment ``events()`` contract AND the 20 ms
re-chunker. It is stdlib-only (``math``/``array``/``struct`` via ``_audio``) —
no numpy, no mlx.

stdlib-only at module load; heavy backends lazy-import their deps inside
``start()``/``open_stream``.
"""

from __future__ import annotations

import asyncio
import math
from dataclasses import dataclass
from typing import AsyncGenerator, Protocol, runtime_checkable

from ._audio import float_to_pcm16


@dataclass
class AudioEvent:
    """One audio event yielded by a backend stream.

    ``kind`` is ``"delta"`` (carries PCM) or ``"completed"`` (empty ``pcm``,
    fired on generator exhaustion). ``pcm`` is int16-LE mono at the backend's
    ``sample_rate``.
    """

    kind: str  # "delta" | "completed"
    pcm: bytes  # int16-LE mono; empty on "completed"


@runtime_checkable
class TTSStream(Protocol):
    async def feed(self, text: str) -> None: ...
    async def end(self) -> None: ...
    # Async-generator function: implementations must be ``async def`` with
    # ``yield`` so callers can ``async for ev in stream.events()``. Declared as
    # AsyncGenerator (not AsyncIterator) so the structural check rejects an
    # implementation that returns a plain coroutine.
    def events(self) -> AsyncGenerator[AudioEvent, None]: ...
    async def cancel(self) -> None: ...


@runtime_checkable
class TTSBackend(Protocol):
    # Identity surfaced in ``server.hello``/``server.status`` so a client can
    # verify which model is behind a socket. ``model`` is ``None`` for backends
    # with no model (tone).
    backend_name: str
    model: str | None
    # The per-session rate contract (R1): advertised in ``server.hello`` and the
    # exact rate of every ``response.audio.delta`` frame. Readable after
    # ``start()`` (for Kokoro, from ``model.sample_rate`` — pre-warmup).
    sample_rate: int

    def capabilities(self) -> dict: ...
    # Full voice list (decided default #4: count in ``server.hello``, full list
    # via ``server.status``). Optional — the server reads it via ``getattr`` and
    # tolerates a backend that does not implement it.
    def voices(self) -> list[str]: ...
    async def start(self) -> None: ...
    async def open_stream(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
    ) -> TTSStream: ...
    async def close(self) -> None: ...


# ---------------------------------------------------------------------------
# ToneBackend — a dependency-free streaming reference for tests/smoke-checks.
# ---------------------------------------------------------------------------


class _ToneStream:
    """Emits ``segment_count`` sine segments, each ``segment_ms`` long, with a
    ``segment_delay_ms`` pause before each segment lands.

    The delay drives the steady-stream contract test (first audio must arrive
    before the whole utterance is synthesized, with a bounded inter-delta gap).
    EOF comes from generator exhaustion — there is no ``is_final_chunk`` flag,
    mirroring Kokoro (Testing Notes: "EOF without ``.is_final_chunk``").
    """

    def __init__(
        self,
        *,
        sample_rate: int,
        frequency: float,
        amplitude: float,
        segment_count: int,
        segment_ms: int,
        segment_delay_ms: int,
        raises: bool,
    ) -> None:
        self._sample_rate = sample_rate
        self._frequency = frequency
        self._amplitude = amplitude
        self._segment_count = segment_count
        self._segment_ms = segment_ms
        self._segment_delay_ms = segment_delay_ms
        self._raises = raises
        self._text = ""
        self._cancelled = asyncio.Event()

    async def feed(self, text: str) -> None:
        self._text += text

    async def end(self) -> None:
        # Non-blocking: signal end-of-input only. Synthesis (and any delay)
        # happens lazily inside ``events()`` as each segment lands, so ``end()``
        # returns before the first segment completes (the R4 contract).
        return None

    async def cancel(self) -> None:
        self._cancelled.set()

    def _segment_pcm(self, segment_idx: int) -> bytes:
        n = int(self._sample_rate * self._segment_ms / 1000)
        # Continuous phase across segments so a multi-segment utterance is one
        # uninterrupted tone (no per-segment click), making rate-exactness and
        # reassembly assertions deterministic.
        base = segment_idx * n
        two_pi_f = 2.0 * math.pi * self._frequency
        samples = (
            self._amplitude * math.sin(two_pi_f * (base + i) / self._sample_rate) for i in range(n)
        )
        return float_to_pcm16(samples)

    async def events(self) -> AsyncGenerator[AudioEvent, None]:
        if self._cancelled.is_set():
            return
        if self._raises:
            raise RuntimeError("ToneBackend synthesis failure (test fixture)")
        for idx in range(self._segment_count):
            if self._cancelled.is_set():
                return
            if self._segment_delay_ms > 0:
                # Sleep so the next segment "lands" after a delay. A cancel
                # during the wait breaks out promptly (barge-in).
                try:
                    await asyncio.wait_for(
                        self._cancelled.wait(), timeout=self._segment_delay_ms / 1000.0
                    )
                    # cancel fired during the wait
                    return
                except asyncio.TimeoutError:
                    pass
            if self._cancelled.is_set():
                return
            yield AudioEvent(kind="delta", pcm=self._segment_pcm(idx))
        # EOF from exhaustion (NOT a flag).
        yield AudioEvent(kind="completed", pcm=b"")


class ToneBackend:
    """Dependency-free sine backend. The streaming reference for Phase 1 tests.

    Defaults emit 3 segments of 100 ms each with a 120 ms per-segment delay,
    which exercises the multi-segment streaming path and the 20 ms re-chunker
    (100 ms is a clean multiple of 20 ms; the re-chunker's short-tail behaviour
    is exercised by feeding a non-multiple total elsewhere). Construct with
    ``raises=True`` to drive the ``response.failed`` path.
    """

    backend_name = "tone"
    model = None

    def __init__(
        self,
        *,
        sample_rate: int = 24000,
        frequency: float = 440.0,
        amplitude: float = 0.5,
        segment_count: int = 3,
        segment_ms: int = 100,
        segment_delay_ms: int = 120,
        raises: bool = False,
        ideal_words: int = 40,
        max_text_chars: int = 2000,
        languages: list[str] | None = None,
        extras: list[str] | None = None,
    ) -> None:
        self.sample_rate = sample_rate
        self._frequency = frequency
        self._amplitude = amplitude
        self._segment_count = segment_count
        self._segment_ms = segment_ms
        self._segment_delay_ms = segment_delay_ms
        self._raises = raises
        self._ideal_words = ideal_words
        self._max_text_chars = max_text_chars
        self._languages = languages if languages is not None else ["en"]
        # ``extras`` are the accepted model-kwarg names this backend advertises
        # and forwards. ToneBackend forwards nothing to a real model, but it
        # advertises a non-empty set so the capabilities / unknown-extras-drop /
        # collision tests have something to validate against.
        self._extras = extras if extras is not None else ["speed"]

    def capabilities(self) -> dict:
        return {
            "streaming": False,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            "voice_count": 1,
            "extras": list(self._extras),
            "ideal_words": self._ideal_words,
            "max_text_chars": self._max_text_chars,
        }

    def voices(self) -> list[str]:
        # Decided default #4: full voice list via ``server.status``. ToneBackend
        # has a single synthetic voice.
        return ["tone"]

    async def start(self) -> None:
        return None

    async def open_stream(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
    ) -> TTSStream:
        return _ToneStream(
            sample_rate=self.sample_rate,
            frequency=self._frequency,
            amplitude=self._amplitude,
            segment_count=self._segment_count,
            segment_ms=self._segment_ms,
            segment_delay_ms=self._segment_delay_ms,
            raises=self._raises,
        )

    async def close(self) -> None:
        return None
