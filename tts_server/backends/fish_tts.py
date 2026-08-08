"""fish_tts — Fish Audio S2 Pro backend (mlx-audio 0.4.4, ``fish_qwen3_omni``).

``fish_tts`` is a **segment-level** backend, like ``dia`` — Fish's ``generate()``
explicitly raises ``NotImplementedError`` on ``stream=True`` (Phase 0 Q3
source-confirmed), so this backend drains ``generate(text, stream=False,
**extras)`` through the same shared ``_stream_util.stream_generate`` bridge
every other backend uses and advertises **``streaming:false``**. No server-side
change.

Phase 0 (2026-08-06, ``mlx-community/fish-audio-s2-pro``) verified:

- ``model.sample_rate == 44100`` (dataclass default, confirmed live).
- live ``generate()`` signature: ``generate(text, voice=None, ref_audio=None,
  ref_text=None, instruct=None, max_tokens=1024, temperature=0.7, top_p=0.7,
  top_k=30, repetition_penalty=1.2, stream=False, speed=1.0, chunk_length=300,
  verbose=True, **kwargs)``.
- ``voice`` is discarded UNCONDITIONALLY (``del voice, ...`` at the top of
  ``generate()``) — an even stronger case than dia's structural voice-discard
  (dia at least binds ``voice=None`` positionally). ``voice_count: 0``, no
  ``voices()`` method.
- ``ref_audio``/``ref_text`` are real, live cloning kwargs — forbidden in v1
  (standing decision, matches dia/pocket_tts/qwen3_tts).
- ``instruct`` is a real, plain-string kwarg with no binary-transport
  requirement (unlike ``ref_audio``) — the first backend to advertise a
  string-typed extra. ``instruct=None`` generates cleanly (no-op default);
  ``instruct`` at 1320 chars generates cleanly (no crash) — informs
  ``_INSTRUCT_MAX_LEN`` below as a deliberate product/DoS choice, not a
  model-crash-avoidance number.
- Cross-batch coupling for ``<|speaker:N|>``-tagged multi-turn input is
  CONFIRMED (batch 2's audio depends on batch 1's content, matching dia's
  documented cross-segment coupling) — accepted as designed-in, not a defect.
  Ordinary untagged prose is ALWAYS exactly one batch (``_split_generation_text``
  falls back to ``[text]`` when no ``<|speaker:N|>`` turns are found), so this
  has no bearing on plain-prose commits.
- **Truncation risk is real** (Q5): a 954-char ordinary-prose probe hit the
  per-batch token ceiling EXACTLY. The per-batch ceiling is **NOT** a flat
  ``max_tokens=1024`` — the installed mlx-audio computes
  ``semantic_token_budget = min(max_new_tokens, max(32, text_token_count *
  12))`` per batch (``fish_speech.py:700-703``), so a SHORT input can truncate
  well below 1024 tokens too. ``_check_truncation`` below checks the real
  formula, not a bare ``>= 1024`` comparison — see ``FishTruncationError``.

Lazy-imports ``mlx_audio`` INSIDE ``start()`` — never at module load (the
lean-base invariant). ``mx.disable_compile()`` is called immediately after
``load()``, before warmup: Fish's ``_sample_logits`` is ``mx.compile``-wrapped
(``fish_speech.py:361``) and runs on the same daemon-thread bridge that caused
qwen3's ``CompilerCache`` thread-exit segfault (see ``qwen3_tts.py``'s
``start()`` for the full crash-class writeup) — applied here PROACTIVELY, not
after rediscovering the same crash.

LICENSE (Phase 0 Q6, fetched live from HF, not recalled): the "FISH AUDIO
RESEARCH LICENSE AGREEMENT" — free for Research/Non-Commercial use; any
Commercial Purpose requires a separate written agreement
(``business@fish.audio``). This is a DIFFERENT license family from
``voxtral_tts``'s CC-BY-NC (both are restrictive, neither is Apache/MIT).
"""

from __future__ import annotations

