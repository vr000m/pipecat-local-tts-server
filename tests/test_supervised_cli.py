"""``serve --supervised`` — LEAN tests (tone backend, no mlx).

The macOS menu bar app supervises one server per backend through this mode, so
its contract is pinned here:

  * stdout carries exactly one ``{"event": "ready", ...}`` JSON line once the
    listener is bound, and nothing else (logs stay on stderr);
  * closing stdin stops the server cleanly (exit 0), like SIGTERM;
  * a busy port fails fast with ``{"event": "error", "code": "EADDRINUSE"}``;
  * a missing backend extra fails with ``code: "ModuleNotFoundError"``;
  * without ``--supervised`` stdout stays empty (behaviour unchanged).
"""

from __future__ import annotations

import errno
import json
import os
import select
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import pytest

from tts_server import supervise
from tts_server.server import SocketInUseError, SocketPathConflictError


def _env(**extra: str) -> dict[str, str]:
    env = {k: v for k, v in os.environ.items() if not k.startswith(("TTS_WS_", "PIPECAT_TTS_"))}
    env.update(extra)
    return env


def _serve(*args: str, env: dict[str, str] | None = None) -> subprocess.Popen:
    return subprocess.Popen(
        [sys.executable, "-m", "tts_server", "serve", *args, "--supervised"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env or _env(),
    )


def _read_line(proc: subprocess.Popen, timeout: float = 20.0) -> str:
    assert proc.stdout is not None
    ready, _, _ = select.select([proc.stdout], [], [], timeout)
    if not ready:
        proc.kill()
        raise AssertionError(
            "no stdout line within timeout; stderr:\n" + proc.stderr.read().decode()
        )
    return proc.stdout.readline().decode()


def test_ready_line_then_stdin_eof_stops():
    proc = _serve("--backend", "tone", "--host", "127.0.0.1", "--port", "0")
    try:
        event = json.loads(_read_line(proc))
        assert event["event"] == "ready"
        assert event["backend"] == "tone"
        assert event["pid"] == proc.pid
        assert event["socket_path"] is None
        assert event["host"] == "127.0.0.1"
        assert event["rate"] == 24000
        port = event["port"]
        assert isinstance(port, int) and port > 0  # --port 0 reports the real port
        with socket.create_connection(("127.0.0.1", port), timeout=2):
            pass
        assert proc.stdin is not None
        proc.stdin.close()  # the supervisor goes away
        assert proc.wait(timeout=15) == 0
        assert proc.stdout.read() == b""  # nothing after the ready line
    finally:
        if proc.poll() is None:
            proc.kill()


def test_ready_line_reports_socket_path():
    # Short path under /tmp: pytest's tmp_path overflows the AF_UNIX length limit.
    sock_dir = Path(tempfile.mkdtemp(prefix="tts-sup-", dir="/tmp"))
    sock = sock_dir / "tts.sock"
    proc = _serve("--backend", "tone", "--socket-path", str(sock))
    try:
        event = json.loads(_read_line(proc))
        assert event["event"] == "ready"
        assert event["socket_path"] == str(sock)
        assert event["port"] is None and event["host"] is None
        proc.stdin.close()
        assert proc.wait(timeout=15) == 0
    finally:
        if proc.poll() is None:
            proc.kill()
        shutil.rmtree(sock_dir, ignore_errors=True)


def test_port_in_use_reports_eaddrinuse_fast():
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        port = busy.getsockname()[1]
        started = time.monotonic()
        proc = _serve("--backend", "tone", "--host", "127.0.0.1", "--port", str(port))
        try:
            event = json.loads(_read_line(proc))
            assert proc.wait(timeout=15) == 1
        finally:
            if proc.poll() is None:
                proc.kill()
        assert event["event"] == "error"
        assert event["code"] == "EADDRINUSE"
        assert time.monotonic() - started < 10


def test_missing_extra_reports_module_not_found(tmp_path):
    # A stand-in ``mlx_audio`` that fails like an absent extra, whatever is
    # installed on this machine; nothing real is loaded or downloaded.
    fake = tmp_path / "mlx_audio"
    fake.mkdir()
    (fake / "__init__.py").write_text(
        "raise ModuleNotFoundError(\"No module named 'mlx_audio'\", name='mlx_audio')\n"
    )
    proc = _serve(
        "--backend",
        "voxtral_tts",
        "--host",
        "127.0.0.1",
        "--port",
        "0",
        env=_env(PYTHONPATH=str(tmp_path)),
    )
    try:
        event = json.loads(_read_line(proc, timeout=60))
        assert proc.wait(timeout=15) == 1
    finally:
        if proc.poll() is None:
            proc.kill()
    assert event["event"] == "error"
    assert event["code"] == "ModuleNotFoundError"
    assert "mlx_audio" in event["message"]


def test_unsupervised_stdout_stays_empty():
    proc = subprocess.Popen(
        [sys.executable, "-m", "tts_server", "serve", "--backend", "tone"]
        + ["--host", "127.0.0.1", "--port", "0"],
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=_env(),
    )
    try:
        time.sleep(1.5)
        proc.terminate()
        out, _ = proc.communicate(timeout=15)
    finally:
        if proc.poll() is None:
            proc.kill()
    assert out == b""


class _HubError(Exception):
    pass


_HubError.__module__ = "huggingface_hub.errors"


@pytest.mark.parametrize(
    ("exc", "code"),
    [
        (
            ModuleNotFoundError("No module named 'mlx_audio'", name="mlx_audio"),
            "ModuleNotFoundError",
        ),
        (OSError(errno.EADDRINUSE, "Address already in use"), "EADDRINUSE"),
        (SocketInUseError("address already in use: x"), "EADDRINUSE"),
        (OSError(errno.EACCES, "Permission denied"), "EACCES"),
        (SocketPathConflictError("refusing to bind"), "SocketPathConflict"),
        (_HubError("404"), "ModelDownloadError"),
        (ConnectionResetError("reset"), "ModelDownloadError"),
        (RuntimeError("model.sample_rate is missing"), "BackendStartError"),
    ],
)
def test_classify_startup_error(exc, code):
    assert supervise.classify_startup_error(exc)[0] == code


def test_classify_follows_cause_chain():
    try:
        try:
            raise OSError(errno.EADDRINUSE, "Address already in use")
        except OSError as inner:
            raise RuntimeError("bind failed") from inner
    except RuntimeError as outer:
        assert supervise.classify_startup_error(outer)[0] == "EADDRINUSE"


def test_json_channel_routes_prints_to_stderr(capsys):
    with supervise.json_channel():
        print("library noise")
        supervise.emit({"event": "x", "n": 1})
    out, err = capsys.readouterr()
    assert out == '{"event":"x","n":1}\n'
    assert "library noise" in err
