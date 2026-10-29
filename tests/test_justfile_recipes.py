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

import dataclasses
import importlib.util
import os
import re
import shutil
import signal
import subprocess
import time
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


def test_app_open_quits_by_built_id_and_waits_before_opening():
    """``BUNDLE_ID`` overrides the built app's identifier, so ``app-open`` must quit
    whatever id the build wrote, not a hardcoded default; and the quit is asynchronous,
    so it must wait for the exit before ``open`` (else ``open`` re-activates the old copy)."""
    body = _recipe_body("app-open")
    assert "CFBundleIdentifier" in body, body
    assert 'quit app id "ai.pipecat.ServiceToolbar"' not in body, body
    assert body.index('macos/scripts/quit_app.sh "$id"') < body.index('open "$app"'), body


def test_app_open_resolves_the_identity_before_the_build():
    """``app-open`` takes its identity from the shared resolver (its fallback behaviour is
    tested on the script below) and exports it before the build: a plain assignment never
    reaches build_app.sh, and ``export X="$(…)"`` would hide the resolver's failure."""
    body = _recipe_body("app-open")
    assign = 'SIGN_IDENTITY="$(macos/scripts/resolve_sign_identity.sh)"'
    assert assign in body, body
    assert body.index(assign) < body.index("export SIGN_IDENTITY"), body
    assert body.index("export SIGN_IDENTITY") < body.index("macos/scripts/build_app.sh"), body
    assert "Code Signing" not in body, body  # the default name lives in the resolver only


def test_app_install_signs_stably_and_quits_by_built_id():
    """``app-install`` must not ship the ad-hoc default (cdhash-bound, so every rebuild
    resets TCC grants): it requires the resolved identity before the build. It must quit
    the id the build wrote and wait for it to exit before touching the bundle, and must
    replace the installed copy (staged + verified first) rather than ditto-merge into it."""
    body = _recipe_body("app-install")
    assign = 'SIGN_IDENTITY="$(macos/scripts/resolve_sign_identity.sh --require)"'
    assert assign in body, body
    assert body.index(assign) < body.index("export SIGN_IDENTITY"), body
    assert body.index("export SIGN_IDENTITY") < body.index("macos/scripts/build_app.sh"), body
    assert "Code Signing" not in body, body  # the default name lives in the resolver only
    assert "CFBundleIdentifier" in body, body
    assert 'quit app id "ai.pipecat.ServiceToolbar"' not in body, body
    # Quit (and wait for the exit) before the installed copy is removed.
    assert body.index('macos/scripts/quit_app.sh "$id"') < body.index('rm -rf "${dest:?}'), body
    # Stage + verify, then remove the old copy, then move the new one in.
    stage = body.index('ditto "$src" "$stage/$name"')
    assert stage < body.index("codesign --verify") < body.index('rm -rf "${dest:?}'), body
    assert body.index('rm -rf "${dest:?}') < body.index('mv "$stage/$name"'), body


# --- quit_app.sh: the shared quit-and-wait step ---------------------------------

_QUIT_APP = REPO_ROOT / "macos" / "scripts" / "quit_app.sh"


@dataclasses.dataclass
class _QuitRun:
    result: subprocess.CompletedProcess
    sent: bool  # the quit request was sent
    polls: int  # running checks after the quit was sent
    orphans: list[int]  # stub osascript pids still alive after the script exited
    leftovers: list[str]  # entries left in the script's TMPDIR
    elapsed: float