import asyncio
import functools
import logging
import re
import threading
from collections.abc import Mapping
from typing import Any

from ..backend import TTSStream
from ._bridge_stream import BridgedStream
from ._extras_util import (
    coerce_instruct,
    coerce_temperature,
    coerce_top_k,
    coerce_top_p,
    merge_extras,
    validate_extras,
)
from ._introspect_util import verify_generate_signature
from ._truncation_util import check_per_result_ceiling

# Speaker-tag delimiter for fish's multi-speaker payload shape (Q3-verified
# live). Shared by the L1 (instruct truncation-risk scoping) and L2
# (untagged-prefix) pre-flight checks below.
_SPEAKER_TAG_RE = re.compile(r"<\|speaker:\d+\|>")

logger = logging.getLogger("tts_server.backends.fish_tts")

# Default model for ``--backend fish_tts``. Phase 0 Q6 confirmed the
# ``mlx-community/fish-audio-s2-pro`` conversion repo (from ``fishaudio/s2-pro``).
DEFAULT_FISH_MODEL = "mlx-community/fish-audio-s2-pro"

# fish-specific length bound for ``instruct`` — deliberately NOT a
# ``_extras_util.py`` constant (see ``coerce_instruct``'s docstring): the model
# itself tolerates at least 1320 chars without erroring (Phase 0 Q4), so 500 is
# a product/DoS-shaped choice with real headroom, not a crash-avoidance number.
# NOTE: numerically equal to ``_MAX_TEXT_CHARS`` below — COINCIDENTAL, not
# intentional coupling: this bound is a DoS/product cap on ``instruct`` length,
# unrelated to ``_MAX_TEXT_CHARS``'s token-ceiling calibration. Do not derive
# one from the other.
_INSTRUCT_MAX_LEN = 500

# Params Fish's generate() accepts that this backend MUST NEVER forward:
# ``ref_audio``/``ref_text`` are the live voice-cloning channel (no cloning in
# v1, matching dia/pocket_tts/qwen3_tts). DOCUMENTARY ONLY (anchors the
# negative-guard test) — the actual enforcement is the allow-list in
# ``_EXTRA_COERCERS``: ``open_stream`` copies ONLY those keys, so neither of
# these (nor any other out-of-scope kwarg — ``speed``, ``chunk_length``,
# ``repetition_penalty``, ``max_tokens``) can ever reach ``generate()``.
_FORBIDDEN_GENERATE_KWARGS = ("ref_audio", "ref_text")

# Chunk-size hints. Chosen defaults, not model facts (mirrors dia/qwen3).
# Phase 0 Q5: a 954-char ordinary-prose probe hit the per-batch token ceiling
# EXACTLY (1024 tokens). Phase 0's calibration run (max_tokens=64 -> 2.97s
# audio, ~0.0464s/token) implies the ceiling is actually reached around
# ~700 chars of ordinary prose (954 chars needing ~1370 tokens at that
# density) — the 954-char probe measured the FAILURE point, not the ONSET,
# so a cap chosen close to 954 would carry little real margin (mid-phase
# review finding, 2026-08-06). Set well below the estimated ~700-char onset
# instead, so ordinary in-spec commits stay clear of the tripwire.
# NOTE: numerically equal to ``_INSTRUCT_MAX_LEN`` above — COINCIDENTAL, not
# intentional coupling: this bound is calibrated against the per-batch
# token-ceiling tripwire (see the module docstring's Q5 correction), unrelated
# to ``_INSTRUCT_MAX_LEN``'s DoS/product cap. Do not derive one from the other.
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 500

# Bounded depth of the daemon-thread -> asyncio bridge queue. Fish yields one
# (potentially large) segment per batch, like dia; a small bound keeps the send
# loop fed while applying producer-side backpressure.
_BRIDGE_MAXSIZE = 8

