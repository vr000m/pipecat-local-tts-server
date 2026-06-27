"""Drift guard + resolver behaviour for the justfile port map.

The backend -> ``(label, host, port)`` map has THREE copies that must agree:

* the justfile ``_resolve`` recipe (the canonical operator map),
* the README "Per-backend port convention" table, and
* the ``render_tts_plist._BACKEND_RE`` allowlist (the renderer's accepted set).

The authoritative backend SET is the ``--backend`` choices tuple in
``tts_server/__main__.py`` (the server's trust anchor). This test derives that
set DYNAMICALLY (it does not hardcode the four names) and asserts the resolver,
README, and renderer cover exactly those backends, and that ``dia`` (reserved,
not yet a ``--backend`` choice) is absent from all three. It also drives
``just _resolve <b>`` per backend and asserts the emitted ``(label host port)``.

``just`` is invoked as a subprocess; if ``just`` is not on PATH the subprocess
tests skip gracefully.
"""

from __future__ import annotations

import importlib.util
import re
import shutil
import subprocess
from pathlib import Path

import pytest

from tts_server.__main__ import build_parser

REPO_ROOT = Path(__file__).resolve().parent.parent
README = REPO_ROOT / "README.md"
JUSTFILE = REPO_ROOT / "justfile"
RENDER_SCRIPT = REPO_ROOT / "scripts" / "render_tts_plist.py"

_HAVE_JUST = shutil.which("just") is not None
_skip_no_just = pytest.mark.skipif(not _HAVE_JUST, reason="`just` not on PATH")