def _run_quit_app(
    tmp_path: Path,
    *,
    quit_ends_it: bool | None,
    exit_after_polls: int = 0,
    wait: str = "5",
    args=("x.y.Z",),
    first_answer: str = "",
    after_quit: str = "",
    quit_hangs: bool = False,
    probe_secs: float = 0,
    abort_after_quit: bool = False,
    term_when: str = "",
    ignore_term: bool = False,
) -> _QuitRun:
    """Run quit_app.sh against a stub ``osascript``.

    ``quit_ends_it`` None: the app is never running. True: running until it has been sent
    ``quit`` and then polled ``exit_after_polls`` more times (a slow exit). False: running
    forever (a refused quit). ``first_answer`` / ``after_quit`` replace the running check's
    answer before / after the quit: ``error`` (osascript fails), ``garbage`` (an answer that
    is neither true nor false), ``unknown`` (-1728) or ``hang``. ``quit_hangs``: the quit
    event never returns. ``probe_secs``: each running check takes that long (osascript is not
    instant). ``abort_after_quit``: the main loop's ``sleep 0.1`` fails once the quit was
    sent, so set -e aborts the script. ``term_when`` ``quit`` / ``probe``: SIGTERM the script
    once the quit was sent / the first running check started. ``ignore_term``: every
    osascript ignores SIGTERM (so only SIGKILL ends a hung one). Every stub records its pid.
    """
    state = tmp_path / "running"
    sent = tmp_path / "quit-sent"
    polls = tmp_path / "polls"
    pids = tmp_path / "pids"
    tmpdir = tmp_path / "tmp"
    tmpdir.mkdir()
    if quit_ends_it is not None:
        state.write_text("1")
    ends = "1" if quit_ends_it else ""
    odd = {
        "": ":",
        "error": "echo 'execution error: boom (-1712)' >&2; exit 1",
        "garbage": "echo 'missing value'; exit 0",
        "unknown": 'echo "syntax error: Can\'t get application id. (-1728)" >&2; exit 1',
        "hang": "exec sleep 60",
    }
    bindir = tmp_path / "bin"
    bindir.mkdir()
    stub = bindir / "osascript"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        f'echo $$ >> "{pids}"\n' + ("trap '' TERM\n" if ignore_term else "") + 'case "$2" in\n'
        '  *"is running"*)\n'
        + (f"    sleep {probe_secs}\n" if probe_secs else "")
        + f'    if [[ -e "{sent}" ]]; then {odd[after_quit]}; else {odd[first_answer]}; fi\n'
        f'    [[ -e "{state}" ]] || {{ echo false; exit 0; }}\n'
        f'    if [[ -e "{sent}" ]]; then\n'
        f'      n=$(cat "{polls}" 2>/dev/null || echo 0); echo $((n + 1)) > "{polls}"\n'
        f'      if [[ -n "{ends}" ]] && (( n >= {exit_after_polls} )); then rm -f "{state}"; echo false; exit 0; fi\n'
        "    fi\n"
        "    echo true ;;\n"
        f'  *"quit app id"*) : > "{sent}"' + ("; exec sleep 60" if quit_hangs else "") + " ;;\n"
        "esac\n"
    )
    stub.chmod(0o755)
    if abort_after_quit:
        sleep_stub = bindir / "sleep"
        sleep_stub.write_text(
            "#!/bin/bash\n"
            f'if [[ "$1" == 0.1 && -e "{sent}" ]]; then exit 1; fi\n'
            'exec /bin/sleep "$@"\n'
        )
        sleep_stub.chmod(0o755)
    env = {"PATH": f"{bindir}:/usr/bin:/bin", "QUIT_WAIT_SECS": wait, "TMPDIR": str(tmpdir)}
    start = time.monotonic()
    proc = subprocess.Popen(
        ["/bin/bash", str(_QUIT_APP), *args],
        env=env,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    try:
        if term_when:
            trigger = {"quit": sent, "probe": pids}[term_when]
            while not trigger.exists() and proc.poll() is None:
                assert time.monotonic() - start < 15, "the SIGTERM trigger never fired"
                time.sleep(0.02)
            time.sleep(0.2)  # let the pending osascript settle into its wait
            proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=45)
    finally:
        if proc.poll() is None:
            proc.kill()
            proc.communicate()
    elapsed = time.monotonic() - start
    orphans = []
    for pid in (int(p) for p in pids.read_text().split()) if pids.exists() else ():
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        orphans.append(pid)
        os.kill(pid, signal.SIGKILL)  # don't leave a 60s sleep behind the test
    result = subprocess.CompletedProcess(proc.args, proc.returncode, out, err)
    return _QuitRun(
        result=result,
        sent=sent.exists(),
        polls=int(polls.read_text()) if polls.exists() else 0,
        orphans=orphans,
        leftovers=sorted(p.name for p in tmpdir.iterdir()),
        elapsed=elapsed,
    )


def test_quit_app_does_nothing_when_the_app_is_not_running(tmp_path):
    """Sending ``quit`` to a stopped app can launch it just to quit it."""
    run = _run_quit_app(tmp_path, quit_ends_it=None)
    assert run.result.returncode == 0, run.result.stderr
    assert not run.sent


def test_quit_app_waits_for_a_running_app_to_exit(tmp_path):
    """The exit lands a few polls after the quit: returning right after sending it would
    leave the old process alive for the caller's ``open`` / bundle replacement."""
    run = _run_quit_app(tmp_path, quit_ends_it=True, exit_after_polls=3)
    assert run.result.returncode == 0, run.result.stderr
    assert run.sent
    assert run.polls == 4, run.polls  # three "still running" answers, then the exit


def test_quit_app_fails_when_the_quit_is_refused(tmp_path):
    """A surviving process must stop the caller before it opens or replaces the bundle."""
    run = _run_quit_app(tmp_path, quit_ends_it=False, wait="3")
    assert run.result.returncode == 1, (run.result.returncode, run.result.stderr)
    assert run.sent
    assert "did not quit within 3s" in run.result.stderr


def test_quit_app_failure_mentions_a_pending_quit_confirmation(tmp_path):
    """The app's Quit guard can hold the quit behind a confirmation dialog, so the timeout
    message must point the operator at it. Exit status and the one-deadline wait are
    unchanged (see the neighbouring tests)."""
    run = _run_quit_app(tmp_path, quit_ends_it=False, wait="2")
    assert run.result.returncode == 1, (run.result.returncode, run.result.stderr)
    assert run.sent
    assert "did not quit within 2s" in run.result.stderr
    assert "a quit confirmation may be waiting in the app" in run.result.stderr


def test_quit_app_waits_at_least_the_stated_time(tmp_path):
    """bash's SECONDS ticks on whole-second boundaries: a ``SECONDS + wait`` deadline gave
    up anywhere from 0 to ``wait`` seconds in, so ``QUIT_WAIT_SECS=1`` could fail in 0.1s.
    Only the lower bound is timed tightly; the ceiling just catches an unbounded wait."""
    run = _run_quit_app(tmp_path, quit_ends_it=False, wait="1")
    assert run.result.returncode == 1, run.result.stderr
    assert 1.0 <= run.elapsed < 15, run.elapsed


