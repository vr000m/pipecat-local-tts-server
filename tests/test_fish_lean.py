"""fish_tts backend LEAN tests (no mlx) — Phase 1.

On the lean allow-list (dia/qwen3-lean-derived structure). ``fish_tts`` is a
non-streaming (segment-level) backend built on the dia template: no voice
concept (``voice_count: 0``, no ``voices()`` method, ``open_stream(voice=...,
language=...)`` accepts-and-discards BOTH), ``ref_audio``/``ref_text`` forbidden
(real ``generate()`` kwargs but never advertised/forwarded — Phase 0 Q3), and a
net-new string-typed extra ``instruct`` (``coerce_instruct`` in
``_extras_util.py``: generic ``str``-type check, rejects non-str incl.
``bool``/``bytes``, whitespace-strips, REJECTS an oversized string rather than
truncating, and coerces an empty-after-strip string to ``None`` which
``open_stream``'s copy loop must OMIT, not forward as ``""``).

Distinctive Phase-1 deliverables proved WITHOUT loading the S2-Pro model:
  - ``capabilities()`` shape: ``streaming:false``, ``voice_count:0``,
    ``text_formats:["plain"]``, ``extras == ["temperature", "top_k", "top_p",
    "instruct"]`` (dict order load-bearing);
  - ``sample_rate == 0`` pre-``start()``;
  - the STRUCTURAL voice+language discard: neither reaches ``generate()`` even
    when supplied (spy-model test, bypassing the server pre-filter);
  - the decision-#2 negative guard: ``ref_audio``/``ref_text`` can never reach
    ``generate()`` even injected directly via ``open_stream`` extras;
  - ``coerce_instruct`` exercised via ``validate_extras`` (not called
    directly): valid string passes (stripped), non-str rejected (int, bool,
    bytes), oversized string rejected (not truncated), empty-after-strip
    coerces to omission;
  - a lean extras-merge end-to-end test: a string ``instruct`` value survives
    the ``open_stream``/``_gen_factory`` path intact (post-strip) — the first
    STRING-typed extra exercised through this generic path
    (``tests/test_capabilities_extras.py`` only covers numeric/short values);
  - a direct ``_FishStream.cancel()``/``wait_closed()`` spy test (external-cancel
    flag set; ``wait_closed()`` blocks until the worker-done event fires —
    mirrors the Metal-lock-hold rationale in ``dia.py:160-172``);
  - per-backend numeric-coercer coverage (``temperature``/``top_k``/``top_p``):
    non-finite/bool rejection, clamp-to-bounds via ``validate_extras``;
  - the Q5-corrected truncation tripwire (Phase 0 Findings, "mid-phase review
    corrections"): the real per-batch ceiling is
    ``min(max_tokens_default, max(32, input_text_token_count * 12))``, NOT a
    flat ``>= 1024`` check — the test below exercises a SHORT input where the
    12x-derived ceiling is well under 1024, so it actually catches a
    regression to the naive predicate;
  - lazy-import: the module import pulls neither ``mlx_audio`` nor ``numpy``;
  - the dual-wire (Phase 2 dependency): ``make_backend("fish_tts")``,
    ``--backend fish_tts`` argparse acceptance, and ``DEFAULT_FISH_MODEL``
    dual-path resolution are all marked ``xfail(strict=False)`` in this phase —
    the registry/CLI wiring that makes them pass for real lands in Phase 2.

The mlx-gated synthesis assertions live in ``tests/test_fish_backend.py``.
"""

from __future__ import annotations

import asyncio

import pytest

from tts_server.backends import fish_tts as F

from ._helpers import lean_import_offenders

# asyncio_mode = "auto" (pyproject.toml) auto-detects async tests — no
# pytestmark/decorator needed (matches tests/test_qwen3_lean.py's convention).


# --- backend-unit: capabilities -------------------------------------------------


def test_capabilities_streaming_false():
    """Fish's ``generate()`` raises ``NotImplementedError`` on ``stream=True``
    (Context) — it is structurally segment-level like dia, NOT a sub-segment
    streamer, so it MUST advertise ``streaming:false``."""
    assert F.FishBackend().capabilities()["streaming"] is False


