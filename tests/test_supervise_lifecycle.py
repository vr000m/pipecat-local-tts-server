"""Supervised-mode policy lives in ``supervise``; ``server`` only offers hooks — LEAN.

Invariant: ``tts_server.server`` never imports ``tts_server.supervise`` and never
ends the process itself; the ``serve --supervised`` contract (stdout = JSON
lines only, exit codes, stdin-EOF stop, hard exit when the supervisor leaves
mid-startup) is produced by ``supervise.run_supervised`` and holds across the
whole matrix: startup ok / busy port / model-load error / config error /
SIGTERM after ready / SIGTERM during startup / stdin EOF during startup /
stdin EOF after ready.
"""

from __future__ import annotations

import ast
import asyncio
import json
import select
import signal
import socket
import subprocess
import sys
import textwrap
import time
from pathlib import Path

from tts_server.backend import ToneBackend
from tts_server.server import serve

from .test_supervised_cli import _env

SERVER_PY = Path(__file__).resolve().parents[1] / "tts_server" / "server.py"

# Drives ``supervise.run_supervised`` exactly as ``__main__._cmd_serve`` does,
# with a backend whose ``start()`` is controlled by MODE.
_DRIVER = textwrap.dedent(
    """
    import asyncio, sys
    from tts_server import supervise
    from tts_server.backend import ToneBackend
    from tts_server.server import serve

    MODE = sys.argv[1]

    class B(ToneBackend):
        async def start(self):
            if MODE == "fail":
                raise RuntimeError("model.sample_rate is missing")
            if MODE == "slow":
                await asyncio.sleep(60)
            await super().start()

    def run(**hooks):
        if MODE == "config":
            raise SystemExit("tts_server: bad config")
        asyncio.run(serve(B(), host="127.0.0.1", port=0, **hooks))

    supervise.run_supervised(run)
    """
)


def _driver(mode: str) -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, "-c", _DRIVER, mode],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_env(),
    )


def _cli(*args: str) -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, "-m", "tts_server", "serve", "--backend", "tone", *args, "--supervised"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_env(),
    )


def _first_line(proc: subprocess.Popen, timeout: float = 20.0) -> dict:
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    assert ready, "no stdout line in time; stderr:\n" + proc.stderr.read().decode()
    return json.loads(proc.stdout.readline())


def _finish(proc: subprocess.Popen) -> tuple[int, list[dict]]:
    """Exit status and every remaining stdout line (each must be a JSON object)."""
    if proc.stdin is not None and proc.stdin.closed:
        # Python 3.12's communicate() flushes a non-None stdin and raises
        # "flush of closed file" (3.13 checks .closed first).
        proc.stdin = None
    try:
        out, err = proc.communicate(timeout=15)
        proc.stderr_text = err.decode()  # type: ignore[attr-defined]
    finally:
        if proc.poll() is None:
            proc.kill()
    return proc.returncode, [json.loads(line) for line in out.splitlines()]


# --- the dependency points one way ------------------------------------------------


def test_server_module_does_not_import_supervise_or_exit_the_process():
    tree = ast.parse(SERVER_PY.read_text())
    imported = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.ImportFrom):
            imported.add(node.module or "")
            imported.update(f"{node.module or ''}.{a.name}" for a in node.names)
        elif isinstance(node, ast.Import):
            imported.update(a.name for a in node.names)
    assert not {m for m in imported if "supervise" in m}, imported
    exits = [
        n.lineno
        for n in ast.walk(tree)
        if isinstance(n, ast.Attribute) and n.attr in ("_exit", "exit", "abort")
    ]
    assert exits == [], f"server.py ends the process at lines {exits}"


# --- the whole supervised matrix -------------------------------------------------


def test_startup_ok_then_stdin_eof_after_ready_exits_0():
    proc = _cli("--host", "127.0.0.1", "--port", "0")
    ready = _first_line(proc)
    assert ready["event"] == "ready" and ready["port"] > 0 and ready["pid"] == proc.pid
    proc.stdin.close()
    assert _finish(proc) == (0, [])


def test_sigterm_after_ready_exits_0():
    proc = _cli("--host", "127.0.0.1", "--port", "0")
    assert _first_line(proc)["event"] == "ready"
    proc.send_signal(signal.SIGTERM)
    assert _finish(proc) == (0, [])


def test_busy_port_is_one_error_line_exit_1():
    with socket.socket() as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        proc = _cli("--host", "127.0.0.1", "--port", str(busy.getsockname()[1]))
        code, lines = _finish(proc)
    assert code == 1
    assert [(e["event"], e["code"], e["exc_type"]) for e in lines] == [
        ("error", "EADDRINUSE", "OSError")
    ]


def test_model_load_error_is_one_error_line_exit_1():
    code, lines = _finish(_driver("fail"))
    assert code == 1
    assert lines == [
        {
            "event": "error",
            "code": "BackendStartError",
            "message": "model.sample_rate is missing",
            "exc_type": "RuntimeError",
        }
    ]


def test_config_error_is_one_error_line_exit_1():
    code, lines = _finish(_driver("config"))
    assert code == 1
    assert lines == [
        {
            "event": "error",
            "code": "ConfigError",
            "message": "tts_server: bad config",
            "exc_type": "SystemExit",
        }
    ]


def test_stdin_eof_during_startup_exits_0_at_once_with_no_output():
    proc = _driver("slow")
    time.sleep(1.0)  # let it reach the (60 s) backend start
    started = time.monotonic()
    proc.stdin.close()
    code, lines = _finish(proc)
    assert (code, lines) == (0, [])
    assert time.monotonic() - started < 10
    assert "supervisor went away during startup" in proc.stderr_text


def test_sigterm_during_startup_keeps_the_default_action():
    # Signal handlers are installed only once listening (unchanged behaviour), so
    # SIGTERM mid-load takes the default action.
    proc = _driver("slow")
    time.sleep(1.0)
    proc.send_signal(signal.SIGTERM)
    assert _finish(proc) == (-signal.SIGTERM, [])


# --- the abstract hook, in-process ----------------------------------------------


class _StopAtOnce:
    """A lifecycle that asks to stop before the backend starts, and returns from
    ``startup_abandoned`` instead of ending the process."""

    def __init__(self) -> None:
        self.abandoned = 0

    def attach(self, loop, request_stop) -> None:
        loop.call_soon(request_stop)

    def startup_abandoned(self) -> None:
        self.abandoned += 1


async def test_lifecycle_that_returns_lets_start_finish_then_drains():
    class Slow(ToneBackend):
        async def start(self):
            await asyncio.sleep(0.2)
            await super().start()

    lifecycle = _StopAtOnce()
    readies = []

    async def ready(server):
        readies.append(server)

    await asyncio.wait_for(
        serve(
            Slow(),
            host="127.0.0.1",
            port=0,
            install_signal_handlers=False,
            ready=ready,
            lifecycle=lifecycle,
        ),
        timeout=10,
    )
    assert lifecycle.abandoned == 1
    assert readies == []  # never reported ready: it was stopped during startup


async def test_lifecycle_stop_after_ready_is_a_clean_stop():
    stops = []

    class _Later:
        def attach(self, loop, request_stop):
            stops.append(request_stop)

        def startup_abandoned(self):
            raise AssertionError("not abandoned")

    async def ready(server):
        assert server.listening_port()
        stops[0]()

    await asyncio.wait_for(
        serve(
            ToneBackend(),
            host="127.0.0.1",
            port=0,
            install_signal_handlers=False,
            ready=ready,
            lifecycle=_Later(),
        ),
        timeout=10,
    )
