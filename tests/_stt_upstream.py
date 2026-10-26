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
``site-packages``). Run it locally whenever the excerpt is re-recorded.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "stt_server_0.4.0_source.txt"


@dataclass(frozen=True)
class UpstreamSTT:
    #: The release the excerpt was recorded from.
    version: str
    #: ``stt_server.supervise.CODE_*`` values.
    error_codes: frozenset[str]
    #: ``stt_server.backends.BACKENDS``: backend name -> its default model (None: none).
    default_models: dict[str, str | None]


def upstream_stt(path: Path = FIXTURE) -> UpstreamSTT:
    text = path.read_text()
    release = re.search(
        r"^# release: pipecat-local-stt-server (\S+) \(tag v\1, commit [0-9a-f]{40}\)$",
        text,
        re.MULTILINE,
    )
    assert release, f"{path.name}: no release/commit header"
    codes = frozenset(re.findall(r'^CODE_[A-Z_]+ = "(\w+)"$', text, re.MULTILINE))
    constants = dict(re.findall(r'^(DEFAULT_[A-Z_]+_MODEL) = "([^"]+)"$', text, re.MULTILINE))
    body = text.split("BACKENDS: dict", 1)[1]
    parts = re.split(r'^    "(\w+)": BackendEntry\(', body, flags=re.MULTILINE)
    models: dict[str, str | None] = {}
    for name, segment in zip(parts[1::2], parts[2::2], strict=True):
        constant = re.search(r"\b(DEFAULT_[A-Z_]+_MODEL)\b", segment)
        models[name] = constants[constant.group(1)] if constant else None
    assert codes and models, f"{path.name}: the parser sees the excerpt"
    return UpstreamSTT(version=release.group(1), error_codes=codes, default_models=models)


def excerpt_lines_missing_from(site: Path, path: Path = FIXTURE) -> list[str]:
    """The excerpt's code lines that are not, verbatim, a line of the file their ``## <path>``
    section names under ``site`` (empty: the excerpt is a faithful copy of that source)."""
    missing: list[str] = []
    source: list[str] | None = None
    for line in path.read_text().splitlines():
        if line.startswith("## "):
            source = (site / line[3:]).read_text().splitlines()
        elif source is not None and line.strip() and not line.startswith("#"):
            if line not in source:
                missing.append(line)
    assert source is not None, f"{path.name}: no ## <path> section"
    return missing