def test_capabilities_extras_ordered_temperature_top_k_top_p_instruct():
    """Advertised extras are EXACTLY ``["temperature", "top_k", "top_p",
    "instruct"]`` — dict order load-bearing (matches the qwen3/voxtral numeric
    trio order with ``instruct`` appended)."""
    assert F.FishBackend().capabilities()["extras"] == [
        "temperature",
        "top_k",
        "top_p",
        "instruct",
    ]


def test_capabilities_text_formats_and_voice_count_zero():
    caps = F.FishBackend().capabilities()
    assert caps["text_formats"] == ["plain"]
    assert caps["voice_count"] == 0
    assert caps["binary_audio"] is False


def test_capabilities_excludes_ref_audio_and_ref_text():
    """``ref_audio``/``ref_text`` are real ``generate()`` kwargs (Phase 0 Q3)
    but are forbidden — never advertised, so this exclusion is non-vacuous."""
    extras = F.FishBackend().capabilities()["extras"]
    assert "ref_audio" not in extras
    assert "ref_text" not in extras


def test_no_voices_method_so_voice_set_stays_empty():
    """``voice_count:0`` has TWO halves: the backend MUST NOT define a
    ``voices()`` method (dia's ``test_no_voices_method_so_voice_set_stays_empty``
    pattern) — Fish's ``generate()`` deletes ``voice`` unconditionally
    (``del voice, ...`` — Context), an even stronger case than dia's."""
    assert not hasattr(F.FishBackend(), "voices")


# --- sample_rate: presence pre-start, NEVER the mlx-gated value -----------------


def test_sample_rate_zero_pre_start():
    """The model is unloaded pre-``start()``. The rate VALUE 44100 (Phase 0 Q3,
    ``model.sample_rate = 44100``) is a single-run local observation and is
    mlx-gated-only — a lean test must not assert ``== 44100``."""
    backend = F.FishBackend()
    assert hasattr(backend, "sample_rate")
    assert backend.sample_rate == 0
    assert backend.sample_rate != 44100


# --- spy model: voice/language discard + ref_audio/ref_text negative guard -----


class _SpyModel:
    """Fake mlx model: ``generate`` records the kwargs it is called with and
    returns an empty generator, so ``_gen_factory`` can be driven WITHOUT mlx."""

    sample_rate = 44100

    def __init__(self) -> None:
        self.calls: list[dict] = []

    def generate(self, text, **kwargs):
        self.calls.append({"text": text, **kwargs})
        return iter(self.results)

    results: tuple = ()


async def _open_spy_stream(*, voice=None, language=None, extras=None):
    backend = F.FishBackend()
    spy = _SpyModel()
    backend._loaded_model = spy  # bypass start(); no mlx needed
    stream = await backend.open_stream(voice=voice, language=language, extras=extras)
    return backend, spy, stream


async def _gen_kwargs(*, voice=None, language=None, extras=None, text="hello world"):
    """Open a stream on a spy-model fish backend and return the kwargs that
    ``_gen_factory`` would pass to ``model.generate`` (positional ``text``
    folded into the recorded call dict). ``open_stream`` is called DIRECTLY,
    bypassing the server pre-filter — the load-bearing backend-layer guard."""
    _backend, spy, stream = await _open_spy_stream(voice=voice, language=language, extras=extras)
    stream._text = text
    list(stream._gen_factory())  # drive the (empty) generator to record the call
    assert len(spy.calls) == 1
    return spy.calls[0]


async def test_voice_never_reaches_generate_even_when_supplied():
    """No ``voice`` parameter exists on the stream class at all (an even
    stronger structural guarantee than dia's — Fish discards ``voice``
    unconditionally at the source level)."""
    call = await _gen_kwargs(voice="some_speaker")
    assert "voice" not in call


async def test_language_never_reaches_generate_even_when_supplied():
    """``open_stream(voice=..., language=...)`` accepts and unconditionally
    discards BOTH — no ``language`` kwarg exists on Fish's ``generate()``
    (Phase 0 Q3 signature)."""
    call = await _gen_kwargs(language="en")
    assert "language" not in call


async def test_voice_and_language_both_absent_together():
    call = await _gen_kwargs(voice="some_speaker", language="en")
    assert "voice" not in call
    assert "language" not in call


