"""Qwen3-TTS backend (mlx-audio 0.4.4) — a Voxtral-derived sub-segment streamer.

Like Voxtral, Qwen3-TTS is a genuine **sub-segment streamer**:
``generate(stream=True, streaming_interval=...)`` yields a ``GenerationResult``
every ``max(1, int(streaming_interval * 12.5))`` codec tokens (12.5 tokens/s of
audio — the cadence is TOKEN-quantized, not seconds-quantized like Voxtral's).
The Phase-0 gate measured 11 chunks at 0.4 s interval with ~0.10 s gaps and
TTFB ~0.10 s (see the plan's ``## Findings`` → *Phase 0 gate results*).

Lazy-imports ``mlx_audio`` INSIDE ``start()`` — never at module load (the
**lean-base invariant**: ``import tts_server.backends.qwen3_tts`` must succeed
with the ``qwen3_tts`` extra absent and must NOT pull ``mlx_audio``/``numpy``).

LICENSE: the default weights (``mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-
bf16``) carry the HF card tag ``license: apache-2.0`` (gate Q6; no LICENSE file
ships in the repo). Weights download on first ``start()``.

Model-variant semantics (gate-decided, post-gate re-plan):

- **CustomVoice** (the default) carries 9 named speakers and REQUIRES a
  ``voice`` — ``generate()`` raises without one. When the client sends no
  voice, the backend injects ``DEFAULT_QWEN3_VOICE``.
- **Base** (reachable via ``--model``) has ``spk_id: {}`` — NO named speakers.
  ``voices()`` is legitimately empty (``voice_count: 0``, dia precedent) and
  the backend OMITS the ``voice`` kwarg entirely (speaker-unconditioned path).
  No fake static fallback: advertising voices the model ignores would lie.

Streaming lifecycle — identical seam to Voxtral, only the model + kwargs
differ:

- ``start()`` calls ``mlx_audio.tts.utils.load(model_path, lazy=False,
  strict=True)`` and reads the rate from ``model.sample_rate`` (gate-verified
  24000 — but NEVER hardcoded; the ModelConfig default is a dataclass default,
  not a repo fact), available **pre-warmup**. ``load()``'s ``post_load_hook``
  wires the tokenizers automatically — no manual speech-tokenizer plumbing.
- ``open_stream()`` returns a ``_Qwen3Stream`` whose ``events()`` drains
  ``model.generate(text, stream=True, streaming_interval=_STREAMING_INTERVAL,
  **kwargs)`` through the SHARED ``_stream_util.stream_generate`` bridge — the
  same per-chunk queue every streaming backend uses, NO bridge change. EOF is
  generator exhaustion, never ``.is_final_chunk`` (qwen3 sets it; the bridge
  ignores it by design).

``extras`` is the effective sampling set ONLY: ``["temperature", "top_k",
"top_p"]``. The live ``generate()`` signature accepts far more (``ref_audio``,
``ref_text``, ``instruct``, ``speed``, ``split_pattern``, ``max_tokens``,
``streaming_context_size``, ``repetition_penalty``) — ALL out of scope for v1,
and ``ref_audio``+``ref_text`` silently activate ICL voice cloning, so the
backend filters extras to the advertised allowlist as a hard negative guard:
nothing outside it can ever reach ``generate()``.

Unlike Voxtral, ``language`` is a REAL knob here: ``generate(lang_code=...)``.
The server validates the client ``language`` against
``capabilities()["languages"]`` (discovered via
``model.get_supported_languages()``) and forwards it into ``open_stream``; the
backend maps it to ``lang_code``, defaulting to ``"auto"`` when absent.
"""

from __future__ import annotations

import asyncio
import logging
import math
import threading
from typing import Any, AsyncGenerator

from ..backend import AudioEvent, TTSStream
from ._stream_util import stream_generate

logger = logging.getLogger("tts_server.backends.qwen3_tts")

# Default model for ``--backend qwen3_tts``. CustomVoice (not Base) is the
# default because the voice knob only works there: gate Q3 falsified the
# assumption that Base carried named speakers (its config has ``spk_id: {}``).
# CustomVoice carries 9 and streams with identical latency through the same
# ``generate()`` entry. Exported so the CLI's backend-aware ``--model`` default
# imports it rather than hardcoding a copy.
DEFAULT_QWEN3_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16"

