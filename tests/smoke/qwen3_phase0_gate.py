#!/usr/bin/env python3
"""Qwen3-TTS Phase 0 verification gate (dia precedent — run BEFORE any backend code).

Standalone script: direct mlx-audio usage (``mlx_audio.tts.utils.load``), no
tts_server involvement. Downloads the model once and answers the six gate
questions from the plan (``docs/dev_plans/20260703-feature-tts-qwen3-backend.md``),
printing a clearly-labeled PASS/FAIL/RECORD line per question plus a
machine-greppable final summary (``GATE-SUMMARY ...`` / ``qwen3 phase0 gate: ...``).

  Q1 — incremental streaming: does ``generate(stream=True, streaming_interval=0.4)``
       yield >=2 chunks with real wall-clock gaps between yields (genuinely
       incremental, not batched-at-end)? Records chunk count and each yield's
       ``is_streaming_chunk`` / ``is_final_chunk`` attributes as present.
  Q2 — latency + memory: TTFB and full-utterance RTF for a short and a ~15 s
       utterance at ``streaming_interval`` 0.4 and 2.0; peak memory via
       ``mx.get_peak_memory()`` and ``GenerationResult.peak_memory_usage`` (the
       Phase-3 profiler cannot see it — the bridge strips everything but PCM).
  Q3 — speakers + languages + rate: ``model.get_supported_speakers()`` VERBATIM
       (exact case — the server validates voices case-exactly while ``generate()``
       lowercases its lookup), ``model.get_supported_languages()`` if present, and
       ``model.sample_rate`` actually reported.
  Q4 — ``voice=None``: the no-speaker path (base models are speaker-UNconditioned,
       no default, per ``qwen3_tts.py:381-389``). Writes a WAV to listen to; does
       not crash on error — records it. Feeds the Phase-1 inject-default-vs-
       unconditioned decision.
  Q5 — cross-segment state: seeded A/B/C comparison (dia gate method, see
       ``tests/smoke/dia_dialogue_smoke.py``): A = two-line ``\\n`` input;
       B = identical repeat (determinism control, greedy temperature=0.0);
       C = same with line 1 edited. Compares segment-2 audio A vs C. Also checks
       two separate ``generate()`` calls are independent (X alone vs X after a
       prior call, re-seeded).
  Q6 — license: fetch the HF repo license (card metadata + LICENSE/README file)
       via ``huggingface_hub`` with a network guard; prints what is found or
       ``RECORD: license-unresolved`` when offline.

Every generated WAV also gets an audio-sanity record: NaN count, max abs value,
duration. WAVs land in a fresh secure ``mkdtemp`` dir by default (mirrors
run_smoke.sh / the dia smoke driver); paths are printed for perceptual listening.

GATE semantics (from the plan): Q1 FAIL -> re-shape as a segment-level
``streaming:false`` backend (re-plan). Q5 cross-CALL state -> dia-precedent
re-plan. Q3/Q4 surprises -> update Phase 1 defaults. Findings land in the plan's
``## Findings``.

Usage (the ``dia`` extra supplies mlx-audio 0.4.4; the qwen3_tts extra does not
exist until Phase 2 — a bare ``uv run`` re-syncs to lean base and strips mlx):

  uv run --extra dia python tests/smoke/qwen3_phase0_gate.py
  uv run --extra dia python tests/smoke/qwen3_phase0_gate.py --only q1 q3
  uv run --extra dia python tests/smoke/qwen3_phase0_gate.py --out-dir /tmp/qwen3-gate
"""

from __future__ import annotations

import argparse
import sys
import tempfile
import time
import wave
from pathlib import Path

DEFAULT_MODEL = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16"
_DEFAULT_SEED = 42
_GREEDY_TEMPERATURE = 0.0

# Sentinel for chunk attributes that may be absent (streaming yields set
# is_streaming_chunk=True; only the terminal yield sets is_final_chunk).
_ABSENT = object()

_SHORT_TEXT = "The quick brown fox jumps over the lazy dog."
# ~15 s of speech at a normal rate (~2.5 words/s -> ~38 words).
_LONG_TEXT = (
    "Streaming text to speech is most useful when the first audio arrives quickly, "
    "because a listener starts judging responsiveness long before the sentence ends. "
    "This longer utterance exists purely to measure sustained generation throughput "
    "on this machine."
)

