"""Voxtral TTS backend (mlx-audio 0.4.4) — the streaming reference backend (5a).

Unlike Kokoro (``streaming:false``, one ``GenerationResult`` per ``\\n+``
segment), Voxtral is a genuine **sub-segment streamer**: ``generate(stream=True,
streaming_interval=...)`` yields a ``GenerationResult`` roughly every
``streaming_interval`` seconds of audio (measured: 19 chunks for a 4.4 s single
sentence at 0.3 s — see ``## Findings`` → *Phase 5a measurements*). It therefore
exercises the ``streaming:true`` no-split client path that Kokoro/Tone cannot.

Lazy-imports ``mlx_audio`` INSIDE ``start()`` — never at module load (the
**lean-base invariant**: ``import tts_server.backends.voxtral_tts`` must succeed
with the ``voxtral_tts`` extra absent and must NOT pull ``mlx_audio``). The heavy
deps (``mlx_audio`` + ``mistral-common[audio]`` for the tekken tokenizer) stay
behind the extra.

LICENSE (non-commercial): the weights this backend loads
(``mlx-community/Voxtral-4B-TTS-2603-mlx-bf16``) are **CC-BY-NC**. The package
ships only the runtime; weights download on first ``start()``. Operators must
honour the model license. Kokoro (Apache-2.0) is the commercial-safe default.

Streaming lifecycle (R3 / R4 / Architecture & Call Flow) — identical seam to
Kokoro, only the model + ``generate()`` kwargs differ:

- ``start()`` calls ``mlx_audio.tts.utils.load(model_path, lazy=False,
  strict=True)`` and reads the rate from ``model.sample_rate`` (24000),
  available **pre-warmup** (R1/R3). Rate discovery is decoupled from warmup.
- ``open_stream()`` returns a ``_VoxtralStream`` whose ``events()`` drains
  ``model.generate(text, stream=True, streaming_interval=_STREAMING_INTERVAL,
  **kwargs)`` through the SHARED ``_stream_util.stream_generate`` bridge — the
  same per-chunk queue Kokoro uses, NO bridge change. The bridge holds the
  process-wide Metal lock for the whole drain, converts each
  ``GenerationResult.audio`` (float32 mono) to int16-LE PCM (R3 clip+map), and
  ends on **generator exhaustion** — NOT ``.is_final_chunk``. (Voxtral *does*
  set ``is_final_chunk=True`` on its last chunk, unlike Kokoro; correctness does
  not depend on it — exhaustion handles both shapes.)

``extras`` is Voxtral's EFFECTIVE set ONLY: ``["temperature", "top_k",
"top_p"]`` (verified via ``inspect.signature`` on the live 0.4.4 callable). The
``generate()`` signature is ``(text, voice='casual_male', temperature, top_k,
top_p, max_tokens, verbose, stream, streaming_interval, **kwargs)`` — there is
**no ``ref_audio``** (so no cloning concern, decision #2) and **no
``lang_code``** (language is selected by the ``voice`` preset, not a separate
kwarg). Anything outside the advertised set is dropped before the call so the
contract never lies.

``voice`` handling (the ``voice=None`` rule): the server forwards
``voice=None`` straight into ``open_stream`` by design; the omit-when-None logic
lives HERE, mirroring Kokoro's ``speed``-omit pattern applied to ``voice``. When
the resolved ``voice is None`` the ``voice`` kwarg is OMITTED from
``generate()`` so Voxtral's own default (``'casual_male'``) stands rather than
forwarding ``voice=None``.
"""

from __future__ import annotations

import asyncio
import logging
import math
import threading
from typing import Any, AsyncGenerator

from ..backend import AudioEvent, TTSStream
from ._stream_util import stream_generate

logger = logging.getLogger("tts_server.backends.voxtral_tts")

# Default model for ``--backend voxtral_tts``. The only model the upstream
# ``voxtral_tts`` arch supports (per its README). Exported so the CLI's
# backend-aware ``--model`` default imports it rather than hardcoding a copy.
DEFAULT_VOXTRAL_MODEL = "mlx-community/Voxtral-4B-TTS-2603-mlx-bf16"

