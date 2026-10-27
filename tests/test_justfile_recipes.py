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


def test_app_install_signs_stably_and_quits_by_built_id():
    """``app-install`` must not ship the ad-hoc default (cdhash-bound, so every rebuild
    resets TCC grants), must quit the id the build wrote, and must replace the installed
    copy rather than ditto-merge into it."""
    body = _recipe_body("app-install")
    assert 'SIGN_IDENTITY="${SIGN_IDENTITY:-Code Signing}"' in body, body
    assert "CFBundleIdentifier" in body, body
    assert body.index("rm -rf") < body.index('ditto "$src"'), body
    assert "codesign --verify" in body, body


# --- Phase 6: docs + out-of-process smoke contract -------------------------

_MACOS = REPO_ROOT / "macos"
_UI_SMOKE = _MACOS / "scripts" / "ui_smoke.sh"
_ARCH_DOC = _MACOS / "docs" / "architecture.md"
_HELPER_ERA = (
    "pipecat_app_helper",
    "PIPECAT_TOOLBAR_HELPER",
    "MODEL_REVISIONS",
    "sttModelRevisions",
    "serve-stt",
)
_REAL_AGENT_PORTS = ("8965", "9565", "9665", "9765", "9865")


def _helper_era_files() -> list[Path]:
    files = [
        _MACOS / "README.md",
        REPO_ROOT / "AGENTS.md",
        JUSTFILE,
        README,
        *sorted((_MACOS / "docs").glob("*.md")),
    ]
    return [f for f in files if f.is_file()]


@pytest.mark.parametrize("path", _helper_era_files(), ids=lambda p: p.name)
def test_no_helper_era_mentions(path: Path) -> None:
    text = path.read_text()
    found = [s for s in _HELPER_ERA if s in text]
    assert not found, f"{path.relative_to(REPO_ROOT)} still mentions {found}"


def test_app_smoke_recipe_points_at_ui_smoke() -> None:
    text = JUSTFILE.read_text()
    m = re.search(r"^app-smoke\b[^\n]*\n((?:[ \t]+[^\n]*\n?)+)", text, re.MULTILINE)
    assert m is not None, "app-smoke recipe missing from justfile"
    assert "ui_smoke.sh" in m.group(1)
    assert _UI_SMOKE.is_file()


