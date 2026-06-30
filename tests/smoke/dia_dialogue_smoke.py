#!/usr/bin/env python3
"""Dia dialogue smoke driver (Phase 3 — manual, mlx-gated, **listen-and-judge**).

This is NOT a CI assertion. The pytest suite mocks the model and a WAV-only smoke
only proves "non-empty audio"; neither proves dia's *dialogue* behaviour — two
distinct speakers, natural turn-taking, an interruption that resumes coherently.
Those are perceptual and cannot be cheaply auto-verified, so this driver writes
one WAV per crafted script and prints its path for a human to listen and judge.

It mirrors ``tests/smoke/latency_smoke.py`` + ``examples/reference_client.py``:
connect a real ``TTSClient`` to a real dia server, append+commit a tagged-text
dialogue, reassemble the pcm16 deltas, and write a mono WAV at the
server-advertised ``hello.audio.rate``. Speakers are addressed purely in-text via
``[S1]``/``[S2]`` tags inside an ordinary ``plain`` payload (decision #1/#2) — the
server forwards the buffer untouched; dia interprets the tags itself.

Two parts, both manual / local-only:

1. **Perceptual scripts (live server).** Three scripts from the committed fixtures
   in ``tests/smoke/fixtures/dia/``:
     (1) turn-taking (``podcast_turntaking.txt``; contains a one-word S2
         backchannel "Mm-hmm" inside an S1 turn — script 3 of the plan folds into
         this one);
     (2a) interruption+resumption, inline layout (no ``\n``);
     (2b) interruption+resumption, newline layout (same dialogue).
   Per redesigned decision #3, BOTH interruption layouts ride in ONE commit
   each — the comparison is in-context continuity *inline vs ``\n``-separated*,
   NOT segment independence. Listen to (2a) vs (2b) back-to-back; record the
   prosodic-continuity result in the plan's Findings after the first dia run.
   Structural asserts (cheap, non-perceptual) per script: non-empty audio; a
   per-script sample-count sanity bound (finite, roughly proportional to text
   length). These ride over the wire (pcm bytes), so the ``ndim == 1`` mono-shape
   assert is done separately against the backend in part 2 (a per-fixture-script
   mono-shape guard, mlx-gated) — satisfying the acceptance criterion that each
   script's first item asserts ``audio.ndim == 1``.

2. **mlx-gated statelessness checks (no server; direct model).** decision #3 rests
   on dia being STATELESS across ``generate()`` calls (= across commits). These
   guard that load-bearing finding so a future ``mlx-audio`` bump that silently
   reintroduces cross-call coupling is caught:
     - **Greedy regression guard** — fixed ``seed`` + ``temperature=0.0`` (greedy
       decoding is deterministic), assert ``X_alone == X_after`` as ARRAY equality
       where ``X_alone`` renders ``textX`` with no prior call and ``X_after``
       renders ``textPRIOR`` then ``textX`` on the SAME model object. This pins the
       Phase 0 byte-identity finding.
     - **Production-temperature coupling diagnostic** — the greedy guard only
       covers ``temperature=0.0``; production runs ``1.3`` (non-deterministic), so
       byte-equality cannot apply (decision #3 names this residual assumption).
       Render ``textX`` alone vs after ``textPRIOR`` across N seeds at
       ``temperature=1.3`` and compare the sample-count (duration) DISTRIBUTION of
       the two render sets. A statistically indistinguishable distribution
       *supports* cross-call statelessness; a shifted one *falsifies* it and
       re-opens decision #3. This is a DIAGNOSTIC (print + soft-flag), NOT a hard
       byte-assert.
     - **Per-script mono-shape guard** — the ``item.audio.ndim == 1`` assert (the
       bridge contract is a single-run Phase 0 snapshot, and ``_audio_to_pcm``
       duck-types via ``.tolist()`` so a stereo drift would not hard-fail loudly)
       runs against the model on the first item of EACH fixture script — loudly.

The statelessness invariant has **zero CI protection by design** (named accepted
risk in the plan): the whole module is import-safe WITHOUT ``mlx_audio`` (the
mlx-gated parts are guarded behind a runtime availability check), and the
perceptual scripts need a live server. Run it manually on Apple Silicon with the
``dia`` extra installed.

Usage:
  # perceptual scripts only (live dia server) — writes 3 WAVs
  uv run python tests/smoke/dia_dialogue_smoke.py --socket-path /tmp/tts.sock

  # also run the mlx-gated statelessness checks (loads the model locally)
  uv run python tests/smoke/dia_dialogue_smoke.py --socket-path /tmp/tts.sock \
      --check-statelessness --seed 42

  # ONLY the mlx-gated checks (no live server needed)
  uv run python tests/smoke/dia_dialogue_smoke.py --statelessness-only --seed 42

Endpoint precedence mirrors the protocol: --uri > --socket-path > --host/--port.
Exit code 0 only if every structural assert holds and the greedy guard passes
(the production-temp diagnostic only soft-flags — it never fails the run).
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import statistics
import sys
import wave
from pathlib import Path

from tts_server.backends.dia import DEFAULT_DIA_MODEL
from tts_server.client import TTSClient

# --- fixtures -------------------------------------------------------------------
# The committed dialogue scripts. See tests/smoke/fixtures/dia/README.md.
_FIXTURE_DIR = Path(__file__).resolve().parent / "fixtures" / "dia"

# (label, fixture filename). Script 1 = turn-taking (the "Mm-hmm" backchannel and
# the "(laughs)" nonverbal — plan script 3 — ride inside this fixture). Scripts
# 2a/2b = the interruption+resumption continuity comparison (inline vs newline),
# both committed in ONE commit each (decision #3).
_SCRIPTS = [
    ("turntaking", "podcast_turntaking.txt"),
    ("interruption_inline", "interview_interruption_inline.txt"),
    ("interruption_newline", "interview_interruption_newline.txt"),
]

# --- statelessness-check payloads (decision #3 greedy guard + diagnostic) -------
# Two short tagged-text dialogues. The guard renders ``textX`` alone vs after
# ``textPRIOR`` on the same model object; if dia were stateful across calls,
# ``textX``'s output would differ. Kept short so the local check is quick.
_TEXT_PRIOR = (
    "[S1] We were talking about the weather earlier. [S2] Right, it was raining all morning."
)
_TEXT_X = "[S1] Anyway, let us get back to the main topic. [S2] Yes, where were we?"

# The Phase 0 control run that established cross-commit byte-identity was "seeded"
# but did NOT pin an exact numeric value in the plan's ## Findings. So the seed is
# a CLI arg / module constant the HUMAN sets to whatever value the Phase 0 control
# run used. ANY fixed seed makes greedy decoding deterministic, so the guard's
# X_alone == X_after equality holds for any value; pin it to the Phase 0 seed for
# a true regression check against that exact recorded run.
_DEFAULT_SEED = 42

# Production default temperature (dia's generate() default; see Phase 0 signature).
_PROD_TEMPERATURE = 1.3
# Greedy temperature for the deterministic guard.
_GREEDY_TEMPERATURE = 0.0
# Number of seeds for the production-temp distribution diagnostic.
_DEFAULT_DIAG_SEEDS = 8


def _load_script(filename: str) -> str:
    """Read a fixture, stripping a trailing newline (the commit buffer is fed
    verbatim; a stray trailing ``\\n`` would add an empty trailing segment)."""
    return (_FIXTURE_DIR / filename).read_text(encoding="utf-8").rstrip("\n")


# --- perceptual scripts over the live server ------------------------------------


def _make_client(args: argparse.Namespace) -> TTSClient:
    if args.uri:
        return TTSClient(uri=args.uri, auth_token=args.token)
    if args.socket_path:
        return TTSClient(socket_path=args.socket_path, auth_token=args.token)
    return TTSClient(host=args.host, port=args.port, auth_token=args.token)


async def _synthesize(client: TTSClient, text: str, timeout: float) -> bytes:
    """One round-trip on an already-connected client: append the tagged dialogue,
    commit (NO voice — dia is voice_count:0, it ignores any supplied voice), and
    reassemble the pcm16 deltas in ``seq`` order."""
    await client.append(text)
    await client.commit()
    frames: dict[int, bytes] = {}
    expected = 0
    async with asyncio.timeout(timeout):
        async for ev in client.events():
            t = ev.get("type")
            if t == "response.audio.delta":
                seq = ev["seq"]
                if seq != expected:
                    raise RuntimeError(f"seq gap: expected {expected}, got {seq}")
                frames[seq] = base64.b64decode(ev["audio"])
                expected += 1
            elif t == "response.audio.done":
                break
            elif t in ("error", "response.failed"):
                raise RuntimeError(f"server returned {t}: {ev}")
    return b"".join(frames[i] for i in range(expected))


def _write_wav(path: Path, pcm: bytes, rate: int) -> None:
    with wave.open(str(path), "wb") as w:
        w.setnchannels(1)  # mono (the bridge emits mono int16; see ndim assert)
        w.setsampwidth(2)  # pcm16
        w.setframerate(rate)
        w.writeframes(pcm)


async def _run_perceptual(args: argparse.Namespace) -> int:
    """Connect to the live dia server, render each script, write one WAV each, and
    apply the cheap structural asserts. Perceptual judgement is the human's."""
    out_dir = Path(args.out_dir)
    out_dir.mkdir(parents=True, exist_ok=True)

    rc = 0
    written: list[Path] = []
    for label, filename in _SCRIPTS:
        text = _load_script(filename)
        # A fresh connection per script keeps each commit a clean, independent
        # coherence unit (decision #3: state does not cross commits) and dodges
        # the K=1 in-flight cap (a second commit on the same connection before the
        # prior response is terminal returns BUSY).
        client = _make_client(args)
        hello = await client.connect()
        rate = int(hello.get("audio", {}).get("rate", 0))
        caps = hello.get("capabilities", {})
        backend = hello.get("backend")
        print(
            f"[{label}] connected: backend={backend} rate={rate} "
            f"streaming={caps.get('streaming')} voice_count={caps.get('voice_count')}"
        )
        if backend != "dia":
            print(
                f"[{label}] WARN: connected backend is {backend!r}, not 'dia' — the "
                "[S1]/[S2] tags will likely be read aloud literally"
            )
        try:
            pcm = await _synthesize(client, text, args.timeout)
        finally:
            await client.close()

        samples = len(pcm) // 2  # int16 mono
        out_path = out_dir / f"dia_{label}.wav"
        _write_wav(out_path, pcm, rate or 44100)
        written.append(out_path)
        approx_s = samples / rate if rate else float("nan")
        print(
            f"[{label}] wrote {out_path} — {samples} samples "
            f"(~{approx_s:.1f}s @ {rate}Hz), {len(text)} chars of text"
        )

        # --- structural asserts (cheap, non-perceptual) ---
        # 1. non-empty audio.
        if samples == 0:
            print(f"[{label}] FAIL: empty audio")
            rc = 1
        # 2. per-script sample-count sanity bound: finite, and roughly proportional
        #    to text length. dia @ 44100 Hz speaks well under ~25 chars/sec even
        #    slow, and well over ~2 chars/sec even fast; these are loose finite
        #    bounds (NOT a perceptual check) to catch a runaway/empty render.
        if rate:
            lo = (len(text) / 25.0) * rate * 0.2  # generous lower bound
            hi = (len(text) / 2.0) * rate * 5.0  # generous upper bound
            if not (lo <= samples <= hi):
                print(
                    f"[{label}] FAIL: sample count {samples} outside sane bound "
                    f"[{lo:.0f}, {hi:.0f}] for {len(text)} chars"
                )
                rc = 1

    print()
    print("=== WAVs written — LISTEN AND JUDGE (no automated perceptual check) ===")
    for p in written:
        print(f"  {p}")
    print(
        "Judge: (turntaking) speaker identity stays consistent across turns, S1 != "
        "S2, the 'Mm-hmm' backchannel + '(laughs)' land naturally; "
        "(interruption_inline vs interruption_newline) does S1 resume the SAME "
        "sentence with continuous prosody after S2 cuts in? Compare the two layouts "
        "back-to-back and RECORD the (a)-vs-(b) continuity result in the plan's "
        "Findings."
    )
    return rc