# Voxtral's advertised effective extras (R7), verified via ``inspect.signature``
# on the live 0.4.4 ``Model.generate``. ``temperature``/``top_k``/``top_p`` are
# the sampling tunables; everything else (``max_tokens``/``verbose``) is not a
# client knob. ``streaming_interval`` is BACKEND CONFIG (a module constant
# below), never a client extra — advertising it would let a client inflate TTFB.
_VOXTRAL_EXTRAS = ["temperature", "top_k", "top_p"]

# Per-backend streaming cadence — a MODULE CONSTANT baked into the generate()
# call (exactly how kokoro.py hardcodes lang_code/speed), NOT a constructor
# param / CLI flag / client extra. With ``stream=True`` the model yields a
# ``GenerationResult`` roughly every ``_STREAMING_INTERVAL`` seconds of audio,
# so this bounds the ADDED buffering latency before the first chunk (the 20 ms
# re-chunker downstream cannot lower TTFB — it only re-frames AFTER a chunk
# lands).
#
# LOCKED at 0.3 s from measurement (## Findings → Phase 5a, arm64, mlx-audio
# 0.4.4, Voxtral-4B-TTS-2603-mlx-bf16): TTFB at 0.3/0.5/1.0 s = 0.395/0.637/
# 1.126 s — 0.3 s gives the lowest TTFB and finest cadence (19 native chunks for
# a 4.4 s sentence) with no NaN/clipping (peak 0.192). Steady-state is safe: on a
# 15.3 s utterance the mean inter-chunk gap (0.254 s) is below the ~0.3 s of
# audio each chunk carries, so production stays ahead of realtime and the
# client's playback buffer does not starve (R4). The overall RTF (~1.07–1.17) is
# one-time prefill cost, not a steady-state stall. The backend test asserts
# equality to THIS single value (never a range).
_STREAMING_INTERVAL = 0.3

# Bounded depth of the daemon-thread -> asyncio bridge queue. Voxtral emits MANY
# SMALL sub-segment chunks (~one per ``_STREAMING_INTERVAL``: 19 for a 4.4 s
# sentence, 64 for a 15 s one) — unlike Kokoro's FEW LARGE per-segment chunks
# (``_BRIDGE_MAXSIZE=8`` there). A larger bound keeps the send loop fed across
# the finer cadence while still applying producer-side backpressure; 32 chunks
# at ~0.3 s each is ~9.6 s of headroom, ample without unbounded buffering. Each
# backend declares its OWN value (the rule is *don't share the constant*); the
# ``maxsize`` arg already exists on ``stream_generate`` — no bridge change.
_BRIDGE_MAXSIZE = 32

# Chunk-size hints (R7). Soft client target / hard server cap; chosen defaults,
# not model facts (mirrors Kokoro).
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# Sampling-extra bounds. ``generate()`` forwards these under the process-wide
# Metal lock, so unbounded values are a denial-of-service / correctness vector:
# a degenerate ``top_p``/``temperature`` can drive runaway or broken sampling
# that stalls every other connection's commit. Finite values are CLAMPED;
# non-finite (NaN/inf) or non-numeric values are rejected outright.
_TEMPERATURE_MIN = 0.0
_TEMPERATURE_MAX = 2.0
_TOP_K_MIN = 1
_TOP_K_MAX = 500
_TOP_P_MIN = 0.0  # exclusive lower bound enforced in _coerce_top_p
_TOP_P_MAX = 1.0


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


