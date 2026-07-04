"""Qwen3 backend LEAN tests (no mlx) — Phase 1.

On the lean allow-list (CI wiring lands in Phase 2). Covers everything provable
WITHOUT loading the 0.6B CustomVoice model:
- locked constants: ``_STREAMING_INTERVAL == 0.4`` plus the token-quantum math
  (qwen3 quantizes cadence in codec tokens at 12.5 tok/s, NOT seconds),
  ``DEFAULT_QWEN3_MODEL`` and ``DEFAULT_QWEN3_VOICE``;
- capabilities shape: ``streaming:true``, extras exactly
  ``[temperature, top_k, top_p]``, ``streaming_interval`` never advertised;
  languages/voice_count discovered dynamically from the model API (spied on a
  fake model exposing ``get_supported_speakers``/``get_supported_languages``);
- BOTH voice branches via an ``open_stream`` spy: voices non-empty +
  ``voice=None`` → inject ``DEFAULT_QWEN3_VOICE`` ("ryan"); explicit voice
  passes through verbatim; voices EMPTY (Base models, ``spk_id: {}``) → the
  ``voice`` kwarg is OMITTED (speaker-unconditioned path);
- language → ``lang_code`` mapping incl. ``None`` → ``"auto"``;
- the **forbidden-kwargs negative guard**: cloning/style/control kwargs
  (``ref_audio``/``ref_text``/``instruct``/``speed``/``split_pattern``/
  ``max_tokens``/``streaming_context_size``/``repetition_penalty``) must NEVER
  reach ``generate()`` even when injected DIRECTLY via ``open_stream`` extras
  (bypassing the server pre-filter) — ``ref_audio``+``ref_text`` silently
  activate ICL voice cloning upstream, so this is load-bearing;
- lazy-import: the module import pulls neither ``mlx_audio`` nor ``numpy``.

- the dual-wire (Phase 2): ``make_backend`` resolves ``qwen3_tts`` without
  pulling mlx, and argparse accepts ``--backend qwen3_tts``.

The mlx-gated synthesis assertions live in ``tests/test_qwen3_backend.py``.
"""

from __future__ import annotations


import pytest

from tts_server.backends import qwen3_tts as Q
from tts_server.backends._extras_util import TEMPERATURE_MAX, TOP_K_MAX, TOP_P_MAX

from ._helpers import lean_import_offenders

