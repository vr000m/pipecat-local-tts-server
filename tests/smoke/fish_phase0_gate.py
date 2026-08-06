#!/usr/bin/env python3
"""Fish Audio S2 Pro (``fish_tts``) Phase 0 verification gate (dia/qwen3 precedent —
run BEFORE any backend code).

Standalone script: direct mlx-audio usage (``mlx_audio.tts.utils.load``), no
tts_server involvement. Downloads the model once and answers the six gate
questions from the plan
(``docs/dev_plans/20260804-feature-tts-fish-s2pro-backend.md``), printing a
clearly-labeled PASS/FAIL/RECORD line per question plus a machine-greppable
final summary (``GATE-SUMMARY ...`` / ``fish phase0 gate: ...``).

  Q1 — cross-batch coupling: seeded A/B/C comparison (dia precedent), using
       ``<|speaker:N|>``-tagged multi-turn input — plain untagged prose never
       leaves ``_split_generation_text``'s single-batch ``[text]`` fallback,
       so a coupling probe MUST use tagged turns to exercise multi-batch
       generation at all. Two independent split triggers exist
       (``group_turns_into_batches``: a 5-turn cap and a ``chunk_length``
       byte cap) and both are exercised here. Also checks the mixed-input
       hazard (untagged prose before the first tag is silently dropped by
       ``split_text_by_speaker``) and cross-CALL independence (two separate
       ``generate()`` calls). Byte-identity of batch-2's waveform is the
       machine-checked verdict; "audibly broken" is a human-listen judgment
       recorded separately in the plan's ``## Findings``, not asserted here.
  Q2 — latency + memory: TTFB (first ``GenerationResult`` wall time) and
       full-utterance RTF for a short and a ~15s-equivalent ordinary-prose
       utterance. Peak memory via ``GenerationResult.peak_memory_usage`` /
       ``mx.get_peak_memory()`` (the Phase-3 profiler cannot see it — the
       bridge strips everything but PCM, qwen3/dia precedent).
  Q3 — sample rate + voice/language surface: confirms ``model.sample_rate``
       actually reported (dataclass default is 44100 — verify, don't
       assume), that ``generate()`` truly ignores ``voice`` empirically
       (already source-verified via unconditional ``del voice``), and that
       no ``language`` parameter exists in ``generate()``'s signature.
  Q4 — ``instruct`` behavior: with and without an ``instruct`` string, and a
       very long ``instruct`` string, to inform ``coerce_instruct``'s
       length-reject bound.
  Q5 — token budget / truncation: ``max_tokens`` defaults to 1024 and is a
       per-BATCH ceiling (not a flat per-``generate()``-call ceiling).
       Measures how much audio that caps out at on realistic ordinary prose
       (always exactly one batch — ``chunk_length`` provides zero
       protection there), informing ``_MAX_TEXT_CHARS`` (qwen3
       CustomVoice-truncation precedent).
  Q6 — license + upstream model-card figures: fetches and reads the actual
       HF repo license/card for both ``mlx-community/fish-audio-s2-pro`` (the
       conversion actually used) and ``fishaudio/s2-pro`` (the assumed
       source repo) — nothing is assumed, only what is fetched is recorded.

Also records (not a numbered question): audio sanity (NaN count, clipping,
duration) for every generated buffer, and an inline ``[tag]`` emotion-markup
utterance to confirm the markup is at least accepted without erroring.

Every WAV lands in a fresh secure ``mkdtemp`` dir by default (mirrors
run_smoke.sh / the qwen3/dia gate scripts); paths are printed for
perceptual listening.

Compile-mode note: this script calls ``mx.disable_compile()`` before loading
the model, matching Phase 1's production ``FishBackend.start()`` (proactive
``mx.compile``/``CompilerCache`` worker-thread crash-class guard, qwen3
precedent) — this keeps Q1's determinism/coupling verdict and Q2's latency
numbers representative of production execution mode rather than diverging
from it (see the plan's Context "Gate/production measurement divergence").

GATE semantics (from the plan): Q1 FAIL (determinism control broken, or
cross-CALL state detected) -> re-plan. Coupling ITSELF (batch-2 differing
when batch-1 is varied, within one call) is NOT a FAIL — it is expected,
matches dia — it is recorded for a human-listen "audibly broken?" judgment
in ``## Findings``; the GATE only fires if that judgment is yes. Q3
surprises (non-44100 rate, voice/language behaving unexpectedly) -> update
Phase 1 defaults. Q5 truncation on realistic prose -> set
``_MAX_TEXT_CHARS`` conservatively. Findings land in the plan's
``## Findings`` below the ``<!-- reviewed -->`` marker.

Usage (the ``dia`` extra supplies mlx-audio 0.4.4; the ``fish_tts`` extra
does not exist until Phase 2 — a bare ``uv run`` re-syncs to lean base and
strips mlx):

  uv run --extra dia python tests/smoke/fish_phase0_gate.py
  uv run --extra dia python tests/smoke/fish_phase0_gate.py --only q1 q6
  uv run --extra dia python tests/smoke/fish_phase0_gate.py --out-dir /tmp/fish-gate
"""