def _coerce_top_k(raw: Any) -> int:
    """Validate + clamp a client-supplied ``top_k`` (a positive integer)."""
    if isinstance(raw, bool):  # bool is an int subclass; reject it explicitly.
        raise ValueError(f"top_k must be an integer, got {raw!r}")
    # Reject a non-integral float (e.g. 2.9) rather than silently truncating to 2
    # — the client should learn its value was not an integer, not get a quietly
    # different one. Integral floats (50.0) and int-valued strings ("40") are ok.
    if isinstance(raw, float) and not raw.is_integer():
        raise ValueError(f"top_k must be an integer, got {raw!r}")
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise ValueError(f"top_k must be an integer, got {raw!r}") from None
    if value < _TOP_K_MIN:
        return _TOP_K_MIN
    if value > _TOP_K_MAX:
        return _TOP_K_MAX
    return value


def _coerce_top_p(raw: Any) -> float:
    """Validate + clamp a client-supplied ``top_p`` into ``(0, 1]``."""
    try:
        value = float(raw)
    except (TypeError, ValueError):
        raise ValueError(f"top_p must be a number, got {raw!r}") from None
    if not math.isfinite(value):
        raise ValueError(f"top_p must be a finite number, got {raw!r}")
    if value <= _TOP_P_MIN:
        # A non-positive top_p selects no tokens — reject rather than clamp to a
        # surprising tiny value, so the client learns its request was invalid.
        raise ValueError(f"top_p must be > 0 and <= 1, got {raw!r}")
    if value > _TOP_P_MAX:
        return _TOP_P_MAX
    return value


# Coercion dispatch for the advertised extras. Keyed by extra name so
# ``validate_extras`` and ``open_stream`` share one source of truth.
_EXTRA_COERCERS = {
    "temperature": _coerce_temperature,
    "top_k": _coerce_top_k,
    "top_p": _coerce_top_p,
}

# Voice-name prefix -> ISO language. Voxtral encodes language in the voice preset
# (there is no ``lang_code`` kwarg): a ``<iso>_<gender>`` voice maps to that ISO
# code; the English presets (``casual_*``/``cheerful_*``/``neutral_*``) have no
# prefix and map to ``en``. Verified against the loaded model's 20 voice presets.
_VOICE_PREFIX_TO_ISO = {
    "ar": "ar",
    "de": "de",
    "es": "es",
    "fr": "fr",
    "hi": "hi",
    "it": "it",
    "nl": "nl",
    "pt": "pt",
}

# Canonical advertised order (English first, then the multilingual set). Used to
# keep ``capabilities()["languages"]`` deterministic across runs and as the
# static fallback if voice discovery fails.
_STATIC_LANGUAGES = ["en", "fr", "es", "de", "it", "pt", "nl", "ar", "hi"]
# Static fallback voice count (the model ships 20 presets across 9 languages).
_STATIC_VOICE_COUNT = 20