# Fish's own ``generate()`` default for ``max_tokens`` (Phase 0 Q3-verified
# live signature). NOT overridden by this backend — kept here so the
# truncation-tripwire predicate below matches the ceiling actually in effect
# without hardcoding a duplicate literal at the call site.
#
# ``_batch_ceiling`` (below) mirrors mlx-audio's PRIVATE per-batch formula —
# ``semantic_token_budget = min(max_new_tokens, max(32, text_token_count *
# 12))`` — verbatim from the installed ``fish_speech.py:699-703`` (not a
# public API, not documented, and not covered by mlx-audio's own version
# guarantees). The real safety net here is the ``mlx-audio==0.4.4`` pin, NOT
# this reimplementation: the pin is what keeps the mirrored formula in sync
# with the model code actually running. If a future mlx-audio bump changes
# ``699-703`` and the pin is bumped WITHOUT re-verifying this formula against
# the new source, the tripwire silently drifts in one of two directions —
# neither of which fails loudly on its own:
#   - if the real ceiling grows (upstream raises the multiplier/floor) and
#     this formula is not updated to match, the tripwire becomes STRICTER
#     than reality and can raise ``FishTruncationError`` on batches that
#     actually completed cleanly (a false-positive failure, i.e.
#     over-detection);
#   - if the real ceiling shrinks (upstream lowers the multiplier/floor) and
#     this formula is not updated, the tripwire becomes LOOSER than reality
#     and can miss a genuine mid-utterance truncation, letting it through as
#     a clean ``completed`` response (a false-negative, i.e. under-detection
#     — the exact silent-truncation failure mode this tripwire exists to
#     catch in the first place).
# Bumping the mlx-audio pin without re-diffing ``fish_speech.py``'s batch
# ceiling logic is therefore the one change most likely to silently break
# this tripwire in either direction.
#
# Separately, the L1 instruct-truncation-risk guard
# (``_check_instruct_truncation_risk`` / ``FishInstructTruncationRiskError``)
# adds a SECOND
# private-internals dependency on top of this one: it calls
# ``model.tokenizer.encode`` directly, which is likewise not a documented
# public surface. A future mlx-audio restructuring could break that call
# independently of anything here — see its own fail-safe (not fail-closed)
# handling where the attribute is missing.
_DEFAULT_MAX_TOKENS = 1024

# Model-card language list (Phase 0 Q6, fetched live from both
# ``mlx-community/fish-audio-s2-pro`` and ``fishaudio/s2-pro`` — identical on
# both repos). No language knob exists in ``generate()``'s signature (Q3
# source-confirmed), so this is advertised as a static fact, not discovered.
_STATIC_LANGUAGES = [
    "en",
    "zh",
    "ja",
    "ko",
    "es",
    "pt",
    "ar",
    "ru",
    "fr",
    "de",
    "sv",
    "it",
    "tr",
    "no",
    "nl",
    "cy",
    "eu",
    "ca",
    "da",
    "gl",
    "ta",
    "hu",
    "fi",
    "pl",
    "et",
    "hi",
    "la",
    "ur",
    "th",
    "vi",
    "jw",
    "bn",
    "yo",
    "sl",
    "cs",
    "sw",
    "nn",
    "he",
]

# Bound single-arg callable — ``validate_extras`` and the ``open_stream`` copy
# loop both invoke every coercer with exactly ONE argument; ``coerce_instruct``
# is a two-arg function (``raw``, ``max_len``), so its fish-calibrated bound is
# baked in here rather than widening either calling convention.
_coerce_fish_instruct = functools.partial(coerce_instruct, max_len=_INSTRUCT_MAX_LEN)

# Coercion dispatch for the advertised extras. Entry ORDER is load-bearing —
# the advertised extras list is derived from this dict and its order is
# asserted by the lean tests / documented in docs/protocol.md. Matches the
# qwen3/voxtral numeric-trio order with ``instruct`` appended.
_EXTRA_COERCERS = {
    "temperature": coerce_temperature,
    "top_k": coerce_top_k,
    "top_p": coerce_top_p,
    "instruct": _coerce_fish_instruct,
}