def test_quit_app_wait_is_bounded_by_the_clock_not_the_poll_count(tmp_path):
    """Each poll spawns osascript, which takes a while (0.3s here): a poll-count bound
    (wait x 10 polls of 0.1s sleep, 30 here) overshoots the stated wait; the clock stops at
    it after about 3 / 0.4 polls. Counted, not timed: a loaded runner only lowers the count."""
    run = _run_quit_app(tmp_path, quit_ends_it=False, wait="3", probe_secs=0.3)
    assert run.result.returncode == 1, run.result.stderr
    assert run.elapsed >= 3.0, run.elapsed
    assert 1 <= run.polls < 15, run.polls


@pytest.mark.parametrize(
    "hang",
    [
        dict(quit_ends_it=True, first_answer="hang"),  # the first running check
        dict(quit_ends_it=False, quit_hangs=True),  # the quit request
        dict(quit_ends_it=False, after_quit="hang"),  # a running check after the quit
        dict(quit_ends_it=False, quit_hangs=True, after_quit="hang"),  # both at once
    ],
    ids=["probe", "quit", "probe-after-quit", "both"],
)
def test_quit_app_stops_an_osascript_that_ignores_sigterm(tmp_path, hang):
    """A hung osascript that ignores SIGTERM: a bare ``kill`` then ``wait`` blocked on it for
    its whole 60s sleep, past the deadline. It gets SIGKILL after a short grace, so the script
    still gives up at the deadline and leaves nothing running. The lower bound is the stated
    wait; the ceiling only catches the 60s hang (a loaded runner may be slow)."""
    run = _run_quit_app(tmp_path, wait="3", ignore_term=True, **hang)
    assert run.result.returncode == 1, (run.result.returncode, run.result.stderr)
    assert run.orphans == [], f"osascript left running: {run.orphans}"
    assert run.leftovers == [], run.leftovers
    assert 3.0 <= run.elapsed < 15, run.elapsed
    assert "Killed" not in run.result.stderr and "Terminated" not in run.result.stderr, (
        run.result.stderr
    )