class _VoxtralStream:
    """Adapts one Voxtral utterance to the ``TTSStream`` protocol.

    Structurally identical to ``_KokoroStream`` (the streaming seam is
    backend-agnostic): ``feed()`` accumulates text; ``end()`` is non-blocking;
    ``events()`` drives the shared bridge and yields a ``delta`` per native
    sub-segment chunk, then a ``completed`` on generator exhaustion; ``cancel()``
    sets the bridge's cancel event so the generator breaks out and releases the
    Metal lock. The only difference is ``_gen_factory`` — it builds the streaming
    ``generate()`` with Voxtral's kwargs and the ``voice``-omit rule.
    """

    def __init__(
        self,
        *,
        model: Any,
        voice: str | None,
        extras: dict[str, Any],
        metal_lock: threading.Lock,
    ) -> None:
        self._model = model
        self._voice = voice
        # Pre-coerced effective extras (only advertised keys, values validated).
        self._extras = extras
        self._metal_lock = metal_lock
        self._text = ""
        # Bridge break-out signal (see _KokoroStream for the cancel-vs-exhaustion
        # distinction the two flags encode).
        self._cancel = threading.Event()
        self._external_cancel = False
        self._worker_done = threading.Event()
        self._worker_started = False

    async def feed(self, text: str) -> None:
        if self._external_cancel:
            return
        self._text += text

    async def end(self) -> None:
        # Non-blocking end-of-input marker (R4 steady-stream contract).
        return None

    async def cancel(self) -> None:
        self._external_cancel = True
        self._cancel.set()

    async def wait_closed(self, timeout: float | None = None) -> None:
        """Block (up to ``timeout``) until the worker has exited and released the
        Metal lock. See ``_KokoroStream.wait_closed`` for the full rationale —
        the server awaits this before freeing a cancelled commit's slot."""
        if not self._worker_started:
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._worker_done.wait, timeout)

    def _gen_factory(self):
        # Built on the worker thread (inside the Metal lock) so the whole
        # generator-drain is serialized. ``stream=True`` makes generate() a
        # sub-segment generator; ``streaming_interval`` is the locked backend
        # constant. ``voice`` follows the voice=None-OMIT rule (replicating
        # Kokoro's speed-omit): omitted when None so Voxtral's own default
        # (``'casual_male'``) stands. Advertised extras splat in last.
        kwargs: dict[str, Any] = {}
        if self._voice is not None:
            kwargs["voice"] = self._voice
        kwargs.update(self._extras)
        return self._model.generate(
            self._text,
            stream=True,
            streaming_interval=_STREAMING_INTERVAL,
            **kwargs,
        )

    async def events(self) -> AsyncGenerator[AudioEvent, None]:
        if self._external_cancel:
            return
        loop = asyncio.get_running_loop()
        self._worker_started = True
        # Shared bridge owns Metal-lock acquisition for the whole drain, float32
        # -> int16-LE PCM conversion (R3), bounded backpressure, and EOF on
        # generator exhaustion (NOT ``.is_final_chunk``).
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
        yield AudioEvent(kind="completed", pcm=b"")