# --- mlx-gated statelessness checks (no server) ---------------------------------


def _mlx_available() -> bool:
    """True iff the ``dia`` extra (mlx-audio + mlx) is importable. Kept behind a
    runtime check so this module imports cleanly on the lean base / in CI
    import-scans without ``mlx_audio``."""
    import importlib.util

    return (
        importlib.util.find_spec("mlx_audio") is not None
        and importlib.util.find_spec("mlx") is not None
    )


def _render_seeded(model, text: str, *, seed: int, temperature: float) -> tuple[object, int]:
    """Seed mlx's RNG then render — so a fixed seed + ``temperature=0.0`` gives
    deterministic (greedy) output for the byte-identity guard."""
    import mlx.core as mx  # type: ignore

    mx.random.seed(seed)
    return _render_samples_with_temp(model, text, temperature=temperature)


def _render_samples_with_temp(model, text: str, *, temperature: float) -> tuple[object, int]:
    first_audio = None
    total = 0
    for item in model.generate(text, temperature=temperature):
        audio = getattr(item, "audio", item)
        if first_audio is None:
            first_audio = audio
            ndim = getattr(audio, "ndim", None)
            assert ndim == 1, (
                f"dia bridge contract broken: first item audio.ndim == {ndim!r}, expected 1 (mono)."
            )
        total += int(getattr(audio, "shape", [len(audio)])[0])
    return first_audio, total


