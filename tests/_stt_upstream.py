"""The upstream STT server's facts the app depends on, from a recorded source excerpt.

The lean job cannot install ``pipecat-local-stt-server``, so its ``supervise.CODE_*``
error codes and its backend registry (``BACKENDS``, each backend's default model) are
recorded verbatim in ``tests/fixtures/stt_server_<version>_source.txt``, with the tag and
commit they came from. The drift tests compare the contract and the macOS catalog with
this excerpt (not with a hand-typed copy), and with the live package when it is
importable. Re-record it from the new tag whenever ``sttServerRequirement`` moves.

No CI job installs the STT server, so CI checks only that the excerpt names the release the
app installs. Its content is checked against real source only where one is present: the
importable-package tests, and ``test_recorded_stt_excerpt_is_verbatim_upstream_source``
when ``PIPECAT_STT_SERVER_SITE`` names a directory holding that release's ``stt_server/``
and ``pipecat_local_stt_server-<version>.dist-info`` (e.g. the app's uv cache entry, or a
``site-packages``). That check (``excerpt_drift``) also parses the real files' whole
``CODE_*`` set and ``BACKENDS`` registry, so an excerpt that leaves one out fails. Run it
locally whenever the excerpt is re-recorded.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "stt_server_0.5.0_source.txt"


@dataclass(frozen=True)
class UpstreamSTT:
    #: The release the excerpt was recorded from.
    version: str
    #: ``stt_server.supervise.CODE_*`` values.
    error_codes: frozenset[str]
    #: ``stt_server.backends.BACKENDS``: backend name -> its default model (None: none).
    default_models: dict[str, str | None]


def _parse(text: str, name: str) -> tuple[frozenset[str], dict[str, str | None]]:
    """``CODE_*`` values and ``BACKENDS`` (name -> default model) from an excerpt or the real
    source files, by one parser, so the two can be compared as sets. Fails on a ``CODE_`` line
    or a ``BACKENDS`` entry the parser cannot read (it would otherwise drop out of the set)."""
    codes = re.findall(r'^CODE_[A-Z_]+ = "(\w+)"$', text, re.MULTILINE)
    assert len(codes) == len(re.findall(r"^CODE_", text, re.MULTILINE)), f"{name}: unparsed CODE_"
    constants = dict(re.findall(r'^(DEFAULT_[A-Z_]+_MODEL) = "([^"]+)"$', text, re.MULTILINE))
    body = text.split("BACKENDS: dict", 1)[1].split("\n}\n", 1)[0]
    parts = re.split(r'^    "(\w+)": BackendEntry\(', body, flags=re.MULTILINE)
    keys = re.findall(r'^    "(\w+)":', body, re.MULTILINE)
    assert keys == parts[1::2], f"{name}: unparsed BACKENDS entries {keys}"
    models: dict[str, str | None] = {}
    for backend, segment in zip(parts[1::2], parts[2::2], strict=True):
        constant = re.search(r"\b(DEFAULT_[A-Z_]+_MODEL)\b", segment)
        models[backend] = constants[constant.group(1)] if constant else None
    assert codes and models, f"{name}: the parser sees the source"
    return frozenset(codes), models


def upstream_stt(path: Path = FIXTURE) -> UpstreamSTT:
    text = path.read_text()
    release = re.search(
        r"^# release: pipecat-local-stt-server (\S+) \(tag v\1, commit [0-9a-f]{40}\)$",
        text,
        re.MULTILINE,
    )
    assert release, f"{path.name}: no release/commit header"
    codes, models = _parse(text, path.name)
    return UpstreamSTT(version=release.group(1), error_codes=codes, default_models=models)


def _sections(path: Path) -> list[str]:
    """The source files the excerpt's ``## <path>`` sections name, in order."""
    sections = [line[3:] for line in path.read_text().splitlines() if line.startswith("## ")]
    assert sections, f"{path.name}: no ## <path> section"
    return sections


def excerpt_drift(site: Path, path: Path = FIXTURE) -> list[str]:
    """How the excerpt differs from the real source under ``site`` (empty: none). Two checks:
    every excerpt code line is, verbatim, a line of the file its ``## <path>`` section names;
    and the ``CODE_*`` set and the ``BACKENDS`` registry parsed from those whole files equal
    the excerpt's, so a code or backend the excerpt leaves out is drift too."""
    drift: list[str] = []
    source: list[str] | None = None
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            source = (site / line[3:]).read_text().splitlines()
        elif source is not None and line.strip() and not line.startswith("#"):
            if line not in source:
                drift.append(f"not in the source: {line}")
    real = "\n".join((site / section).read_text() for section in _sections(path))
    codes, models = _parse(real, str(site))
    excerpt = upstream_stt(path)
    if codes != excerpt.error_codes:
        drift.append(
            f"CODE_* values: source {sorted(codes)} != excerpt {sorted(excerpt.error_codes)}"
        )
    if models != excerpt.default_models:
        drift.append(f"BACKENDS: source {models} != excerpt {excerpt.default_models}")
    return drift