@pytest.mark.skipif(shutil.which("bash") is None, reason="bash not on PATH")
def test_ui_smoke_parses() -> None:
    r = subprocess.run(["bash", "-n", str(_UI_SMOKE)], capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr


def test_ui_smoke_recognises_external_phase() -> None:
    # The bootstrap phase-line regex must accept the `external` phase.
    lines = [
        ln for ln in _UI_SMOKE.read_text().splitlines() if "notInstalled" in ln and "running" in ln
    ]
    assert lines, "phase-line regex not found in ui_smoke.sh"
    assert any("external" in ln for ln in lines)


def test_ui_smoke_skips_when_canonical_port_held() -> None:
    code = "\n".join(
        ln for ln in _UI_SMOKE.read_text().splitlines() if not ln.lstrip().startswith("#")
    )
    tone_port = _macos_catalog_ports("tts")["tone"]
    assert re.search(rf"^EXT_PORT={tone_port}\b", code, re.MULTILINE), (
        "the external step must use tone's canonical port"
    )
    held = re.search(r'lsof -nP -iTCP:"\$EXT_PORT" -sTCP:LISTEN', code)
    skip = re.search(r"SKIP external: port", code)
    serve = re.search(r"tts_server serve --backend tone", code)
    assert held and skip and serve, "held-port check, SKIP message and tone launch must all be code"
    assert held.start() < skip.start() < serve.start(), (
        "the held-port skip must come before the launch"
    )


def test_ui_smoke_never_names_real_agent_ports() -> None:
    code = [ln for ln in _UI_SMOKE.read_text().splitlines() if not ln.lstrip().startswith("#")]
    hits = [ln for ln in code if any(re.search(rf"\b{p}\b", ln) for p in _REAL_AGENT_PORTS)]
    assert not hits, f"ui_smoke.sh hardcodes real agent ports: {hits}"


def test_architecture_known_followups_lists_deferred_discovery() -> None:
    text = _ARCH_DOC.read_text()
    m = re.search(r"^## Known follow-ups\n(.*?)(?=^## |\Z)", text, re.DOTALL | re.MULTILINE)
    assert m is not None, "Known follow-ups section missing"
    body = m.group(1)
    assert re.search(r"Unix-socket discovery", body)
    assert re.search(r"\bLAN endpoints\b", body)
    assert re.search(r"token storage", body)


def _ui_smoke_functions(*names: str) -> str:
    """The named shell functions, verbatim from ui_smoke.sh (to run them without the script)."""
    text = _UI_SMOKE.read_text()
    out = []
    for name in names:
        m = re.search(rf"^{name}\(\) \{{\n.*?^\}}\n", text, re.DOTALL | re.MULTILINE)
        assert m is not None, f"{name}() not found in ui_smoke.sh"
        out.append(m.group(0))
    return "\n".join(out)


def test_ui_smoke_signals_its_children_only_by_job_spec() -> None:
    """Every signal the script sends to a process it started names a job spec (``%N``), never a
    pid: the shell resolves a job spec from its own job table and skips a child it has already
    reaped, while a check-then-``kill $pid`` can hit a pid the kernel reused in between. The one
    ``kill`` is in ``signal_job``, which looks the job number up from the pid when it signals
    (no cached ``%N``: the shell reuses job numbers)."""
    code = [ln for ln in _UI_SMOKE.read_text().splitlines() if not ln.lstrip().startswith("#")]
    signals = [ln for ln in code if re.search(r"\bkill\b(?! -0)", ln)]
    assert signals, "the pattern sees the script's signals"
    for ln in signals:
        assert re.search(r'\bkill "?-\$?\w+"? "%\$\w+"', ln), (
            f"signal not by job spec: {ln.strip()}"
        )
    assert len(signals) == 1 and signals[0] in _ui_smoke_functions("signal_job"), signals
    assert "EXT_JOB" not in _UI_SMOKE.read_text(), "a cached job number"
    body = _ui_smoke_functions("stop_job")
    assert "kill" not in body.split('wait "$1"', 1)[1], "no signal after the reap"


def _bash_candidates() -> list:
    """The PATH ``bash``, and the stock macOS ``/bin/bash`` when it is bash 3.x (it reuses a
    reaped job's number, which the PATH bash 5 may not); missing ones are skipped."""
    params = []
    path_bash = shutil.which("bash")
    params.append(
        pytest.param(path_bash, id="path-bash")
        if path_bash
        else pytest.param(None, id="path-bash", marks=pytest.mark.skip(reason="bash not on PATH"))
    )
    stock = Path("/bin/bash")
    major = None
    if stock.exists():
        r = subprocess.run(
            [str(stock), "-c", "echo ${BASH_VERSINFO[0]}"], capture_output=True, text=True
        )
        major = r.stdout.strip()
    params.append(
        pytest.param(str(stock), id="bin-bash-3")
        if major == "3"
        else pytest.param(
            None, id="bin-bash-3", marks=pytest.mark.skip(reason="/bin/bash is not bash 3.x")
        )
    )
    return params


_SIGNAL_FUNCTIONS = ("ext_is_ours", "job_of", "job_running", "signal_job", "stop_job", "stop_ext")


def _run_signal_script(bash: str, body: str) -> subprocess.CompletedProcess:
    script = f"set -euo pipefail\n{_ui_smoke_functions(*_SIGNAL_FUNCTIONS)}\n{body}\necho done\n"
    return subprocess.run([bash, "-c", script], capture_output=True, text=True, timeout=30)


@pytest.mark.parametrize("bash", _bash_candidates())
def test_ui_smoke_never_signals_a_pid_that_is_no_longer_its_child(bash: str) -> None:
    """``stop_ext`` and ``signal_job`` against (a) the script's own child, which they stop and
    reap, and (b) the race the identity check alone cannot close: the child has exited and been
    reaped and its pid now names an unrelated process that even passes ``ext_is_ours`` (the
    check ran before the pid changed hands). Neither may signal that process."""
    stranger = subprocess.Popen(["sleep", "30"])
    try:
        r = _run_signal_script(
            bash,
            f"""EXT_MATCH="sleep 30"
sleep 30 &
EXT_PID=$!
[[ -n "$(job_of "$EXT_PID")" ]] || {{ echo "job_of found no job"; exit 2; }}
sleep 0.2
ext_is_ours || {{ echo "own child not recognised"; exit 3; }}
stop_ext
[[ -z "$EXT_PID" ]] || {{ echo "EXT_PID not cleared"; exit 4; }}
sleep 30 &
own=$!
signal_job TERM "$own"
wait "$own" && {{ echo "signal_job did not stop its own child"; exit 5; }}
sleep 0.1 &
EXT_PID=$!
sleep 0.5
EXT_PID={stranger.pid}
ext_is_ours() {{ return 0; }}
stop_ext
signal_job KILL {stranger.pid}""",
        )
        assert r.returncode == 0 and r.stdout.strip().endswith("done"), (r.stdout, r.stderr)
        assert stranger.poll() is None, "a signal reached a process that was not the shell's child"
    finally:
        stranger.kill()
        stranger.wait()


@pytest.mark.parametrize("bash", _bash_candidates())
def test_ui_smoke_stop_ext_never_signals_a_job_that_took_its_number(bash: str) -> None:
    """The server exits on its own and is reaped; the next job may get its job number (bash 3.2
    reuses it). ``stop_ext`` resolves the job from the pid when it signals, so it leaves the new
    job alone (a job number cached at start would name the new job)."""
    r = _run_signal_script(
        bash,
        """sleep 0.1 &
EXT_PID=$!
first="$(job_of "$EXT_PID")"
sleep 0.5
sleep 30 &
other=$!
echo "ext was %$first, the next job is %$(job_of "$other")"
stop_ext
sleep 0.5  # a signal it sent has landed and the shell has reaped the job by now
job_running "$other" || { echo "stop_ext signalled another job"; exit 6; }
stop_job "$other"
""",
    )
    assert r.returncode == 0 and r.stdout.strip().endswith("done"), (r.stdout, r.stderr)


@pytest.mark.parametrize("bash", _bash_candidates())
def test_ui_smoke_stop_job_reaps_a_child_that_ignores_sigterm(bash: str) -> None:
    """A helper job (``log stream``, the ``osascript`` quitter) is stopped AND reaped before the
    script moves on: ``stop_job`` escalates to SIGKILL after its bounded wait and returns only once
    the job has exited, so it cannot outlive the step that started it."""
    r = _run_signal_script(
        bash,
        """( trap '' TERM; exec sleep 30 ) &
helper=$!
sleep 0.2
stop_job "$helper"
job_running "$helper" && { echo "still a running job"; exit 7; }
ps -p "$helper" >/dev/null 2>&1 && { echo "still alive after stop_job"; exit 8; }
sleep 30 &
quick=$!
stop_job "$quick"
ps -p "$quick" >/dev/null 2>&1 && { echo "quick child still alive"; exit 9; }
""",
    )
    assert r.returncode == 0 and r.stdout.strip().endswith("done"), (r.stdout, r.stderr)