def _run_greedy_guard(model, seed: int) -> int:
    """Greedy regression guard (decision #3): with a fixed seed + temperature=0.0,
    rendering ``textX`` ALONE must be byte-identical to rendering ``textX`` AFTER
    ``textPRIOR`` on the SAME model object. Re-runs the Phase 0 cross-commit
    byte-identity check. Returns 0 on pass, 1 on fail."""
    import mlx.core as mx  # type: ignore

    print("=== greedy statelessness guard (seed=%d, temperature=0.0) ===" % seed)

    # X_alone: render textX with no prior call.
    x_alone_audio, x_alone_n = _render_seeded(
        model, _TEXT_X, seed=seed, temperature=_GREEDY_TEMPERATURE
    )
    # X_after: render textPRIOR then textX on the SAME model object. Re-seed so the
    # RNG state entering the textX render matches the X_alone render — equality
    # then isolates *model* cross-call state from RNG drift.
    mx.random.seed(seed)
    list(model.generate(_TEXT_PRIOR, temperature=_GREEDY_TEMPERATURE))
    mx.random.seed(seed)
    x_after_audio, x_after_n = _render_samples_with_temp(
        model, _TEXT_X, temperature=_GREEDY_TEMPERATURE
    )

    print(f"   X_alone: {x_alone_n} samples; X_after: {x_after_n} samples")
    if x_alone_n != x_after_n:
        print(
            f"   FAIL: sample counts differ ({x_alone_n} != {x_after_n}) — dia is "
            "STATEFUL across calls under greedy decoding. decision #3 (incremental "
            "commits are safe) is FALSIFIED — re-open it."
        )
        return 1

    # Array equality (mx.array_equal, falling back to numpy / element compare).
    equal = _array_equal(x_alone_audio, x_after_audio)
    if equal:
        print("   PASS: X_alone == X_after (byte-identical) — stateless across calls (greedy)")
        return 0
    print(
        "   FAIL: same sample count but arrays differ — dia carries cross-call "
        "state under greedy decoding. decision #3 FALSIFIED — re-open it."
    )
    return 1


