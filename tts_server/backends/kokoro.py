"""Kokoro TTS backend (mlx-audio 0.4.4) — the first model backend.

Lazy-imports ``mlx_audio`` INSIDE ``start()`` / ``_get_model`` — never at module
load (the **lean-base invariant**: ``import tts_server.backends.kokoro`` must
succeed with the ``kokoro`` extra absent and must NOT pull ``mlx_audio``). Heavy
deps (``mlx_audio`` → ``misaki``/``spacy``/``torch``) stay behind the extra.

Streaming lifecycle (R3 / R4 / Architecture & Call Flow):

- ``start()`` calls ``mlx_audio.tts.utils.load(model_path, lazy=False,
  strict=True)`` and reads the rate from ``model.sample_rate`` — a config
  property available **immediately after load, pre-warmup** (24000 for Kokoro).
  Rate discovery is decoupled from the warmup-generate (warmup only pays the
  Metal JIT cost off the hot path; the handshake can advertise the rate before
  the first synth).
- ``open_stream()`` returns a ``_KokoroStream`` whose ``events()`` drains
  ``model.generate(text, voice=..., lang_code=..., **extras)`` (a generator that
  yields one ``GenerationResult`` per ``\n+`` segment) through the SHARED
  ``_stream_util.stream_generate`` bridge — NOT a second bridge. The bridge holds
  the **process-wide Metal lock** for the whole drain (Metal is not
  concurrency-safe), converts each ``GenerationResult.audio`` (float32 mono) to
  int16-LE PCM via the R3 clip+asymmetric map, and ends on **generator
  exhaustion** (Kokoro never sets ``.is_final_chunk``). ``cancel()`` sets a
  ``threading.Event`` that breaks the generator out, releasing the lock.

``extras`` is Kokoro's EFFECTIVE set ONLY: ``["speed"]``. Kokoro's
``generate()`` is ``(text, voice, speed, lang_code, split_pattern, **kwargs)``
(verified against 0.4.4), so ``temperature``/``cfg_scale``/``ddpm_steps`` are NOT
Kokoro params — any such kwarg is DROPPED (not forwarded) so the advertised
contract never lies. ``voice``/``language`` are fixed params; the validated
``extras`` are kept disjoint from them by the server before this backend is
called, and this backend additionally drops anything outside its advertised set.
"""

from __future__ import annotations

import asyncio
import logging
import threading
from typing import Any, AsyncGenerator

from ..backend import AudioEvent, TTSStream
from ._stream_util import stream_generate

logger = logging.getLogger("tts_server.backends.kokoro")

# Default model for ``--backend kokoro``. Exported so the CLI's backend-aware
# ``--model`` default imports it rather than hardcoding a second copy.
DEFAULT_KOKORO_MODEL = "mlx-community/Kokoro-82M-bf16"

# Kokoro's advertised effective extras (R7). ``generate()`` accepts
# ``(text, voice, speed, lang_code, split_pattern, **kwargs)`` — ``speed`` is the
# only model-effective tunable. Anything else is swallowed by ``**kwargs`` and
# ignored, so it MUST NOT be advertised and MUST be dropped before the call.
_KOKORO_EXTRAS = ["speed"]

# --- Upstream mlx-audio Kokoro vocoder fix --------------------------------------
# Bug (present in mlx-audio 0.4.4 — the latest PyPI release — AND on mlx-audio
# ``main`` as of 2026-06-24, so no version bump fixes it):
# ``istftnet.SineGen._f02sine`` reconstructs its time axis with an
# ``interpolate(1/upsample_scale)`` -> ``cumsum`` -> ``interpolate(upsample_scale)``
# round-trip that is NOT length-preserving — for most inputs it returns one extra
# ``upsample_scale`` hop (300 samples at 24 kHz). In ``SineGen.__call__`` the
# resulting ``sine_waves`` is then one hop longer than ``uv``/``noise_amp`` (which
# keep the original f0 length), so ``noise_amp * mx.random.normal(sine_waves.shape)``
# multiplies ``(1, T, 1)`` by ``(1, T+300, 9)`` and MLX (correctly) refuses to
# broadcast. Result: ``generate()`` raises ``[broadcast_shapes]`` for every
# utterance whose length is not a fixed point of the round-trip (e.g.
# "Hello there."); only rare inputs (e.g. "GOAL!") happen to align.
#
# Fix: enforce ``_f02sine``'s length contract by truncating its output to the
# input length. This is a NO-OP when the lengths already match, so it is safe for
# all inputs and stays correct if upstream later fixes the round-trip. Applied
# once, idempotently, in ``start()`` before any ``generate()`` (warmup or synth).
# Reported upstream: https://github.com/Blaizzy/mlx-audio/issues/803 — remove this
# shim once a fixed mlx-audio is released and the pin is bumped.
_SINEGEN_PATCH_ATTR = "_tts_server_length_fix"