@pytest.mark.parametrize(
    "case",
    [
        # (name, stub kwargs, exit code, quit sent, stderr fragment)
        # -- clean exits; the probe answers true / false / -1728 / error / odd / hangs
        ("not running", dict(quit_ends_it=None), 0, False, ""),
        ("exits after quit", dict(quit_ends_it=True, exit_after_polls=1), 0, True, ""),
        ("refused", dict(quit_ends_it=False, wait="3"), 1, True, "did not quit within 3s"),
        ("first check fails", dict(quit_ends_it=True, first_answer="error"), 3, False, "boom"),
        # A fresh build's id is unknown to LaunchServices until it is opened: osascript then
        # fails with -1728, and no app with an unknown id can be running.
        ("id unknown", dict(quit_ends_it=None, first_answer="unknown"), 0, False, ""),
        (
            "first check fails, not running",
            dict(quit_ends_it=None, first_answer="error"),
            3,
            False,
            "boom",
        ),
        (
            "first answer odd",
            dict(quit_ends_it=True, first_answer="garbage"),
            3,
            False,
            "missing value",
        ),
        (
            "first check hangs",
            dict(quit_ends_it=True, first_answer="hang", wait="1"),
            1,
            False,
            "did not say",
        ),
        # -- after the quit, quit request finished
        ("check fails after quit", dict(quit_ends_it=False, after_quit="error"), 3, True, "boom"),
        (
            "answer odd after quit",
            dict(quit_ends_it=False, after_quit="garbage"),
            3,
            True,
            "missing value",
        ),
        (
            "check hangs after quit",
            dict(quit_ends_it=False, after_quit="hang", wait="3"),
            1,
            True,
            "did not quit",
        ),
        # -- after the quit, quit request still pending (hung): every exit path reaps it
        (
            "quit hangs, app stays",
            dict(quit_ends_it=False, quit_hangs=True, wait="3"),
            1,
            True,
            "no answer",
        ),
        (
            # The polls run beside the pending quit request, so the exit still counts.
            "quit hangs, app went",
            dict(quit_ends_it=True, quit_hangs=True),
            0,
            True,
            "",
        ),
        (
            "quit hangs, id unknown after quit",
            dict(quit_ends_it=False, quit_hangs=True, after_quit="unknown"),
            0,
            True,
            "",
        ),
        (
            "quit hangs, check fails after quit (exit 3)",
            dict(quit_ends_it=False, quit_hangs=True, after_quit="error"),
            3,
            True,
            "boom",
        ),
        (
            "quit hangs, answer odd after quit (exit 3)",
            dict(quit_ends_it=False, quit_hangs=True, after_quit="garbage"),
            3,
            True,
            "missing value",
        ),
        (
            "quit hangs, check hangs after quit",
            dict(quit_ends_it=False, quit_hangs=True, after_quit="hang", wait="3"),
            1,
            True,
            "no answer",
        ),
        # -- set -e abort mid-loop
        (
            "set -e abort, quit pending",
            dict(quit_ends_it=False, quit_hangs=True, abort_after_quit=True),
            1,
            True,
            "",
        ),
        (
            "set -e abort, quit finished",
            dict(quit_ends_it=False, abort_after_quit=True),
            1,
            True,
            "",
        ),
        # -- SIGTERM
        (
            "TERM, first check hung",
            dict(quit_ends_it=True, first_answer="hang", term_when="probe"),
            143,
            False,
            "",
        ),
        (
            "TERM, quit pending",
            dict(quit_ends_it=False, quit_hangs=True, term_when="quit"),
            143,
            True,
            "",
        ),
        (
            "TERM, quit pending, check hung",
            dict(quit_ends_it=False, quit_hangs=True, after_quit="hang", term_when="quit"),
            143,
            True,
            "",
        ),
        ("TERM, quit finished", dict(quit_ends_it=False, term_when="quit"), 143, True, ""),
        # -- an osascript that ignores SIGTERM: SIGKILL after the grace, on every path
        (
            "first check hangs, ignores TERM",
            dict(quit_ends_it=True, first_answer="hang", wait="1", ignore_term=True),
            1,
            False,
            "did not say",
        ),
        (
            "check hangs after quit, ignores TERM",
            dict(quit_ends_it=False, after_quit="hang", wait="3", ignore_term=True),
            1,
            True,
            "did not quit",
        ),
        (
            "quit hangs, app stays, ignores TERM",
            dict(quit_ends_it=False, quit_hangs=True, wait="3", ignore_term=True),
            1,
            True,
            "no answer",
        ),
        (
            "quit hangs, app went, ignores TERM",
            dict(quit_ends_it=True, quit_hangs=True, ignore_term=True),
            0,
            True,
            "",
        ),
        (
            "set -e abort, quit pending, ignores TERM",
            dict(quit_ends_it=False, quit_hangs=True, abort_after_quit=True, ignore_term=True),
            1,
            True,
            "",
        ),
        (
            "TERM, first check hung, ignores TERM",
            dict(quit_ends_it=True, first_answer="hang", term_when="probe", ignore_term=True),
            143,
            False,
            "",
        ),
        (
            "TERM, quit pending, check hung, ignores TERM",
            dict(
                quit_ends_it=False,
                quit_hangs=True,
                after_quit="hang",
                term_when="quit",
                ignore_term=True,
            ),
            143,
            True,
            "",
        ),
        # -- arguments
        (
            "leading-zero wait 08",
            dict(quit_ends_it=True, exit_after_polls=1, wait="08"),
            0,
            True,
            "",
        ),
        (
            "leading-zero wait 09",
            dict(quit_ends_it=True, exit_after_polls=1, wait="09"),
            0,
            True,
            "",
        ),
        ("non-numeric wait", dict(quit_ends_it=True, wait="soon"), 2, False, "whole seconds"),
        ("negative wait", dict(quit_ends_it=True, wait="-1"), 2, False, "whole seconds"),
        ("no bundle id", dict(quit_ends_it=None, args=()), 2, False, "usage"),
    ],
    ids=lambda c: c[0],
)
def test_quit_app_state_space(tmp_path, case):
    """Every (who exits x quit request x running check) cell. Only a clean ``false`` or
    -1728 reads as "not running": an osascript failure or odd answer must stop the caller
    (exit 3) rather than let it open or replace the bundle under a live copy. On every exit
    path (0-3, set -e abort, SIGTERM) no osascript the script started is left running and
    its temp dir is gone, and nothing outlasts the wait."""
    _, kwargs, code, quit_sent, fragment = case
    run = _run_quit_app(tmp_path, **kwargs)
    assert run.orphans == [], f"osascript left running: {run.orphans}"
    assert run.leftovers == [], f"temp dir left behind: {run.leftovers}"
    assert run.result.returncode == code, (run.result.returncode, run.result.stderr)
    assert run.sent == quit_sent
    assert fragment in run.result.stderr, run.result.stderr
    # A hung stub sleeps 60s: anything near that is an unbounded osascript call.
    assert run.elapsed < 20, "an osascript call outlasted QUIT_WAIT_SECS"


def test_quit_app_signals_its_children_only_by_job_spec() -> None:
    """Every signal quit_app.sh sends names a job spec from ``live_job`` inside ``stop_child``,
    never a pid: ``kill -0 $pid`` / ``kill $pid`` on a child bash already reaped can hit an
    unrelated process that took the pid."""
    code = [ln.split("#", 1)[0] for ln in _QUIT_APP.read_text().splitlines()]
    kills = [ln.strip() for ln in code if re.search(r"\bkill\b", ln)]
    assert kills == [
        'kill -TERM "%$live" || true',
        '[[ -z "$live" ]] || kill -KILL "%$live" || true',
    ], kills
    assert kills[0] in _shell_functions(_QUIT_APP, "stop_child")


# --- has_sign_identity.sh: the keychain probe behind resolve_sign_identity.sh ------

_HAS_IDENTITY = REPO_ROOT / "macos" / "scripts" / "has_sign_identity.sh"
_RESOLVE_IDENTITY = REPO_ROOT / "macos" / "scripts" / "resolve_sign_identity.sh"