from __future__ import annotations

import argparse
import inspect
import sys
import tempfile
import time
import wave
from pathlib import Path

DEFAULT_MODEL = "mlx-community/fish-audio-s2-pro"
SOURCE_MODEL = "fishaudio/s2-pro"
_DEFAULT_SEED = 42
_GREEDY_TEMPERATURE = 0.0
_DEFAULT_CHUNK_LENGTH = 300  # generate()'s own default, per fish_speech.py:959
_DEFAULT_MAX_TOKENS = 1024  # generate()'s own default (per-BATCH ceiling), per fish_speech.py:953

_SHORT_TEXT = "The quick brown fox jumps over the lazy dog."
# ~15 s of speech at a normal rate (~2.5 words/s -> ~38 words). Ordinary
# prose, no <|speaker:N|> tags -> always exactly one batch (Q1 correction).
_LONG_TEXT = (
    "Streaming text to speech is most useful when the first audio arrives quickly, "
    "because a listener starts judging responsiveness long before the sentence ends. "
    "This longer utterance exists purely to measure sustained generation throughput "
    "on this machine."
)

# --- Q1 payloads --------------------------------------------------------------------

# Turn-count trigger: 6 alternating-speaker turns, each short enough that the
# first 5 turns stay well under the default chunk_length=300 byte cap, so the
# split is driven by group_turns_into_batches' max_speakers=5 cap, not bytes.
_Q1_TC_TURN0_A = "<|speaker:0|>The weather today is quite mild and pleasant."
_Q1_TC_TURN0_C = "<|speaker:0|>The committee reviewed the annual budget figures."
_Q1_TC_TURNS_REST = [
    "<|speaker:1|>That sounds nice, tell me a bit more.",
    "<|speaker:0|>Sure, it should stay dry for the whole week.",
    "<|speaker:1|>Great, I was hoping to go for a long walk.",
    "<|speaker:0|>Perfect timing then, enjoy your afternoon.",
    "<|speaker:1|>Thanks, I will let you know how it goes later.",
]

# Byte trigger: 2 turns where the first turn alone is close to the default
# chunk_length=300 byte cap, so adding the second (short) turn forces a new
# batch on the byte threshold rather than the 5-turn cap.
_Q1_BYTE_TURN0_A = "<|speaker:0|>" + (
    "This is a deliberately long first turn, padded with extra words, meant to "
    "occupy most of the default chunk_length byte budget on its own so that the "
    "very next short turn gets pushed into its own separate batch by the byte "
    "threshold rather than by the five-turn speaker cap that the other probe uses."
)
_Q1_BYTE_TURN0_C = "<|speaker:0|>" + (
    "This is a deliberately long FIRST turn, reworded a little, still meant to "
    "occupy most of the default chunk_length byte budget on its own so that the "
    "very next short turn gets pushed into its own separate batch by the byte "
    "threshold rather than by the five-turn speaker cap that the other probe uses."
)
_Q1_BYTE_TURN1 = "<|speaker:1|>Okay, got it, thanks for explaining."

# Mixed-input hazard: untagged prose before the first <|speaker:N|> tag.
_Q1_MIXED_TEXT = "Intro sentence that should be dropped. <|speaker:0|>Hello there."

# Cross-CALL independence probe (plain untagged text; no batching involved).
_Q1_TEXT_PRIOR = "This sentence exists only to advance the model before the probe."
_Q1_TEXT_X = "Yes, where were we before that interruption happened?"

# --- Q5 payload ----------------------------------------------------------------------

_Q5_LONG_PROSE = (
    "This is a realistic long paragraph of ordinary prose without any speaker tags, "
    "written to approximate what a client might actually send in one committed turn. "
) * 6  # several hundred words; no <|speaker:N|> tags -> always exactly one batch.

_QUESTIONS = ("q1", "q2", "q3", "q4", "q5", "q6")


