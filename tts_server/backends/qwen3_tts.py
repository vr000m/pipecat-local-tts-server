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
import threading
from typing import Any

from ..backend import TTSStream
from ._extras_util import (
    coerce_temperature,
    coerce_top_k,
    coerce_top_p,
    merge_extras,
    validate_extras,
)
from ._segment_stream import SegmentStream
from ._truncation_util import check_per_segment_ceiling

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

# Qwen3's advertised effective extras (``_QWEN3_EXTRAS``) are DERIVED from
# ``_EXTRA_COERCERS`` below — single source of truth, so the advertised list
# can never drift from what ``open_stream``'s coercer loop actually honours.
# Everything else the live ``generate()`` accepts (cloning/style/control
# kwargs) is actively filtered out, not merely undocumented (see module
# docstring). ``streaming_interval`` is BACKEND CONFIG (a module constant
# below), never a client extra — advertising it would let a client inflate
# TTFB.

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
# SINGLE-generation ceiling: ``max_tokens=4096`` at 12.5 tokens/s is ≈328 s
# (~5.5 min) of audio, after which output is silently TRUNCATED mid-utterance.
#
# Voxtral's 2000-char cap does NOT carry over. Measured on the multiconn-smoke
# fix loop (2026-07-03, CustomVoice-bf16, voice=ryan): long repetitive text
# degenerates to ~0.17-0.19 s of audio PER CHAR (~3x normal pacing — 400 chars
# -> 68 s, 1001 chars -> 194.5 s), and a 1701-char commit hit the 4096-token
# ceiling EXACTLY (16384 x 960 B deltas = 327.68 s) — i.e. truncation from
# ~1700 chars at worst-case pacing, with ~93 s of wall time pinning the Metal
# lock for that one commit. 800 chars caps the worst case at ~160 s of audio
# (2x margin under the token ceiling) and ~45 s of generation. Normal prose
# (~0.07 s/char measured) stays unaffected: 800 chars ≈ 140 words ≈ 60 s of
# speech. Streaming still yields every ~5 tokens, so latency is unchanged.
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 800

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


# Coercion dispatch for the advertised extras. Keyed by extra name so
# ``validate_extras`` and ``open_stream`` share one source of truth — and it
# doubles as the ALLOWLIST: only these keys survive extras filtering, which is
# what keeps the forbidden kwargs (ref_audio/ref_text/instruct/speed/
# split_pattern/max_tokens/streaming_context_size/repetition_penalty) provably
# out of ``generate()``.
# NOTE: entry ORDER is load-bearing — the advertised extras list is derived
# from this dict, and its order is asserted by the lean tests / documented in
# docs/protocol.md. Do not reorder.
_EXTRA_COERCERS = {
    "temperature": coerce_temperature,
    "top_k": coerce_top_k,
    "top_p": coerce_top_p,
}

# Derived, not restated — see the comment above ``_STREAMING_INTERVAL``.
_QWEN3_EXTRAS = list(_EXTRA_COERCERS)

# mlx-audio's single-generation cap (its ``generate()`` default). Hitting it
# truncates SILENTLY: the token loop is ``for step in range(max_tokens)`` with
# EOS breaking BEFORE the append, so natural completion always sums fewer
# codec tokens than the cap — a run that sums exactly the cap was cut off
# mid-utterance and the client still sees a clean ``completed``.
# ``_MAX_TEXT_CHARS`` keeps normal inputs far below this, but pacing is
# input-dependent (measured up to ~0.19 s audio/char on degenerate text), so
# the drain ALSO counts tokens and RAISES when the cap is reached — the raise
# propagates through the bridge to ``events()`` and the server emits
# ``response.failed`` (BACKEND_ERROR), so truncated audio is a client-visible
# failure, never a clean ``completed`` with missing tail audio. The invariant
# check, not just the proxy cap.
_MAX_TOKENS_CEILING = 4096


class Qwen3TruncationError(RuntimeError):
    """A generation segment reached mlx-audio's ``max_tokens`` ceiling: the
    audio was silently cut off mid-utterance. Raised from the drain so the
    response FAILS instead of completing with missing audio."""


