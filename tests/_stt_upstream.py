"""The upstream STT server's facts the app depends on, from a recorded source excerpt.

The lean job cannot install ``pipecat-local-stt-server``, so its ``supervise.CODE_*``
error codes and its backend registry (``BACKENDS``, each backend's default model) are
recorded verbatim in ``tests/fixtures/stt_server_<version>_source.txt``, with the tag and
commit they came from. The drift tests compare the contract and the macOS catalog with
this excerpt (not with a hand-typed copy), and with the live package when it is
importable. Re-record it from the new tag whenever ``sttServerRequirement`` moves.
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