_CS_HASH = "AAC7E2B994E42BED55FAD8E292CF3BA1A4629CEE"  # "Code Signing"
_CS2_HASH = "FEDCBA9876543210FEDCBA9876543210FEDCBA98"  # a second "Code Signing"
_FOO_HASH = "0123456789ABCDEF0123456789ABCDEF01234567"  # "Developer ID Application: Foo …"

# `security find-identity -p codesigning` on a keychain with no identity at all: the
# "Policy: Code Signing" header is printed regardless of what the keychain holds.
_NO_IDENTITIES = (
    "Policy: Code Signing\n  Matching identities\n     0 identities found\n\n"
    "  Valid identities only\n     0 valid identities found\n"
)
_ONE_UNTRUSTED = (
    "Policy: Code Signing\n  Matching identities\n"
    f'  1) {_CS_HASH} "Code Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
    "     1 identities found\n\n  Valid identities only\n     0 valid identities found\n"
)
_TWO = (
    "Policy: Code Signing\n  Matching identities\n"
    f'  1) {_CS_HASH} "Code Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
    f'  2) {_FOO_HASH} "Developer ID Application: Foo (TEAM123)"\n'
    "     2 identities found\n\n  Valid identities only\n"
    f'  1) {_FOO_HASH} "Developer ID Application: Foo (TEAM123)"\n'
    "     1 valid identities found\n"
)
# Two identities with the same name (e.g. a re-created self-signed certificate).
_DUP = (
    "Policy: Code Signing\n  Matching identities\n"
    f'  1) {_CS_HASH} "Code Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
    f'  2) {_CS2_HASH} "Code Signing" (CSSMERR_TP_NOT_TRUSTED)\n'
    "     2 identities found\n\n  Valid identities only\n     0 valid identities found\n"
)
# A name that holds another identity's full hash: 40 hex digits are a hash, never a name.
_HEX_NAME = (
    "Policy: Code Signing\n  Matching identities\n"
    f'  1) {_CS_HASH} "Build {_FOO_HASH}" (CSSMERR_TP_NOT_TRUSTED)\n'
    "     1 identities found\n\n  Valid identities only\n     0 valid identities found\n"
)
_SECURITY_FAILS = None  # the stub exits non-zero, as `security` does on a keychain error
_LISTING_IDS = {
    _NO_IDENTITIES: "empty",
    _ONE_UNTRUSTED: "one-untrusted",
    _TWO: "two",
    _DUP: "two-same-name",
    _HEX_NAME: "hex-in-name",
    None: "fails",
}


@pytest.fixture(scope="module")
def security_bin(tmp_path_factory) -> Path:
    """One stub ``security`` for the module: macOS scans each new executable on its first
    run (about 0.3s), so a stub per test would cost that for every cell. It prints the
    listing file named by ``STUB_SECURITY_LISTING``, or fails like a locked keychain when
    that is empty, and records each call in ``STUB_SECURITY_CALLS``."""
    bindir = tmp_path_factory.mktemp("security-bin")
    stub = bindir / "security"
    stub.write_text(
        "#!/usr/bin/env bash\n"
        'echo x >> "$STUB_SECURITY_CALLS"\n'
        'if [[ -n "${STUB_SECURITY_LISTING:-}" ]]; then cat "$STUB_SECURITY_LISTING"; exit 0; fi\n'
        'echo "security: SecKeychainSearchCopyNext: keychain locked" >&2; exit 45\n'
    )
    stub.chmod(0o755)
    return bindir


def _run_identity_script(
    bindir: Path,
    tmp_path: Path,
    script: Path,
    listing: str | None,
    *args: str,
    env_extra=None,
):
    listing_file = tmp_path / "listing"
    calls = tmp_path / "security-calls"
    if listing is not None:
        listing_file.write_text(listing)
    env = {
        "PATH": f"{bindir}:/usr/bin:/bin",
        "STUB_SECURITY_LISTING": "" if listing is None else str(listing_file),
        "STUB_SECURITY_CALLS": str(calls),
        **(env_extra or {}),
    }
    result = subprocess.run(
        ["/bin/bash", str(script), *args], env=env, capture_output=True, text=True, timeout=30
    )
    return result, calls.exists()


def _run_has_identity(bindir: Path, tmp_path: Path, listing: str | None, *args: str):
    return _run_identity_script(bindir, tmp_path, _HAS_IDENTITY, listing, *args)[0]


def test_has_sign_identity_ignores_the_policy_header(security_bin, tmp_path):
    """The listing's own ``Policy: Code Signing`` line must not count as an identity: it made
    ``app-open`` pick an identity that did not exist and fail at the last build step."""
    assert _run_has_identity(security_bin, tmp_path, _NO_IDENTITIES, "Code Signing").returncode == 1


def test_has_sign_identity_finds_an_untrusted_self_signed_identity(security_bin, tmp_path):
    """The non -v listing is searched: codesign signs with a self-signed, untrusted identity."""
    assert _run_has_identity(security_bin, tmp_path, _ONE_UNTRUSTED, "Code Signing").returncode == 0


def test_has_sign_identity_matches_a_partial_name_and_rejects_another(security_bin, tmp_path):
    assert _run_has_identity(security_bin, tmp_path, _ONE_UNTRUSTED, "Code Sign").returncode == 0
    assert (
        _run_has_identity(
            security_bin, tmp_path, _ONE_UNTRUSTED, "Developer ID Application"
        ).returncode
        == 1
    )