# --- small helpers (qwen3/dia gate pattern) ------------------------------------------


def _to_numpy(audio):
    """Materialise an mlx (or array-like) audio buffer as a float32 numpy array."""
    import numpy as np

    return np.asarray(audio, dtype=np.float32)


def _audio_sanity(label: str, audio_np, rate: int) -> None:
    """Audio-sanity record for a generated buffer: NaN count, max abs, duration."""
    import numpy as np

    nan_count = int(np.isnan(audio_np).sum())
    max_abs = float(np.max(np.abs(audio_np))) if audio_np.size else 0.0
    duration = audio_np.shape[0] / rate if rate else float("nan")
    clipped = " CLIPPED" if max_abs > 1.0 else ""
    print(
        f"   RECORD [{label}] audio-sanity: nan_count={nan_count} "
        f"max_abs={max_abs:.4f}{clipped} duration={duration:.2f}s samples={audio_np.shape[0]}"
    )


def _write_wav(path: Path, audio_np, rate: int) -> None:
    """Write a float32 [-1, 1] mono buffer as pcm16 WAV (clipped, not normalised)."""
    import numpy as np

    # Asymmetric x32768/x32767 map — the wire mapping (tts_server/_audio.py);
    # the naive symmetric x32767 never reaches -32768 and clips the negative
    # rail one LSB early. Inlined (numpy) to keep this script standalone.
    clipped = np.clip(audio_np, -1.0, 1.0)
    pcm = np.where(clipped < 0, clipped * 32768.0, clipped * 32767.0).astype(np.int16)
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm.tobytes())
    print(f"   WAV written: {path}")


def _drain(gen) -> list:
    """Drain a generate() generator, returning the list of GenerationResults."""
    return list(gen)


def _concat_audio(results) -> object:
    import numpy as np

    parts = [_to_numpy(r.audio) for r in results if getattr(r, "audio", None) is not None]
    if not parts:
        return np.zeros(0, dtype=np.float32)
    return np.concatenate(parts)


def _array_equal(a, b) -> bool:
    import numpy as np

    a, b = np.asarray(a), np.asarray(b)
    return a.shape == b.shape and bool(np.array_equal(a, b))


def _max_abs_diff(a, b) -> float:
    import numpy as np

    a, b = np.asarray(a), np.asarray(b)
    if a.shape != b.shape:
        return float("inf")
    return float(np.max(np.abs(a - b))) if a.size else 0.0


def _reset_peak_memory() -> None:
    import mlx.core as mx

    reset = getattr(mx, "reset_peak_memory", None)
    if callable(reset):
        reset()


def _render_seeded(model, text: str, seed: int, **kwargs) -> list:
    """Seed mlx's RNG then render greedily (temperature=0.0) — the dia/qwen3
    gate's determinism recipe. Non-stream: one GenerationResult per batch."""
    import mlx.core as mx

    mx.random.seed(seed)
    return _drain(model.generate(text, stream=False, temperature=_GREEDY_TEMPERATURE, **kwargs))


# --- Q1: cross-batch coupling ---------------------------------------------------------


def _q1_probe_batch2_identity(
    model, label: str, text_a: str, text_c: str, seed: int
) -> tuple[str, bool]:
    """Seeded A/B/C comparison for one tagged multi-turn payload. Returns
    (verdict, hard_fail) where hard_fail is True only on a broken
    determinism control (not on coupling itself, which is expected/RECORD)."""
    print(f"   --- {label} ---")
    res_a = _render_seeded(model, text_a, seed)
    res_b = _render_seeded(model, text_a, seed)  # determinism control
    res_c = _render_seeded(model, text_c, seed)
    print(f"   RECORD {label} batches: A={len(res_a)} B={len(res_b)} C={len(res_c)}")

    if len(res_a) < 2 or len(res_b) < 2 or len(res_c) < 2:
        print(
            f"   RECORD {label}: fewer than 2 batches actually generated "
            "(payload did not trigger a split as constructed) -- inconclusive for this probe."
        )
        return "INCONCLUSIVE", False

    a1, b1 = _to_numpy(res_a[1].audio), _to_numpy(res_b[1].audio)
    if not _array_equal(a1, b1):
        print(
            f"   {label} FAIL: determinism control failed (A vs B batch-2 differ, "
            f"max_abs_diff={_max_abs_diff(a1, b1):.6f}) -- seeded greedy decoding is not "
            "reproducible; the A/C comparison below is inconclusive."
        )
        return "FAIL", True

    print(f"   RECORD {label} determinism control: A == B batch-2 (byte-identical) OK")
    c1 = _to_numpy(res_c[1].audio)
    batch2_equal = _array_equal(a1, c1)
    print(
        f"   RECORD {label} batch-2 byte-identity A vs C: equal={batch2_equal} "
        f"shapes={a1.shape}/{c1.shape} max_abs_diff={_max_abs_diff(a1, c1):.6f}"
    )
    if batch2_equal:
        print(f"   {label} PASS (machine): batch-2 byte-identical -- no cross-batch coupling.")
        return "PASS", False
    print(
        f"   {label} RECORD (machine): batch-2 differs when batch-1's tagged text is varied "
        "-- cross-batch coupling CONFIRMED (matches dia precedent; conversation history carries "
        "batch-1's audio codes into batch-2's prompt). NOT itself a FAIL -- listen to the WAVs "
        "and record a human-listen 'audibly broken?' verdict in ## Findings. The GATE only "
        "triggers if that human-listen judgment is yes."
    )
    return "COUPLED", False


