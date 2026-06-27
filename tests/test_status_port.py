"""Port-aware ``status`` smoke (lean — no mlx, no launchd).

Phase 6's ops surface probes a backend over its canonical ``--host``/``--port``
(the launchd agents bind a loopback TCP port, one per backend). This exercises
that real port-aware status path end to end WITHOUT launchd: start a ``tone``
server (no model needed) on ``127.0.0.1:<free-port>`` as a subprocess, then run
``python -m tts_server status --host 127.0.0.1 --port <p>`` and assert it reports
``backend: tone``. This is the same code path ``just tts-status <backend>`` and
``tts-list`` invoke, minus launchctl.
"""

from __future__ import annotations

import os
import socket
import subprocess
import sys
import time

import pytest


def _free_port() -> int:
    """Reserve an ephemeral loopback port, then release it for the server."""
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _clean_env() -> dict[str, str]:
    # Strip TTS_WS_* so a stray dev-shell override can't redirect the probe.
    return {k: v for k, v in os.environ.items() if not k.startswith("TTS_WS_")}


def _wait_until_listening(port: int, timeout: float = 15.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.settimeout(0.5)
            if s.connect_ex(("127.0.0.1", port)) == 0:
                return True
        time.sleep(0.1)
    return False


def test_status_reports_backend_over_host_port():
    port = _free_port()
    env = _clean_env()
    server = subprocess.Popen(
        [
            sys.executable,
            "-m",
            "tts_server",
            "serve",
            "--backend",
            "tone",
            "--host",
            "127.0.0.1",
            "--port",
            str(port),
            "--log-level",
            "WARNING",
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        env=env,
    )
    try:
        if not _wait_until_listening(port):
            out = ""
            if server.poll() is not None and server.stdout is not None:
                out = server.stdout.read()
            pytest.fail(f"tone server never listened on 127.0.0.1:{port}; output={out!r}")

        r = subprocess.run(
            [
                sys.executable,
                "-m",
                "tts_server",
                "status",
                "--host",
                "127.0.0.1",
                "--port",
                str(port),
                "--timeout",
                "5.0",
            ],
            capture_output=True,
            text=True,
            timeout=20,
            env=env,
        )
        assert r.returncode == 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
        # The port-aware status path resolves the live backend identity.
        assert "backend: tone" in r.stdout, f"stdout={r.stdout!r}"
    finally:
        server.terminate()
        try:
            server.wait(timeout=10)
        except subprocess.TimeoutExpired:
            server.kill()
            server.wait(timeout=5)