def _array_equal(a: object, b: object) -> bool:
    """Array equality for mlx / numpy arrays (the X_alone == X_after guard)."""
    try:
        import mlx.core as mx  # type: ignore

        if isinstance(a, mx.array) and isinstance(b, mx.array):
            return bool(mx.array_equal(a, b))
    except Exception:
        pass
    try:
        import numpy as np  # type: ignore

        return bool(np.array_equal(np.asarray(a), np.asarray(b)))
    except Exception:
        pass
    return list(a) == list(b)  # type: ignore[arg-type]


def _run_prod_temp_diagnostic(model, seeds: int) -> None:
    """Production-temperature coupling DIAGNOSTIC (decision #3 named residual
    assumption). The greedy guard only covers temperature=0.0; production runs
    1.3 (non-deterministic), so byte-equality cannot apply. Render ``textX`` alone
    vs after ``textPRIOR`` across N seeds at temperature=1.3 and compare the
    sample-count (duration) DISTRIBUTION of the two render sets. Indistinguishable
    distributions *support* cross-call statelessness at production temp; a shifted
    one *falsifies* it and re-opens decision #3.

    DIAGNOSTIC ONLY — prints + soft-flags, never fails the run (production-temp
    output is non-deterministic, so byte-equality is impossible by construction).
    """
    import mlx.core as mx  # type: ignore

    print(
        "=== production-temperature coupling diagnostic "
        f"(N={seeds} seeds, temperature={_PROD_TEMPERATURE}) ==="
    )
    alone_counts: list[int] = []
    after_counts: list[int] = []
    for s in range(seeds):
        mx.random.seed(s)
        _, n_alone = _render_samples_with_temp(model, _TEXT_X, temperature=_PROD_TEMPERATURE)
        alone_counts.append(n_alone)

        mx.random.seed(s)
        list(model.generate(_TEXT_PRIOR, temperature=_PROD_TEMPERATURE))
        # NOTE: deliberately do NOT re-seed between the prior and the X render —
        # at production temp the RNG advances through the prior call exactly as it
        # would in a real two-commit sequence; the question is whether the prior
        # call shifts textX's duration distribution, not whether a re-seeded RNG
        # reproduces it.
        _, n_after = _render_samples_with_temp(model, _TEXT_X, temperature=_PROD_TEMPERATURE)
        after_counts.append(n_after)

    mean_alone = statistics.mean(alone_counts)
    mean_after = statistics.mean(after_counts)
    stdev_alone = statistics.pstdev(alone_counts) if len(alone_counts) > 1 else 0.0
    stdev_after = statistics.pstdev(after_counts) if len(after_counts) > 1 else 0.0
    print(f"   X_alone counts:  {alone_counts}")
    print(f"   X_after counts:  {after_counts}")
    print(f"   X_alone: mean={mean_alone:.0f} stdev={stdev_alone:.0f}")
    print(f"   X_after: mean={mean_after:.0f} stdev={stdev_after:.0f}")

    # Soft-flag heuristic: if the means differ by more than the pooled spread, the
    # distributions look shifted — a coupling signal worth investigating. This is
    # NOT a statistical test (N is small); it is a coarse SOFT flag, by design.
    pooled = max(1.0, (stdev_alone + stdev_after) / 2.0)
    shift = abs(mean_alone - mean_after)
    if shift > pooled:
        print(
            f"   SOFT-FLAG: mean shift {shift:.0f} exceeds pooled stdev {pooled:.0f} "
            "— distributions look SHIFTED. Possible cross-call coupling at "
            "production temperature; decision #3's 'incremental commits are safe' "
            "conclusion may need revisiting. Investigate (this is a diagnostic, not "
            "a hard failure)."
        )
    else:
        print(
            f"   OK: mean shift {shift:.0f} within pooled stdev {pooled:.0f} — "
            "distributions look indistinguishable, supporting cross-call "
            "statelessness at production temperature."
        )