def q1_cross_batch_coupling(model, out_dir: Path, seed: int) -> str:
    from mlx_audio.tts.models.fish_qwen3_omni.prompt import (
        group_turns_into_batches,
        split_text_by_speaker,
    )

    print("=== Q1: cross-batch coupling (seeded A/B/C, <|speaker:N|>-tagged input) ===")

    # --- mixed-input hazard: untagged prefix before the first tag is dropped ---
    mixed_turns = split_text_by_speaker(_Q1_MIXED_TEXT)
    prefix_dropped = not any("Intro sentence" in t for t in mixed_turns)
    print(f"   RECORD mixed-input split_text_by_speaker({_Q1_MIXED_TEXT!r}) = {mixed_turns!r}")
    print(f"   RECORD mixed-input-hazard: untagged prefix silently dropped = {prefix_dropped}")

    # --- pre-validate batch counts directly (no model needed) for both triggers ---
    text_tc_a = "\n".join([_Q1_TC_TURN0_A, *_Q1_TC_TURNS_REST])
    text_tc_c = "\n".join([_Q1_TC_TURN0_C, *_Q1_TC_TURNS_REST])
    batches_tc_a = group_turns_into_batches(
        split_text_by_speaker(text_tc_a), max_bytes=_DEFAULT_CHUNK_LENGTH
    )
    print(
        f"   RECORD turn-count-trigger batch count = {len(batches_tc_a)} "
        f"(5-turn cap; per-batch bytes={[len(b.encode('utf-8')) for b in batches_tc_a]})"
    )

    text_byte_a = f"{_Q1_BYTE_TURN0_A}\n{_Q1_BYTE_TURN1}"
    text_byte_c = f"{_Q1_BYTE_TURN0_C}\n{_Q1_BYTE_TURN1}"
    batches_byte_a = group_turns_into_batches(
        split_text_by_speaker(text_byte_a), max_bytes=_DEFAULT_CHUNK_LENGTH
    )
    print(
        f"   RECORD byte-trigger batch count = {len(batches_byte_a)} "
        f"(chunk_length={_DEFAULT_CHUNK_LENGTH} byte cap; "
        f"per-batch bytes={[len(b.encode('utf-8')) for b in batches_byte_a]})"
    )

    overall = "PASS"

    tc_verdict, tc_hard_fail = _q1_probe_batch2_identity(
        model, "turn-count-trigger", text_tc_a, text_tc_c, seed
    )
    if tc_hard_fail:
        overall = "FAIL"

    byte_verdict, byte_hard_fail = _q1_probe_batch2_identity(
        model, "byte-trigger", text_byte_a, text_byte_c, seed
    )
    if byte_hard_fail:
        overall = "FAIL"

    # Perceptual WAVs for the human-listen judgment.
    for label, text_a in (("tc", text_tc_a), ("byte", text_byte_a)):
        res = _render_seeded(model, text_a, seed)
        audio = _concat_audio(res)
        _audio_sanity(f"q1-{label}-a", audio, model.sample_rate)
        _write_wav(out_dir / f"q1_coupling_{label}_a.wav", audio, model.sample_rate)

    # Mixed-input perceptual WAV (accepted-without-erroring check).
    try:
        res_mixed = _render_seeded(model, _Q1_MIXED_TEXT, seed)
        audio_mixed = _concat_audio(res_mixed)
        _audio_sanity("q1-mixed-input", audio_mixed, model.sample_rate)
        _write_wav(out_dir / "q1_mixed_input.wav", audio_mixed, model.sample_rate)
        print(
            "   RECORD mixed-input generate(): succeeded without erroring (listen to confirm the intro is missing)"
        )
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(f"   RECORD mixed-input generate() raised {type(exc).__name__}: {exc}")

    # Cross-CALL independence (the hard-gate part): X alone vs X after a prior
    # call on the same model object, re-seeded before each X render.
    print("   --- cross-call independence ---")
    x_alone = _render_seeded(model, _Q1_TEXT_X, seed)
    _render_seeded(model, _Q1_TEXT_PRIOR, seed)
    x_after = _render_seeded(model, _Q1_TEXT_X, seed)
    xa, xf = _concat_audio(x_alone), _concat_audio(x_after)
    cross_call_equal = _array_equal(xa, xf)
    print(
        f"   RECORD cross-call X_alone vs X_after: equal={cross_call_equal} "
        f"shapes={xa.shape}/{xf.shape} max_abs_diff={_max_abs_diff(xa, xf):.6f}"
    )
    if not cross_call_equal:
        print(
            "   Q1 FAIL: cross-CALL state detected -- two separate generate() calls "
            "are NOT independent. Dia-precedent re-plan required."
        )
        overall = "FAIL"
    else:
        print("   RECORD cross-call: generate() calls are independent (stateless across calls)")

    print(
        f"   RECORD Q1 decision: accept within-call coupling as designed-in for tagged "
        f"multi-turn input (matches dia) unless a human-listen verdict says otherwise "
        f"-- turn-count-trigger={tc_verdict}, byte-trigger={byte_verdict}. This has NO bearing "
        "on ordinary/untagged prose, which is always single-batch regardless of chunk_length."
    )
    return overall


