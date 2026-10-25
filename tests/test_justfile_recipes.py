"""Drift guard + resolver behaviour for the justfile port map.

The backend -> ``(label, host, port)`` map has THREE copies that must agree:

* the justfile ``_resolve`` recipe (the canonical operator map),
* the README "Per-backend port convention" table, and
* the ``render_tts_plist._BACKEND_RE`` allowlist (the renderer's accepted set).

The authoritative backend SET is the ``--backend`` choices tuple in
``tts_server/__main__.py`` (the server's trust anchor). This test derives that
set DYNAMICALLY (it does not hardcode the backend names) and asserts the
resolver, README, and renderer cover exactly those backends, and that ``dia``
(now a wired ``--backend`` choice) is present in all three. It also drives
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

from ._macos_catalog import macos_catalog

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
        check=False,  # returncode is asserted by callers
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
    # And it rejects an unknown name.
    assert not renderer._BACKEND_RE.match("bogus")


def test_readme_table_covers_exactly_the_argparse_backends():
    backends = _argparse_backends()
    table = _readme_port_table()
    assert set(table) == backends, f"README port table {set(table)} != --backend choices {backends}"
    # Each label follows the canonical pipecat.tts-server.<backend> scheme.
    for backend, (label, _port) in table.items():
        assert label == f"pipecat.tts-server.{backend}"


def test_dia_is_present_in_readme_and_renderer():
    """``dia`` is now a wired backend: it is in the argparse choices, the README
    port table, and the renderer allowlist (matching the other backends)."""
    table = _readme_port_table()
    assert "dia" in table
    renderer = _load_renderer()
    assert renderer._BACKEND_RE.match("dia")
    assert "dia" in _argparse_backends()


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
def test_resolve_dia_exits_zero_with_canonical_port():
    """``dia`` is now wired into the resolver map at its canonical port 9065."""
    label, host, port = _resolve_fields("dia")
    assert label == "pipecat.tts-server.dia"
    assert host == "127.0.0.1"
    assert port == 9065


@_skip_no_just
def test_resolve_fish_tts_exits_zero_with_canonical_port():
    """``fish_tts`` is now wired into the resolver map at its canonical port
    9265 (next in the +100 sequence after dia's 9065; plan Decision, port
    convention table)."""
    label, host, port = _resolve_fields("fish_tts")
    assert label == "pipecat.tts-server.fish_tts"
    assert host == "127.0.0.1"
    assert port == 9265


@_skip_no_just
def test_resolve_phonon_exits_zero_with_canonical_port():
    """``phonon`` is wired into the resolver map at port 9365 (next +100 step
    after fish_tts's 9265)."""
    label, host, port = _resolve_fields("phonon")
    assert label == "pipecat.tts-server.phonon"
    assert host == "127.0.0.1"
    assert port == 9365


def test_readme_port_table_lists_phonon_9365():
    assert _readme_port_table()["phonon"] == ("pipecat.tts-server.phonon", 9365)


def test_phonon_is_in_argparse_and_renderer():
    assert "phonon" in _argparse_backends()
    assert _load_renderer()._BACKEND_RE.match("phonon")


def _alternation(text: str, anchor: str) -> set[str]:
    """Backend names from the first ``a|b|c`` run that follows ``anchor``."""
    tail = text[text.index(anchor) :]
    m = re.search(r"[a-z0-9_]+(?:\|[a-z0-9_]+)+", tail)
    assert m, f"no alternation after {anchor!r}"
    return set(m.group(0).split("|"))


def test_justfile_case_alternations_cover_exactly_the_argparse_backends():
    """The ``tts-status`` case-arm backend alternation equals the argparse set."""
    text = JUSTFILE.read_text()
    assert _alternation(text, 'case "$target" in') == _argparse_backends()


def test_renderer_error_hint_lists_exactly_the_argparse_backends():
    """The renderer's human-readable ``tone|kokoro|...`` hint can't drift."""
    text = RENDER_SCRIPT.read_text()
    hint = _alternation(text, '"BACKEND"')
    assert hint == _argparse_backends()


@pytest.mark.parametrize("script", ["run_smoke.sh", "run_multiconn.sh"])
def test_smoke_scripts_enumerate_every_backend(script):
    """Every ``--backend`` choice is named in the smoke script's backend gate
    (so ``just smoke-<b>`` / ``smoke-multiconn-<b>`` is not rejected)."""
    text = (REPO_ROOT / "tests" / "smoke" / script).read_text()
    for b in _argparse_backends() - {"tone"}:
        assert f'"$BACKEND" == "{b}"' in text, f"{script} does not mention backend {b!r}"
    assert '"$BACKEND" == "phonon"' in text


def test_justfile_has_phonon_smoke_recipes():
    text = JUSTFILE.read_text()
    assert re.search(
        r"^smoke-phonon \*args:\n\s+tests/smoke/run_smoke.sh --backend phonon", text, re.MULTILINE
    )
    assert re.search(
        r"^smoke-multiconn-phonon \*args:\n\s+tests/smoke/run_multiconn.sh --backend phonon",
        text,
        re.MULTILINE,
    )


def test_justfile_has_supervised_smoke_recipes():
    """``smoke-supervised <backend>`` defaults to tone; ``-all`` takes its backend
    list from the registry (``--all``), never a hand-written one."""
    text = JUSTFILE.read_text()
    assert re.search(
        r'^smoke-supervised backend="tone" \*args:\n\s+uv run --no-sync python '
        r"tests/smoke/supervised_smoke.py --backend \{\{quote\(backend\)\}\} \{\{args\}\}",
        text,
        re.MULTILINE,
    )
    body = _recipe_body("smoke-supervised-all")
    assert "tests/smoke/supervised_smoke.py --all {{args}}" in body
    named = {b for b in _argparse_backends() if re.search(rf"\b{b}\b", body)}
    assert not named, f"smoke-supervised-all hand-lists backends: {sorted(named)}"


@_skip_no_just
def test_smoke_supervised_dry_run_passes_backend_and_args():
    out = subprocess.run(
        ["just", "--dry-run", "smoke-supervised", "phonon", "--download"],
        cwd=REPO_ROOT,
        capture_output=True,
        text=True,
        check=True,
    )
    # just shell-quotes the backend (`quote()`); args pass through verbatim.
    assert re.search(r"supervised_smoke\.py --backend '?phonon'? --download", out.stderr)


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
        check=False,  # returncode is asserted below
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
def test_plist_endpoint_ignores_flaglike_arg_value(tmp_path):
    """An arg VALUE that looks like a flag (e.g. a model id beginning with '-')
    must not be mis-read as the next flag. _plist_endpoint consumes each flag's
    value in the same step, so the port stays correct rather than being clobbered
    by a `--port`-looking model value."""
    plist = _render_plist_file(tmp_path, host="127.0.0.1", port=8765, model="--port")
    host, port, sock, authfile = _plist_endpoint(plist)
    assert host == "127.0.0.1"
    assert port == "8765"
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


# ---------------------------------------------------------------------------
# Drift invariant: the macOS menu bar app's catalog (a fourth copy of the map)
# ---------------------------------------------------------------------------


def _macos_catalog_ports(kind: str = "tts", *, variants: bool = False) -> dict[str, int]:
    """``{server name: port}`` for one service kind, from the shared
    ``Service.swift`` parser (family defaults only unless ``variants``)."""
    return {
        e.name: e.port
        for e in macos_catalog().values()
        if e.kind == kind and (variants or not e.is_variant)
    }


def test_macos_app_catalog_matches_readme_ports():
    ports = _macos_catalog_ports("tts")
    table = _readme_port_table()
    assert set(ports) == _argparse_backends()
    assert ports == {backend: port for backend, (_label, port) in table.items()}


def test_macos_app_stt_ports_do_not_collide_with_tts():
    stt = _macos_catalog_ports("stt", variants=True)
    assert stt, "expected STT services in the macOS catalog"
    assert not set(stt.values()) & set(_macos_catalog_ports("tts", variants=True).values())


def _recipe_body(name: str) -> str:
    """The indented body of justfile recipe ``name`` (up to the next blank line)."""
    lines = JUSTFILE.read_text().splitlines()
    start = next(i for i, line in enumerate(lines) if re.match(rf"^{re.escape(name)}\b.*:", line))
    body = []
    for line in lines[start + 1 :]:
        if not line.startswith((" ", "\t")):
            break
        body.append(line)
    return "\n".join(body)


def test_app_open_quits_the_bundle_id_the_build_used():
    """``BUNDLE_ID`` overrides the built app's identifier, so ``app-open`` must quit
    whatever id the build wrote, not a hardcoded default (else it misses the running
    copy and ``open`` just re-activates it)."""
    body = _recipe_body("app-open")
    assert "CFBundleIdentifier" in body, body
    assert 'quit app id "ai.pipecat.ServiceToolbar"' not in body, body