async def test_ref_audio_and_ref_text_never_reach_generate():
    """Decision #2 negative guard at the BACKEND layer: call ``open_stream``
    DIRECTLY with the forbidden cloning kwargs (bypassing the server
    pre-filter) and assert NEITHER reaches ``generate()``. Both are real Fish
    ``generate()`` kwargs (Phase 0 Q3 signature), so this guard is non-vacuous."""
    call = await _gen_kwargs(
        voice="speaker",
        extras={
            "ref_audio": "clone_me.wav",
            "ref_text": "say it like this",
            "temperature": 1.0,
        },
    )
    assert "ref_audio" not in call
    assert "ref_text" not in call
    assert call.get("temperature") == 1.0


async def test_advertised_extras_survive_to_generate():
    call = await _gen_kwargs(
        extras={"temperature": 1.0, "top_k": 40, "top_p": 0.9},
    )
    assert call.get("temperature") == 1.0
    assert call.get("top_k") == 40
    assert call.get("top_p") == 0.9


async def test_unadvertised_extra_dropped_by_backend_filter():
    call = await _gen_kwargs(extras={"temperature": 1.0, "repetition_penalty": 1.5})
    assert "repetition_penalty" not in call


# --- coerce_instruct: exercised via validate_extras, not called directly -------


def test_validate_extras_accepts_and_strips_valid_instruct():
    backend = F.FishBackend()
    assert backend.validate_extras({"instruct": "speak calmly"}) is None
    assert backend.validate_extras({"instruct": "  speak calmly  "}) is None


@pytest.mark.parametrize("bad", [123, 1.5, True, False, b"bytes", [], {}])
def test_validate_extras_rejects_non_str_instruct(bad):
    backend = F.FishBackend()
    msg = backend.validate_extras({"instruct": bad})
    assert msg and "instruct" in msg, f"instruct={bad!r} was not rejected"


def test_validate_extras_rejects_oversized_instruct_not_truncated():
    """Oversized ``instruct`` is REJECTED, not clamped/truncated (unlike
    ``temperature``/``top_p``/``top_k``, where any in-range value is still a
    valid sample knob) — a truncated instruction silently changes what the
    model is told to do (Requirements, user-confirmed 2026-08-04)."""
    backend = F.FishBackend()
    oversized = "x" * (F._INSTRUCT_MAX_LEN + 1)
    msg = backend.validate_extras({"instruct": oversized})
    assert msg and "instruct" in msg


def test_validate_extras_boundary_length_instruct_accepted():
    backend = F.FishBackend()
    at_bound = "x" * F._INSTRUCT_MAX_LEN
    assert backend.validate_extras({"instruct": at_bound}) is None


def test_validate_extras_empty_after_strip_instruct_is_valid():
    """An empty-or-whitespace-only ``instruct`` is a VALID input (coerces to
    ``None``, omitted from forwarded extras — see the merge test below), not a
    validation error."""
    backend = F.FishBackend()
    assert backend.validate_extras({"instruct": ""}) is None
    assert backend.validate_extras({"instruct": "   "}) is None


# --- lean extras-merge end-to-end: string instruct through open_stream ---------


async def test_instruct_string_survives_extras_merge_stripped():
    """The first STRING-typed extra exercised through the generic
    ``open_stream``/``_gen_factory`` extras-merge path
    (``tests/test_capabilities_extras.py`` only covers numeric/short values).
    Post-coercion the value is whitespace-stripped, not otherwise altered."""
    call = await _gen_kwargs(extras={"instruct": "  be warm and cheerful  "})
    assert call.get("instruct") == "be warm and cheerful"


async def test_empty_instruct_omitted_from_generate_kwargs_not_forwarded_as_empty_string():
    """``coerce_instruct`` returns ``str | None`` — ``None`` for the
    valid-but-empty-after-strip case — and ``open_stream``'s copy loop must
    SKIP a ``None`` coercion result rather than assign it (a deliberate
    departure from the numeric coercers' always-forwardable-or-raise
    convention)."""
    call = await _gen_kwargs(extras={"instruct": "   "})
    assert "instruct" not in call

    call = await _gen_kwargs(extras={"instruct": ""})
    assert "instruct" not in call


async def test_unset_instruct_is_omitted_not_none():
    call = await _gen_kwargs(extras={"temperature": 0.7})
    assert "instruct" not in call


# --- per-backend numeric-coercer coverage ---------------------------------------


