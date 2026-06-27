"""Pocket TTS backend (mlx-audio 0.4.4) — streaming + the no-cloning negative guard (5b).

Like Voxtral, Pocket is a genuine `streaming:true` sub-segment streamer
(`generate(stream=True, streaming_interval=...)` yields a `GenerationResult`
roughly every `streaming_interval` seconds of audio). Unlike Voxtral, its
`generate()` exposes a **`ref_audio`** voice-cloning channel AND an undocumented
**`frames_after_eos`** param — both of which this backend deliberately leaves
UNWIRED (decision #2: no voice cloning in v1). This is the backend that
exercises the decision-#2 negative guard (Voxtral structurally cannot — it has
no `ref_audio`).

Lazy-imports `mlx_audio` INSIDE `start()` — never at module load (the lean-base
invariant). Heavy deps stay behind the `pocket_tts` extra.

Load path: `mlx_audio.tts.utils.load("mlx-community/pocket-tts")` — the full
model repo (the sibling `kyutai/pocket-tts-without-voice-cloning` holds only the
voice-embedding safetensors, not a loadable config). `sample_rate=24000`, read
from `model.sample_rate` pre-warmup (R1/R3).

Streaming lifecycle is the SAME shared seam as Kokoro/Voxtral
(`_stream_util.stream_generate`) — no bridge/re-chunker/scheduler changes. EOF is
generator-exhaustion-driven; Pocket never sets `.is_final_chunk` (like Kokoro,
unlike Voxtral) — confirmed on-host; correctness does not depend on it either way.

`extras` is Pocket's EFFECTIVE set ONLY: ``["temperature"]`` (verified via
`inspect.signature`: `generate(text, voice=None, ref_audio=None, temperature=None,
verbose=False, stream=False, streaming_interval=2.0, frames_after_eos=None,
**kwargs)`). `top_k`/`top_p` are NOT Pocket params. `voice` follows the
voice=None-OMIT rule (Kokoro's speed-omit applied to voice).
"""

from __future__ import annotations

import asyncio
import logging
import math
import threading
from typing import Any, AsyncGenerator

from ..backend import AudioEvent, TTSStream
from ._stream_util import stream_generate

logger = logging.getLogger("tts_server.backends.pocket_tts")

# Default model for ``--backend pocket_tts``. The full loadable repo (the
# kyutai/...-without-voice-cloning repo is voice embeddings only).
DEFAULT_POCKET_MODEL = "mlx-community/pocket-tts"

# Pocket's advertised effective extras (R7), verified via ``inspect.signature``.
# ``temperature`` is the only sampling tunable Pocket's generate() accepts
# (no top_k/top_p). ``ref_audio`` and ``frames_after_eos`` are real params but
# are INTENTIONALLY NOT advertised and never forwarded (see below).
_POCKET_EXTRAS = ["temperature"]

# Params Pocket's generate() accepts that this backend MUST NEVER forward:
# ``ref_audio`` is the voice-cloning channel (decision #2 — no cloning in v1);
# ``frames_after_eos`` is undocumented. Kept here only to document intent and to
# anchor the negative-guard test — they are dropped by the advertised-extras
# filter in ``open_stream`` regardless.
_FORBIDDEN_GENERATE_KWARGS = ("ref_audio", "frames_after_eos")

# Per-backend streaming cadence — a MODULE CONSTANT baked into the generate()
# call (not CLI/ctor/extras). LOCKED at 0.3 s (## Findings → Phase 5b, arm64,
# mlx-audio 0.4.4, mlx-community/pocket-tts). NOTE: unlike Voxtral, Pocket's TTFB
# is NON-discriminating across 0.3/0.5/1.0 s (all ~0.03–0.04 s) because its
# RTF ≪ 1 (~0.05–0.13×) — the whole utterance generates in a fraction of its
# duration, so the first chunk is ready almost immediately regardless of
# interval. 0.3 s is locked for the finest native cadence (smoothest incremental
# delivery), consistent with Voxtral. The backend test asserts equality to THIS
# single value (never a range).
_STREAMING_INTERVAL = 0.3

# Bounded depth of the daemon-thread -> asyncio bridge queue. Pocket emits many
# small sub-segment chunks AND produces them faster than realtime (RTF ≪ 1), so
# the producer can outrun the consumer (20 ms re-chunker + socket send); a larger
# bound than Kokoro's 8 keeps the fast producer from blocking while still
# applying backpressure. Each backend declares its own value — no bridge change.
_BRIDGE_MAXSIZE = 32

# Chunk-size hints (R7). Chosen defaults, not model facts (mirrors Kokoro/Voxtral).
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# temperature bounds. Forwarded under the process-wide Metal lock, so unbounded
# values are a DoS / correctness vector: finite values are CLAMPED, non-finite
# (NaN/inf) or non-numeric are rejected outright.
_TEMPERATURE_MIN = 0.0
_TEMPERATURE_MAX = 2.0

# Static fallback facts (the model ships 8 predefined voices; English-primary —
# only ``en`` is verified on-host, so that is all that is advertised).
_STATIC_VOICES = ["alba", "azelma", "cosette", "eponine", "fantine", "javert", "jean", "marius"]
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


# Coercion dispatch for the advertised extras (one entry — kept as a dict so the
# filter/validate code is identical in shape to Voxtral's).
_EXTRA_COERCERS = {"temperature": _coerce_temperature}