def _assert_first_item_mono(model, text: str, *, temperature: float) -> None:
    """Render ``text`` and assert ONLY the first yielded item is mono
    (``audio.ndim == 1``) LOUDLY, then stop. The generator is abandoned after the
    first item so we do not synthesise the rest of a multi-turn dialogue just to
    read one shape — closing the generator releases the model."""
    gen = model.generate(text, temperature=temperature)
    try:
        item = next(iter(gen))
    except StopIteration:
        raise AssertionError(f"dia generate() yielded no items for: {text!r}") from None
    finally:
        close = getattr(gen, "close", None)
        if callable(close):
            close()  # stop synthesis early; don't drain the remaining turns
    audio = getattr(item, "audio", item)
    ndim = getattr(audio, "ndim", None)
    assert ndim == 1, (
        f"dia bridge contract broken: first item audio.ndim == {ndim!r}, expected 1 (mono)."
    )


def _check_script_mono_shapes(model) -> int:
    """Acceptance criterion: each fixture script's FIRST item asserts
    ``audio.ndim == 1`` (mono). The perceptual path carries pcm bytes over the wire
    with no ``.audio``/``ndim`` available, so this mono-shape guard runs against the
    model directly (mlx-gated/local-only). Returns 0 on pass; an AssertionError
    propagates loudly on shape drift."""
    print("=== per-script mono-shape guard (audio.ndim == 1 on first item) ===")
    for label, filename in _SCRIPTS:
        text = _load_script(filename)
        # Greedy temperature keeps this quick and deterministic; we only need the
        # first item's shape, so stop the generator after item 0 rather than
        # rendering the whole (multi-turn) dialogue.
        _assert_first_item_mono(model, text, temperature=_GREEDY_TEMPERATURE)
        print(f"   [{label}] first item audio.ndim == 1 (mono) OK")
    return 0