# Q5 payloads: two-line \n-separated input (generate() splits on \n by default).
_Q5_LINE1_A = "We were talking about the weather earlier today."
_Q5_LINE1_C = "The committee reviewed the quarterly budget figures in detail."
_Q5_LINE2 = "Anyway, let us get back to the main topic of the discussion."
# Cross-call independence payloads (dia greedy-guard method).
_Q5_TEXT_PRIOR = "This sentence exists only to advance the model before the probe."
_Q5_TEXT_X = "Yes, where were we before that interruption happened?"

_QUESTIONS = ("q1", "q2", "q3", "q4", "q5", "q6")


# --- small helpers ----------------------------------------------------------------


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


def _pick_speaker(speakers: list[str]) -> str | None:
    """Pick an English-looking speaker for the timed runs (exact-case string from
    the model's own list). Family README names English speakers, but names are
    only known at runtime — prefer a known-English candidate, else the first."""
    english_candidates = {"ryan", "aiden", "chelsie", "ethan", "serena", "eric", "emily"}
    for s in speakers:
        if s.lower() in english_candidates:
            return s
    return speakers[0] if speakers else None


def _reset_peak_memory() -> None:
    import mlx.core as mx

    reset = getattr(mx, "reset_peak_memory", None)
    if callable(reset):
        reset()


# --- Q1: incremental streaming ------------------------------------------------------


def q1_incremental_streaming(model, speaker: str | None, out_dir: Path) -> str:
    print("=== Q1: incremental streaming (stream=True, streaming_interval=0.4) ===")
    kwargs = {"stream": True, "streaming_interval": 0.4}
    if speaker is not None:
        kwargs["voice"] = speaker

    t0 = time.monotonic()
    yield_times: list[float] = []
    results = []
    for res in model.generate(_SHORT_TEXT, **kwargs):
        yield_times.append(time.monotonic() - t0)
        results.append(res)
    total_wall = time.monotonic() - t0

    print(f"   RECORD chunk_count={len(results)} total_wall={total_wall:.2f}s")
    for i, (res, t) in enumerate(zip(results, yield_times)):
        gap = yield_times[i] - yield_times[i - 1] if i else yield_times[0]
        is_streaming = getattr(res, "is_streaming_chunk", _ABSENT)
        is_final = getattr(res, "is_final_chunk", _ABSENT)
        streaming_s = "<absent>" if is_streaming is _ABSENT else repr(is_streaming)
        final_s = "<absent>" if is_final is _ABSENT else repr(is_final)
        n = getattr(res, "samples", None)
        print(
            f"   RECORD chunk[{i}]: t={t:.2f}s gap={gap:.2f}s samples={n} "
            f"is_streaming_chunk={streaming_s} is_final_chunk={final_s}"
        )

    audio_np = _concat_audio(results)
    _audio_sanity("q1", audio_np, model.sample_rate)
    _write_wav(out_dir / "q1_streaming_short.wav", audio_np, model.sample_rate)

    if len(results) < 2:
        print(f"   Q1 FAIL: only {len(results)} chunk(s) — not incremental. Re-plan (kokoro-like).")
        return "FAIL"
    # Genuinely incremental means yields are spread across the wall time, not
    # batched at the end: the first->last yield span must be a real fraction of
    # the total wall clock.
    span = yield_times[-1] - yield_times[0]
    if span < 0.2 * total_wall:
        print(
            f"   Q1 FAIL: yield span {span:.2f}s is <20% of wall {total_wall:.2f}s — "
            "chunks look batched-at-end, not incremental."
        )
        return "FAIL"
    print(f"   Q1 PASS: {len(results)} chunks, yield span {span:.2f}s of {total_wall:.2f}s wall")
    return "PASS"


# --- Q2: latency + memory -----------------------------------------------------------