def test_has_sign_identity_requires_a_name(security_bin, tmp_path):
    assert _run_has_identity(security_bin, tmp_path, _ONE_UNTRUSTED).returncode == 2


@pytest.mark.parametrize(
    ("listing", "identity", "code"),
    [
        # How the identity is given x what the keychain holds. codesign --sign takes the full
        # 40-hex SHA-1 (any case, decided on the hashes alone) or a case-insensitive
        # substring of a name; nothing else names one. Advisory: ambiguity is codesign's call.
        (_ONE_UNTRUSTED, "Code Signing", 0),  # exact name
        (_ONE_UNTRUSTED, "Code Sign", 0),  # substring of the name
        (_ONE_UNTRUSTED, "code signing", 0),  # name, lower case (codesign ignores case)
        (_ONE_UNTRUSTED, "CODE SIGNING", 0),  # name, upper case
        (_ONE_UNTRUSTED, "cOdE sIgN", 0),  # substring, odd case
        (_ONE_UNTRUSTED, "Code Signing!", 1),  # longer than the name
        (_ONE_UNTRUSTED, _CS_HASH, 0),  # full hash
        (_ONE_UNTRUSTED, _CS_HASH.lower(), 0),  # full hash, lower case
        (_ONE_UNTRUSTED, _CS_HASH[:20].lower() + _CS_HASH[20:], 0),  # full hash, mixed case
        (_ONE_UNTRUSTED, "AAC7E2B9", 1),  # partial hash
        (_ONE_UNTRUSTED, _CS_HASH[:-1], 1),  # 39 digits
        (_ONE_UNTRUSTED, _CS_HASH + "0", 1),  # 41 digits
        (_ONE_UNTRUSTED, f" {_CS_HASH}", 1),  # not exactly the hash
        (_ONE_UNTRUSTED, _FOO_HASH, 1),  # another keychain's hash
        (_ONE_UNTRUSTED, "NOT_TRUSTED", 1),  # status text
        (_ONE_UNTRUSTED, "CSSMERR_TP_NOT_TRUSTED", 1),
        (_ONE_UNTRUSTED, "cssmerr_tp_not_trusted", 1),  # status text, any case
        (_ONE_UNTRUSTED, "Policy", 1),  # header text
        (_ONE_UNTRUSTED, "policy: code signing", 1),  # the header line, any case
        (_TWO, "Developer ID Application: Foo (TEAM123)", 0),
        (_TWO, "Developer ID Application: Foo", 0),
        (_TWO, "TEAM123", 0),  # inside the quoted name
        (_TWO, "0123456789ABCDEF", 1),  # partial hash, still rejected
        (_TWO, _FOO_HASH, 0),  # the full hash of the same identity is accepted
        (_TWO, _FOO_HASH.lower(), 0),
        (_TWO, "developer id application: foo (team123)", 0),  # whole name, lower case
        (_TWO, "Apple Development", 1),
        (_DUP, "Code Signing", 0),  # both match the name
        (_DUP, _CS_HASH, 0),  # the hash picks one
        (_DUP, _CS2_HASH.lower(), 0),
        (_DUP, "code signing", 0),
        (_DUP, _FOO_HASH, 1),
        (_HEX_NAME, _CS_HASH, 0),  # the listed hash
        (_HEX_NAME, _FOO_HASH, 1),  # 40 hex inside a name: a hash, and not a listed one
        (_HEX_NAME, _FOO_HASH.lower(), 1),
        (_HEX_NAME, f"Build {_FOO_HASH}", 0),  # the whole name (not 40 hex): a name match
        (_HEX_NAME, f"build {_FOO_HASH.lower()}", 0),
        (_HEX_NAME, _FOO_HASH[:16], 0),  # fewer than 40 hex digits read as a name, as codesign
        (_NO_IDENTITIES, "Code Signing", 1),
        (_NO_IDENTITIES, "identities found", 1),
        (_NO_IDENTITIES, _CS_HASH, 1),
        (_NO_IDENTITIES, "code signing", 1),
        # A failing `security` is not "no identity": the caller must not fall back to ad hoc.
        (_SECURITY_FAILS, "Code Signing", 2),
        (_SECURITY_FAILS, "Developer ID Application: Foo", 2),
        (_SECURITY_FAILS, _FOO_HASH, 2),
        (_SECURITY_FAILS, "code signing", 2),
    ],
    ids=lambda v: _LISTING_IDS.get(v, str(v)) if isinstance(v, str) or v is None else str(v),
)
def test_has_sign_identity_state_space(security_bin, tmp_path, listing, identity, code):
    result = _run_has_identity(security_bin, tmp_path, listing, identity)
    assert result.returncode == code, (result.returncode, result.stderr)
    if listing is _SECURITY_FAILS:
        assert "security find-identity" in result.stderr, result.stderr


# --- resolve_sign_identity.sh: how app-open / app-install choose their identity ----