def _load_renderer():
    spec = importlib.util.spec_from_file_location("render_tts_plist", RENDER_SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def _argparse_backends() -> set[str]:
    """The authoritative ``--backend`` choices set from the server CLI."""
    parser = build_parser()
    for action in parser._subparsers._group_actions[0].choices["serve"]._actions:
        if action.dest == "backend":
            return set(action.choices)
    raise AssertionError("--backend action not found on the serve subparser")


def _readme_port_table() -> dict[str, tuple[str, int]]:
    """Parse the README 'Per-backend port convention' table into
    ``{backend: (label, port)}``. Rows look like ``| tone | `pipecat...` | 8665 |``."""
    text = README.read_text()
    start = text.index("### Per-backend port convention")
    section = text[start:]
    out: dict[str, tuple[str, int]] = {}
    for line in section.splitlines():
        m = re.match(
            r"^\|\s*([A-Za-z0-9_]+)\s*\|\s*`([^`]+)`\s*\|\s*(\d+)\s*\|\s*$",
            line,
        )
        if m:
            out[m.group(1)] = (m.group(2), int(m.group(3)))
    return out


def _resolve(backend: str) -> subprocess.CompletedProcess:
    return subprocess.run(
        ["just", "_resolve", backend],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=30,
    )


def _resolve_fields(backend: str) -> tuple[str, str, int]:
    r = _resolve(backend)
    assert r.returncode == 0, f"_resolve {backend} failed: {r.stderr!r}"
    label, host, port = r.stdout.strip().splitlines()
    return label, host, int(port)


# ---------------------------------------------------------------------------
# Drift invariant: argparse choices == README == _resolve == renderer allowlist
# ---------------------------------------------------------------------------


def test_renderer_allowlist_matches_argparse_backends():
    """The renderer ``_BACKEND_RE`` accepts EXACTLY the wired ``--backend``
    choices — derived dynamically, not hardcoded."""
    backends = _argparse_backends()
    renderer = _load_renderer()
    for b in backends:
        assert renderer._BACKEND_RE.match(b), f"renderer rejects wired backend {b!r}"
    # And it rejects a reserved/unknown name.
    assert not renderer._BACKEND_RE.match("dia")
    assert not renderer._BACKEND_RE.match("bogus")


def test_readme_table_covers_exactly_the_argparse_backends():
    backends = _argparse_backends()
    table = _readme_port_table()
    assert set(table) == backends, f"README port table {set(table)} != --backend choices {backends}"
    # Each label follows the canonical pipecat.tts-server.<backend> scheme.
    for backend, (label, _port) in table.items():
        assert label == f"pipecat.tts-server.{backend}"


def test_dia_is_absent_from_readme_and_renderer():
    table = _readme_port_table()
    assert "dia" not in table
    renderer = _load_renderer()
    assert not renderer._BACKEND_RE.match("dia")
    assert "dia" not in _argparse_backends()


@_skip_no_just
def test_resolve_matches_readme_and_argparse_for_each_backend():
    """``just _resolve <b>`` == README (label, port) for each wired backend, and
    the SET of resolvable backends equals the --backend choices."""
    backends = _argparse_backends()
    table = _readme_port_table()
    for backend in sorted(backends):
        label, host, port = _resolve_fields(backend)
        assert host == "127.0.0.1", f"{backend}: non-loopback host {host!r}"
        readme_label, readme_port = table[backend]
        assert label == readme_label, f"{backend}: _resolve label != README"
        assert port == readme_port, f"{backend}: _resolve port {port} != README {readme_port}"


@_skip_no_just
def test_resolve_unknown_backend_exits_nonzero():
    r = _resolve("bogus")
    assert r.returncode != 0
    assert "unknown backend" in r.stderr


@_skip_no_just
def test_resolve_dia_exits_nonzero():
    """``dia`` is reserved and intentionally NOT in the resolver map."""
    r = _resolve("dia")
    assert r.returncode != 0


# ---------------------------------------------------------------------------
# _plist_endpoint: tts-list reads the live endpoint (and auth token) from the
# agent's own plist, so a secured agent is probed WITH its token instead of
# being mislabeled stopped/unreachable on a 401.
# ---------------------------------------------------------------------------


def _render_plist_file(tmp_path: Path, **overrides) -> Path:
    """Render a real plist via render_plist() and write it to a temp file."""
    renderer = _load_renderer()
    kwargs = {
        "backend": "kokoro",
        "label": "pipecat.tts-server.kokoro",
        "host": "127.0.0.1",
        "port": 8765,
        "python": "/usr/bin/python3",
        "repo_root": "/repo",
        "home": "/home/u",
        "log_dir": "/home/u/logs",
    }
    kwargs.update(overrides)
    xml = renderer.render_plist(**kwargs)
    plist = tmp_path / "agent.plist"
    plist.write_text(xml)
    return plist


def _plist_endpoint(plist: Path) -> tuple[str, str, str, str]:
    r = subprocess.run(
        ["just", "_plist_endpoint", str(plist)],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        timeout=30,
    )
    assert r.returncode == 0, f"_plist_endpoint failed: {r.stderr!r}"
    lines = r.stdout.splitlines()
    lines += [""] * (4 - len(lines))
    host, port, sock, authfile = lines[:4]
    return host, port, sock, authfile


@_skip_no_just
def test_plist_endpoint_extracts_host_and_port(tmp_path):
    """A loopback agent (no token) yields host+port, empty socket+auth."""
    plist = _render_plist_file(tmp_path, host="127.0.0.1", port=8765)
    host, port, sock, authfile = _plist_endpoint(plist)
    assert (host, port) == ("127.0.0.1", "8765")
    assert sock == ""
    assert authfile == ""


@_skip_no_just
def test_plist_endpoint_extracts_auth_token_file(tmp_path):
    """A secured agent's plist carries --auth-token-file; _plist_endpoint must
    surface it so tts-list can probe WITH the token (no false 401/unreachable)."""
    token_path = "/Users/op/Library/Application Support/pipecat-tts/token"
    plist = _render_plist_file(tmp_path, host="127.0.0.1", port=8765, auth_token_file=token_path)
    host, port, sock, authfile = _plist_endpoint(plist)
    assert (host, port) == ("127.0.0.1", "8765")
    assert sock == ""
    assert authfile == token_path