# Injected when the client sends no voice AND the model exposes named speakers
# (CustomVoice ``generate()`` RAISES without a voice — gate Q4). "ryan" is an
# English-male member of the gate-verified speaker list (all lowercase:
# serena, vivian, uncle_fu, ryan, aiden, ono_anna, sohee, eric, dylan). If a
# future checkpoint drops it, the backend falls back to the first discovered
# voice with a logged warning — never to a name the model does not know.
DEFAULT_QWEN3_VOICE = "ryan"

# Qwen3's advertised effective extras — the same sampling trio as Voxtral.
# Everything else the live ``generate()`` accepts (cloning/style/control
# kwargs) is actively filtered out, not merely undocumented (see module
# docstring). ``streaming_interval`` is BACKEND CONFIG (a module constant
# below), never a client extra — advertising it would let a client inflate
# TTFB.
_QWEN3_EXTRAS = ["temperature", "top_k", "top_p"]

# Per-backend streaming cadence — a MODULE CONSTANT baked into the generate()
# call, NOT a constructor param / CLI flag / client extra. Qwen3 quantizes the
# cadence in CODEC TOKENS: ``streaming_chunk_size = max(1, int(
# streaming_interval * 12.5))`` (qwen3_tts.py:2278), so 0.4 s -> 5 tokens ≈
# 0.4 s of audio per chunk.
#
# LOCKED at 0.4 s from the Phase-0 gate (arm64, mlx-audio 0.4.4,
# CustomVoice-bf16): TTFB 0.10-0.11 s at 0.4 vs 0.46 s at the 2.0 default, 11
# genuinely incremental chunks for a single sentence (~0.10 s gaps), RTF
# 0.23-0.25 (≈4x realtime) — production stays comfortably ahead of the ~0.4 s
# of audio each chunk carries, so the client's playback buffer never starves.
# Peak memory was also LOWER at 0.4 (3.1 GB vs 4.1-4.3 GB at 2.0 — larger
# decode chunks cost more). The lean test asserts equality to THIS single
# value and its 5-token quantum (never a range).
_STREAMING_INTERVAL = 0.4

# Bounded depth of the daemon-thread -> asyncio bridge queue. Qwen3 emits MANY
# SMALL sub-segment chunks (~one per 5 codec tokens ≈ 0.4 s audio; 11 for a
# short sentence), the same fine-cadence shape as Voxtral — so it takes the
# same bound: 32 chunks at ~0.4 s each is ~12.8 s of headroom while still
# applying producer-side backpressure. Each backend declares its OWN value
# (the rule is *don't share the constant*); the ``maxsize`` arg already exists
# on ``stream_generate`` — no bridge change.
_BRIDGE_MAXSIZE = 32

# Chunk-size hints. Soft client target / hard server cap; chosen defaults, not
# model facts. On CustomVoice a whole commit renders as ONE autoregressive
# generation (``generate_custom_voice()`` has no ``split_pattern`` — a
# multi-``\n`` commit is a single segment), so these must respect the
# SINGLE-generation ceiling: ``max_tokens=4096`` at 12.5 tokens/s is ≈5.5 min
# of audio, far above any sane commit. Voxtral's values (40 words / 2000
# chars: ~2000 chars ≈ 350 words ≈ 2.5 min speech) sit comfortably inside
# that ceiling AND inside the streaming sweet spot, so they carry over —
# streaming yields every ~5 tokens regardless of commit length, so latency is
# unaffected by the one-generation shape.
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# Sampling-extra bounds. ``generate()`` forwards these under the process-wide
# Metal lock, so unbounded values are a denial-of-service / correctness
# vector: a degenerate ``top_p``/``temperature`` can drive runaway or broken
# sampling that stalls every other connection's commit. Finite values are
# CLAMPED; non-finite (NaN/inf) or non-numeric values are rejected outright.
_TEMPERATURE_MIN = 0.0
_TEMPERATURE_MAX = 2.0
_TOP_K_MIN = 1
_TOP_K_MAX = 500
_TOP_P_MIN = 0.0  # exclusive lower bound enforced in _coerce_top_p
_TOP_P_MAX = 1.0