# The SIGN_IDENTITY values tried, by label (None: unset).
_EXPLICIT = {
    "unset": None,
    "empty": "",
    "adhoc": "-",
    "exact": "Developer ID Application: Foo (TEAM123)",
    "substr": "Developer ID Application: Foo",
    "hash": _FOO_HASH,
    "hash-lower": _FOO_HASH.lower(),
    "hash-dup": _CS2_HASH,
    "lower": "developer id application: foo",
    "cs-lower": "code signing",
    "partial": "0123456789ABCDEF",
    "status": "CSSMERR_TP_NOT_TRUSTED",
    "absent": "Apple Development: Nope",
}
_KEYCHAINS = {
    "empty": _NO_IDENTITIES,
    "one": _ONE_UNTRUSTED,
    "two": _TWO,
    "dup": _DUP,
    "fails": _SECURITY_FAILS,
}
# Expected outcome per (SIGN_IDENTITY, mode), one token per keychain in _KEYCHAINS order.
# "=X": prints X without asking the keychain. "?X": asks the keychain, then prints X.
# "!1": not in the keychain (--require). "!2": the keychain query failed. X is a label of
# _EXPLICIT, "cs" ("Code Signing", the default) or "-" (ad hoc). Written out, not computed.
_RESOLVED = {
    # fallback (just app-open): an explicit value wins as is; unset, the default or ad hoc.
    ("unset", "fallback"): ("?-", "?cs", "?cs", "?cs", "!2"),
    ("empty", "fallback"): ("?-", "?cs", "?cs", "?cs", "!2"),
    ("adhoc", "fallback"): ("=-", "=-", "=-", "=-", "=-"),
    ("exact", "fallback"): ("=exact", "=exact", "=exact", "=exact", "=exact"),
    ("substr", "fallback"): ("=substr", "=substr", "=substr", "=substr", "=substr"),
    ("hash", "fallback"): ("=hash", "=hash", "=hash", "=hash", "=hash"),
    ("hash-lower", "fallback"): (
        "=hash-lower",
        "=hash-lower",
        "=hash-lower",
        "=hash-lower",
        "=hash-lower",
    ),
    ("hash-dup", "fallback"): ("=hash-dup", "=hash-dup", "=hash-dup", "=hash-dup", "=hash-dup"),
    ("lower", "fallback"): ("=lower", "=lower", "=lower", "=lower", "=lower"),
    ("cs-lower", "fallback"): ("=cs-lower", "=cs-lower", "=cs-lower", "=cs-lower", "=cs-lower"),
    ("partial", "fallback"): ("=partial", "=partial", "=partial", "=partial", "=partial"),
    ("status", "fallback"): ("=status", "=status", "=status", "=status", "=status"),
    ("absent", "fallback"): ("=absent", "=absent", "=absent", "=absent", "=absent"),
    # --require (just app-install): no ad-hoc fallback; the identity must be in the keychain.
    ("unset", "require"): ("!1", "?cs", "?cs", "?cs", "!2"),
    ("empty", "require"): ("!1", "?cs", "?cs", "?cs", "!2"),
    ("adhoc", "require"): ("=-", "=-", "=-", "=-", "=-"),
    ("exact", "require"): ("!1", "!1", "?exact", "!1", "!2"),
    ("substr", "require"): ("!1", "!1", "?substr", "!1", "!2"),
    ("hash", "require"): ("!1", "!1", "?hash", "!1", "!2"),
    ("hash-lower", "require"): ("!1", "!1", "?hash-lower", "!1", "!2"),
    ("hash-dup", "require"): ("!1", "!1", "!1", "?hash-dup", "!2"),
    ("lower", "require"): ("!1", "!1", "?lower", "!1", "!2"),
    ("cs-lower", "require"): ("!1", "?cs-lower", "?cs-lower", "?cs-lower", "!2"),
    ("partial", "require"): ("!1", "!1", "!1", "!1", "!2"),
    ("status", "require"): ("!1", "!1", "!1", "!1", "!2"),
    ("absent", "require"): ("!1", "!1", "!1", "!1", "!2"),
}
_RESOLVE_CELLS = [
    pytest.param(explicit, mode, keychain, token, id=f"{explicit}-{mode}-{keychain}")
    for (explicit, mode), tokens in _RESOLVED.items()
    for keychain, token in zip(_KEYCHAINS, tokens, strict=True)
]


def test_resolve_sign_identity_table_covers_the_state_space():
    assert {e for e, _ in _RESOLVED} == set(_EXPLICIT)
    assert len(_RESOLVED) == 2 * len(_EXPLICIT)


@pytest.mark.parametrize(("explicit", "mode", "keychain", "token"), _RESOLVE_CELLS)
def test_resolve_sign_identity_state_space(security_bin, tmp_path, explicit, mode, keychain, token):
    """Every (SIGN_IDENTITY, keychain, mode) cell: an explicit value wins; unset, app-open
    gets ``Code Signing`` when present else ad hoc, app-install (``--require``) fails
    before the build unless the keychain has the identity (by name or full hash); a failing
    keychain query is an error, never a silent ad-hoc build."""
    value = _EXPLICIT[explicit]
    env = {} if value is None else {"SIGN_IDENTITY": value}
    args = ("--require",) if mode == "require" else ()
    result, asked = _run_identity_script(
        security_bin, tmp_path, _RESOLVE_IDENTITY, _KEYCHAINS[keychain], *args, env_extra=env
    )
    kind, label = token[0], token[1:]
    if kind == "!":
        assert result.returncode == int(label), (result.returncode, result.stderr)
        assert result.stdout == ""
        assert asked
        if label == "1":
            assert "no code-signing identity matching" in result.stderr, result.stderr
        return
    printed = {"cs": "Code Signing", "-": "-"}.get(label, _EXPLICIT.get(label))
    assert result.returncode == 0, (result.returncode, result.stderr)
    assert result.stdout == f"{printed}\n", result.stdout
    assert asked == (kind == "?")