def test_validate_extras_rejects_non_finite_temperature():
    backend = F.FishBackend()
    assert backend.validate_extras({}) is None
    assert backend.validate_extras({"temperature": 1.0}) is None
    msg = backend.validate_extras({"temperature": float("nan")})
    assert msg and "temperature" in msg
    msg = backend.validate_extras({"temperature": float("inf")})
    assert msg and "temperature" in msg


def test_validate_extras_rejects_out_of_range_top_k_by_clamping_on_forward():
    """``top_k`` clamps both bounds (shared coercer) — validated here via
    ``validate_extras`` (no error for any real int) and via the forwarding path
    for the actual clamp behavior."""
    backend = F.FishBackend()
    assert backend.validate_extras({"top_k": 40}) is None
    msg = backend.validate_extras({"top_k": 2.9})
    assert msg and "top_k" in msg  # non-integral float rejected, not truncated


def test_validate_extras_rejects_non_finite_top_p():
    backend = F.FishBackend()
    assert backend.validate_extras({"top_p": 0.95}) is None
    msg = backend.validate_extras({"top_p": float("nan")})
    assert msg and "top_p" in msg
    msg = backend.validate_extras({"top_p": float("inf")})
    assert msg and "top_p" in msg
    msg = backend.validate_extras({"top_p": 0.0})
    assert msg and "top_p" in msg


def test_validate_extras_rejects_booleans_for_numeric_extras():
    """A JSON ``true``/``false`` is a client config mistake, not a number —
    every numeric coercer must reject it (mirrors dia's/qwen3's own
    per-backend re-assertion of the shared coercer behavior)."""
    backend = F.FishBackend()
    for key in ("temperature", "top_k", "top_p"):
        for bad in (True, False):
            msg = backend.validate_extras({key: bad})
            assert msg and key in msg, f"{key}={bad!r} was not rejected"


async def test_out_of_bound_numeric_extras_clamped_on_forward():
    from tts_server.backends._extras_util import TEMPERATURE_MAX, TOP_K_MAX, TOP_P_MAX

    call = await _gen_kwargs(
        extras={"temperature": 99, "top_k": 10_000, "top_p": 2.0},
    )
    assert call["temperature"] == TEMPERATURE_MAX
    assert call["top_k"] == TOP_K_MAX
    assert call["top_p"] == TOP_P_MAX


# --- direct _FishStream cancel()/wait_closed() spy test -------------------------


async def test_cancel_sets_external_flag():
    _backend, _spy, stream = await _open_spy_stream()
    assert stream._external_cancel is False
    await stream.cancel()
    assert stream._external_cancel is True


async def test_wait_closed_returns_immediately_when_worker_never_started():
    """Mirrors dia's ``wait_closed`` contract (``dia.py:160-172``): if the
    synthesis worker never started (no commit drained), ``wait_closed()`` must
    not block."""
    _backend, _spy, stream = await _open_spy_stream()
    await asyncio.wait_for(stream.wait_closed(timeout=1.0), timeout=2.0)


async def test_wait_closed_blocks_until_worker_done_event_fires():
    """The Metal-lock-hold rationale (``dia.py:160-172``): once the worker has
    started, ``wait_closed()`` must block until the worker-done event fires —
    not return early while synthesis (and the Metal lock) is still held."""
    _backend, _spy, stream = await _open_spy_stream()
    stream._worker_started = True

    waiter = asyncio.ensure_future(stream.wait_closed(timeout=2.0))
    await asyncio.sleep(0.05)
    assert not waiter.done(), "wait_closed() returned before worker_done was set"

    stream._worker_done.set()
    await asyncio.wait_for(waiter, timeout=1.0)


# --- Q5-corrected truncation tripwire (Phase 0 Findings, mid-phase review) ------
#
# Real per-batch ceiling: min(max_tokens_default, max(32, text_token_count * 12))
# — NOT a flat >=1024 check. The gate's own simplified `capped = token_count >=
# 1024` predicate is a FALSE-NEGATIVE detector for inputs under ~340 chars
# (Findings, "Phase 0 — mid-phase review corrections", [HIGH] item). These
# tests use a SHORT input so the 12x-derived ceiling is well under 1024 —
# a regression to the naive `>=1024` predicate would let the first test below
# pass through as a silent completion instead of raising.

