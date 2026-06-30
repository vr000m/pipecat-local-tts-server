"""dia multi-speaker DIALOGUE TTS backend (mlx-audio 0.4.4).

dia is a **dialogue** model: speakers are addressed purely in-text via ``[S1]``/
``[S2]`` tags inside an ordinary ``plain`` payload. It is segment-level (like
Kokoro — ``generate()`` returns a generator that yields one ``GenerationResult``
per ``split_pattern='\n'`` segment), NOT a sub-segment streamer, so it advertises
**``streaming:false``** and reuses the SAME shared ``_stream_util`` bridge with no
server-side change. Phase 0 (2026-06-30, ``mlx-community/Dia-1.6B-fp16``) verified
``model.sample_rate == 44100`` and the live signature::

    generate(text, voice=None, temperature=1.3, top_p=0.95, split_pattern='\n',
             max_tokens=None, verbose=False, ref_audio=None, ref_text=None,
             **kwargs)

Three deliberate departures from the single-voice sibling backends
(Kokoro/Pocket), all locked design decisions (see the dev plan):

1. **Voice-ignore is STRUCTURAL.** dia advertises ``voice_count: 0`` and defines
   no ``voices()`` method, so the server's ``_validate_voice`` treats it as having
   no voice concept and ACCEPTS a supplied ``voice`` rather than rejecting it
   (``server.py:752-768``) and carries it into ``open_stream`` (``server.py:1152``).
   The backend MUST therefore ignore it. To make "never build a ``voice`` kwarg"
   *unrepresentable* rather than merely test-enforced, ``_DiaStream`` takes NO
   ``voice`` parameter and stores no ``self._voice`` — ``open_stream(voice=...)``
   accepts the arg at the server-facing signature and DISCARDS it without
   threading it into the stream. This deliberately avoids Pocket's
   conditional-``voice=None``-omit look-alike, which would forward a non-None
   voice (the exact bug).
2. **No voice cloning.** Both ``ref_audio`` AND ``ref_text`` are real
   ``generate()`` kwargs (Phase 0) but are left UNWIRED (decision #2) — never
   advertised, never forwarded. ``_gen_factory`` only splats advertised, coerced
   extras, so neither can ever reach ``generate()``.
3. **extras are ``{temperature, top_p}``** — dia's two effective sampling
   tunables (verified via ``inspect.signature``). ``text_formats`` is
   ``["plain"]`` (dialogue tags ride inside plain text, undocumented on the wire).

Lazy-imports ``mlx_audio`` INSIDE ``start()`` — never at module load (the
lean-base invariant). Heavy deps stay behind the ``dia`` extra.
"""

from __future__ import annotations

import asyncio
import inspect
import logging
import math
import threading
from typing import Any, AsyncGenerator

from ..backend import AudioEvent, TTSStream
from ._stream_util import stream_generate

logger = logging.getLogger("tts_server.backends.dia")

# Default model for ``--backend dia``. The concrete repo id verified in Phase 0.
DEFAULT_DIA_MODEL = "mlx-community/Dia-1.6B-fp16"

# dia's advertised effective extras (R7), verified via ``inspect.signature``:
# ``temperature`` and ``top_p`` are dia's two sampling tunables. ORDERED list —
# ``docs/protocol.md`` + ``tests/test_capabilities_extras.py`` assert this exact
# order.
_DIA_EXTRAS = ["temperature", "top_p"]

# Params dia's generate() accepts that this backend MUST NEVER forward:
# ``ref_audio``/``ref_text`` are the voice-cloning channel (decision #2 — no
# cloning in v1). Kept here to document intent and anchor the negative-guard test;
# they are dropped by the advertised-extras filter regardless.
_FORBIDDEN_GENERATE_KWARGS = ("ref_audio", "ref_text")

# Accepted ranges for the sampling extras. Forwarded under the process-wide Metal
# lock, so unbounded values are a DoS / correctness vector: finite values are
# CLAMPED, non-finite (NaN/inf) or non-numeric are rejected outright.
_TEMPERATURE_MIN = 0.0
_TEMPERATURE_MAX = 2.0
_TOP_P_MIN = 0.0  # exclusive lower bound — a non-positive top_p is rejected, not clamped
_TOP_P_MAX = 1.0

# Chunk-size hints (R7). Chosen defaults, not model facts (mirrors Kokoro/Pocket).
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# Bounded depth of the daemon-thread -> asyncio bridge queue. dia yields one
# (potentially large) segment per ``\n`` group like Kokoro; a small bound keeps
# the send loop fed while applying producer-side backpressure.
_BRIDGE_MAXSIZE = 8

# dia is a dialogue model: only English is verified on-host, so that is all that
# is advertised.
_STATIC_LANGUAGES = ["en"]