def q2_latency_memory(model, speaker: str | None, out_dir: Path) -> str:
    import mlx.core as mx

    print("=== Q2: TTFB / RTF / peak memory (short + ~15s, intervals 0.4 and 2.0) ===")
    rate = model.sample_rate
    for label, text in (("short", _SHORT_TEXT), ("long", _LONG_TEXT)):
        for interval in (0.4, 2.0):
            _reset_peak_memory()
            kwargs = {"stream": True, "streaming_interval": interval}
            if speaker is not None:
                kwargs["voice"] = speaker
            t0 = time.monotonic()
            ttfb = float("nan")
            results = []
            for res in model.generate(text, **kwargs):
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
                f"   RECORD [{label} interval={interval}]: ttfb={ttfb:.2f}s wall={wall:.2f}s "
                f"audio={audio_s:.2f}s rtf={rtf:.2f} chunks={len(results)} "
                f"peak_mem(mx)={peak_mx_gb:.2f}GB peak_mem(result)={peak_result_gb:.2f}GB"
            )
            _audio_sanity(f"q2-{label}-{interval}", audio_np, rate)
            if label == "long" and interval == 0.4:
                _write_wav(out_dir / "q2_long_interval04.wav", audio_np, rate)
    print("   Q2 RECORD: measurement question — numbers above go into ## Findings")
    return "RECORD"


# --- Q3: speakers + languages + sample rate -------------------------------------------


def q3_speakers_languages_rate(model) -> str:
    print("=== Q3: speakers (VERBATIM, exact case) + languages + sample rate ===")
    speakers = model.get_supported_speakers()
    print(f"   RECORD get_supported_speakers() = {speakers!r}")
    if hasattr(model, "get_supported_languages"):
        print(f"   RECORD get_supported_languages() = {model.get_supported_languages()!r}")
    else:
        print("   RECORD get_supported_languages: <method absent>")
    print(f"   RECORD model.sample_rate = {model.sample_rate!r}")
    if not speakers:
        print(
            "   Q3 FAIL: empty speaker list (config.talker_config.spk_id empty?) — "
            "the Phase-1 dynamic voices() plan needs the static-fallback path."
        )
        return "FAIL"
    print(f"   Q3 PASS: {len(speakers)} speakers reported (verify English ones by ear via Q4 WAVs)")
    return "PASS"


# --- Q4: voice=None (speaker-unconditioned path) --------------------------------------


def q4_voice_none(model, out_dir: Path) -> str:
    print("=== Q4: no-voice kwarg (speaker-unconditioned base path) ===")
    try:
        results = _drain(model.generate(_SHORT_TEXT, stream=False))
    except Exception as exc:  # noqa: BLE001 -- deliberate: gate must record, not crash
        print(f"   Q4 RECORD: generate() without voice raised {type(exc).__name__}: {exc}")
        print("   Q4 RECORD: no-voice path ERRORS — Phase 1 must inject a default speaker.")
        return "RECORD"
    audio_np = _concat_audio(results)
    _audio_sanity("q4-unconditioned", audio_np, model.sample_rate)
    _write_wav(out_dir / "q4_voice_none.wav", audio_np, model.sample_rate)
    print(
        "   Q4 RECORD: no-voice generate() succeeded (speaker-unconditioned). LISTEN "
        "to the WAV and decide: inject a discovered default speaker vs accept this."
    )
    return "RECORD"


# --- Q5: cross-segment + cross-call state ----------------------------------------------


def _render_seeded(model, text: str, seed: int, speaker: str | None = None) -> list:
    """Seed mlx's RNG then render greedily (temperature=0.0) — the dia gate's
    determinism recipe. Non-stream: one GenerationResult per \\n segment.
    ``speaker`` is required for custom_voice models (generate() raises without it)."""
    import mlx.core as mx

    mx.random.seed(seed)
    kwargs = {} if speaker is None else {"voice": speaker}
    return _drain(model.generate(text, stream=False, temperature=_GREEDY_TEMPERATURE, **kwargs))


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