_SHORT_INPUT = "Hi there."  # a handful of tokens under any reasonable estimate


class _SegRes:
    """Minimal ``GenerationResult`` stand-in for the truncation tripwire.
    ``_FishStream._check_truncation`` reads ``token_count`` (the batch's
    generated-audio token count) and ``prompt["tokens"]`` (the batch's own
    INPUT-text token count, already computed by mlx-audio) to derive the real
    per-batch ceiling ``min(_DEFAULT_MAX_TOKENS, max(32, input_tokens * 12))``
    — see ``fish_tts.py:_check_truncation``."""

    def __init__(self, token_count: int, input_tokens: int = 0, audio=(0.0, 0.1, -0.1)):
        self.token_count = token_count
        self.prompt = {"tokens": input_tokens}
        self.audio = list(audio)


@pytest.mark.skipif(
    not hasattr(F, "FishTruncationError"),
    reason="Q5 gate decided the truncation tripwire IS required (Findings) — "
    "skip only if fish_tts.py has not yet defined FishTruncationError",
)
def test_truncation_tripwire_uses_corrected_per_input_ceiling_not_flat_1024():
    """A SHORT-input batch (``input_tokens=6`` -> 12x ceiling ``max(32, 72) =
    72``) has a per-batch ceiling far below the flat 1024 default. A batch
    reporting a ``token_count`` above that per-input ceiling but well under
    1024 MUST raise — a naive ``>= 1024`` check would silently let this
    through, reintroducing qwen3's CustomVoice silent-truncation bug."""
    stream = object.__new__(F._FishStream)
    stream._text = _SHORT_INPUT

    # Comfortably below the short-input ceiling (72): completes naturally.
    list(stream._check_truncation(iter([_SegRes(token_count=50, input_tokens=6)])))

    # Above the short-input 12x ceiling (72) but well under the flat 1024
    # default — must raise under the corrected predicate; a regression to a
    # bare `>= 1024` comparison would NOT raise here.
    with pytest.raises(F.FishTruncationError, match="ceiling"):
        list(stream._check_truncation(iter([_SegRes(token_count=100, input_tokens=6)])))


@pytest.mark.skipif(
    not hasattr(F, "FishTruncationError"),
    reason="Q5 gate decided the truncation tripwire IS required (Findings) — "
    "skip only if fish_tts.py has not yet defined FishTruncationError",
)
async def test_truncated_segment_fails_response_not_silent_success():
    """Adversarial-review fix (qwen3 precedent): a ceiling-hit must be a
    CLIENT-VISIBLE failure, not an operator log line. Drive the full
    ``events()`` drain through the real bridge with a generation that reaches
    the (corrected, per-input) ceiling and assert the raise propagates with NO
    ``completed`` event."""
    backend, spy, _stream = await _open_spy_stream()
    spy.results = (_SegRes(token_count=100, input_tokens=6),)
    stream = await backend.open_stream(voice=None, language=None, extras=None)
    stream._text = _SHORT_INPUT

    events = []
    with pytest.raises(F.FishTruncationError, match="ceiling"):
        async for ev in stream.events():
            events.append(ev)
    assert all(ev.kind != "completed" for ev in events)
    await stream.wait_closed(timeout=5.0)


@pytest.mark.skipif(
    not hasattr(F, "FishTruncationError"),
    reason="Q5 gate decided the truncation tripwire IS required (Findings) — "
    "skip only if fish_tts.py has not yet defined FishTruncationError",
)
async def test_truncation_after_earlier_streamed_batch_fails_response():
    """A generate() call with >=2 GenerationResults (multi-batch
    ``<|speaker:N|>`` input): batch 1 is under-ceiling and already streamed as
    a ``delta`` event when batch 2 hits the ceiling. The response must still
    FAIL (raise) — partial audio already sent to the client is not a license
    to report a clean completion for the rest."""
    backend, spy, _stream = await _open_spy_stream()
    spy.results = (
        _SegRes(token_count=50, input_tokens=6),  # under short-input ceiling(72) -> streamed
        _SegRes(token_count=100, input_tokens=6),  # over ceiling(72) -> must raise
    )
    stream = await backend.open_stream(voice=None, language=None, extras=None)
    stream._text = _SHORT_INPUT

    events = []
    with pytest.raises(F.FishTruncationError, match="ceiling"):
        async for ev in stream.events():
            events.append(ev)
    assert any(ev.kind == "delta" for ev in events)
    assert all(ev.kind != "completed" for ev in events)
    await stream.wait_closed(timeout=5.0)


