#!/usr/bin/env python3
"""Regenerate ``macos/constraints/stt-<engine>.txt``: the hash-pinned constraints
the app installs each STT engine's environment with.

    uv run python macos/scripts/compile_stt_constraints.py

Each engine's top-level requirements are read from ``Service.swift`` (through
``tests/_macos_catalog.py``, the parser the drift tests use) and resolved with
``uv pip compile --generate-hashes`` for the app's target: CPython 3.12
(``EnvironmentManager.pythonVersion``) on arm64 macOS 15 (``Package.swift``),
so the pins are what a fresh install on that floor would pick. The output is
checked in, so an app build is reproducible; rerun this (network needed) after
bumping a requirement in ``Service.swift`` — ``tests/test_supervised_contract.py``
fails until you do. ``PIPECAT_UV`` overrides the uv binary (default: the app's pinned
uv from ``fetch_uv.sh``).
"""

from __future__ import annotations

import importlib.util
import os
import subprocess
import sys
import tempfile
from pathlib import Path

SCRIPTS = Path(__file__).resolve().parent
REPO = SCRIPTS.parents[1]
OUT_DIR = REPO / "macos" / "constraints"

PYTHON_VERSION = "3.12"
PLATFORM = "aarch64-apple-darwin"
MACOS_TARGET = "15.0"


def _catalog():
    spec = importlib.util.spec_from_file_location(
        "_macos_catalog", REPO / "tests" / "_macos_catalog.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = module  # dataclasses resolve the module by name
    spec.loader.exec_module(module)
    return module.macos_catalog()


def engine_requirements() -> dict[str, tuple[str, ...]]:
    engines: dict[str, tuple[str, ...]] = {}
    for entry in _catalog().values():
        if entry.engine and not entry.is_variant:
            engines[entry.engine] = entry.requirements
    return engines


def _uv() -> str:
    if os.environ.get("PIPECAT_UV"):
        return os.environ["PIPECAT_UV"]
    return subprocess.run(
        [str(SCRIPTS / "fetch_uv.sh")], check=True, capture_output=True, text=True
    ).stdout.strip()


def main() -> int:
    uv = _uv()
    OUT_DIR.mkdir(exist_ok=True)
    env = dict(os.environ, MACOSX_DEPLOYMENT_TARGET=MACOS_TARGET)
    for engine, requirements in sorted(engine_requirements().items()):
        out = OUT_DIR / f"stt-{engine}.txt"
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / f"stt-{engine}.in"
            source.write_text("".join(f"{r}\n" for r in requirements))
            compiled = Path(tmp) / out.name
            subprocess.run(
                [
                    uv, "pip", "compile", str(source),
                    "--python-version", PYTHON_VERSION,
                    "--python-platform", PLATFORM,
                    "--generate-hashes", "--no-header", "--quiet",
                    "--output-file", str(compiled),
                ],
                check=True,
                env=env,
            )  # fmt: skip
            body = compiled.read_text().replace(str(source), f"stt-{engine}.in")
        header = [
            f"# Hash-pinned constraints for the {engine} STT environment. GENERATED, do not edit:",
            "#   uv run python macos/scripts/compile_stt_constraints.py",
            f"# python-version: {PYTHON_VERSION}",
            f"# python-platform: {PLATFORM}",
            f"# macos-deployment-target: {MACOS_TARGET}",
            *(f"# requirement: {r}" for r in requirements),
        ]
        out.write_text("\n".join(header) + "\n" + body)
        print(f"wrote {out.relative_to(REPO)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