def test_resolve_sign_identity_requires_a_hash_to_be_a_listed_hash(security_bin, tmp_path):
    """A full hash that only appears inside an identity's name is not that identity: codesign
    reads 40 hex digits as a hash, so ``--require`` must not let the build start on it."""
    for value in (_FOO_HASH, _FOO_HASH.lower()):
        result, asked = _run_identity_script(
            security_bin,
            tmp_path,
            _RESOLVE_IDENTITY,
            _HEX_NAME,
            "--require",
            env_extra={"SIGN_IDENTITY": value},
        )
        assert (result.returncode, result.stdout, asked) == (1, "", True), result.stderr


def test_resolve_sign_identity_rejects_unknown_arguments(security_bin, tmp_path):
    for args in (("--bogus",), ("--require", "extra")):
        result, _ = _run_identity_script(security_bin, tmp_path, _RESOLVE_IDENTITY, _TWO, *args)
        assert result.returncode == 2, (args, result.stderr)
        assert result.stdout == ""


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


def _ui_smoke_code() -> str:
    return "\n".join(
        ln for ln in _UI_SMOKE.read_text().splitlines() if not ln.lstrip().startswith("#")
    )


def test_ui_smoke_disables_restore_on_launch_by_default() -> None:
    # Without it a developer's persisted wanted set would start real servers during the smoke.
    code = _ui_smoke_code()
    assert re.search(r'-restoreOnLaunch "\$\{RESTORE:-NO\}"|-restoreOnLaunch NO', code)


def test_ui_smoke_external_step_seeds_the_wanted_set_and_restores() -> None:
    code = _ui_smoke_code()
    assert "-restore.wanted" in code, "the external step must seed the wanted set"
    assert re.search(r"RESTORE=YES|-restoreOnLaunch YES", code), (
        "the external step must turn restore on"
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


def _shell_functions(script: Path, *names: str) -> str:
    """The named shell functions, verbatim from ``script`` (to run them without the script).
    A function ends at the first unindented ``}``, which may carry a redirection."""
    text = script.read_text()
    out = []
    for name in names:
        m = re.search(rf"^{name}\(\) \{{\n.*?^\}}[^\n]*\n", text, re.DOTALL | re.MULTILINE)
        assert m is not None, f"{name}() not found in {script.name}"
        out.append(m.group(0))
    return "\n".join(out)


def _ui_smoke_functions(*names: str) -> str:
    """The named shell functions, verbatim from ui_smoke.sh."""
    return _shell_functions(_UI_SMOKE, *names)


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


_QUIT_APP_HELPERS = ("live_job", "stop_child", "stop_quit", "cleanup")


@pytest.mark.parametrize("bash", _bash_candidates())
def test_quit_app_never_signals_a_pid_that_is_no_longer_its_child(bash: str) -> None:
    """quit_app.sh's stop helpers against (a) its own pending osascript, even one that ignores
    SIGTERM, which they stop and reap, and (b) a pending pid whose child has exited and been
    reaped and which now names an unrelated process (pid reuse): they must not signal it."""
    stranger = subprocess.Popen(["sleep", "30"])
    try:
        script = f"""set -euo pipefail
{_shell_functions(_QUIT_APP, *_QUIT_APP_HELPERS)}
tmp="$(mktemp -d)"; quit_err=""; probe_pid=""; quit_pid=""; live=""
( trap '' TERM; exec sleep 30 ) &
probe_pid=$!
( trap '' TERM; exec sleep 30 ) &
quit_pid=$!
own="$probe_pid $quit_pid"
sleep 0.2
live_job "$probe_pid"
[[ -n "$live" ]] || {{ echo "live_job found no job"; exit 2; }}
cleanup
set -e
for p in $own; do ps -p "$p" >/dev/null 2>&1 && {{ echo "own child $p still alive"; exit 3; }}; done
[[ "$quit_err" == "the quit request got no answer" ]] || {{ echo "quit_err: $quit_err"; exit 4; }}
[[ ! -e "$tmp" ]] || {{ echo "cleanup left $tmp"; exit 6; }}
tmp="$(mktemp -d)"  # cleanup removed it; the helpers list jobs through it
sleep 0.1 &
probe_pid=$!
sleep 0.1 &
quit_pid=$!
sleep 0.5
live_job "$probe_pid"
[[ -z "$live" ]] || {{ echo "a reaped child counts as live"; exit 5; }}
probe_pid={stranger.pid}
quit_pid={stranger.pid}
cleanup
tmp="$(mktemp -d)"
stop_child {stranger.pid}
rm -rf "$tmp"
echo done
"""
        r = subprocess.run([bash, "-c", script], capture_output=True, text=True, timeout=30)
        assert r.returncode == 0 and r.stdout.strip().endswith("done"), (r.stdout, r.stderr)
        assert stranger.poll() is None, "a signal reached a process that was not the shell's child"
    finally:
        stranger.kill()
        stranger.wait()