def _apply_kokoro_vocoder_fix() -> None:
    """Idempotently patch mlx-audio's ``SineGen._f02sine`` to be length-preserving.

    Best-effort: if the upstream symbol cannot be located (a future mlx-audio may
    restructure it), the failure is logged rather than raised — but synthesis
    would then hit the upstream ``broadcast_shapes`` bug, so the warning is
    actionable. Class-level patch, shared across all instances.
    """
    try:
        from mlx_audio.tts.models.kokoro import istftnet  # type: ignore
    except Exception as exc:  # noqa: BLE001 - upstream import shape may change
        logger.warning("kokoro: could not import istftnet to apply vocoder fix: %s", exc)
        return
    sine_gen = getattr(istftnet, "SineGen", None)
    orig = getattr(sine_gen, "_f02sine", None) if sine_gen is not None else None
    if orig is None:
        logger.warning(
            "kokoro: mlx-audio SineGen._f02sine not found; vocoder length fix NOT "
            "applied (synthesis may fail with broadcast_shapes)"
        )
        return
    if getattr(orig, _SINEGEN_PATCH_ATTR, False):
        return  # already patched

    def _f02sine_length_preserving(self, f0_values):  # type: ignore[no-untyped-def]
        out = orig(self, f0_values)
        t = f0_values.shape[1]
        # Drop the spurious extra hop(s) so ``sine_waves`` matches ``uv`` length.
        return out[:, :t, :] if out.shape[1] != t else out

    setattr(_f02sine_length_preserving, _SINEGEN_PATCH_ATTR, True)
    sine_gen._f02sine = _f02sine_length_preserving
    logger.info("kokoro: applied mlx-audio SineGen._f02sine length fix")


# Kokoro voice-name prefix letter -> ISO language. Verified via ``--load``
# 2026-06-24 (voice-prefix/lang_code mapping in mlx-community/Kokoro-82M-bf16):
# a:20,b:8 -> en, e:3 -> es, f:1 -> fr, h:4 -> hi, i:2 -> it, j:5 -> ja,
# p:3 -> pt, z:8 -> zh. The voice prefix IS the Kokoro ``lang_code`` letter, so
# this table doubles as the ISO -> lang_code translation source.
_PREFIX_TO_ISO = {
    "a": "en",  # American English
    "b": "en",  # British English
    "e": "es",
    "f": "fr",
    "h": "hi",
    "i": "it",
    "j": "ja",
    "p": "pt",
    "z": "zh",
}

# ISO language -> Kokoro single-letter ``lang_code``. ``en`` maps to ``a``
# (American English) — the package's own ``generate()`` default. The backend
# translates the client's ISO ``language`` to this letter before ``generate()``.
_ISO_TO_LANG_CODE = {
    "en": "a",
    "es": "e",
    "fr": "f",
    "hi": "h",
    "it": "i",
    "ja": "j",
    "pt": "p",
    "zh": "z",
}

# Chunk-size hints (R7). Soft client target / hard server cap; chosen defaults,
# not model facts (see capabilities example in the plan).
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# Bounded depth of the daemon-thread -> asyncio bridge queue. Kokoro yields one
# (potentially large) segment per ``\n+`` group; a small bound is enough to keep
# the send loop fed while applying producer-side backpressure.
_BRIDGE_MAXSIZE = 8