# Derived, not restated — the advertised list cannot drift from the coercer
# allowlist.
_FISH_EXTRAS = list(_EXTRA_COERCERS)

# L1 (instruct truncation-risk pre-flight): a commit whose REAL per-batch
# generation budget leaves almost no room, combined with a non-empty
# ``instruct`` extra, is treated as high-risk. The previous threshold
# (``_INSTRUCT_RISK_MAX_INPUT_TOKENS = 2``) compared the RAW input-token
# count directly against a flat floor of 2 — miscalibrated against the real
# per-batch ceiling formula (``_batch_ceiling``'s ``min(_DEFAULT_MAX_TOKENS,
# max(32, input_tokens * 12))``): an input of, say, 5 tokens already produces
# a budget of ``max(32, 60) = 60``, comfortably clearing the old ``<= 2``
# floor and so NEVER flagged — even though a 60-token generation budget
# competing against instruct-driven style control is still a real truncation
# risk. This constant is compared against the COMPUTED budget instead of the
# raw token count, so it tracks the actual formula the tripwire protects
# against, not a proxy for it. Deliberately tiny relative to
# ``_DEFAULT_MAX_TOKENS``: this is a near-floor guard, not a general
# "short text" rejection — ordinary short commits WITHOUT ``instruct`` are
# unaffected. 72 is chosen to catch exactly the regression case the old
# threshold missed (input_tokens=5 -> budget 60 -> now correctly flagged)
# while still passing comfortably-provisioned commits (input_tokens=50 ->
# budget 600 -> unaffected).
_INSTRUCT_RISK_MAX_BUDGET_TOKENS = 72


class FishPreflightError(RuntimeError):
    """Base class for a fish_tts validation failure raised BEFORE synthesis
    starts and BEFORE the commit is even admitted — specifically
    ``FishUntaggedPrefixError``, raised from ``FishBackend.validate_text``
    (the ``SupportsTextValidation`` hook) at commit time. A rejected commit
    here costs nothing beyond the check itself."""


class FishUntaggedPrefixError(FishPreflightError):
    """Non-whitespace text precedes the first ``<|speaker:N|>`` tag in a
    multi-speaker commit. mlx-audio's batch split on speaker tags silently
    DROPS any text before the first tag — the client-visible symptom would
    otherwise be missing audio at the very start of the response with no
    error at all. Raised instead so the drop is a client-visible failure."""


class FishInstructTruncationRiskError(RuntimeError):
    """A commit whose REAL per-batch generation budget (see
    ``_INSTRUCT_RISK_MAX_BUDGET_TOKENS``) leaves almost no room was combined
    with a non-empty ``instruct`` extra. See
    ``_INSTRUCT_RISK_MAX_BUDGET_TOKENS``'s comment for why this combination is
    high-risk for the same silent-truncation failure mode
    ``FishTruncationError`` exists to catch. Raised from ``_gen_factory`` —
    rejected at generate-time, before the model call, NOT a
    ``FishPreflightError`` subclass: by the time this check runs, the worker
    thread has already started and the Metal lock has already been acquired,
    so this is not a zero-cost pre-admission rejection like
    ``FishUntaggedPrefixError``."""


class FishTruncationError(RuntimeError):
    """A generation batch reached Fish's real per-batch token ceiling: the
    audio was silently cut off mid-utterance. Raised from the drain so the
    response FAILS instead of completing with missing audio.

    The real ceiling (Phase 0 mid-phase review correction) is ``min(
    _DEFAULT_MAX_TOKENS, max(32, input_text_token_count * 12))``, NOT a flat
    ``_DEFAULT_MAX_TOKENS`` — a short/medium batch's own 12x-input-token
    budget can bind tighter than the flat ceiling, so a bare ``>=
    _DEFAULT_MAX_TOKENS`` check would let those truncations through as a
    silent ``completed`` response, reintroducing the exact qwen3 CustomVoice
    bug this tripwire exists to prevent."""