def _run_statelessness(args: argparse.Namespace) -> int:
    """Load the dia model locally and run the per-script mono-shape guard, the
    greedy statelessness guard, and the prod-temp diagnostic. mlx-gated: returns a
    clear skip (rc 0) if ``mlx_audio`` is not installed."""
    if not _mlx_available():
        print(
            "SKIP statelessness checks: mlx_audio / mlx not importable. Install the "
            "dia extra (uv sync --extra dia) on Apple Silicon to run the per-script "
            "mono-shape guard, greedy guard + production-temp diagnostic."
        )
        return 0

    from mlx_audio.tts.utils import load  # type: ignore

    print(f"loading dia model {args.model!r} for statelessness checks (this is slow)...")
    model = load(args.model, lazy=False, strict=True)

    rc = _check_script_mono_shapes(model)
    print()
    rc |= _run_greedy_guard(model, args.seed)
    print()
    _run_prod_temp_diagnostic(model, args.diag_seeds)
    return rc


# --- entrypoint -----------------------------------------------------------------


async def _amain(args: argparse.Namespace) -> int:
    rc = 0
    if not args.statelessness_only:
        rc |= await _run_perceptual(args)
    if args.statelessness_only or args.check_statelessness:
        print()
        rc |= _run_statelessness(args)
    print()
    print("dia dialogue smoke: PASS" if rc == 0 else "dia dialogue smoke: FAILED")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description="dia dialogue smoke driver (manual, listen-and-judge)")
    ap.add_argument("--uri", help="full ws:// URI (highest precedence)")
    ap.add_argument("--socket-path", help="Unix domain socket path")
    ap.add_argument("--host", default="127.0.0.1")
    # dia's canonical port (justfile _resolve / README port table). NOT kokoro's
    # 8765 — this is a dia-only driver, so the host/port default must point at dia
    # or an operator running with --host (no --port) would hit a kokoro agent and
    # the [S1]/[S2] tags would be read aloud literally.
    ap.add_argument("--port", type=int, default=9065)
    ap.add_argument("--token", help="bearer token (else none)")
    ap.add_argument(
        "--out-dir",
        default="/tmp/dia_smoke",
        help="directory to write the per-script WAVs (default: /tmp/dia_smoke)",
    )
    ap.add_argument("--timeout", type=float, default=300.0, help="per-script synthesis timeout (s)")
    ap.add_argument(
        "--check-statelessness",
        action="store_true",
        help="ALSO run the mlx-gated greedy guard + prod-temp diagnostic (loads the model)",
    )
    ap.add_argument(
        "--statelessness-only",
        action="store_true",
        help="run ONLY the mlx-gated checks (no live server / perceptual scripts)",
    )
    ap.add_argument(
        "--seed",
        type=int,
        default=_DEFAULT_SEED,
        help=(
            "fixed RNG seed for the greedy byte-identity guard. SET THIS to the seed "
            "the Phase 0 control run used (the plan's ## Findings records the run as "
            "'seeded' but does not pin the numeric value); any fixed seed makes "
            f"greedy decoding deterministic. Default {_DEFAULT_SEED}."
        ),
    )
    ap.add_argument(
        "--diag-seeds",
        type=int,
        default=_DEFAULT_DIAG_SEEDS,
        help=f"number of seeds for the prod-temp distribution diagnostic (default {_DEFAULT_DIAG_SEEDS})",
    )
    ap.add_argument(
        "--model",
        default=DEFAULT_DIA_MODEL,
        help=f"dia model id for the mlx-gated checks (default {DEFAULT_DIA_MODEL})",
    )
    args = ap.parse_args()
    return asyncio.run(_amain(args))


if __name__ == "__main__":
    sys.exit(main())