# Gate-verified language list (Phase 0 Q3), used ONLY as the static fallback
# if ``get_supported_languages()`` is absent on a future mlx-audio. The live
# list from the loaded model is authoritative.
_STATIC_LANGUAGES = [
    "auto",
    "chinese",
    "english",
    "german",
    "italian",
    "portuguese",
    "spanish",
    "japanese",
    "korean",
    "french",
    "russian",
]


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
# ``validate_extras`` and ``open_stream`` share one source of truth — and it
# doubles as the ALLOWLIST: only these keys survive extras filtering, which is
# what keeps the forbidden kwargs (ref_audio/ref_text/instruct/speed/
# split_pattern/max_tokens/streaming_context_size/repetition_penalty) provably
# out of ``generate()``.
_EXTRA_COERCERS = {
    "temperature": _coerce_temperature,
    "top_k": _coerce_top_k,
    "top_p": _coerce_top_p,
}


class _Qwen3Stream:
    """Adapts one Qwen3-TTS utterance to the ``TTSStream`` protocol.

    Structurally identical to ``_VoxtralStream`` (the streaming seam is
    backend-agnostic): ``feed()`` accumulates text; ``end()`` is non-blocking;
    ``events()`` drives the shared bridge and yields a ``delta`` per native
    sub-segment chunk, then a ``completed`` on generator exhaustion;
    ``cancel()`` sets the bridge's cancel event so the generator breaks out and
    releases the Metal lock. The only difference is ``_gen_factory`` — it
    builds the streaming ``generate()`` with qwen3's kwargs: the resolved
    voice (or omitted, Base path) and the ``lang_code`` mapping.
    """

    def __init__(
        self,
        *,
        model: Any,
        voice: str | None,
        lang_code: str,
        extras: dict[str, Any],
        metal_lock: threading.Lock,
    ) -> None:
        self._model = model
        # ALREADY RESOLVED by ``open_stream`` (default injected / None for the
        # Base omit-path) — the stream never re-derives voice policy.
        self._voice = voice
        self._lang_code = lang_code
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
        # constant. ``voice`` is OMITTED when None (Base models are
        # speaker-unconditioned; forwarding voice=None would still work for
        # Base but the omit keeps the unconditioned intent explicit — and
        # CustomVoice never reaches here with None: open_stream injected the
        # default). ``lang_code`` is always forwarded (language is a real
        # generate() knob on qwen3, unlike Voxtral). Advertised extras splat in
        # last — they are pre-filtered to the allowlist, so no forbidden kwarg
        # can ride in here.
        kwargs: dict[str, Any] = {}
        if self._voice is not None:
            kwargs["voice"] = self._voice
        kwargs.update(self._extras)
        return self._model.generate(
            self._text,
            lang_code=self._lang_code,
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
        # generator exhaustion (NOT ``.is_final_chunk`` — qwen3 sets it, the
        # bridge ignores it by design).
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


class Qwen3Backend:
    """mlx-audio Qwen3-TTS backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "qwen3_tts"

    def __init__(self, *, model: str = DEFAULT_QWEN3_MODEL) -> None:
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
        self._voice_names: list[str] = []
        self._languages: list[str] = []

    async def start(self) -> None:
        # Lazy import — the ONLY place ``mlx_audio`` enters the process. Fails
        # fast here (not at module load / construction) if the extra is absent.
        import mlx.core as mx  # type: ignore
        from mlx_audio.tts.utils import load  # type: ignore

        # CRASH GUARD (segfault at thread exit; mlx 0.31.2 / mlx-audio 0.4.4):
        # unlike every sibling backend's model, qwen3's model code uses
        # ``mx.compile`` (talker.py rotary/swiglu decorators + the vocoder
        # decoder wrapped by ``load()``'s post_load_hook). mlx's CompilerCache
        # is THREAD-LOCAL, and its cache entries hold Python objects (the
        # traced callables). When a thread that ran compiled functions exits —
        # the bridge's per-stream "tts-synth" worker after every drain, and the
        # asyncio default-executor threads (warmup/load) at loop shutdown — the
        # pthread TLS destructor tears the cache down WITHOUT the GIL and the
        # process dies with EXC_BAD_ACCESS in ``tupledealloc`` (verified via
        # the macOS crash report: ``CompilerCache::~CompilerCache`` invoked
        # from ``_pthread_tsd_cleanup``). Voxtral shares the exact same bridge
        # and never crashes because its model never calls ``mx.compile``.
        #
        # ``mx.disable_compile()`` makes every ``mx.compile`` wrapper a
        # pass-through, so the thread-local cache is never populated and
        # transient-thread exit is clean. Measured cost is noise: RTF
        # 0.248→0.267, TTFB 0.103→0.111 s on the gate sentence (still ~4x
        # realtime). The switch is process-global, but a server process hosts
        # exactly ONE backend, and no sibling backend's model uses
        # ``mx.compile`` (verified across kokoro/voxtral/pocket/dia), so
        # nothing else regresses. Revisit if mlx makes its compile cache
        # teardown GIL-safe (then this line and this comment can go).
        mx.disable_compile()

        loop = asyncio.get_running_loop()
        # ``load(lazy=False)`` evaluates params immediately and downloads the
        # checkpoint if not cached. Run it off the event loop so the connect
        # handshake's load step does not block other coroutines. ``load()``'s
        # ``post_load_hook`` wires AutoTokenizer + speech_tokenizer +
        # generation_config automatically — the model returns ready to
        # generate, same as Voxtral.
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )
        # Rate is a config property available IMMEDIATELY after load — no
        # warmup-generate needed to learn it (R1/R3). Read from the model, never
        # a hardcoded literal (the ModelConfig's 24000 is a dataclass default,
        # not a repo-confirmed fact), so a wrong constant can't satisfy the
        # rate test.
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "qwen3_tts: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract (R1)"
            )
        self.sample_rate = int(rate)

        # Discover voices + languages from the model API (NET-NEW vs Voxtral's
        # embedding-file walk). Pure in-memory reads over the loaded config —
        # no I/O — so no run_in_executor.
        self._voice_names = self._discover_voices()
        self._languages = self._discover_languages()
        logger.info(
            "qwen3_tts: serving %d voices, languages %s",
            len(self._voice_names),
            self._languages,
        )

        # Warmup-generate to pay the Metal JIT cost off the hot path. Decoupled
        # from rate discovery (the rate is already set above). Best-effort: a
        # warmup failure must not block serving, so it is logged and swallowed.
        await loop.run_in_executor(None, self._warmup)

    def _discover_voices(self) -> list[str]:
        """Return the model's named speakers, VERBATIM exact-case.

        ``get_supported_speakers()`` reads ``config.talker_config.spk_id`` —
        gate-verified all-lowercase on CustomVoice (serena, vivian, uncle_fu,
        ryan, aiden, ono_anna, sohee, eric, dylan). The server validates a
        client voice case-exactly against this list while ``generate()``
        lowercases internally, so advertising the verbatim keys keeps both
        sides consistent.

        An EMPTY list is a VALID state, not an error: Base models have
        ``spk_id: {}`` (speaker-unconditioned only, gate Q3). No static
        fallback list — a fake list would advertise voices the model ignores.
        """
        try:
            speakers = self._loaded_model.get_supported_speakers()
            return list(speakers) if speakers else []
        except Exception as exc:  # noqa: BLE001 - voice discovery is best-effort
            logger.warning(
                "qwen3_tts: could not enumerate speakers (%s); serving voice_count 0",
                exc,
            )
            return []

    def _discover_languages(self) -> list[str]:
        """Return the model's supported ``lang_code`` values.

        From ``get_supported_languages()`` (guarded: a future mlx-audio may
        restructure), falling back to the gate-verified static list."""
        try:
            if hasattr(self._loaded_model, "get_supported_languages"):
                languages = self._loaded_model.get_supported_languages()
                if languages:
                    return list(languages)
        except Exception as exc:  # noqa: BLE001 - language discovery is best-effort
            logger.warning(
                "qwen3_tts: could not enumerate languages (%s); using static facts",
                exc,
            )
        return list(_STATIC_LANGUAGES)

    def _resolve_default_voice(self) -> str | None:
        """Pick the voice to inject when the client sent none.

        CustomVoice ``generate()`` RAISES without a voice (gate Q4), so a
        default MUST be injected whenever the model exposes speakers. The
        injected default must be a member of the discovered list — if
        ``DEFAULT_QWEN3_VOICE`` is missing (a future checkpoint renamed its
        speakers), fall back to the first discovered voice with a warning
        rather than sending a name the model does not know. Returns ``None``
        only when no voices exist (Base — the caller then OMITS the kwarg)."""
        if not self._voice_names:
            return None
        if DEFAULT_QWEN3_VOICE in self._voice_names:
            return DEFAULT_QWEN3_VOICE
        fallback = self._voice_names[0]
        logger.warning(
            "qwen3_tts: default voice %r not in discovered speakers %s; falling back to %r",
            DEFAULT_QWEN3_VOICE,
            self._voice_names,
            fallback,
        )
        return fallback

    def _warmup(self) -> None:
        """Drain a tiny streaming generate under the Metal lock to JIT-compile
        kernels. Best-effort: a failure is logged and swallowed (rate discovery
        does NOT depend on it, R3). Uses the resolved default voice — required
        on CustomVoice — or the unconditioned path when voices are empty."""
        try:
            kwargs: dict[str, Any] = {}
            voice = self._resolve_default_voice()
            if voice is not None:
                kwargs["voice"] = voice
            with self._metal_lock:
                for _ in self._loaded_model.generate(
                    "Hello there.",
                    stream=True,
                    streaming_interval=_STREAMING_INTERVAL,
                    **kwargs,
                ):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("qwen3_tts: warmup generate failed (non-fatal): %s", exc)

    def capabilities(self) -> dict:
        return {
            # ``streaming:true`` = genuine SUB-segment streaming (native
            # stream/streaming_interval, gate Q1: 11 incremental chunks for a
            # single sentence). The client MAY pass larger text (incremental
            # audio), though bounded commits still serve fairness.
            "streaming": True,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            # Discovered count: 9 on CustomVoice, 0 on Base (a valid state —
            # the server then skips voice validation, dia precedent).
            "voice_count": len(self._voice_names),
            # Qwen3's effective set ONLY. ``streaming_interval`` is NOT here —
            # it is backend config, not a client knob.
            "extras": list(_QWEN3_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def voices(self) -> list[str]:
        # Decided default #4: full voice list via ``server.status``. Empty until
        # ``start()`` discovers them — and legitimately empty forever on Base.
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
            raise RuntimeError("qwen3_tts: open_stream() called before start()")
        # DROP any kwarg outside the advertised effective set so the contract
        # never lies — only temperature/top_k/top_p survive, each coerced. The
        # server validates ``extras`` keys before this call, but the backend
        # filters again as the LAST line of defence: this allowlist is what
        # keeps the out-of-scope generate() kwargs (ref_audio/ref_text/
        # instruct/speed/split_pattern/max_tokens/streaming_context_size/
        # repetition_penalty) provably unreachable — ref_audio+ref_text would
        # silently activate voice cloning.
        effective: dict[str, Any] = {}
        if extras:
            for key, coerce in _EXTRA_COERCERS.items():
                raw = extras.get(key)
                if raw is not None:
                    effective[key] = coerce(raw)
        # Voice resolution (gate-decided): a client voice (pre-validated by the
        # server against exact-case ``voices()``) passes through; None →
        # inject the default when speakers exist (CustomVoice raises without a
        # voice); None with NO speakers (Base) stays None and the stream OMITS
        # the kwarg (unconditioned path).
        resolved_voice = voice if voice is not None else self._resolve_default_voice()
        # Language → ``lang_code`` (a real generate() knob here, unlike
        # Voxtral). The server has already validated it against the advertised
        # languages; None defaults to "auto" (the model's own default).
        lang_code = language if language is not None else "auto"
        return _Qwen3Stream(
            model=self._loaded_model,
            voice=resolved_voice,
            lang_code=lang_code,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        # Release the model so its mlx/Metal resources can be reclaimed.
        self._loaded_model = None