class _Qwen3Stream(SegmentStream):
    """Adapts one Qwen3-TTS utterance to the ``TTSStream`` protocol.

    Structurally identical to ``_VoxtralStream`` (the streaming seam is
    backend-agnostic): ``feed()`` accumulates text; ``end()`` is non-blocking;
    ``events()`` drives the shared bridge and yields a ``delta`` per native
    sub-segment chunk, then a ``completed`` on generator exhaustion;
    ``cancel()`` sets the bridge's cancel event so the generator breaks out and
    releases the Metal lock — all now on the shared ``SegmentStream`` base.
    The only difference is ``_gen_factory`` — it builds the streaming
    ``generate()`` with qwen3's kwargs: the resolved voice (or omitted, Base
    path) and the ``lang_code`` mapping.
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
        super().__init__(metal_lock=metal_lock, bridge_maxsize=_BRIDGE_MAXSIZE)
        self._model = model
        # ALREADY RESOLVED by ``open_stream`` (default injected / None for the
        # Base omit-path) — the stream never re-derives voice policy.
        self._voice = voice
        self._lang_code = lang_code
        # Pre-coerced effective extras (only advertised keys, values validated).
        self._extras = extras

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
        gen = self._model.generate(
            self._text,
            lang_code=self._lang_code,
            stream=True,
            streaming_interval=_STREAMING_INTERVAL,
            **kwargs,
        )
        # Pass-through wrapper (yields each GenerationResult unchanged) — the
        # one structural deviation from the sibling template, which returns the
        # model generator directly. See _count_tokens for why.
        return self._count_tokens(gen)

    def _count_tokens(self, gen):
        # Truncation tripwire (see ``_MAX_TOKENS_CEILING``): the cap is PER
        # SEGMENT — the Base path splits on the default split_pattern='\n'
        # into independent generations, each with its own ``for step in
        # range(max_tokens)`` loop (CustomVoice is always one segment) — so
        # sum each SEGMENT's ``token_count`` keyed on ``segment_idx`` and
        # RAISE when any segment reaches the cap (the worker surfaces the
        # exception through the bridge and the server fails the response). A
        # cross-segment sum would false-alarm on multi-segment Base commits
        # that each finished naturally on EOS. Without the tripwire, a capped
        # run drains to a clean ``completed`` and the cut-off audio reads as
        # a client-side playback bug. Pass-through wrapper; the bridge
        # contract (yields GenerationResult with ``.audio``) is untouched.
        # Delegates to the shared per-segment checker
        # (``_truncation_util.check_per_segment_ceiling``).
        return check_per_segment_ceiling(
            gen,
            ceiling=_MAX_TOKENS_CEILING,
            make_error=self._make_truncation_error,
        )

    def _make_truncation_error(self, segment_total: int) -> Qwen3TruncationError:
        return Qwen3TruncationError(
            f"qwen3_tts: a segment hit the {_MAX_TOKENS_CEILING}-token "
            f"single-generation ceiling ({segment_total} tokens, "
            f"{len(self._text)} chars in) — audio was silently truncated "
            "mid-utterance; failing the response instead of reporting a "
            "clean completion (commit shorter text)"
        )


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
        # Resolved once in ``start()`` (``_voice_names`` never changes after
        # discovery); ``None`` on Base — the voice kwarg is then omitted.
        self._default_voice: str | None = None

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

        # Fail fast on unsupported model variants (same pattern as the rate
        # guard above). 'base' and 'custom_voice' both work through
        # ``generate()``; 'voice_design' REQUIRES the ``instruct`` kwarg, which
        # this backend deliberately never passes (out of scope) — without this
        # guard a VoiceDesign checkpoint boots "healthy" (the warmup failure is
        # swallowed) and then fails EVERY synthesis with BACKEND_ERROR.
        model_type = getattr(getattr(self._loaded_model, "config", None), "tts_model_type", "base")
        if model_type not in ("base", "custom_voice"):
            raise RuntimeError(
                f"qwen3_tts: model {self._model_id!r} has tts_model_type="
                f"{model_type!r}, which this backend does not support (it "
                "requires kwargs like 'instruct' that are deliberately out of "
                "scope). Use a 'base' or 'custom_voice' variant."
            )

        # Discover voices + languages from the model API (NET-NEW vs Voxtral's
        # embedding-file walk). Pure in-memory reads over the loaded config —
        # no I/O — so no run_in_executor.
        self._voice_names = self._discover_voices()
        self._languages = self._discover_languages()
        # Resolve the injected default ONCE — the discovered list is fixed for
        # the backend's lifetime, and resolving per commit would re-emit the
        # missing-default warning on every voiceless utterance.
        self._default_voice = self._resolve_default_voice()
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
        except Exception as exc:
            # FAIL FAST, do not fall back to []. An empty list is only valid
            # when the model REPORTS no speakers (Base). Masquerading a
            # discovery FAILURE as "voice_count 0" would fail-open the server's
            # voice validation (``_validate_voice`` accepts any voice at count
            # 0) and, on CustomVoice, break every voiceless commit mid-synthesis
            # ("CustomVoice model requires 'voice'") while start() reports
            # healthy. Kokoro's analogous fallback stays fail-closed for the
            # same reason.
            raise RuntimeError(
                "qwen3_tts: could not enumerate speakers from the loaded model "
                f"({exc}); refusing to serve with an unknown voice set"
            ) from exc

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
            if self._default_voice is not None:
                kwargs["voice"] = self._default_voice
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
        return validate_extras(_EXTRA_COERCERS, extras)

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
        effective = merge_extras(_EXTRA_COERCERS, extras)
        # Voice resolution (gate-decided): a client voice (pre-validated by the
        # server against exact-case ``voices()``) passes through; None →
        # inject the default when speakers exist (CustomVoice raises without a
        # voice). With NO speakers (Base), ANY client voice is DISCARDED, not
        # forwarded: the server's voice_count:0 accept-branch exists precisely
        # because such backends ignore voice (dia precedent), and forwarding
        # would ride on mlx-audio's silent-ignore behavior — the docstring's
        # "Base OMITS the voice kwarg entirely" must hold for supplied voices
        # too, not just None.
        if not self._voice_names:
            resolved_voice = None
        else:
            resolved_voice = voice if voice is not None else self._default_voice
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
