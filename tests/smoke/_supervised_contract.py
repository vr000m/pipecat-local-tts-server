"""Pure helpers for the app-path supervised smoke (``supervised_smoke.py``).

Stdlib only, no ``tts_server`` import: the lean unit test
(``tests/test_supervised_smoke_helpers.py``) and the contract drift guard
(``tests/test_supervised_contract.py``) import this module, and so does the
smoke script itself (same-directory top-level import, like ``_gate_helpers``).

- :func:`event_errors` checks one JSON-lines event against
  ``docs/supervised-contract.json`` (exact required keys, optional keys only from
  the contract, JSON types) and returns the problems instead of asserting.
- :func:`parse_json_lines` splits a captured stdout into events, flagging every
  line that is not a JSON object (``--supervised`` reserves stdout for JSON).
- :func:`ready_errors` checks a ``ready`` line against what the supervisor asked
  for (backend, model, loopback host, the real port, the child's pid).
- :data:`APP_BASE_ENV_KEYS` / :func:`app_child_env` mirror the environment the
  macOS app gives its children (``ProcessEnvironment.base()`` /
  ``huggingFace()`` in ``macos/Sources/PipecatToolbarCore/ToolLocator.swift``;
  drift-tested).
"""

from __future__ import annotations

import json
import os
import re
import tempfile
from pathlib import Path
from typing import Any

REPO = Path(__file__).resolve().parents[2]
CONTRACT_PATH = REPO / "docs" / "supervised-contract.json"

_JSON_TYPES = {
    "string": lambda v: isinstance(v, str),
    "integer": lambda v: isinstance(v, int) and not isinstance(v, bool),
    "boolean": lambda v: isinstance(v, bool),
    "null": lambda v: v is None,
}


def load_contract(path: Path = CONTRACT_PATH) -> dict[str, Any]:
    return json.loads(path.read_text())


def known_error_codes(contract: dict[str, Any], emitter: str | None = None) -> set[str]:
    """The ``error.code`` values of one emitter (``tts`` / ``stt``), or of either by default."""
    by_emitter = contract["error_codes"]
    if emitter is not None:
        return set(by_emitter[emitter])
    return {code for codes in by_emitter.values() for code in codes}


def event_errors(
    scope: str, event: Any, contract: dict[str, Any] | None = None, emitter: str | None = None
) -> list[str]:
    """Every way ``event`` departs from its ``contract[scope]`` entry ([] = conforms).

    An ``error`` line's ``code`` must be one of ``emitter``'s codes (either emitter's when
    ``emitter`` is None: the app-path smoke runs both)."""
    contract = contract if contract is not None else load_contract()
    if not isinstance(event, dict):
        return [f"{scope}: not a JSON object: {event!r}"]
    name = event.get("event")
    entry = contract[scope].get(name) if isinstance(name, str) else None
    if entry is None:
        return [f"{scope}: {name!r} is not a contract event"]
    fields, optional = entry["fields"], entry.get("optional", {})
    keys = set(event)
    errors = []
    missing = set(fields) - keys
    if missing:
        errors.append(f"{name}: missing {sorted(missing)}")
    extra = keys - set(fields) - set(optional)
    if extra:
        errors.append(f"{name}: not in the contract {sorted(extra)}")
    allowed_types = {**fields, **optional}
    for key, value in event.items():
        allowed = allowed_types.get(key)
        if allowed is not None and not any(_JSON_TYPES[t](value) for t in allowed):
            errors.append(f"{name}.{key} = {value!r} is not {allowed}")
    if (
        name == "error"
        and "code" in event
        and event["code"] not in known_error_codes(contract, emitter)
    ):
        errors.append(f"error.code {event['code']!r} is not a contract error code")
    return errors


def parse_json_lines(text: str) -> tuple[list[dict[str, Any]], list[str]]:
    """``(events, bad_lines)``: blank lines are ignored; any other non-object line is bad."""
    events: list[dict[str, Any]] = []
    bad: list[str] = []
    for line in text.splitlines():
        if not line.strip():
            continue
        try:
            obj = json.loads(line)
        except ValueError:
            bad.append(line)
            continue
        if isinstance(obj, dict):
            events.append(obj)
        else:
            bad.append(line)
    return events, bad