def q5_cross_segment_state(model, seed: int, speaker: str | None = None) -> str:
    print("=== Q5: cross-segment state (seeded A/B/C, dia gate method) ===")
    text_a = f"{_Q5_LINE1_A}\n{_Q5_LINE2}"
    text_c = f"{_Q5_LINE1_C}\n{_Q5_LINE2}"

    res_a = _render_seeded(model, text_a, seed, speaker)
    res_b = _render_seeded(model, text_a, seed, speaker)  # determinism control
    res_c = _render_seeded(model, text_c, seed, speaker)
    print(f"   RECORD segments: A={len(res_a)} B={len(res_b)} C={len(res_c)}")

    if len(res_a) < 2 or len(res_c) < 2:
        # custom_voice models render the whole text as ONE segment —
        # generate_custom_voice() has no split_pattern (qwen3_tts.py:2074-2088),
        # unlike the base path which splits on \n (:1269-1270). With no segments
        # there is no within-commit coupling question; only cross-call
        # independence below still gates.
        print(
            "   RECORD within-commit: single segment per render "
            f"(A={len(res_a)}, C={len(res_c)}) — no \\n split in this model's "
            "generate path; within-commit coupling N/A."
        )
    else:
        # Determinism control: identical seeded repeats must match, else the
        # segment-2 comparison below is meaningless.
        a2, b2 = _to_numpy(res_a[1].audio), _to_numpy(res_b[1].audio)
        if not _array_equal(a2, b2):
            print(
                "   Q5 RECORD: determinism control FAILED (A vs B segment-2 differ, "
                f"max_abs_diff={_max_abs_diff(a2, b2):.6f}) — seeded greedy decoding is "
                "not reproducible here; A/C comparison inconclusive. Investigate."
            )
            return "RECORD"
        print("   RECORD determinism control: A == B segment-2 (byte-identical) OK")

        # The core question: does editing line 1 change line 2's audio?
        c2 = _to_numpy(res_c[1].audio)
        seg2_equal = _array_equal(a2, c2)
        print(
            f"   RECORD segment-2 A vs C: equal={seg2_equal} "
            f"shapes={a2.shape}/{c2.shape} max_abs_diff={_max_abs_diff(a2, c2):.6f}"
        )
        if seg2_equal:
            print("   RECORD within-commit: segments are INDEPENDENT (no dia-style coupling)")
        else:
            print(
                "   RECORD within-commit: segment 2 IS affected by segment 1 "
                "(dia-style autoregressive coupling) — feed into Phase 1 design."
            )

    # Cross-CALL independence (the hard-gate part): X alone vs X after a prior
    # call on the same model object, re-seeded before each X render.

    x_alone = _render_seeded(model, _Q5_TEXT_X, seed, speaker)
    _render_seeded(model, _Q5_TEXT_PRIOR, seed, speaker)
    x_after = _render_seeded(model, _Q5_TEXT_X, seed, speaker)
    xa, xf = _concat_audio(x_alone), _concat_audio(x_after)
    cross_call_equal = _array_equal(xa, xf)
    print(
        f"   RECORD cross-call X_alone vs X_after: equal={cross_call_equal} "
        f"shapes={xa.shape}/{xf.shape} max_abs_diff={_max_abs_diff(xa, xf):.6f}"
    )
    if not cross_call_equal:
        print(
            "   Q5 FAIL: cross-CALL state detected — two separate generate() calls "
            "are NOT independent. Dia-precedent re-plan required."
        )
        return "FAIL"
    print(
        "   Q5 PASS: generate() calls are independent (cross-call stateless); "
        "within-commit coupling recorded above."
    )
    return "PASS"


# --- Q6: license ---------------------------------------------------------------------