# Gate-verified facts (## Findings → Phase 0 gate results, CustomVoice run):
# 9 speakers, exact-case all-lowercase; languages incl. "auto" and "english".
_GATE_SPEAKERS = [
    "serena",
    "vivian",
    "uncle_fu",
    "ryan",
    "aiden",
    "ono_anna",
    "sohee",
    "eric",
    "dylan",
]
_GATE_LANGUAGES = [
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

# The out-of-scope generate() kwargs (plan → Requirements / Review Focus):
# generate() ACCEPTS them all, and ref_audio+ref_text silently activate cloning,
# so "never forwarded" must be proven at the backend layer, not assumed.
_FORBIDDEN_KWARGS = {
    "ref_audio": "clone_me.wav",
    "ref_text": "clone me",
    "instruct": "sound angry",
    "speed": 2.0,
    "split_pattern": r"\n+",
    "max_tokens": 99,
    "streaming_context_size": 3,
    "repetition_penalty": 1.5,
}


# --- locked constants ----------------------------------------------------------


def test_streaming_interval_locked_value():
    """The cadence default is LOCKED to the single gate-measured value
    (## Findings → Phase 0 Q2: TTFB 0.10 s @0.4). Equality to that one value,
    never a range — if a re-measurement moves it, this test moves with the
    Findings, not a band. (Cadence is token-quantized: ``max(1,
    int(0.4 * 12.5))`` = 5 codec tokens ≈ 0.4 s of audio per chunk, unlike
    Voxtral's seconds semantics.)"""
    assert Q._STREAMING_INTERVAL == 0.4


def test_max_text_chars_locked_value():
    """``_MAX_TEXT_CHARS`` is LOCKED to the measured safety value: 800 caps
    worst-case degenerate pacing (~0.19 s audio/char) at ~160 s of audio, 2x
    margin under mlx-audio's silent 4096-token single-generation ceiling
    (~328 s). A revert toward 2000 re-opens the multiconn keepalive cascade
    this value closed — see the constant's comment and the plan Findings."""
    assert Q._MAX_TEXT_CHARS == 800
    assert Q._MAX_TOKENS_CEILING == 4096


def test_default_model_constant():
    """CustomVoice is the gate-decided default (Base has ``spk_id: {}`` — the
    voice knob only works on CustomVoice; see the post-gate re-plan note)."""
    assert Q.DEFAULT_QWEN3_MODEL == "mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16"


def test_default_voice_constant():
    """CustomVoice models REQUIRE a voice (generate() raises without one), so the
    backend injects this default when the client sends none (gate Q4 decision)."""
    assert Q.DEFAULT_QWEN3_VOICE == "ryan"


# --- backend-unit: capabilities shape (pre-start) --------------------------------


def test_streaming_interval_not_in_advertised_extras():
    """``streaming_interval`` is per-backend CONFIG, never a client knob — it
    MUST NOT appear in ``capabilities()["extras"]``. The advertised set is
    exactly the effective sampling tunables (mirrors Voxtral); the exact-
    equality assertion is also guard #1 of the two-layer negative guard (no
    forbidden knob can be advertised — guard #2 is the open_stream spy)."""
    extras = Q.Qwen3Backend().capabilities()["extras"]
    assert "streaming_interval" not in extras
    assert extras == ["temperature", "top_k", "top_p"]


def test_capabilities_streaming_true():
    """qwen3 is a genuine sub-segment streamer (native stream/streaming_interval)."""
    assert Q.Qwen3Backend().capabilities()["streaming"] is True


def test_capabilities_shape_lean():
    """The static parts of capabilities() are available pre-start (rate/voices
    are not — those need the model). ``ideal_words``/``max_text_chars`` are
    gate-informed choices, so only shape/positivity is asserted here."""
    caps = Q.Qwen3Backend().capabilities()
    assert caps["binary_audio"] is False
    assert caps["text_formats"] == ["plain"]
    assert isinstance(caps["ideal_words"], int) and caps["ideal_words"] > 0
    assert isinstance(caps["max_text_chars"], int) and caps["max_text_chars"] > 0


# --- spy model: dynamic discovery + generate() kwargs ----------------------------


class _SpyModel:
    """A fake mlx model: ``generate`` records the kwargs it is called with and
    returns an empty generator, so the backend's ``_gen_factory`` can be driven
    WITHOUT mlx. Exposes the qwen3 model API the backend discovers from
    (``get_supported_speakers`` reads ``config.talker_config.spk_id`` upstream;
    an EMPTY speaker list is a VALID state — Base models)."""

    sample_rate = 24000

    def __init__(self, *, speakers=None, languages=None) -> None:
        self.calls: list[dict] = []
        self._speakers = list(_GATE_SPEAKERS) if speakers is None else list(speakers)
        self._languages = list(_GATE_LANGUAGES) if languages is None else list(languages)

    def get_supported_speakers(self):
        return list(self._speakers)

    def get_supported_languages(self):
        return list(self._languages)

    def generate(self, text, **kwargs):
        self.calls.append({"text": text, **kwargs})
        # ``results`` lets a test script the yielded GenerationResults (e.g.
        # the truncation-ceiling path); default stays an empty generator.
        return iter(self.results)

    results: tuple = ()


def _spy_backend(*, speakers=None, languages=None):
    """A backend wired to a spy model with discovery run — WITHOUT ``start()``
    (start() imports mlx_audio, the exact thing this suite must not do). Mirrors
    the discovery assignment ``start()`` performs on the loaded model."""
    backend = Q.Qwen3Backend()
    spy = _SpyModel(speakers=speakers, languages=languages)
    backend._loaded_model = spy
    backend._voice_names = backend._discover_voices()
    backend._languages = backend._discover_languages()
    backend._default_voice = backend._resolve_default_voice()
    return backend, spy


async def _gen_kwargs(*, voice, language, extras, speakers=None):
    """Open a stream on a spy-model backend and return the kwargs that
    ``_gen_factory`` would pass to ``model.generate`` (positional text excluded)."""
    backend, spy = _spy_backend(speakers=speakers)
    stream = await backend.open_stream(voice=voice, language=language, extras=extras)
    stream._text = "hello world"
    list(stream._gen_factory())  # drive the (empty) generator to record the call
    assert len(spy.calls) == 1
    return spy.calls[0]


def test_capabilities_dynamic_from_model_discovery():
    """voice_count/languages/voices() come from the MODEL API (never a hardcoded
    list), and voices() advertises the model's EXACT-CASE strings verbatim — the
    server validates case-exactly against ``frozenset(voices())``."""
    backend, _ = _spy_backend()
    caps = backend.capabilities()
    assert caps["voice_count"] == len(_GATE_SPEAKERS)
    assert sorted(caps["languages"]) == sorted(_GATE_LANGUAGES)
    assert sorted(backend.voices()) == sorted(_GATE_SPEAKERS)


def test_default_voice_is_member_of_discovered_voices():
    """The injected default must be a member of the discovered ``voices()`` when
    non-empty (Review Focus) — otherwise the server would advertise voices the
    injected default is not among."""
    backend, _ = _spy_backend()
    assert Q.DEFAULT_QWEN3_VOICE in backend.voices()


def test_empty_speakers_is_valid_voice_count_zero():
    """Empty ``get_supported_speakers()`` is a VALID state (Base models,
    ``spk_id: {}``) — ``voice_count: 0``, no static fallback list (a fake list
    would advertise voices the model ignores)."""
    backend, _ = _spy_backend(speakers=[])
    assert backend.voices() == []
    assert backend.capabilities()["voice_count"] == 0


# --- voice branches (gate Q4 decision) -------------------------------------------


async def test_voice_none_injects_default_when_voices_nonempty():
    """CustomVoice REQUIRES a voice (generate() raises without one, gate Q4):
    when the client sends none and discovery found speakers, the backend injects
    ``DEFAULT_QWEN3_VOICE`` rather than forwarding ``voice=None``."""
    call = await _gen_kwargs(voice=None, language=None, extras=None)
    assert call["voice"] == Q.DEFAULT_QWEN3_VOICE
    # streaming is always driven; the locked interval is always passed.
    assert call["stream"] is True
    assert call["streaming_interval"] == Q._STREAMING_INTERVAL


async def test_explicit_voice_passes_through_verbatim():
    """A client voice (server-validated, exact-case) passes through unchanged."""
    call = await _gen_kwargs(voice="uncle_fu", language=None, extras=None)
    assert call["voice"] == "uncle_fu"


async def test_voice_kwarg_omitted_when_voices_empty():
    """Base models (empty ``voices()``) take the speaker-UNCONDITIONED path: the
    ``voice`` kwarg is OMITTED from generate() entirely — no injected default
    (injecting "ryan" into a model with ``spk_id: {}`` would be a lie)."""
    call = await _gen_kwargs(voice=None, language=None, extras=None, speakers=[])
    assert "voice" not in call


async def test_client_voice_discarded_when_voices_empty():
    """A client-SUPPLIED voice is also DISCARDED on the no-speakers path, not
    forwarded: the server's voice_count:0 accept-branch exists precisely
    because such backends ignore voice (dia precedent) — forwarding would ride
    on mlx-audio's silent-ignore of unknown speakers and break the docstring's
    'Base OMITS the voice kwarg entirely' contract."""
    call = await _gen_kwargs(voice="ryan", language=None, extras=None, speakers=[])
    assert "voice" not in call


# --- language → lang_code mapping -------------------------------------------------


async def test_language_maps_to_lang_code():
    """The server-validated client ``language`` forwards as ``lang_code`` —
    language is a real generate() knob on qwen3, unlike Voxtral's voice-preset
    encoding."""
    call = await _gen_kwargs(voice=None, language="english", extras=None)
    assert call["lang_code"] == "english"


async def test_language_none_maps_to_auto():
    call = await _gen_kwargs(voice=None, language=None, extras=None)
    assert call["lang_code"] == "auto"


# --- forbidden-kwargs negative guard + extras filtering/coercion ------------------


async def test_forbidden_kwargs_never_reach_generate():
    """The load-bearing backend-layer guard: call open_stream DIRECTLY with the
    full forbidden set (bypassing the server pre-filter, robust to a future
    unfiltered ``**extras`` refactor) and assert NONE of them reach generate()
    while the advertised extras survive coerced."""
    extras = dict(_FORBIDDEN_KWARGS)
    extras.update({"temperature": 0.5, "top_k": 30, "top_p": 0.9})
    call = await _gen_kwargs(voice=None, language=None, extras=extras)
    for key in _FORBIDDEN_KWARGS:
        assert key not in call, f"forbidden kwarg {key!r} reached generate()"
    assert call["temperature"] == 0.5
    assert call["top_k"] == 30
    assert call["top_p"] == 0.9


async def test_allowed_extras_clamped_to_bounds():
    """Out-of-range advertised extras are CLAMPED (not forwarded raw): a
    degenerate value runs under the process-wide Metal lock, so it is a
    denial-of-service vector, mirroring Voxtral's bounds discipline."""
    call = await _gen_kwargs(
        voice=None,
        language=None,
        extras={"temperature": 99, "top_k": 10_000, "top_p": 2.0},
    )
    assert call["temperature"] == TEMPERATURE_MAX
    assert call["top_k"] == TOP_K_MAX
    assert call["top_p"] == TOP_P_MAX


async def test_unset_extras_are_omitted_not_none():
    """Extras not supplied are OMITTED (not forwarded as None) so the model's own
    sampling defaults stand — same discipline as the voice omit."""
    call = await _gen_kwargs(voice=None, language=None, extras={"temperature": 0.7})
    assert call["temperature"] == 0.7
    assert "top_k" not in call
    assert "top_p" not in call


def test_validate_extras_reports_bad_value():
    backend = Q.Qwen3Backend()
    assert backend.validate_extras({}) is None
    assert backend.validate_extras({"temperature": 0.5}) is None
    msg = backend.validate_extras({"top_p": 0})
    assert msg and "top_p" in msg
    # ref_audio is not an advertised key, so validate_extras ignores it (the
    # server drops it; the backend filter in open_stream is the real guard).
    assert backend.validate_extras({"ref_audio": "x"}) is None


def test_validate_extras_rejects_booleans():
    """A JSON ``true``/``false`` is a client config mistake, not a number:
    every coercer must reject it (``bool`` is float-coercible — without the
    explicit check, ``{"temperature": true}`` silently synthesizes at 1.0)."""
    backend = Q.Qwen3Backend()
    for key in ("temperature", "top_k", "top_p"):
        for bad in (True, False):
            msg = backend.validate_extras({key: bad})
            assert msg and key in msg, f"{key}={bad!r} was not rejected"


class _SegRes:
    """Minimal GenerationResult stand-in for the truncation tripwire."""

    def __init__(self, segment_idx: int, token_count: int, audio=(0.0, 0.1, -0.1)):
        self.segment_idx = segment_idx
        self.token_count = token_count
        # A bare float sequence — the bridge's converter accepts it (the
        # documented mlx-free test path), so events() can be driven end-to-end.
        self.audio = list(audio)


def test_truncation_tripwire_is_per_segment():
    """The 4096-token ceiling is PER SEGMENT: the Base path splits the commit
    on ``\\n`` into independent generations, each with its own ``max_tokens``
    loop. Two naturally-completed 2500-token segments must NOT trip (their sum
    exceeds the cap), while any single segment reaching the cap must raise —
    including one in the middle of the stream."""
    stream = object.__new__(Q._Qwen3Stream)
    stream._text = "x" * 100

    # Cross-segment sum > cap, each segment under it: natural completion.
    list(stream._count_tokens(iter([_SegRes(0, 2500), _SegRes(1, 2500)])))

    with pytest.raises(Q.Qwen3TruncationError, match="ceiling"):
        list(stream._count_tokens(iter([_SegRes(0, 100), _SegRes(1, 4200), _SegRes(2, 50)])))


async def test_truncated_segment_fails_response_not_silent_success():
    """Adversarial-review fix: a ceiling-hit must be a CLIENT-VISIBLE failure,
    not an operator log line. Drive the full ``events()`` drain through the
    real bridge with a generation that reaches the cap and assert the raise
    propagates with NO ``completed`` event — the server turns that exception
    into ``response.failed`` (BACKEND_ERROR), so truncated audio can never
    masquerade as a clean completion."""
    backend, spy = _spy_backend()
    spy.results = (_SegRes(0, 4096),)
    stream = await backend.open_stream(voice=None, language=None, extras=None)
    await stream.feed("hello")
    await stream.end()

    events = []
    with pytest.raises(Q.Qwen3TruncationError, match="ceiling"):
        async for ev in stream.events():
            events.append(ev)
    assert all(ev.kind != "completed" for ev in events)
    await stream.wait_closed(timeout=5.0)


# --- lazy-import / dual-wire (make_backend + argparse choices) --------------------


def _assert_lean(body: str) -> None:
    """Run ``body`` in a FRESH interpreter via the shared probe; fail if it
    pulled any ``LEAN_FORBIDDEN_ROOTS`` module (``mlx_audio``/``numpy``) into
    ``sys.modules``. The child interpreter keeps the assertion independent of
    test order, since mlx IS installed in the full env."""
    offenders = lean_import_offenders(body)
    assert not offenders, f"forbidden modules leaked: {offenders}"


def test_import_qwen3_module_does_not_pull_mlx_or_numpy():
    """The lean-base invariant: importing the module pulls neither ``mlx_audio``
    nor ``numpy`` — the heavy deps enter the process only in ``start()``."""
    _assert_lean("import importlib; importlib.import_module('tts_server.backends.qwen3_tts')")


def test_default_model_constant_importable_lean():
    _assert_lean(
        "from tts_server.backends.qwen3_tts import DEFAULT_QWEN3_MODEL, DEFAULT_QWEN3_VOICE\n"
        "assert isinstance(DEFAULT_QWEN3_MODEL, str) and DEFAULT_QWEN3_MODEL\n"
        "assert isinstance(DEFAULT_QWEN3_VOICE, str) and DEFAULT_QWEN3_VOICE\n"
    )


def test_make_backend_resolves_qwen3_without_mlx():
    _assert_lean(
        "from tts_server.backends import make_backend\n"
        "b = make_backend('qwen3_tts')\n"
        "assert b.backend_name == 'qwen3_tts', b.backend_name\n"
        "assert b.sample_rate == 0, b.sample_rate\n"  # not started -> rate unknown
    )


def test_qwen3_is_accepted_backend_choice():
    """The argparse ``--backend`` choices tuple half of the dual-wire: a passing
    ``make_backend`` is not enough — argparse must also accept the name, else
    ``--backend qwen3_tts`` dies before the resolver. Parse real argv."""
    from tts_server.__main__ import build_parser

    parser = build_parser()
    args = parser.parse_args(["serve", "--backend", "qwen3_tts"])
    assert args.backend == "qwen3_tts"