# --- L4: _batch_ceiling non-Mapping / missing-key prompt fallback ---------------


class _PromptRes:
    """Minimal ``GenerationResult`` stand-in exposing only ``.prompt`` — for
    the L4 ``_batch_ceiling`` fallback tests (non-Mapping / missing key)."""

    def __init__(self, prompt):
        self.prompt = prompt


def test_batch_ceiling_falls_back_on_non_mapping_prompt(caplog):
    """A ``result.prompt`` that is not a ``Mapping`` (e.g. a list) must not
    crash on ``.get()`` — falls back to the flat default ceiling with a
    warning, same treatment as a genuinely missing key."""
    stream = object.__new__(F._FishStream)
    with caplog.at_level("WARNING"):
        ceiling = stream._batch_ceiling(_PromptRes(prompt=["not", "a", "mapping"]))
    assert ceiling == F._DEFAULT_MAX_TOKENS
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert warnings, "expected a warning for a non-Mapping prompt"


def test_batch_ceiling_falls_back_when_tokens_key_missing(caplog):
    """A dict ``prompt`` missing the ``\"tokens\"`` key falls back to the flat
    default ceiling with a warning (distinct from a legitimate zero, which
    uses the real per-input formula via its own ``max(32, ...)`` floor)."""
    stream = object.__new__(F._FishStream)
    with caplog.at_level("WARNING"):
        ceiling = stream._batch_ceiling(_PromptRes(prompt={}))
    assert ceiling == F._DEFAULT_MAX_TOKENS
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert warnings, "expected a warning for a missing prompt['tokens'] key"


# --- L2: untagged prefix before the first <|speaker:N|> tag ---------------------


def test_check_untagged_prefix_rejects_prose_before_first_tag():
    with pytest.raises(F.FishUntaggedPrefixError):
        F._check_untagged_prefix("stray prose <|speaker:0|> hello")


def test_check_untagged_prefix_allows_tag_at_start():
    F._check_untagged_prefix("<|speaker:0|> hello")  # must not raise


def test_check_untagged_prefix_allows_plain_prose_with_no_speaker_tags():
    F._check_untagged_prefix("just plain prose, no speaker tags at all")  # must not raise


# --- SupportsTextValidation: FishBackend.validate_text ---------------------------


def test_validate_text_rejects_untagged_prefix():
    backend = F.FishBackend()
    msg = backend.validate_text("stray prose <|speaker:0|> hello")
    assert msg and "speaker" in msg


def test_validate_text_accepts_clean_text():
    backend = F.FishBackend()
    assert backend.validate_text("just plain prose, no speaker tags at all") is None
    assert backend.validate_text("<|speaker:0|> hello") is None


# --- L1: generate-time guard — near-floor budget + instruct = high truncation risk


class _FixedTokenizer:
    """Stand-in for ``model.tokenizer``: ``encode`` returns a list of the
    given length, independent of the actual text — the L1 check only cares
    about ``len(encode(text))``."""

    def __init__(self, token_count: int) -> None:
        self._token_count = token_count

    def encode(self, text: str) -> list[int]:
        return list(range(self._token_count))


class _ModelWithTokenizer:
    def __init__(self, token_count: int) -> None:
        self.tokenizer = _FixedTokenizer(token_count)


class _ModelWithoutTokenizer:
    """No ``tokenizer`` attribute at all — exercises the fail-safe path."""


def _make_instruct_risk_stream(*, model, text: str = "hi") -> F._FishStream:
    stream = object.__new__(F._FishStream)
    stream._text = text
    stream._extras = {"instruct": "be warm and cheerful"}
    stream._model = model
    return stream


def test_instruct_truncation_risk_rejects_near_floor_input_tokens():
    """``input_tokens=2`` -> ``budget = min(1024, max(32, 2*12)) = 32`` <=
    ``_INSTRUCT_RISK_MAX_BUDGET_TOKENS`` (72) -> must raise."""
    stream = _make_instruct_risk_stream(model=_ModelWithTokenizer(2))
    with pytest.raises(F.FishInstructTruncationRiskError):
        stream._check_instruct_truncation_risk()