# --- Q2: latency + memory -------------------------------------------------------------


def q2_latency_memory(model, out_dir: Path) -> str:
    import mlx.core as mx

    print("=== Q2: TTFB / RTF / peak memory (short + ~15s ordinary prose) ===")
    rate = model.sample_rate
    for label, text in (("short", _SHORT_TEXT), ("long", _LONG_TEXT)):
        _reset_peak_memory()
        t0 = time.monotonic()
        ttfb = float("nan")
        results = []
        for res in model.generate(text, stream=False, temperature=_GREEDY_TEMPERATURE):
            if not results:
                ttfb = time.monotonic() - t0
            results.append(res)
        wall = time.monotonic() - t0

        audio_np = _concat_audio(results)
        audio_s = audio_np.shape[0] / rate if rate else float("nan")
        # RTF = synth wall-clock / audio duration; <1 is faster than real time.
        rtf = wall / audio_s if audio_s else float("nan")
        peak_mx_gb = mx.get_peak_memory() / 1e9
        result_peaks = [
            getattr(r, "peak_memory_usage", None)
            for r in results
            if getattr(r, "peak_memory_usage", None) is not None
        ]
        peak_result_gb = max(result_peaks) if result_peaks else float("nan")
        print(
            f"   RECORD [{label}]: ttfb={ttfb:.2f}s wall={wall:.2f}s audio={audio_s:.2f}s "
            f"rtf={rtf:.2f} batches={len(results)} peak_mem(mx)={peak_mx_gb:.2f}GB "
            f"peak_mem(result)={peak_result_gb:.2f}GB"
        )
        _audio_sanity(f"q2-{label}", audio_np, rate)
        if label == "long":
            _write_wav(out_dir / "q2_long.wav", audio_np, rate)
    print("   Q2 RECORD: measurement question — numbers above go into ## Findings")
    return "RECORD"


# --- Q3: sample rate + voice/language surface -----------------------------------------


def q3_rate_voice_language(model) -> str:
    print("=== Q3: sample rate + voice/language surface ===")
    rate = model.sample_rate
    print(
        f"   RECORD model.sample_rate = {rate!r} (dataclass default is 44100 — verify, don't assume)"
    )

    sig = inspect.signature(model.generate)
    params = list(sig.parameters)
    print(f"   RECORD generate() signature params = {params!r}")
    has_language = "language" in params
    print(f"   RECORD 'language' knob present in generate() signature = {has_language}")

    res_none = _render_seeded(model, _SHORT_TEXT, _DEFAULT_SEED, voice=None)
    res_voice = _render_seeded(model, _SHORT_TEXT, _DEFAULT_SEED, voice="not-a-real-voice")
    a, b = _concat_audio(res_none), _concat_audio(res_voice)
    voice_discarded = _array_equal(a, b)
    print(
        f"   RECORD voice=None vs voice='not-a-real-voice' byte-identical = {voice_discarded} "
        "(source-verified via unconditional `del voice` in fish_speech.py:964; "
        "this confirms it empirically too)"
    )

    ok = bool(rate) and voice_discarded and not has_language
    if not ok:
        print(
            "   Q3 RECORD: surprise detected (non-44100 rate, voice affecting output, or a "
            "language knob present) -- update Phase 1 defaults before proceeding."
        )
        return "RECORD"
    print(
        f"   Q3 PASS: sample_rate={rate}, voice discard confirmed, no language knob in signature."
    )
    return "PASS"


