#!/usr/bin/env python3
"""Verify the mlx-audio TTS API shape that the v1 dev plan depends on.

The plan (docs/dev_plans/20260624-feature-tts-server-v1.md) states the mlx-audio
API as fact ("verified from docs"). This script verifies it against the actually
installed package, turning assumptions into checked facts before backends are
built on them. It works per model family, so it doubles as a backend-survey tool:
each candidate backend has its own `generate()` kwargs, streaming behaviour, and
import dependencies, and a single global capability list cannot describe them all.

Run it with an interpreter that has mlx-audio installed, e.g. the uv tool venv:

    /Users/vr000m/.local/share/uv/tools/mlx-audio/bin/python scripts/verify_mlx_tts_api.py

Static checks (no model download) cover: the package-wide load()/GenerationResult
surface, plus per-family generate() signatures, ignored ("del"d) kwargs, voice
cloning (ref_audio) params, streaming, and whether the family imports under a
lean install. Pass --load to additionally download a model and verify the .audio
dtype/range at runtime (needs Apple Silicon + network on first run).

    python scripts/verify_mlx_tts_api.py --families kokoro pocket_tts dia
    python scripts/verify_mlx_tts_api.py --load --repo mlx-community/Kokoro-82M-bf16
"""

from __future__ import annotations

import argparse
import dataclasses
import importlib
import importlib.metadata
import inspect
import pathlib
import re

# Families the dev plan names or asks about. voxtral / kyutai are listed because
# the plan/requester reference them; the survey reports whether they actually
# exist as mlx-audio TTS families rather than silently skipping them.
DEFAULT_FAMILIES = ["kokoro", "pocket_tts", "dia"]
REQUESTED_BUT_CHECK_EXISTENCE = ["voxtral", "kyutai", "moshi"]

# kwargs the plan advertises in a single global capabilities["extras"] list.
PLAN_EXTRAS = ["speed", "temperature", "instruct", "cfg_scale", "ddpm_steps"]
STREAMING_KWARGS = ["stream", "streaming_interval"]


def _tts_models_dir() -> pathlib.Path:
    import mlx_audio.tts as tts_pkg

    return pathlib.Path(tts_pkg.__file__).parent / "models"


def package_surface() -> list[str]:
    """Check the family-independent API: load(), GenerationResult, model registry."""
    print(f"mlx-audio version = {importlib.metadata.version('mlx-audio')}\n")

    from mlx_audio.tts import utils as tts_utils

    print("== mlx_audio.tts.utils.load ==")
    print("  signature:", inspect.signature(tts_utils.load))
    print("  has generate_audio (plan says unused):", hasattr(tts_utils, "generate_audio"))
    print()

    print("== GenerationResult fields (plan claims .is_streaming_chunk / .is_final_chunk) ==")
    from mlx_audio.tts.models.base import GenerationResult

    field_names = [f.name for f in dataclasses.fields(GenerationResult)]
    print("  fields:", ", ".join(field_names))
    print("  has is_streaming_chunk:", "is_streaming_chunk" in field_names)
    print("  has is_final_chunk:", "is_final_chunk" in field_names)
    print()

    available: list[str] = []
    if hasattr(tts_utils, "get_available_models"):
        available = list(tts_utils.get_available_models())
        print("== get_available_models() ==")
        print(" ", ", ".join(sorted(available)))
        print()
    return available


def _extract_generate_signature(src: str) -> tuple[str, str]:
    """Return (signature_text, function_body) for the public `generate(` method."""
    start = src.index("def generate(")
    # Balance parentheses to find the close of the parameter list — a `):`
    # substring search overshoots signatures with a return annotation, e.g.
    # `) -> Iterable[GenerationResult]:`.
    open_paren = src.index("(", start)
    depth = 0
    close_paren = open_paren
    for i in range(open_paren, len(src)):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                close_paren = i
                break
    signature = src[start : close_paren + 1]
    # Body runs from the param-list close until the next method at the same indent.
    after = src[close_paren:]
    next_def = re.search(r"\n    def \w", after)
    body = after[: next_def.start()] if next_def else after
    return signature, body