def q6_license(repo_id: str) -> str:
    print(f"=== Q6: license for {repo_id} ===")
    try:
        from huggingface_hub import HfApi, hf_hub_download
    except Exception as exc:  # noqa: BLE001 -- optional dep; gate must record, not crash
        print(f"   Q6 RECORD: license-unresolved (huggingface_hub unavailable: {exc})")
        return "RECORD"

    found = False
    try:
        info = HfApi().model_info(repo_id)
        card = getattr(info, "card_data", None)
        license_tag = getattr(card, "license", None) if card is not None else None
        tags = [t for t in (getattr(info, "tags", None) or []) if t.startswith("license:")]
        print(f"   RECORD card_data.license = {license_tag!r}; license tags = {tags!r}")
        found = bool(license_tag or tags)
    except Exception as exc:  # noqa: BLE001 -- network call; gate must record, not crash
        print(f"   RECORD model_info failed ({type(exc).__name__}: {exc})")

    for filename in ("LICENSE", "LICENSE.txt", "LICENSE.md"):
        try:
            path = hf_hub_download(repo_id, filename)
        except Exception:  # noqa: BLE001, S112
            # Best-effort: try the next candidate filename on any failure
            # (404, network error, ...).
            continue
        text = Path(path).read_text(encoding="utf-8", errors="replace")
        head = "\n".join(text.splitlines()[:12])
        print(f"   RECORD {filename} (first 12 lines):\n{head}")
        found = True
        break
    else:
        print("   RECORD no LICENSE file in repo (checked LICENSE/.txt/.md)")

    if not found:
        print("   Q6 RECORD: license-unresolved (network unavailable or no license metadata)")
        return "RECORD"
    print("   Q6 RECORD: quote the above verbatim into ## Findings / the smoke README note")
    return "RECORD"


# --- entrypoint ------------------------------------------------------------------------


def main() -> int:
    ap = argparse.ArgumentParser(
        description="Qwen3-TTS Phase 0 verification gate (direct mlx-audio, no server)"
    )
    ap.add_argument(
        "--model",
        default=DEFAULT_MODEL,
        help=f"HF model id (default {DEFAULT_MODEL})",
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
        help=f"RNG seed for the Q5 seeded comparisons (default {_DEFAULT_SEED})",
    )
    ap.add_argument(
        "--only",
        nargs="+",
        choices=_QUESTIONS,
        default=None,
        help="run only these questions (e.g. --only q1 q3); default: all six",
    )
    args = ap.parse_args()
    selected = set(args.only or _QUESTIONS)

    if args.out_dir:
        out_dir = Path(args.out_dir)
        out_dir.mkdir(parents=True, exist_ok=True)
    else:
        out_dir = Path(tempfile.mkdtemp(prefix="qwen3-gate."))
    print(f"WAV output dir: {out_dir}")

    verdicts: dict[str, str] = {q: "SKIP" for q in _QUESTIONS}

    # Q6 needs no model — run it even if mlx is unavailable / the download fails.
    if "q6" in selected:
        verdicts["q6"] = q6_license(args.model)
        print()

    model_questions = selected - {"q6"}
    if model_questions:
        try:
            from mlx_audio.tts.utils import load
        except ImportError as exc:
            print(
                f"FATAL: mlx_audio not importable ({exc}). Run via an mlx extra, e.g.\n"
                "  uv run --extra dia python tests/smoke/qwen3_phase0_gate.py"
            )
            return 2

        print(f"loading {args.model!r} (downloads on first run; this is slow)...")
        model = load(args.model, lazy=False, strict=True)
        print(f"model loaded: {type(model).__name__}")
        print()

        if "q3" in selected:
            verdicts["q3"] = q3_speakers_languages_rate(model)
            print()
        speaker = _pick_speaker(model.get_supported_speakers() or [])
        print(f"timed runs use speaker={speaker!r} (exact-case string from the model)")
        print()

        if "q1" in selected:
            verdicts["q1"] = q1_incremental_streaming(model, speaker, out_dir)
            print()
        if "q2" in selected:
            verdicts["q2"] = q2_latency_memory(model, speaker, out_dir)
            print()
        if "q4" in selected:
            verdicts["q4"] = q4_voice_none(model, out_dir)
            print()
        if "q5" in selected:
            verdicts["q5"] = q5_cross_segment_state(model, args.seed, speaker)
            print()

    summary = " ".join(f"{q.upper()}={verdicts[q]}" for q in _QUESTIONS)
    print(f"GATE-SUMMARY {summary}")
    failed = [q for q, v in verdicts.items() if v == "FAIL"]
    if failed:
        print(f"qwen3 phase0 gate: FAILED ({', '.join(q.upper() for q in failed)}) — re-plan")
        return 1
    print("qwen3 phase0 gate: PASS (RECORD items go into the plan's ## Findings)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