# --- Q4: instruct behavior --------------------------------------------------------------


def q4_instruct(model, out_dir: Path) -> str:
    print("=== Q4: instruct behavior (absent / present / very-long) ===")
    ok = True

    try:
        res_none = _render_seeded(model, _SHORT_TEXT, _DEFAULT_SEED, instruct=None)
        audio_none = _concat_audio(res_none)
        _audio_sanity("q4-instruct-none", audio_none, model.sample_rate)
        print("   RECORD instruct=None: generate() succeeded cleanly (no-op default)")
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(f"   Q4 RECORD: instruct=None raised {type(exc).__name__}: {exc}")
        ok = False

    try:
        res_present = _render_seeded(
            model, _SHORT_TEXT, _DEFAULT_SEED, instruct="Speak in a cheerful, upbeat tone."
        )
        audio_present = _concat_audio(res_present)
        _audio_sanity("q4-instruct-present", audio_present, model.sample_rate)
        _write_wav(out_dir / "q4_instruct_present.wav", audio_present, model.sample_rate)
        print("   RECORD instruct=<cheerful>: generate() succeeded cleanly")
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(f"   Q4 RECORD: instruct=<cheerful> raised {type(exc).__name__}: {exc}")
        ok = False

    long_instruct = "Please speak calmly and clearly. " * 40  # informs coerce_instruct's bound
    print(f"   RECORD long-instruct probe length = {len(long_instruct)} chars")
    try:
        res_long = _render_seeded(model, _SHORT_TEXT, _DEFAULT_SEED, instruct=long_instruct)
        audio_long = _concat_audio(res_long)
        _audio_sanity("q4-instruct-long", audio_long, model.sample_rate)
        print(
            "   RECORD long instruct: generate() succeeded cleanly (no crash) -- informs "
            f"coerce_instruct's reject bound (proposed 500 chars; this probe used "
            f"{len(long_instruct)} chars and did not crash the model itself)"
        )
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(
            f"   RECORD long instruct raised {type(exc).__name__}: {exc} -- this length is "
            "unsafe at the model level, independent of the coerce_instruct reject bound."
        )

    if not ok:
        print(
            "   Q4 RECORD: one or more instruct cases raised unexpectedly -- investigate before Phase 1."
        )
        return "RECORD"
    print("   Q4 PASS: instruct absent/present both generate cleanly.")
    return "PASS"


# --- Q5: token budget / truncation ------------------------------------------------------


