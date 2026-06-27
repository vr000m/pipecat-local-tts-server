"""Stale Unix-socket handling on server start (adversarial-review finding #3).

The documented local mode binds a Unix domain socket. After a crash / SIGKILL a
leftover ``tts.sock`` is left behind; the server resolves the cases on start:

- stale socket (no listener)   -> unlinked, bind proceeds (the crash-restart case)
- live socket (listener up)     -> refused (never steal another instance's socket;
                                   asyncio's own create_unix_server would silently
                                   unlink and steal it — this guard prevents that)
- non-socket file at the path   -> refused (not ours to delete)

Unix-socket paths are capped (104 chars on macOS), so these tests bind under
``/tmp`` with short names rather than pytest's long ``tmp_path``.
"""

from __future__ import annotations

import os
import socket
import uuid
from pathlib import Path

import pytest

from tts_server.backend import ToneBackend
from tts_server.server import (
    ServerConfig,
    TTSServer,
    _assert_parent_dir_safe,
    _clear_stale_unix_socket,
)


@pytest.fixture
def sock_path():
    """A short, unique Unix-socket path under /tmp (AF_UNIX length limit)."""
    path = Path("/tmp") / f"tts-test-{uuid.uuid4().hex[:8]}.sock"
    yield path
    # Best-effort cleanup of whatever the test left behind.
    try:
        if path.is_symlink() or path.exists():
            path.unlink()
    except OSError:
        pass


def _make_stale_socket(path) -> None:
    """Leave a socket file with no listener behind (the crash leftover shape)."""
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.bind(str(path))
    finally:
        s.close()  # closing does NOT unlink the path -> stale socket file remains


# --- the helper, in isolation ---------------------------------------------


def test_clear_stale_unix_socket_unlinks_stale(sock_path):
    _make_stale_socket(sock_path)
    assert sock_path.exists() and sock_path.is_socket()
    _clear_stale_unix_socket(sock_path)
    assert not sock_path.exists(), "stale socket should be unlinked so bind can proceed"


def test_clear_stale_unix_socket_refuses_regular_file(sock_path):
    sock_path.write_text("not a socket")
    with pytest.raises(RuntimeError, match="not a socket"):
        _clear_stale_unix_socket(sock_path)
    assert sock_path.exists(), "a non-socket file must be preserved, not clobbered"


def test_clear_stale_unix_socket_unlinks_dangling_symlink(sock_path):
    sock_path.symlink_to("/tmp/does-not-exist-%s" % uuid.uuid4().hex[:8])
    assert sock_path.is_symlink() and not sock_path.exists()
    _clear_stale_unix_socket(sock_path)
    assert not sock_path.is_symlink(), "a dangling symlink must be cleared before bind"


def test_clear_stale_unix_socket_noop_when_absent(sock_path):
    _clear_stale_unix_socket(sock_path)  # must not raise
    assert not sock_path.exists()


def test_clear_stale_unix_socket_refuses_live_socket(sock_path):
    """A socket with a live listener must be refused, not unlinked."""
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(sock_path))
    listener.listen(1)
    try:
        with pytest.raises(RuntimeError, match="already"):
            _clear_stale_unix_socket(sock_path)
        assert sock_path.is_socket(), "a live server's socket must be left intact"
    finally:
        listener.close()


# --- parent-directory safety guard ----------------------------------------


def test_parent_dir_safe_accepts_owner_only_dir(tmp_path):
    d = tmp_path / "private"
    d.mkdir(mode=0o700)
    os.chmod(d, 0o700)  # mkdir mode is masked by umask; force it
    _assert_parent_dir_safe(d / "tts.sock")  # must not raise


def test_parent_dir_safe_accepts_world_writable_sticky_dir(tmp_path):
    d = tmp_path / "tmplike"
    d.mkdir()
    os.chmod(d, 0o1777)  # world-writable + sticky, /tmp semantics
    _assert_parent_dir_safe(d / "tts.sock")  # only the owner may unlink -> ok


def test_parent_dir_safe_refuses_world_writable_non_sticky(tmp_path):
    d = tmp_path / "open"
    d.mkdir()
    os.chmod(d, 0o0777)  # world-writable, no sticky bit -> swap vector
    with pytest.raises(RuntimeError, match="group/world-writable"):
        _assert_parent_dir_safe(d / "tts.sock")


def test_parent_dir_safe_refuses_group_writable_non_sticky(tmp_path):
    d = tmp_path / "groupwrite"
    d.mkdir()
    os.chmod(d, 0o0770)  # group-writable, no sticky bit
    with pytest.raises(RuntimeError, match="group/world-writable"):
        _assert_parent_dir_safe(d / "tts.sock")


# --- end-to-end through the server ----------------------------------------


@pytest.mark.asyncio
async def test_server_restarts_over_stale_socket(sock_path):
    """The documented crash-restart path: a stale socket must not block bind."""
    _make_stale_socket(sock_path)

    srv = TTSServer(ToneBackend(), ServerConfig(socket_path=str(sock_path)))
    await srv.start()
    try:
        assert sock_path.is_socket()
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(1.0)
        try:
            probe.connect(str(sock_path))  # a real listener now accepts
        finally:
            probe.close()
    finally:
        await srv.shutdown()


@pytest.mark.asyncio
async def test_server_refuses_live_socket(sock_path):
    """A second server on the same path as a LIVE one must refuse, not steal it."""
    first = TTSServer(ToneBackend(), ServerConfig(socket_path=str(sock_path)))
    await first.start()
    try:
        second = TTSServer(ToneBackend(), ServerConfig(socket_path=str(sock_path)))
        with pytest.raises(RuntimeError, match="already"):
            await second.start()
        # The first server's socket is still live and reachable.
        probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        probe.settimeout(1.0)
        try:
            probe.connect(str(sock_path))
        finally:
            probe.close()
    finally:
        await first.shutdown()


def test_sock_path_within_unix_limit(sock_path):
    """Guard the fixture itself: the path must fit AF_UNIX."""
    assert len(str(sock_path)) < 104, f"socket path too long for AF_UNIX: {sock_path}"