def _check_untagged_prefix(text: str) -> None:
    """L2: reject non-whitespace text preceding the first ``<|speaker:N|>``
    tag. Returns early (no-op) when the text has no speaker tag at all —
    ordinary untagged prose is always a single batch and this check does not
    apply to it."""
    match = _SPEAKER_TAG_RE.search(text)
    if match is None:
        return
    prefix = text[: match.start()]
    if prefix.strip():
        raise FishUntaggedPrefixError(
            "fish_tts: text before the first <|speaker:N|> tag "
            f"({prefix.strip()!r}) would be silently dropped by mlx-audio's "
            "speaker-tag batch split — move it after a tag or remove it"
        )


class _FishStream(BridgedStream):
    """Adapts one Fish utterance to the ``TTSStream`` protocol.

    Structurally identical to ``_DiaStream`` (the streaming seam is
    backend-agnostic; Fish is segment-level, so it drains a plain
    ``model.generate(text, stream=False, **extras)`` generator through the
    shared bridge — ``feed``/``end``/``cancel``/``wait_closed``/``events`` all
    live on the shared ``BridgedStream`` base now), with the same TWO
    departures dia established plus TWO more:

    1. **No ``voice`` parameter** — even stronger than dia's, since Fish's
       ``generate()`` discards ``voice`` UNCONDITIONALLY (``del voice, ...``),
       not merely ignores a positional default.
    2. **``ref_audio``/``ref_text`` are never built** — only advertised, coerced
       extras splat into ``generate()``.
    3. **Truncation guards, both inside ``_gen_factory``**: it first calls
       ``_check_instruct_truncation_risk`` (rejects a near-floor REAL
       per-batch generation budget paired with a non-empty ``instruct``
       extra — see ``FishInstructTruncationRiskError``), BEFORE
       ``self._model.generate(...)`` is invoked, then wraps the returned
       generator so every yielded batch's token count is checked against the
       real per-batch ceiling (see ``FishTruncationError``) before it reaches
       the bridge. Both run on the worker thread, inside the Metal lock.
    4. **Untagged-prefix rejection happens at commit time, not here**:
       non-whitespace text before the first ``<|speaker:N|>`` tag is rejected
       via ``FishBackend.validate_text`` (the ``SupportsTextValidation``
       hook), before the commit is even admitted — see
       ``FishUntaggedPrefixError``.
    """

    def __init__(
        self,
        *,
        model: Any,
        extras: dict[str, Any],
        metal_lock: threading.Lock,
    ) -> None:
        super().__init__(metal_lock=metal_lock, bridge_maxsize=_BRIDGE_MAXSIZE)
        self._model = model
        self._extras = extras  # pre-coerced advertised extras only

    def _check_instruct_truncation_risk(self) -> None:
        """L1: reject a commit whose REAL per-batch generation budget (see
        ``_INSTRUCT_RISK_MAX_BUDGET_TOKENS``) leaves almost no room, paired
        with a non-empty ``instruct`` extra. Scoped OUT for speaker-tagged
        multi-batch text: mlx-audio splits such a commit into independent
        per-speaker batches, each with its OWN input-token count — a
        whole-buffer encode of ``self._text`` does not correspond to any
        single batch's actual budget, so the heuristic would not be measuring
        the thing it claims to measure. Fail SAFE (log + return), not fail
        CLOSED, when ``model.tokenizer.encode`` is unavailable or raises —
        this is a best-effort risk heuristic layered on top of the
        after-the-fact ``FishTruncationError`` tripwire, not the only
        safeguard, so an inability to check must never block synthesis."""
        instruct = self._extras.get("instruct")
        if not instruct:
            return
        if _SPEAKER_TAG_RE.search(self._text):
            return
        tokenizer = getattr(self._model, "tokenizer", None)
        encode = getattr(tokenizer, "encode", None) if tokenizer is not None else None
        if encode is None:
            logger.warning(
                "fish_tts: model.tokenizer.encode unavailable; skipping the "
                "instruct truncation-risk check (fail-safe, not fail-closed)"
            )
            return
        try:
            input_tokens = len(encode(self._text))
        except Exception as exc:  # noqa: BLE001 - best-effort risk heuristic
            logger.warning(
                "fish_tts: model.tokenizer.encode failed (%s); skipping the "
                "instruct truncation-risk check (fail-safe, not fail-closed)",
                exc,
            )
            return
        # Same formula as ``_batch_ceiling`` — this IS the budget the batch
        # will actually get, computed the same way, before generate() ever
        # runs.
        budget = min(_DEFAULT_MAX_TOKENS, max(32, input_tokens * 12))
        if budget <= _INSTRUCT_RISK_MAX_BUDGET_TOKENS:
            raise FishInstructTruncationRiskError(
                f"fish_tts: instruct extra set on a commit whose real "
                f"per-batch generation budget ({budget} tokens, from "
                f"{input_tokens} input tokens) is <= "
                f"{_INSTRUCT_RISK_MAX_BUDGET_TOKENS} — high risk of silent "
                "mid-utterance truncation; commit longer text or drop the "
                "instruct extra"
            )

    def _gen_factory(self):
        # Runs on the worker thread, inside the Metal lock (this call used to
        # live in ``BridgedStream._preflight_check``, which ran BEFORE the
        # worker thread started and the lock was acquired — that hook has
        # been removed; see ``BridgedStream``'s history). Placed FIRST, before
        # ``self._model.generate(...)``, so a rejection here still costs
        # nothing beyond the check itself and one tokenizer call — it just no
        # longer avoids acquiring the Metal lock to do so.
        self._check_instruct_truncation_risk()
        # Built on the worker thread (inside the Metal lock) so the whole drain
        # is serialized. ``stream=False`` is passed EXPLICITLY (Fish's default
        # is already False) as documentation that this is a deliberate
        # non-streaming choice, not an oversight. ``voice`` is NEVER built (no
        # ``self._voice`` to forward); ``ref_audio``/``ref_text`` are NEVER
        # built. Only advertised, coerced extras splat in.
        gen = self._model.generate(self._text, stream=False, **self._extras)
        return self._check_truncation(gen)

    def _batch_ceiling(self, result: Any) -> int:
        """Derive the real per-batch ceiling from ``result.prompt["tokens"]``
        (the batch's own input-text token count, already computed and carried
        by mlx-audio — see the module docstring's Q5 correction), not
        re-tokenized here. A legitimate zero still uses the real formula (its
        own ``max(32, ...)`` floor covers that case); only a genuinely
        *missing* key falls back to the flat default."""
        prompt = getattr(result, "prompt", None)
        prompt = prompt if isinstance(prompt, Mapping) else {}
        input_text_token_count = prompt.get("tokens")
        if input_text_token_count is not None:
            # Covers a legitimate zero (empty-input batch) too: the real
            # formula's own max(32, ...) floor already prevents that from
            # collapsing to a degenerate ceiling.
            return min(_DEFAULT_MAX_TOKENS, max(32, int(input_text_token_count) * 12))
        # Fail SAFE, not closed: only reached when prompt["tokens"] is
        # genuinely absent (future mlx-audio version stops populating it, or
        # renames the key) — a real zero is handled above via the real
        # formula's max(32, ...) floor, not here. Falls back to the flat
        # default rather than collapsing to max(32, 0)==32 — the latter would
        # trip the tripwire on every real batch and wedge the backend
        # entirely (mid-phase review finding, 2026-08-06). Matches
        # _introspect_util's own "warn, don't raise, on upstream drift"
        # philosophy.
        logger.warning(
            "fish_tts: GenerationResult.prompt['tokens'] missing; "
            "falling back to the flat %d-token ceiling for this batch",
            _DEFAULT_MAX_TOKENS,
        )
        return _DEFAULT_MAX_TOKENS

    def _make_truncation_error(
        self, result: Any, token_count: int, ceiling: int
    ) -> FishTruncationError:
        prompt = getattr(result, "prompt", None)
        prompt = prompt if isinstance(prompt, Mapping) else {}
        input_text_token_count = prompt.get("tokens")
        return FishTruncationError(
            f"fish_tts: a batch hit its {ceiling}-token per-batch "
            f"ceiling (token_count={token_count}, "
            f"input_text_token_count={input_text_token_count}, "
            f"{len(self._text)} chars committed) — audio was silently "
            "truncated mid-utterance; failing the response instead of "
            "reporting a clean completion (commit shorter text)"
        )

    def _check_truncation(self, gen):
        """Pass-through wrapper: yields each ``GenerationResult`` unchanged,
        raising ``FishTruncationError`` if a batch hit the real per-batch
        ceiling. ``stream=False`` means exactly ONE ``GenerationResult`` is
        yielded per batch (unlike qwen3's sub-segment streaming, no
        cross-chunk accumulation is needed here — each result IS one whole
        batch), so this delegates straight to the shared per-result checker
        (``_truncation_util.check_per_result_ceiling``)."""
        return check_per_result_ceiling(
            gen,
            ceiling_fn=self._batch_ceiling,
            make_error=self._make_truncation_error,
        )