class _KokoroStream:
    """Adapts one Kokoro utterance to the ``TTSStream`` protocol.

    ``feed()`` accumulates text; ``end()`` is non-blocking (it only marks
    end-of-input — the worker is kicked lazily by ``events()`` so first audio
    ships per segment, not after the whole utterance). ``events()`` drives the
    shared bridge and yields a ``delta`` per segment, then a ``completed`` on
    generator exhaustion. ``cancel()`` sets the bridge's cancel event so the
    generator breaks out and releases the Metal lock.
    """

    def __init__(
        self,
        *,
        model: Any,
        voice: str | None,
        lang_code: str,
        speed: float | None,
        metal_lock: threading.Lock,
    ) -> None:
        self._model = model
        self._voice = voice
        self._lang_code = lang_code
        self._speed = speed
        self._metal_lock = metal_lock
        self._text = ""
        # ``_cancel`` is the bridge's break-out signal. The bridge ALSO sets it
        # in its own consumer ``finally`` on NORMAL exhaustion (to let the worker
        # release the lock), so ``_cancel`` alone cannot distinguish "client
        # barge-in" from "drain finished". ``_external_cancel`` is set ONLY by
        # ``cancel()`` (a real barge-in) and is what gates the terminal
        # ``completed`` event.
        self._cancel = threading.Event()
        self._external_cancel = False

    async def feed(self, text: str) -> None:
        if self._external_cancel:
            return
        self._text += text

    async def end(self) -> None:
        # Non-blocking: end-of-input marker only. Synthesis runs lazily inside
        # ``events()`` so ``end()`` returns before the first segment completes
        # (the R4 steady-stream contract).
        return None

    async def cancel(self) -> None:
        # Breaks the generator out at the next yield boundary, releasing the
        # process-wide Metal lock so a cancelled response does not pin it.
        self._external_cancel = True
        self._cancel.set()

    def _gen_factory(self):
        # Built on the worker thread (inside the Metal lock) so the whole
        # generator-drain is serialized. ``speed`` is the only effective extra;
        # it is passed only when supplied so Kokoro's own default (1.0) stands.
        kwargs: dict[str, Any] = {}
        if self._speed is not None:
            kwargs["speed"] = self._speed
        return self._model.generate(
            self._text,
            voice=self._voice,
            lang_code=self._lang_code,
            **kwargs,
        )

    async def events(self) -> AsyncGenerator[AudioEvent, None]:
        if self._external_cancel:
            return
        loop = asyncio.get_running_loop()
        # The shared bridge owns: Metal-lock acquisition for the whole drain,
        # float32 -> int16-LE PCM conversion (R3 clip+asymmetric map), bounded
        # producer-side backpressure, and EOF on generator exhaustion.
        async for pcm in stream_generate(
            self._gen_factory,
            loop=loop,
            metal_lock=self._metal_lock,
            cancel=self._cancel,
            maxsize=_BRIDGE_MAXSIZE,
        ):
            if self._external_cancel:
                return
            yield AudioEvent(kind="delta", pcm=pcm)
        if self._external_cancel:
            return
        # EOF from generator exhaustion (NOT ``.is_final_chunk``).
        yield AudioEvent(kind="completed", pcm=b"")