def ready_errors(
    event: dict[str, Any],
    *,
    backend: str,
    model: str | None,
    host: str,
    port: int,
    pid: int,
    contract: dict[str, Any] | None = None,
) -> list[str]:
    """``event_errors`` for a ``ready`` line plus the values the supervisor relies on."""
    errors = event_errors("serve", event, contract)
    if errors:
        return errors
    if event["event"] != "ready":
        return [f"expected a ready line, got {event['event']!r}: {event}"]
    expect = {
        "backend": backend,
        "model": model,
        "host": host,
        "port": port,
        "socket_path": None,
        "pid": pid,
    }
    for key, want in expect.items():
        if event[key] != want:
            errors.append(f"ready.{key} = {event[key]!r}, expected {want!r}")
    if event["rate"] <= 0:
        errors.append(f"ready.rate = {event['rate']!r} is not a positive sample rate")
    return errors


def prefetch_errors(events: list[dict[str, Any]], *, check: bool, backend: str) -> list[str]:
    """A whole ``prefetch --json`` run: each line conforms, and it ends where it must.

    ``--check`` writes ``check*`` then one ``summary``; a fetch writes
    ``start``/``progress``/``done``/``warning``/``convert`` lines and ends in one
    ``complete``. Either way the terminal line names ``backend``.
    """
    contract = load_contract()
    errors = [e for ev in events for e in event_errors("prefetch", ev, contract)]
    if errors:
        return errors
    names = [ev["event"] for ev in events]
    if "error" in names:
        return [f"prefetch reported an error: {events[names.index('error')]}"]
    terminal = "summary" if check else "complete"
    body = {"check"} if check else {"start", "progress", "done", "warning", "convert"}
    if not names or names[-1] != terminal or names.count(terminal) != 1:
        return [f"expected exactly one trailing {terminal!r}, got {names}"]
    stray = sorted(set(names[:-1]) - body)
    if stray:
        errors.append(f"unexpected {stray} in a {'--check' if check else 'fetch'} run")
    if events[-1]["backend"] != backend:
        errors.append(f"{terminal}.backend = {events[-1]['backend']!r}, expected {backend!r}")
    return errors


# --- the app's child environment ---------------------------------------------

# Fixed values of ``ProcessEnvironment.base()`` (ToolLocator.swift).
_APP_FIXED_ENV = {
    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
    "LANG": "en_US.UTF-8",
    "LC_ALL": "en_US.UTF-8",
    "PYTHONUNBUFFERED": "1",
    "PYTHONIOENCODING": "utf-8",
    "NO_COLOR": "1",
    "TERM": "dumb",
    "HF_HUB_DISABLE_TELEMETRY": "1",
    "DO_NOT_TRACK": "1",
}
# Inherited when set (``base()``), plus ``HF_TOKEN`` (``huggingFace()``, given to
# the processes that download: ``prefetch`` and ``serve``).
_APP_INHERITED_ENV = ("HF_HOME", "HF_HUB_CACHE", "XDG_CACHE_HOME", "PIPECAT_TTS_PHONON_VOICES")
_APP_HF_ENV = ("HF_TOKEN",)

# Every key ``base()`` writes (HOME and TMPDIR are computed, not fixed).
APP_BASE_ENV_KEYS = frozenset({*_APP_FIXED_ENV, "HOME", "TMPDIR", *_APP_INHERITED_ENV})


def app_child_env(inherited: dict[str, str] | None = None) -> dict[str, str]:
    """The environment the app gives ``prefetch``/``serve`` (``huggingFace()``)."""
    inherited = dict(os.environ if inherited is None else inherited)
    env = dict(_APP_FIXED_ENV)
    env["HOME"] = inherited.get("HOME") or str(Path.home())
    env["TMPDIR"] = inherited.get("TMPDIR") or tempfile.gettempdir()
    for key in (*_APP_INHERITED_ENV, *_APP_HF_ENV):
        if key in inherited:
            env[key] = inherited[key]
    return env


# --- ports the smoke must never use ------------------------------------------

# Same pattern as tests/test_backend_registry.py's ``_RESOLVE``.
_RESOLVE_PORT = re.compile(r'^\s+\w+\)\s+printf .*?"127\.0\.0\.1"\s+"(\d+)"', re.MULTILINE)
# The app's STT services sit next to tone (macos catalog, Service.swift).
_APP_PORT_RANGE = range(8665, 8673)


def canonical_ports(justfile: Path = REPO / "justfile") -> frozenset[int]:
    """Operator/app ports (justfile ``_resolve`` map + the app's 8665-8672 block)."""
    ports = {int(p) for p in _RESOLVE_PORT.findall(justfile.read_text())}
    return frozenset(ports | set(_APP_PORT_RANGE))


def usable_smoke_port(port: int, canonical: frozenset[int]) -> bool:
    """An ephemeral port the smoke may bind: unprivileged, high, never canonical."""
    return port >= 10000 and port not in canonical