def analyze_family(family: str, models_dir: pathlib.Path) -> None:
    print(f"== {family} ==")
    src_file = models_dir / family / f"{family}.py"
    if not src_file.exists():
        print(f"  no {family}/{family}.py — skipping (entry point may be named differently)")
        print()
        return

    src = src_file.read_text()
    try:
        signature, body = _extract_generate_signature(src)
    except ValueError:
        print("  no public generate() found")
        print()
        return

    # Explicit params on generate() — names followed by an annotation, default,
    # comma, or the closing paren. Drop self/*args/**kwargs framing.
    params = [p for p in re.findall(r"\n\s+(\w+)\s*[:=,)]", signature) if p != "self"]
    print("  generate() params:", ", ".join(params))

    # kwargs that are accepted then immediately discarded (`del a, b, c`).
    deleted: list[str] = []
    for m in re.finditer(r"\bdel ([\w, ]+)", body[:400]):
        deleted.extend(p.strip() for p in m.group(1).split(","))
    if deleted:
        print("  accepted-then-DELETED (no-op) kwargs:", ", ".join(deleted))

    # Which of the plan's global extras are real *and effective* here.
    effective = [k for k in PLAN_EXTRAS if k in params and k not in deleted]
    ignored = [k for k in PLAN_EXTRAS if k in params and k in deleted]
    absent = [k for k in PLAN_EXTRAS if k not in params]
    print(
        f"  plan extras -> effective: {effective or '[]'}  ignored: {ignored or '[]'}  absent: {absent or '[]'}"
    )

    # Streaming + voice cloning + generator behaviour.
    streaming = [k for k in STREAMING_KWARGS if k in params]
    print("  streaming kwargs present:", streaming or "[] (no native streaming)")
    print("  is a generator (yields GenerationResult):", "yield" in body)
    print("  voice cloning (ref_audio param):", "ref_audio" in params)

    # Does it import under a lean install, or pull an extra dependency?
    try:
        importlib.import_module(f"mlx_audio.tts.models.{family}")
        print("  imports cleanly (no extra dep needed)")
    except ModuleNotFoundError as exc:
        print(f"  IMPORT BLOCKED by missing dependency: {exc.name}")
    except Exception as exc:  # noqa: BLE001 - surface anything else verbatim
        print(f"  import raised {type(exc).__name__}: {exc}")
    print()


def runtime_checks(repo: str) -> None:
    print(f"== Runtime load: {repo} (downloads on first run) ==")
    import mlx.core as mx
    from mlx_audio.tts.utils import load

    model = load(repo)
    print("  model.sample_rate:", getattr(model, "sample_rate", "<no .sample_rate>"))
    results = list(model.generate("Goal!", voice=None))
    print("  segments yielded:", len(results))
    audio = results[0].audio
    print("  .audio dtype:", audio.dtype, " shape:", audio.shape)
    print(
        "  .audio min/max:",
        round(float(mx.min(audio)), 4),
        round(float(mx.max(audio)), 4),
    )
    print("  -> in [-1, 1]:", bool(mx.all(mx.abs(audio) <= 1.0)))

    # Voice count, when the repo ships per-voice files (e.g. Kokoro's voices/).
    try:
        from huggingface_hub import list_repo_files

        # Repos often ship two formats per voice (.pt + .safetensors); count
        # distinct voice names, not raw files.
        stems = {
            f.rsplit("/", 1)[-1].rsplit(".", 1)[0]
            for f in list_repo_files(repo)
            if f.startswith("voices/") and "." in f.rsplit("/", 1)[-1]
        }
        if stems:
            print("  distinct voices:", len(stems))
    except Exception as exc:  # noqa: BLE001
        print("  voice count: could not determine -", exc)


def main() -> None:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument(
        "--families",
        nargs="+",
        default=DEFAULT_FAMILIES,
        help="model families to analyze",
    )
    ap.add_argument(
        "--load",
        action="store_true",
        help="also download a model and verify .audio dtype/range",
    )
    ap.add_argument("--repo", default="mlx-community/Kokoro-82M-bf16", help="HF repo for --load")
    args = ap.parse_args()

    available = package_surface()
    models_dir = _tts_models_dir()

    print("== Per-family generate() survey ==\n")
    for family in args.families:
        analyze_family(family, models_dir)

    print("== Requested-name existence (exact or by-prefix match) ==")
    for name in REQUESTED_BUT_CHECK_EXISTENCE:
        # A requested short name (e.g. "voxtral") may ship under a suffixed family
        # name (e.g. "voxtral_tts"); match by prefix so we don't falsely report absent.
        matches = [m for m in available if m == name or m.startswith(f"{name}_")]
        if matches:
            print(f"  {name}: PRESENT as {', '.join(sorted(matches))}")
        else:
            print(f"  {name}: ABSENT — no TTS family by this name in mlx-audio")
    print()

    if args.load:
        runtime_checks(args.repo)


if __name__ == "__main__":
    main()