class FishBackend:
    """mlx-audio Fish Audio S2 Pro backend (Apple Silicon). Lazy-imports
    ``mlx_audio``."""

    backend_name = "fish_tts"

    def __init__(self, *, model: str = DEFAULT_FISH_MODEL) -> None:
        self._model_id = model
        # Public identity for ``server.hello`` / ``server.status``.
        self.model = model
        # The loaded mlx-audio model. ``None`` until ``start()``.
        self._loaded_model: Any = None
        # Rate is read from ``model.sample_rate`` in ``start()`` (pre-warmup);
        # 0 before load means "not started". Phase 0 recorded 44100.
        self.sample_rate = 0
        # Process-wide Metal lock: Metal is not concurrency-safe, so every
        # drain serializes on this one lock (the commit is the unit of GPU-lock
        # holding).
        self._metal_lock = threading.Lock()
        self._languages: list[str] = list(_STATIC_LANGUAGES)

    async def start(self) -> None:
        # Lazy import — the ONLY place ``mlx_audio`` enters the process. Fails
        # fast here (not at module load / construction) if the extra is absent.
        import mlx.core as mx  # type: ignore
        from mlx_audio.tts.utils import load  # type: ignore

        loop = asyncio.get_running_loop()
        self._loaded_model = await loop.run_in_executor(
            None,
            lambda: load(self._model_id, lazy=False, strict=True),
        )

        # CRASH GUARD (segfault at thread exit; mlx 0.31.2 / mlx-audio 0.4.4):
        # Fish's ``_sample_logits`` is ``mx.compile``-wrapped
        # (``fish_speech.py:361``), the SAME class of usage that caused
        # qwen3's ``CompilerCache`` thread-exit segfault (see
        # ``qwen3_tts.py``'s ``start()`` for the full writeup — same daemon
        # thread bridge, same thread-local compiler cache, same
        # ``pthread_tsd`` teardown crash). Applied PROACTIVELY here (Codex
        # adversarial review, 2026-08-05) rather than rediscovered reactively.
        # Called immediately after ``load()``, before warmup.
        mx.disable_compile()

        # Re-verify the live ``generate()`` signature. Phase 0 pinned
        # ``mlx-audio==0.4.4``; a future bump that drops one of the advertised
        # extras would silently break the contract. Warn (do not hard-fail) so
        # an upstream signature reshape is actionable rather than fatal at
        # serve time. Shared helper (dia.py uses the same one).
        verify_generate_signature(self._loaded_model, _FISH_EXTRAS, "fish_tts", logger=logger)

        # Rate is a config property available IMMEDIATELY after load — no
        # warmup-generate needed to learn it. Phase 0: fish_tts = 44100. Read
        # from the model, never a hardcoded literal.
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "fish_tts: model.sample_rate is missing after load() — cannot "
                "advertise the rate contract"
            )
        self.sample_rate = int(rate)

        logger.info(
            "fish_tts: serving Fish Audio S2 Pro backend, rate %d, languages %s",
            self.sample_rate,
            self._languages,
        )

        await loop.run_in_executor(None, self._warmup)

    def _warmup(self) -> None:
        """Drain a tiny generate under the Metal lock to JIT-compile kernels.
        Best-effort; rate discovery does NOT depend on it."""
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate("Hello there.", stream=False):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("fish_tts: warmup generate failed (non-fatal): %s", exc)

    def capabilities(self) -> dict:
        return {
            # ``streaming:false`` = no SUB-segment streaming; Fish is
            # segment-level (batches split on ``<|speaker:N|>`` turns, or a
            # single whole-text batch for plain prose) — the server emits each
            # batch as it completes.
            "streaming": False,
            "binary_audio": False,
            # ``<|speaker:N|>`` multi-speaker tags and ``[tag]`` inline emotion
            # markup ride inside ``plain`` (dia dialogue-tag precedent) — no
            # new wire format.
            "text_formats": ["plain"],
            "languages": list(self._languages),
            # No voice concept: Fish's generate() discards ``voice``
            # unconditionally. ``voice_count: 0`` makes the server's
            # ``_validate_voice`` accept a supplied voice instead of rejecting
            # it, and the backend ignores it (no ``voices()`` method).
            "voice_count": 0,
            # Fish's effective set: the numeric sampling trio plus the new
            # string-typed ``instruct`` style-control extra. ``ref_audio``/
            # ``ref_text`` are deliberately ABSENT (no cloning in v1).
            "extras": list(_FISH_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def validate_extras(self, extras: dict) -> str | None:
        """``SupportsExtrasValidation``: reject a malformed advertised extra at
        the trust boundary (commit/update) so the client gets a clean
        ``INVALID_CONFIG`` instead of a mid-synthesis ``BACKEND_ERROR`` raised
        under the Metal lock. Only advertised keys are checked."""
        return validate_extras(_EXTRA_COERCERS, extras)

    def validate_text(self, text: str) -> str | None:
        """``SupportsTextValidation``: reject the highest-risk text shape
        (non-whitespace content before the first ``<|speaker:N|>`` tag) at
        commit time, before the commit is admitted — see
        ``FishUntaggedPrefixError``. Returns an error message, or ``None`` if
        the text is acceptable."""
        try:
            _check_untagged_prefix(text)
        except FishUntaggedPrefixError as exc:
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
            raise RuntimeError("fish_tts: open_stream() called before start()")
        # ``voice`` is accepted at the server-facing signature (the server
        # carries a client voice through here because fish_tts advertises
        # ``voice_count: 0``, which makes ``_validate_voice`` ACCEPT it) and
        # DISCARDED — it is never threaded into ``_FishStream``. The discard is
        # structural: ``_FishStream`` has no ``voice`` param to forward it to.
        # ``language`` is accepted for protocol uniformity but Fish's
        # generate() has no language kwarg (Phase 0 Q3), so it is not
        # forwarded either.
        # DROP any kwarg outside the advertised effective set — only
        # temperature/top_k/top_p/instruct survive, each coerced.
        # ``ref_audio``/``ref_text`` can never reach ``generate()`` because
        # only keys in ``_EXTRA_COERCERS`` are copied.
        # ``merge_extras`` handles both None-skip guards: a missing raw value,
        # and ``coerce_instruct``'s own None-on-valid-but-empty-string result
        # (see its docstring in ``_extras_util``) — fish is the first backend
        # to actually exercise the second guard.
        effective = merge_extras(_EXTRA_COERCERS, extras)
        return _FishStream(
            model=self._loaded_model,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        # Release the model so its mlx/Metal resources can be reclaimed.
        self._loaded_model = None