class VoxtralBackend:
    """mlx-audio Voxtral TTS backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "voxtral_tts"

    def __init__(self, *, model: str = DEFAULT_VOXTRAL_MODEL) -> None:
        self._model_id = model
        # Public identity for ``server.hello`` / ``server.status``.
        self.model = model
        self._loaded_model: Any = None
        # Rate is read from ``model.sample_rate`` in ``start()`` (pre-warmup);
        # 0 before load means "not started".
        self.sample_rate = 0
        # Process-wide Metal lock: Metal is not concurrency-safe, so every
        # generate drain across all sessions serializes on this one lock. The
        # commit is the unit of GPU-lock holding (R3/R4).
        self._metal_lock = threading.Lock()
        # Voice/language facts derived from the model in ``start()``.
        self._voice_count = 0
        self._voice_names: list[str] = []
        self._languages: list[str] = []

    async def start(self) -> None:
        # Lazy import — the ONLY place ``mlx_audio`` enters the process. Fails
        # fast here (not at module load / construction) if the extra is absent.
        from mlx_audio.tts.utils import load  # type: ignore

        loop = asyncio.get_running_loop()
        # ``load(lazy=False)`` evaluates params immediately and downloads the
        # checkpoint if not cached. Run it off the event loop so the connect
        # handshake's load step does not block other coroutines. (No
        # ``model_type`` override needed: the mlx-community repo's config routes
        # to the ``voxtral_tts`` arch directly.)
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )
        # Rate is a config property available IMMEDIATELY after load — no
        # warmup-generate needed to learn it (R1/R3). Read from the model, never
        # a hardcoded literal, so a wrong constant can't satisfy the rate test.
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "voxtral_tts: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract (R1)"
            )
        self.sample_rate = int(rate)

        # Derive voice count + languages from the model's voice presets
        # (data-driven, not a hardcoded copy). Falls back to the verified static
        # facts if the attribute is absent (a future mlx-audio may restructure).
        # Called directly (NOT via run_in_executor, unlike Kokoro's
        # _discover_voices): this is a pure in-memory attribute walk over the
        # already-loaded model's voice-preset dict — no I/O / network (Kokoro's
        # goes through snapshot_download, which is why it needs the executor).
        self._voice_count, self._voice_names, self._languages = self._discover_voices()
        logger.info(
            "voxtral_tts: serving %d voices, languages %s",
            self._voice_count,
            self._languages,
        )

        # Warmup-generate to pay the Metal JIT cost off the hot path. Decoupled
        # from rate discovery (the rate is already set above). Best-effort: a
        # warmup failure must not block serving, so it is logged and swallowed.
        await loop.run_in_executor(None, self._warmup)

    def _discover_voices(self) -> tuple[int, list[str], list[str]]:
        """Return ``(voice_count, voice_names, languages)`` from the loaded
        model's voice presets. Languages are derived from voice-name prefixes
        (Voxtral has no ``lang_code``). On any failure, falls back to the
        verified static facts (20 voices / 9 languages)."""
        try:
            files = getattr(self._loaded_model, "_voice_embedding_files", None)
            names = sorted(files.keys()) if files else []
            if not names:
                return _STATIC_VOICE_COUNT, [], list(_STATIC_LANGUAGES)
            isos: set[str] = set()
            for name in names:
                prefix = name.split("_", 1)[0]
                isos.add(_VOICE_PREFIX_TO_ISO.get(prefix, "en"))
            # Deterministic, canonical order; only languages actually present.
            languages = [iso for iso in _STATIC_LANGUAGES if iso in isos]
            return len(names), names, languages or list(_STATIC_LANGUAGES)
        except Exception as exc:  # noqa: BLE001 - voice discovery is best-effort
            logger.warning(
                "voxtral_tts: could not enumerate voices (%s); using static facts (%d voices)",
                exc,
                _STATIC_VOICE_COUNT,
            )
            return _STATIC_VOICE_COUNT, [], list(_STATIC_LANGUAGES)

    def _warmup(self) -> None:
        """Drain a tiny streaming generate under the Metal lock to JIT-compile
        kernels. Best-effort: a failure is logged and swallowed (rate discovery
        does NOT depend on it, R3). Uses the model's default voice (omitted)."""
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate(
                    "Hello there.",
                    stream=True,
                    streaming_interval=_STREAMING_INTERVAL,
                ):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("voxtral_tts: warmup generate failed (non-fatal): %s", exc)

    def capabilities(self) -> dict:
        return {
            # ``streaming:true`` = genuine SUB-segment streaming (native
            # stream/streaming_interval). The client MAY pass larger text
            # (incremental audio), though bounded commits still serve fairness.
            "streaming": True,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            "voice_count": self._voice_count,
            # Voxtral's effective set ONLY (R7). ``streaming_interval`` is NOT
            # here — it is backend config, not a client knob.
            "extras": list(_VOXTRAL_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def voices(self) -> list[str]:
        # Decided default #4: full voice list via ``server.status``. Empty until
        # ``start()`` discovers them.
        return list(self._voice_names)

    def validate_extras(self, extras: dict) -> str | None:
        """``SupportsExtrasValidation``: reject a malformed advertised extra at
        the trust boundary (commit/update) so the client gets a clean
        ``INVALID_CONFIG`` instead of a ``BACKEND_ERROR`` raised mid-synthesis
        after the commit has already consumed a scheduler slot. Only the
        advertised keys are checked; unknown keys are dropped (not this method's
        job — the server filters keys against ``capabilities()["extras"]``)."""
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
            raise RuntimeError("voxtral_tts: open_stream() called before start()")
        # DROP any kwarg outside the advertised effective set so the contract
        # never lies — only temperature/top_k/top_p survive, each coerced. The
        # server validates ``extras`` keys before this call, but the backend
        # filters again as the last line of defence (R7). ``language`` is
        # accepted for protocol uniformity but Voxtral has no ``lang_code``
        # kwarg (language is encoded in the voice preset), so it is not
        # forwarded to ``generate()``.
        effective: dict[str, Any] = {}
        if extras:
            for key, coerce in _EXTRA_COERCERS.items():
                raw = extras.get(key)
                if raw is not None:
                    effective[key] = coerce(raw)
        return _VoxtralStream(
            model=self._loaded_model,
            voice=voice,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        # Release the model so its mlx/Metal resources can be reclaimed.
        self._loaded_model = None