def test_instruct_truncation_risk_rejects_regression_case_old_threshold_missed():
    """``input_tokens=5`` -> ``budget = min(1024, max(32, 5*12)) = 60`` <= 72
    -> must raise. The OLD threshold (``_INSTRUCT_RISK_MAX_INPUT_TOKENS = 2``,
    compared against the raw input-token count) would NOT have flagged this
    (5 > 2) even though the real generation budget (60 tokens) is still
    near-floor — this is the exact miscalibration the budget-based threshold
    fixes."""
    stream = _make_instruct_risk_stream(model=_ModelWithTokenizer(5))
    with pytest.raises(F.FishInstructTruncationRiskError):
        stream._check_instruct_truncation_risk()


def test_instruct_truncation_risk_allows_safely_long_input_tokens():
    """``input_tokens=50`` -> ``budget = min(1024, max(32, 50*12)) = 600`` >
    72 -> must not raise."""
    stream = _make_instruct_risk_stream(model=_ModelWithTokenizer(50))
    stream._check_instruct_truncation_risk()  # must not raise


def test_instruct_truncation_risk_skips_when_no_tokenizer_attr(caplog):
    """Fail SAFE, not fail CLOSED: a model with no ``tokenizer`` attribute
    must not raise — just log a warning and skip the check, even though the
    text is near-floor length."""
    stream = _make_instruct_risk_stream(model=_ModelWithoutTokenizer())
    with caplog.at_level("WARNING"):
        stream._check_instruct_truncation_risk()  # must not raise
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert warnings, "expected a warning when model.tokenizer is unavailable"


def test_instruct_truncation_risk_skips_speaker_tagged_multi_batch_text():
    """Speaker-tagged multi-batch text is scoped OUT of this check: a
    whole-buffer token count does not correspond to any single batch's real
    budget, so the near-floor heuristic must not fire even though the raw
    token count reported by the (fixed) tokenizer is near-floor."""
    stream = _make_instruct_risk_stream(model=_ModelWithTokenizer(2), text="<|speaker:0|> hi")
    stream._check_instruct_truncation_risk()  # must not raise


class _AssertNeverCalledModel:
    """``generate`` must never be invoked when ``_check_instruct_truncation_risk``
    raises first — asserts the ordering inside ``_gen_factory`` (moved there
    from the old pre-flight hook, see the class docstring's item 3)."""

    def __init__(self, token_count: int) -> None:
        self.tokenizer = _FixedTokenizer(token_count)

    def generate(self, text, **kwargs):
        raise AssertionError("model.generate() must not be called")


def test_gen_factory_raises_instruct_truncation_risk_before_calling_generate():
    """``_gen_factory`` calls ``_check_instruct_truncation_risk`` as its FIRST
    line, before ``self._model.generate(...)`` — a near-floor-budget commit
    paired with ``instruct`` must raise ``FishInstructTruncationRiskError``
    WITHOUT ever calling ``generate()``."""
    stream = object.__new__(F._FishStream)
    stream._text = "hi"
    stream._extras = {"instruct": "be warm and cheerful"}
    stream._model = _AssertNeverCalledModel(2)  # near-floor token count

    with pytest.raises(F.FishInstructTruncationRiskError):
        stream._gen_factory()


# --- _introspect_util.py: model-agnostic unit coverage (net-new shared helper) -
#
# No test exercised the private ``_verify_generate_signature`` before this
# refactor (Codex adversarial review, 2026-08-05) — this is net-new testing,
# not a preserved-behavior verification. A spy object stands in for the mlx
# model so the check runs without ``mlx_audio``.


class _SigSpy:
    """A bare object whose ``generate`` has a real, introspectable signature."""

    def generate(self, text, *, temperature=1.0, top_p=0.9, **kwargs):
        return iter(())


class _SigSpyNoKwargs:
    def generate(self, text, *, temperature=1.0):
        return iter(())


class _SigSpyUnintrospectable:
    # ``generate`` is not a plain function/lambda — inspect.signature() may
    # raise for some exotic callables; a builtin is the simplest stand-in.
    generate = len