def q5_token_budget(model, out_dir: Path) -> str:
    print("=== Q5: token budget / truncation (max_tokens=1024 default is a per-BATCH ceiling) ===")
    print(
        f"   RECORD input length = {len(_Q5_LONG_PROSE)} chars "
        f"({len(_Q5_LONG_PROSE.encode('utf-8'))} bytes), no <|speaker:N|> tags"
    )
    results = _render_seeded(model, _Q5_LONG_PROSE, _DEFAULT_SEED)
    print(
        f"   RECORD batches={len(results)} (ordinary prose has no <|speaker:N|> tags -> always 1 batch)"
    )
    any_capped = False
    for i, r in enumerate(results):
        capped = r.token_count >= _DEFAULT_MAX_TOKENS
        any_capped = any_capped or capped
        print(
            f"   RECORD batch[{i}]: token_count={r.token_count} audio_duration={r.audio_duration} "
            f"at_or_over_default_max_tokens={capped}"
        )
    audio_full = _concat_audio(results)
    _audio_sanity("q5-full", audio_full, model.sample_rate)
    _write_wav(out_dir / "q5_long_prose.wav", audio_full, model.sample_rate)

    # Deliberately-forced small cap, to calibrate seconds-of-audio-per-token —
    # informs how conservative _MAX_TEXT_CHARS needs to be.
    results_capped = _render_seeded(model, _Q5_LONG_PROSE, _DEFAULT_SEED, max_tokens=64)
    audio_capped = _concat_audio(results_capped)
    dur_capped = audio_capped.shape[0] / model.sample_rate if model.sample_rate else float("nan")
    tokens_capped = sum(r.token_count for r in results_capped)
    print(
        f"   RECORD max_tokens=64 forced cap: batches={len(results_capped)} "
        f"audio_duration={dur_capped:.2f}s tokens={tokens_capped} "
        f"(~{dur_capped / tokens_capped:.4f}s/token, if tokens_capped>0)"
        if tokens_capped
        else f"   RECORD max_tokens=64 forced cap: batches={len(results_capped)} audio_duration={dur_capped:.2f}s"
    )
    _write_wav(out_dir / "q5_forced_cap.wav", audio_capped, model.sample_rate)

    if any_capped:
        print(
            "   Q5 RECORD: realistic long prose HIT the default max_tokens=1024 per-batch "
            "ceiling -- likely silent mid-utterance truncation (qwen3 CustomVoice precedent). "
            "Set _MAX_TEXT_CHARS conservatively and consider the truncation tripwire."
        )
    else:
        print(
            "   Q5 RECORD: realistic long prose did NOT hit the default max_tokens=1024 "
            "ceiling at this input length -- still set _MAX_TEXT_CHARS conservatively from "
            "the seconds-per-token estimate above; do not assume longer inputs stay safe. "
            "A _MAX_TEXT_CHARS derived from this ordinary-prose measurement is conservative "
            "(not exact) for tagged multi-batch input, which gets one 1024-token budget PER "
            "batch, a larger effective total."
        )
    return "RECORD"


# --- Q6: license + upstream model-card figures -------------------------------------------


def _fetch_license_and_card(repo_id: str) -> bool:
    try:
        from huggingface_hub import HfApi, hf_hub_download
    except Exception as exc:  # noqa: BLE001 -- optional dep; gate must record, not crash
        print(f"   RECORD [{repo_id}] license-unresolved (huggingface_hub unavailable: {exc})")
        return False

    found = False
    try:
        info = HfApi().model_info(repo_id)
        card = getattr(info, "card_data", None)
        license_tag = getattr(card, "license", None) if card is not None else None
        tags = [t for t in (getattr(info, "tags", None) or []) if t.startswith("license:")]
        print(f"   RECORD [{repo_id}] card_data.license = {license_tag!r}; license tags = {tags!r}")
        found = bool(license_tag or tags)
    except Exception as exc:  # noqa: BLE001 -- network call; gate must record, not crash
        print(f"   RECORD [{repo_id}] model_info failed ({type(exc).__name__}: {exc})")

    for filename in ("LICENSE", "LICENSE.txt", "LICENSE.md"):
        try:
            path = hf_hub_download(repo_id, filename)
        except Exception:  # noqa: BLE001, S112 -- best-effort: try the next candidate
            continue
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        head = "\n".join(text.splitlines()[:20])
        print(f"   RECORD [{repo_id}] {filename} (first 20 lines):\n{head}")
        found = True
        break
    else:
        print(f"   RECORD [{repo_id}] no LICENSE file in repo (checked LICENSE/.txt/.md)")

    try:
        readme_path = hf_hub_download(repo_id, "README.md")
        readme_text = Path(readme_path).read_text(encoding="utf-8", errors="replace")
        head = "\n".join(readme_text.splitlines()[:40])
        print(
            f"   RECORD [{repo_id}] README.md (first 40 lines — for model-card performance/"
            f"scale figures: training hours, language count, commercial-use contact):\n{head}"
        )
        found = True
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(f"   RECORD [{repo_id}] README.md fetch failed ({type(exc).__name__}: {exc})")

    return found


def q6_license_and_model_card(model_repo: str, source_repo: str) -> str:
    print(f"=== Q6: license + model-card figures for {model_repo!r} and {source_repo!r} ===")
    found_model = _fetch_license_and_card(model_repo)
    print()
    found_source = _fetch_license_and_card(source_repo)
    if not (found_model or found_source):
        print(
            "   Q6 RECORD: license-unresolved for both repos (network unavailable or no metadata)"
        )
        return "RECORD"
    print(
        "   Q6 RECORD: quote the above verbatim into ## Findings / README / tests/smoke/README.md "
        "-- never the plan's recalled-but-unverified Context bullet."
    )
    return "RECORD"


# --- extra: inline [tag] emotion markup accepted without erroring ------------------------