def _coerce_temperature(raw: Any) -> float:
    """Validate + clamp a client-supplied ``temperature`` before generate()."""
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError(f"temperature must be a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise ValueError(f"temperature must be a finite number, got {raw!r}")
    if value < _TEMPERATURE_MIN:
        return _TEMPERATURE_MIN
    if value > _TEMPERATURE_MAX:
        return _TEMPERATURE_MAX
    return value


def _coerce_top_p(raw: Any) -> float:
    """Validate + clamp a client-supplied ``top_p`` before generate()."""
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError(f"top_p must be a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise ValueError(f"top_p must be a finite number, got {raw!r}")
    if value <= _TOP_P_MIN:
        # A non-positive top_p selects no tokens — reject rather than clamp to a
        # surprising tiny value (mirrors voxtral), so the client learns its
        # request was invalid instead of getting degenerate sampling.
        raise ValueError(f"top_p must be > 0 and <= 1, got {raw!r}")
    if value > _TOP_P_MAX:
        return _TOP_P_MAX
    return value


# Coercion dispatch for the advertised extras. Kept as a dict so the
# filter/validate code is identical in shape to Pocket/Voxtral.
_EXTRA_COERCERS = {"temperature": _coerce_temperature, "top_p": _coerce_top_p}


class _DiaStream:
    """Adapts one dia dialogue utterance to the ``TTSStream`` protocol.

    Structurally identical to ``_KokoroStream`` (the streaming seam is
    backend-agnostic; dia is segment-level, so it drains a plain
    ``model.generate(text, **extras)`` generator through the shared bridge), with
    ONE deliberate departure: there is **no ``voice`` parameter** and no
    ``self._voice`` member. dia ignores ``voice`` entirely (decision #1); omitting
    it from the constructor makes "never build a ``voice`` kwarg" unrepresentable
    rather than test-enforced. ``ref_audio``/``ref_text`` are never built either
    (decision #2) — only advertised, coerced extras splat into ``generate()``.
    """

    def __init__(
        self,
        *,
        model: Any,
        extras: dict[str, Any],
        metal_lock: threading.Lock,
    ) -> None:
        self._model = model
        self._extras = extras  # pre-coerced advertised extras only
        self._metal_lock = metal_lock
        self._text = ""
        self._cancel = threading.Event()
        self._external_cancel = False
        # Set by the bridge worker as its final act (lock released + EOF
        # enqueued). ``wait_closed()`` awaits it so the server can hold a
        # commit's scheduler slot until the worker has truly exited and the Metal
        # lock is free — dia segments can be long, so this is load-bearing for the
        # cancel/Metal-lock semantics (decision #3).
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
        exited and released the Metal lock. dia segments can be long, so a
        cancelled commit's ``generate()`` runs to its yield boundary before the
        lock frees; the server awaits this before freeing the slot so admission /
        ``queue_depth`` does not advertise free capacity while the next commit
        blocks on the still-held lock. ``None`` waits indefinitely; a finite
        timeout degrades (the next commit serializes on the lock) rather than
        hanging the dispatcher."""
        if not self._worker_started:
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._worker_done.wait, timeout)

    def _gen_factory(self):
        # Built on the worker thread (inside the Metal lock) so the whole drain is
        # serialized. dia is segment-level (split_pattern='\n'), so generate()
        # returns a generator of GenerationResults — NO ``stream`` param. The
        # committed buffer (with its ``[S1]``/``[S2]`` tags intact) is fed
        # verbatim. ``voice`` is NEVER built (decision #1 — there is no
        # ``self._voice`` to forward); ``ref_audio``/``ref_text`` are NEVER built
        # (decision #2). Only advertised, coerced extras splat in.
        return self._model.generate(self._text, **self._extras)

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
            maxsize=_BRIDGE_MAXSIZE,
            worker_done=self._worker_done,
        ):
            if self._external_cancel:
                return
            yield AudioEvent(kind="delta", pcm=pcm)
        if self._external_cancel:
            return
        # EOF from generator exhaustion (NOT ``.is_final_chunk``).
        yield AudioEvent(kind="completed", pcm=b"")


class DiaBackend:
    """mlx-audio dia dialogue backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "dia"

    def __init__(self, *, model: str = DEFAULT_DIA_MODEL) -> None:
        self._model_id = model
        # Public identity for ``server.hello`` / ``server.status``.
        self.model = model
        # The loaded mlx-audio model. ``None`` until ``start()``.
        self._loaded_model: Any = None
        # Rate is read from ``model.sample_rate`` in ``start()`` (pre-warmup);
        # 0 before load means "not started". Phase 0 recorded 44100.
        self.sample_rate = 0
        # Process-wide Metal lock: Metal is not concurrency-safe, so every drain
        # serializes on this one lock (the commit is the unit of GPU-lock holding).
        self._metal_lock = threading.Lock()
        self._languages: list[str] = list(_STATIC_LANGUAGES)

    async def start(self) -> None:
        # Lazy import — the ONLY place ``mlx_audio`` enters the process. Fails
        # fast here (not at module load / construction) if the extra is absent.
        from mlx_audio.tts.utils import load  # type: ignore

        loop = asyncio.get_running_loop()
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )

        # Re-verify the live ``generate()`` signature (R7/R8). Phase 0 pinned
        # ``mlx-audio==0.4.4``; a future bump that drops ``temperature``/``top_p``
        # or makes ``voice`` positionally required would silently break the
        # contract. Warn (do not hard-fail) so an upstream signature reshape is
        # actionable rather than fatal at serve time.
        self._verify_generate_signature()

        # Rate is a config property available IMMEDIATELY after load — no
        # warmup-generate needed to learn it (R1/R3). Phase 0: dia = 44100.
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "dia: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract (R1)"
            )
        self.sample_rate = int(rate)

        logger.info(
            "dia: serving dialogue backend, rate %d, languages %s",
            self.sample_rate,
            self._languages,
        )

        await loop.run_in_executor(None, self._warmup)

    def _verify_generate_signature(self) -> None:
        """Re-verify dia's ``generate()`` accepts the params this backend relies
        on. Best-effort: a mismatch is logged (actionable) rather than raised, so
        an upstream reshape surfaces in the operator log instead of wedging serve.
        Phase 0 (mlx-audio 0.4.4): ``generate(text, voice=None, temperature=1.3,
        top_p=0.95, split_pattern='\\n', max_tokens=None, verbose=False,
        ref_audio=None, ref_text=None, **kwargs)``."""
        try:
            sig = inspect.signature(self._loaded_model.generate)
        except (TypeError, ValueError) as exc:  # pragma: no cover - upstream shape
            logger.warning("dia: could not introspect generate() signature: %s", exc)
            return
        params = sig.parameters
        has_kwargs = any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values())
        for name in _DIA_EXTRAS:
            if name not in params and not has_kwargs:
                logger.warning(
                    "dia: generate() does not accept advertised extra %r "
                    "(signature reshape under the pinned wheel?) — it will be "
                    "swallowed/error at synthesis",
                    name,
                )

    def _warmup(self) -> None:
        """Drain a tiny dialogue generate under the Metal lock to JIT-compile
        kernels. Best-effort; rate discovery does NOT depend on it (R3)."""
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate("[S1] Hello there. [S2] Hi."):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("dia: warmup generate failed (non-fatal): %s", exc)

    def capabilities(self) -> dict:
        return {
            # ``streaming:false`` = no SUB-segment streaming; dia is segment-level
            # (split_pattern='\n'), the server emits each segment as it completes.
            "streaming": False,
            "binary_audio": False,
            # Dialogue tags ride inside ``plain`` (decision #2) — no new format.
            "text_formats": ["plain"],
            "languages": list(self._languages),
            # Speaker control is purely in-text via ``[S1]``/``[S2]`` (decision
            # #1): no enumerable voices. ``voice_count: 0`` makes the server's
            # ``_validate_voice`` accept a supplied voice instead of rejecting it,
            # and the backend ignores it (no ``voices()`` method is defined).
            "voice_count": 0,
            # dia's effective set ONLY (R7): temperature + top_p, in this order.
            # ``ref_audio``/``ref_text`` are deliberately ABSENT (no cloning,
            # decision #2).
            "extras": list(_DIA_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def validate_extras(self, extras: dict) -> str | None:
        """``SupportsExtrasValidation``: reject a malformed advertised extra at
        the trust boundary (commit/update) so the client gets a clean
        ``INVALID_CONFIG`` instead of a mid-synthesis ``BACKEND_ERROR`` raised
        under the Metal lock. Only advertised keys are checked."""
        for key, coerce in _EXTRA_COERCERS.items():
            raw = extras.get(key)
            if raw is None:
                continue
            try:
                coerce(raw)
            except ValueError as exc:
                return str(exc)
        return None

    async def open_stream(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
    ) -> TTSStream:
        if self._loaded_model is None:
            raise RuntimeError("dia: open_stream() called before start()")
        # ``voice`` is accepted at the server-facing signature (the server carries
        # a client voice through here because dia advertises ``voice_count: 0``,
        # which makes ``_validate_voice`` ACCEPT it) and DISCARDED — it is never
        # threaded into ``_DiaStream`` (decision #1). The discard is structural:
        # ``_DiaStream`` has no ``voice`` param to forward it to.
        # ``language`` is accepted for protocol uniformity but dia has no
        # ``lang_code`` kwarg, so it is not forwarded.
        # DROP any kwarg outside the advertised effective set — only
        # ``temperature``/``top_p`` survive; ``ref_audio``/``ref_text`` can never
        # reach ``generate()`` because only keys in ``_EXTRA_COERCERS`` are copied.
        effective: dict[str, Any] = {}
        if extras:
            for key, coerce in _EXTRA_COERCERS.items():
                raw = extras.get(key)
                if raw is not None:
                    effective[key] = coerce(raw)
        return _DiaStream(
            model=self._loaded_model,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        # Release the model so its mlx/Metal resources can be reclaimed.
        self._loaded_model = None