def test_verify_generate_signature_matching_params_no_warning(caplog):
    from tts_server.backends._introspect_util import verify_generate_signature

    with caplog.at_level("WARNING"):
        verify_generate_signature(_SigSpy(), ["temperature", "top_p"], "fish_tts")
    assert not [r for r in caplog.records if r.levelname == "WARNING"]


def test_verify_generate_signature_missing_param_warns(caplog):
    from tts_server.backends._introspect_util import verify_generate_signature

    with caplog.at_level("WARNING"):
        verify_generate_signature(_SigSpyNoKwargs(), ["temperature", "top_p"], "fish_tts")
    warnings = [r for r in caplog.records if r.levelname == "WARNING"]
    assert warnings, "expected a warning for a missing advertised param"
    assert "top_p" in warnings[0].getMessage()


def test_verify_generate_signature_var_keyword_satisfies_every_name(caplog):
    """A ``**kwargs``-catching signature satisfies every expected name (an
    unknown kwarg would still be ACCEPTED, not TypeError, even if silently
    ignored downstream) — no warning."""
    from tts_server.backends._introspect_util import verify_generate_signature

    with caplog.at_level("WARNING"):
        verify_generate_signature(_SigSpy(), ["temperature", "top_p", "instruct"], "fish_tts")
    assert not [r for r in caplog.records if r.levelname == "WARNING"]


def test_verify_generate_signature_uninspectable_callable_does_not_raise(caplog):
    """Best-effort: an ``inspect.signature()`` failure is logged, never raised
    — an upstream reshape must not wedge serve."""
    from tts_server.backends._introspect_util import verify_generate_signature

    with caplog.at_level("WARNING"):
        verify_generate_signature(_SigSpyUnintrospectable(), ["temperature"], "fish_tts")
    # Must not raise; a warning (about the introspection failure itself) is
    # the acceptable outcome here.


# --- lazy-import / dual-wire (make_backend + argparse; Phase 2 dependency) ------


def _assert_lean(body: str) -> None:
    offenders = lean_import_offenders(body)
    assert not offenders, f"forbidden modules leaked: {offenders}"


def test_import_fish_tts_module_does_not_pull_mlx_or_numpy():
    """The lean-base invariant: importing the module pulls neither ``mlx_audio``
    nor ``numpy`` — the heavy deps enter the process only in ``start()``."""
    _assert_lean("import importlib; importlib.import_module('tts_server.backends.fish_tts')")


def test_default_model_constant_importable_lean():
    _assert_lean(
        "from tts_server.backends.fish_tts import DEFAULT_FISH_MODEL\n"
        "assert isinstance(DEFAULT_FISH_MODEL, str) and DEFAULT_FISH_MODEL\n"
    )


def test_make_backend_resolves_fish_tts_without_mlx():
    _assert_lean(
        "from tts_server.backends import make_backend\n"
        "b = make_backend('fish_tts')\n"
        "assert b.backend_name == 'fish_tts', b.backend_name\n"
        "assert b.sample_rate == 0, b.sample_rate\n"  # not started -> rate unknown
    )


def test_fish_tts_is_accepted_backend_choice():
    """The argparse ``--backend`` choices tuple half of the dual-wire: a
    passing ``make_backend`` is not enough — argparse must also accept the
    name, else ``--backend fish_tts`` dies before the resolver."""
    from tts_server.__main__ import build_parser

    parser = build_parser()
    args = parser.parse_args(["serve", "--backend", "fish_tts"])
    assert args.backend == "fish_tts"


def test_default_fish_model_resolves_identically_through_both_paths():
    """``DEFAULT_FISH_MODEL`` must resolve identically through BOTH
    independent paths (Codex adversarial review, 2026-08-05): importability
    alone doesn't prove this — ``tts_server/__main__.py``'s backend->default-
    model resolver AND ``make_backend("fish_tts")``'s ``model or
    DEFAULT_FISH_MODEL`` fallback must agree, asserted explicitly."""
    from tts_server.__main__ import _resolve_model
    from tts_server.backends import make_backend
    from tts_server.backends.fish_tts import DEFAULT_FISH_MODEL

    assert _resolve_model("fish_tts", None) == DEFAULT_FISH_MODEL
    backend = make_backend("fish_tts")
    assert backend.model == DEFAULT_FISH_MODEL