class KokoroBackend:
    """mlx-audio Kokoro backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "kokoro"

    def __init__(self, *, model: str = DEFAULT_KOKORO_MODEL) -> None:
        self._model_id = model
        # Public identity for ``server.hello`` / ``server.status``.
        self.model = model
        # The loaded mlx-audio model. ``None`` until ``start()``.
        self._loaded_model: Any = None
        # Rate is read from ``model.sample_rate`` in ``start()`` (pre-warmup);
        # 0 before load means "not started". The server reads ``sample_rate``
        # only after ``start()`` completes (connect -> load -> hello).
        self.sample_rate = 0
        # Process-wide Metal lock: Metal is not concurrency-safe, so every
        # generate drain across all sessions serializes on this one lock. The
        # commit is the unit of GPU-lock holding (R3/R4).
        self._metal_lock = threading.Lock()
        # Voice/language facts derived from the model in ``start()``.
        self._voice_count = 0
        self._voice_names: list[str] = []
        self._languages: list[str] = []
        # An English voice name used only for the warmup generate (Kokoro's
        # ``voice=None`` warmup path trips a broadcast-shape error in 0.4.4, so
        # warmup needs a concrete voice). ``None`` falls back to skipping warmup.
        self._default_voice: str | None = None

    async def start(self) -> None:
        # Lazy import — the ONLY place ``mlx_audio`` enters the process. Fails
        # fast here (not at module load / construction) if the extra is absent.
        from mlx_audio.tts.utils import load  # type: ignore

        # Correct the upstream Kokoro vocoder length bug before any generate()
        # (warmup or synth). Idempotent; see _apply_kokoro_vocoder_fix.
        _apply_kokoro_vocoder_fix()

        # ``load(lazy=False)`` evaluates params immediately and downloads the
        # checkpoint if not cached. Run it off the event loop so the connect
        # handshake's load step does not block other coroutines.
        loop = asyncio.get_running_loop()
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )
        # Rate is a config property available IMMEDIATELY after load — no
        # warmup-generate needed to learn it (R1/R3). Read it before any synth so
        # the handshake can advertise the correct rate. Kokoro = 24000.
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "kokoro: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract (R1)"
            )
        self.sample_rate = int(rate)

        # Derive voice count + supported languages from the model's voices on
        # disk (data-driven, not a hardcoded copy). Falls back to the verified
        # static set if the voices dir is not locatable (e.g. an unusual local
        # model layout).
        self._voice_count, self._languages = await loop.run_in_executor(None, self._discover_voices)

        # Warmup-generate to pay the Metal JIT cost off the hot path. Decoupled
        # from rate discovery (the rate is already set above). Best-effort: a
        # warmup failure must not block serving, so it is logged and swallowed.
        await loop.run_in_executor(None, self._warmup)

    def _discover_voices(self) -> tuple[int, list[str]]:
        """Count distinct voices and derive the ISO language list from the
        model's ``voices/`` directory (cache-only, no network).

        Returns ``(voice_count, languages)``. On any failure, falls back to the
        verified static facts (54 voices; the 8-language ISO set).
        """
        static_languages = ["en", "es", "fr", "hi", "it", "ja", "pt", "zh"]
        try:
            import pathlib

            from huggingface_hub import snapshot_download  # type: ignore

            # ``local_files_only`` keeps this offline: the checkpoint is already
            # cached after ``load(lazy=False)`` above, so no network is hit. A
            # local model path resolves directly.
            local = pathlib.Path(self._model_id)
            if local.exists():
                root = local
            else:
                root = pathlib.Path(snapshot_download(self._model_id, local_files_only=True))
            voices_dir = root / "voices"
            if not voices_dir.is_dir():
                return 54, static_languages
            stems = {f.stem for f in voices_dir.iterdir() if f.is_file()}
            if not stems:
                return 54, static_languages
            # Full voice list for ``server.status`` (decided default #4).
            self._voice_names = sorted(stems)
            # Pick a stable English voice (prefix ``a``/``b``) for warmup.
            en_voices = sorted(s for s in stems if s[:1] in ("a", "b"))
            self._default_voice = en_voices[0] if en_voices else sorted(stems)[0]
            isos: list[str] = []
            for stem in stems:
                iso = _PREFIX_TO_ISO.get(stem[:1])
                if iso and iso not in isos:
                    isos.append(iso)
            # Keep a stable, sorted-by-the-static-order language list so the
            # advertised contract is deterministic across runs.
            ordered = [iso for iso in static_languages if iso in isos]
            return len(stems), ordered or static_languages
        except Exception as exc:  # noqa: BLE001 - voice discovery is best-effort
            logger.warning(
                "kokoro: could not enumerate voices (%s); using verified static "
                "facts (54 voices, 8 languages)",
                exc,
            )
            return 54, static_languages

    def _warmup(self) -> None:
        """Drain a tiny generate under the Metal lock to JIT-compile kernels.

        Best-effort: a warmup failure is logged and swallowed so it never blocks
        serving. Rate discovery does NOT depend on this (R3).
        """
        if self._default_voice is None:
            # No concrete voice discovered; skip warmup rather than risk the
            # ``voice=None`` broadcast-shape error. JIT cost is then paid on the
            # first real synth (rate discovery is unaffected — R3).
            return
        # With the SineGen length fix applied in start() (see
        # _apply_kokoro_vocoder_fix), well-formed phrases synthesize reliably;
        # WITHOUT it, "Hello there." trips the upstream ``broadcast_shapes`` bug
        # (verified 2026-06-24 — the earlier "deterministically-safe" assumption
        # was wrong). Warmup is a JIT-cost amortization only — a failure here is
        # non-fatal regardless.
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate(
                    "Hello there.", voice=self._default_voice, lang_code="a"
                ):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("kokoro: warmup generate failed (non-fatal): %s", exc)

    def _lang_code_for(self, language: str | None) -> str:
        """Translate an ISO ``language`` to Kokoro's single-letter ``lang_code``.

        Unknown / unset languages fall back to ``a`` (American English), Kokoro's
        own ``generate()`` default, so an unrecognized ISO code degrades to
        English rather than erroring (the server validates against the advertised
        language list separately).
        """
        if not language:
            return "a"
        return _ISO_TO_LANG_CODE.get(language.lower(), "a")

    def capabilities(self) -> dict:
        return {
            # ``streaming:false`` = no SUB-segment streaming; the server still
            # emits each ``\n+`` segment as it completes (R4).
            "streaming": False,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            "voice_count": self._voice_count,
            # Kokoro's effective set ONLY (R7) — must be exactly ["speed"].
            "extras": list(_KOKORO_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def voices(self) -> list[str]:
        # Decided default #4: full voice list via ``server.status`` (the count
        # alone goes in ``server.hello``). Empty until ``start()`` discovers them.
        return list(self._voice_names)

    async def open_stream(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
    ) -> TTSStream:
        if self._loaded_model is None:
            raise RuntimeError("kokoro: open_stream() called before start()")
        # DROP any kwarg outside the advertised effective set so the contract
        # never lies — only ``speed`` survives. The server validates ``extras``
        # against ``capabilities()["extras"]`` before this call, but the backend
        # filters again as the last line of defence (R7).
        speed: float | None = None
        if extras:
            raw = extras.get("speed")
            if raw is not None:
                speed = float(raw)
        return _KokoroStream(
            model=self._loaded_model,
            voice=voice,
            lang_code=self._lang_code_for(language),
            speed=speed,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        # Release the model so its mlx/Metal resources can be reclaimed. The
        # process-wide lock is intentionally not torn down (it is a module-free
        # instance attribute; dropping the model is sufficient).
        self._loaded_model = None