class _PocketStream:
    """Adapts one Pocket utterance to the ``TTSStream`` protocol. Structurally
    identical to ``_VoxtralStream``/``_KokoroStream`` (the streaming seam is
    backend-agnostic); only ``_gen_factory`` differs (Pocket's kwargs + the
    voice-omit rule, and it NEVER forwards ref_audio/frames_after_eos)."""

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
        self._extras = extras  # pre-coerced advertised extras only
        self._metal_lock = metal_lock
        self._text = ""
        self._cancel = threading.Event()
        self._external_cancel = False
        self._worker_done = threading.Event()
        self._worker_started = False

    async def feed(self, text: str) -> None:
        if self._external_cancel:
            return
        self._text += text

    async def end(self) -> None:
        return None

    async def cancel(self) -> None:
        self._external_cancel = True
        self._cancel.set()

    async def wait_closed(self, timeout: float | None = None) -> None:
        if not self._worker_started:
            return
        loop = asyncio.get_running_loop()
        await loop.run_in_executor(None, self._worker_done.wait, timeout)

    def _gen_factory(self):
        # ``stream=True`` makes generate() a sub-segment generator;
        # ``streaming_interval`` is the locked backend constant. ``voice`` follows
        # the voice=None-OMIT rule. Only advertised+coerced extras splat in;
        # ``ref_audio``/``frames_after_eos`` are NEVER added here (no cloning).
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


class PocketBackend:
    """mlx-audio Pocket TTS backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "pocket_tts"

    def __init__(self, *, model: str = DEFAULT_POCKET_MODEL) -> None:
        self._model_id = model
        self.model = model
        self._loaded_model: Any = None
        self.sample_rate = 0
        self._metal_lock = threading.Lock()
        self._voice_count = 0
        self._voice_names: list[str] = []
        self._languages: list[str] = list(_STATIC_LANGUAGES)

    async def start(self) -> None:
        from mlx_audio.tts.utils import load  # type: ignore

        loop = asyncio.get_running_loop()
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "pocket_tts: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract (R1)"
            )
        self.sample_rate = int(rate)

        self._voice_count, self._voice_names, self._languages = self._discover_voices()
        logger.info(
            "pocket_tts: serving %d voices, languages %s",
            self._voice_count,
            self._languages,
        )

        await loop.run_in_executor(None, self._warmup)

    def _discover_voices(self) -> tuple[int, list[str], list[str]]:
        """Return ``(voice_count, voice_names, languages)``. Pocket's predefined
        voices live in the package's ``utils.PREDEFINED_VOICES`` (the model object
        does not expose them); import it lazily (mlx is already loaded by now) and
        fall back to the verified static list if the upstream shape changes.
        Languages: only ``en`` is verified on-host, so that is all advertised."""
        try:
            from mlx_audio.tts.models.pocket_tts.utils import (  # type: ignore
                PREDEFINED_VOICES,
            )

            names = sorted(PREDEFINED_VOICES.keys())
            if names:
                return len(names), names, list(_STATIC_LANGUAGES)
        except Exception as exc:  # noqa: BLE001 - voice discovery is best-effort
            logger.warning(
                "pocket_tts: could not import PREDEFINED_VOICES (%s); using static "
                "facts (%d voices)",
                exc,
                len(_STATIC_VOICES),
            )
        return len(_STATIC_VOICES), list(_STATIC_VOICES), list(_STATIC_LANGUAGES)

    def _warmup(self) -> None:
        """Drain a tiny streaming generate under the Metal lock to JIT-compile
        kernels. Best-effort; rate discovery does NOT depend on it (R3)."""
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate(
                    "Hello there.",
                    stream=True,
                    streaming_interval=_STREAMING_INTERVAL,
                ):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("pocket_tts: warmup generate failed (non-fatal): %s", exc)

    def capabilities(self) -> dict:
        return {
            "streaming": True,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            "voice_count": self._voice_count,
            # Pocket's effective set ONLY (R7): temperature. ``ref_audio`` and
            # ``frames_after_eos`` are deliberately ABSENT (no cloning, decision
            # #2); ``streaming_interval`` is backend config, not a client knob.
            "extras": list(_POCKET_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def voices(self) -> list[str]:
        return list(self._voice_names)

    def validate_extras(self, extras: dict) -> str | None:
        """Reject a malformed advertised extra at the trust boundary so the
        client gets a clean ``INVALID_CONFIG`` instead of a mid-synthesis
        ``BACKEND_ERROR``. Only advertised keys are checked."""
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
            raise RuntimeError("pocket_tts: open_stream() called before start()")
        # DROP any kwarg outside the advertised effective set — only
        # ``temperature`` survives. This is the backend's last line of defence
        # (R7): even if the server's pre-filter were bypassed, ``ref_audio`` and
        # ``frames_after_eos`` can never reach ``generate()`` because only keys in
        # ``_EXTRA_COERCERS`` are copied. ``language`` is accepted for protocol
        # uniformity but Pocket has no ``lang_code`` kwarg, so it is not forwarded.
        effective: dict[str, Any] = {}
        if extras:
            for key, coerce in _EXTRA_COERCERS.items():
                raw = extras.get(key)
                if raw is not None:
                    effective[key] = coerce(raw)
        return _PocketStream(
            model=self._loaded_model,
            voice=voice,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        self._loaded_model = None