def extra_tag_markup_sanity(model, out_dir: Path) -> None:
    print("=== EXTRA: inline [tag] emotion markup accepted without erroring ===")
    text = "[whisper] This should be spoken very quietly. [laughing] That was quite funny!"
    try:
        results = _render_seeded(model, text, _DEFAULT_SEED)
        audio = _concat_audio(results)
        _audio_sanity("extra-tag-markup", audio, model.sample_rate)
        _write_wav(out_dir / "extra_tag_markup.wav", audio, model.sample_rate)
        print(
            "   RECORD [tag] markup: generate() accepted it without erroring (listen to confirm effect)"
        )
    except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
        print(f"   RECORD [tag] markup raised {type(exc).__name__}: {exc}")


# --- entrypoint ----------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Fish Audio S2 Pro Phase 0 verification gate (direct mlx-audio, no server)"
    )
    ap.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"HF model id for the mlx conversion (default {DEFAULT_MODEL})",
    )
    ap.add_argument(
        "--source-model",
        default=SOURCE_MODEL,
        help=f"HF model id for the assumed source repo, Q6 only (default {SOURCE_MODEL})",
    )
    ap.add_argument(
        "--out-dir",
        default=None,
        help=(
            "directory for the perceptual WAVs (default: a fresh secure mkdtemp dir, "
            "like run_smoke.sh; paths are printed for listening)"
        ),
    )
    ap.add_argument(
        "--seed",
        type=int,
        default=_DEFAULT_SEED,
        help=f"RNG seed for the seeded comparisons (default {_DEFAULT_SEED})",
    )
    ap.add_argument(
        "--only",
        nargs="+",
        choices=_QUESTIONS,
        default=None,
        help="run only these questions (e.g. --only q1 q6); default: all six",
    )
    args = ap.parse_args()
    selected = set(args.only or _QUESTIONS)

    if args.out_dir:
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
    else:
        out_dir = Path(tempfile.mkdtemp(prefix="fish-gate."))
    print(f"WAV output dir: {out_dir}")

    verdicts: dict[str, str] = {q: "SKIP" for q in _QUESTIONS}

    # Q6 needs no model — run it even if mlx is unavailable / the download fails.
    if "q6" in selected:
        verdicts["q6"] = q6_license_and_model_card(args.model, args.source_model)
        print()

    model_questions = selected - {"q6"}
    if model_questions:
        try:
            from mlx_audio.tts.utils import load
        except ImportError as exc:
            print(
                f"FATAL: mlx_audio not importable ({exc}). Run via an mlx extra, e.g.\n"
                "  uv run --extra dia python tests/smoke/fish_phase0_gate.py"
            )
            return 2

        # Matches Phase 1's production FishBackend.start(), which calls this
        # proactively as a worker-thread mx.compile/CompilerCache crash-class
        # guard (qwen3 precedent) — keeps this gate's timing/determinism
        # measurements representative of production execution mode.
        try:
            import mlx.core as mx

            mx.disable_compile()
            print("mx.disable_compile() called (matches Phase 1 production mode)")
        except Exception as exc:  # noqa: BLE001 -- gate must record, not crash
            print(
                f"WARNING: mx.disable_compile() failed ({type(exc).__name__}: {exc}) -- continuing anyway"
            )

        print(f"loading {args.model!r} (downloads on first run; this is slow)...")
        model = load(args.model, lazy=False, strict=True)
        print(f"model loaded: {type(model).__name__}")
        print()

        if "q3" in selected:
            verdicts["q3"] = q3_rate_voice_language(model)
            print()
        if "q1" in selected:
            verdicts["q1"] = q1_cross_batch_coupling(model, out_dir, args.seed)
            print()
        if "q2" in selected:
            verdicts["q2"] = q2_latency_memory(model, out_dir)
            print()
        if "q4" in selected:
            verdicts["q4"] = q4_instruct(model, out_dir)
            print()
        if "q5" in selected:
            verdicts["q5"] = q5_token_budget(model, out_dir)
            print()

        extra_tag_markup_sanity(model, out_dir)
        print()

    summary = " ".join(f"{q.upper()}={verdicts[q]}" for q in _QUESTIONS)
    print(f"GATE-SUMMARY {summary}")
    failed = [q for q, v in verdicts.items() if v == "FAIL"]
    if failed:
        print(f"fish phase0 gate: FAILED ({', '.join(q.upper() for q in failed)}) — re-plan")
        return 1
    print("fish phase0 gate: PASS (RECORD items go into the plan's ## Findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
