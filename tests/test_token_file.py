"""Strict ``--auth-token-file`` handling (issue #23): an empty or malformed token file
must stop ``serve`` and the installer instead of silently turning auth off.

Lean: stdlib + the package only. Covers ``tts_server.env.read_token_file`` (strict and
lenient), the installer's file/directory policy, ``serve``'s startup refusal, and the
installer's refusal (with a fake ``launchctl`` so a regression can never load an agent).
"""

from __future__ import annotations

import os
import stat
import subprocess
import sys
from pathlib import Path

import pytest

from tts_server.env import (
    ConfigError,
    check_token_dir_chain,
    check_token_file_policy,
    read_token_file,
)

REPO = Path(__file__).resolve().parent.parent
SECRET = "s3cr3t-token-VALUE"


def _write(path: Path, data: bytes | str, mode: int = 0o600) -> Path:
    path.write_bytes(data if isinstance(data, bytes) else data.encode())
    path.chmod(mode)
    return path


# --- content: strict vs lenient ---------------------------------------------------


def test_strict_returns_the_token_stripped_of_surrounding_whitespace(tmp_path):
    f = _write(tmp_path / "t", f"  {SECRET}\n")
    assert read_token_file(f, strict=True) == SECRET
    assert read_token_file(f) == SECRET


@pytest.mark.parametrize("content", ["", "\n", "   \n\t \n"])
def test_empty_file_is_refused_strict_and_none_lenient(tmp_path, content):
    f = _write(tmp_path / "t", content)
    with pytest.raises(ConfigError, match="empty"):
        read_token_file(f, strict=True)
    assert read_token_file(f) is None


@pytest.mark.parametrize(
    "content",
    [
        f"{SECRET} extra",  # internal space
        f"{SECRET}\nsecond-line",  # internal newline
        f"{SECRET}\ttab",  # internal tab
        f"{SECRET}é",  # non-ASCII
        f"{SECRET}\x7f",  # DEL
        f"{SECRET}\x00",  # NUL
    ],
)
def test_strict_refuses_a_token_that_could_not_match_a_header(tmp_path, content):
    f = _write(tmp_path / "t", content)
    with pytest.raises(ConfigError, match="visible ASCII") as exc:
        read_token_file(f, strict=True)
    assert SECRET not in str(exc.value)  # the message never carries the token
    assert read_token_file(f)  # the lenient probe reader still reads it


def test_non_utf8_is_refused_in_both_modes_without_leaking(tmp_path):
    f = _write(tmp_path / "t", SECRET.encode() + b"\xff\xfe")
    for strict in (True, False):
        with pytest.raises(ConfigError, match="UTF-8") as exc:
            read_token_file(f, strict=strict)
        assert SECRET not in str(exc.value)


def test_strict_turns_a_missing_file_into_a_config_error(tmp_path):
    with pytest.raises(ConfigError, match="cannot be read"):
        read_token_file(tmp_path / "missing", strict=True)


def test_config_error_is_a_value_error():
    assert issubclass(ConfigError, ValueError)


def test_resolve_auth_token_is_strict_for_serve_and_lenient_for_the_probe(tmp_path):
    from tts_server.__main__ import _resolve_auth_token

    f = _write(tmp_path / "t", "\n")
    with pytest.raises(ConfigError):
        _resolve_auth_token(str(f))
    assert _resolve_auth_token(str(f), client=True) is None
    _write(f, SECRET)
    assert _resolve_auth_token(str(f)) == SECRET


def test_an_empty_token_file_path_is_refused_on_serve_not_ignored(monkeypatch):
    """``--auth-token-file ""`` (an unset shell variable) must not fall through to no auth."""
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("PIPECAT_TTS_AUTH_TOKEN", raising=False)
    monkeypatch.delenv("TTS_WS_TOKEN", raising=False)
    with pytest.raises(ConfigError, match="empty path"):
        _resolve_auth_token("")
    assert _resolve_auth_token("", client=True) is None  # the probe stays lenient


# --- the installer's file and directory policy ---------------------------------------


def _ok_file(tmp_path: Path) -> Path:
    d = tmp_path / "secrets"
    d.mkdir(mode=0o700)
    return _write(d / "token", SECRET)


def test_policy_accepts_an_owner_only_file_in_an_owned_directory(tmp_path):
    f = _ok_file(tmp_path)
    assert check_token_file_policy(f) == os.path.realpath(f)


def test_policy_returns_the_symlink_free_path_for_a_symlinked_directory(tmp_path):
    """The installer records this path, so a repointable symlinked component is not trusted."""
    real = _ok_file(tmp_path)
    link_dir = tmp_path / "via-link"
    link_dir.symlink_to(real.parent, target_is_directory=True)
    resolved = check_token_file_policy(link_dir / "token")
    assert resolved == os.path.realpath(real)
    assert "via-link" not in resolved


@pytest.mark.parametrize("mode", [0o640, 0o604, 0o660, 0o644, 0o666])
def test_policy_refuses_group_or_other_access(tmp_path, mode):
    f = _ok_file(tmp_path)
    f.chmod(mode)
    with pytest.raises(ConfigError, match="group/other") as exc:
        check_token_file_policy(f)
    assert SECRET not in str(exc.value)


def test_policy_refuses_a_symlink_even_to_a_good_file(tmp_path):
    real = _ok_file(tmp_path)
    link = real.parent / "link"
    link.symlink_to(real)
    with pytest.raises(ConfigError, match="symlink"):
        check_token_file_policy(link)


def test_policy_refuses_a_directory_a_missing_file_and_a_relative_path(tmp_path):
    with pytest.raises(ConfigError, match="not a regular file"):
        check_token_file_policy(tmp_path)
    with pytest.raises(ConfigError, match="does not exist"):
        check_token_file_policy(tmp_path / "missing")
    with pytest.raises(ConfigError, match="absolute"):
        check_token_file_policy("relative/token")


@pytest.mark.skipif(os.getuid() == 0, reason="root-owned paths are always trusted")
def test_policy_refuses_a_file_owned_by_someone_else(tmp_path):
    f = _ok_file(tmp_path)
    with pytest.raises(ConfigError, match="owned by uid"):
        check_token_file_policy(f, uid=os.getuid() + 1)


@pytest.mark.parametrize("mode, match", [(0o777, "any user"), (0o770, "group-writable")])
@pytest.mark.skipif(os.getuid() == 0, reason="a root-owned group-writable directory is trusted")
def test_dir_chain_refuses_a_writable_parent(tmp_path, mode, match):
    d = tmp_path / "shared"
    d.mkdir()
    f = _write(d / "token", SECRET)
    d.chmod(mode)
    with pytest.raises(ConfigError, match=match):
        check_token_dir_chain(f)


def test_dir_chain_exempts_a_sticky_directory(tmp_path):
    d = tmp_path / "sticky"
    d.mkdir()
    f = _write(d / "token", SECRET)
    d.chmod(0o777 | stat.S_ISVTX)
    check_token_dir_chain(f)


@pytest.mark.skipif(os.getuid() == 0, reason="root-owned paths are always trusted")
def test_dir_chain_refuses_a_directory_owned_by_another_user(tmp_path):
    f = _ok_file(tmp_path)
    with pytest.raises(ConfigError, match="owned by uid"):
        check_token_dir_chain(f, uid=os.getuid() + 1)


# --- serve and the installer stop on a bad file -------------------------------------


def _run(argv, env=None, **kw):
    return subprocess.run(  # noqa: S603
        argv, capture_output=True, text=True, timeout=30, env=env, cwd=REPO, **kw
    )


def test_serve_exits_1_on_an_empty_token_file_path():
    r = _run([sys.executable, "-m", "tts_server", "serve", "--backend", "tone",
              "--host", "127.0.0.1", "--port", "0", "--auth-token-file", ""])  # fmt: skip
    assert r.returncode == 1, r.stderr
    assert "empty path" in r.stderr


@pytest.mark.parametrize("content", ["\n", f"{SECRET} extra"])
def test_serve_exits_1_before_binding_on_a_bad_token_file(tmp_path, content):
    f = _write(tmp_path / "t", content)
    r = _run([sys.executable, "-m", "tts_server", "serve", "--backend", "tone",
              "--host", "127.0.0.1", "--port", "0", "--auth-token-file", str(f)])  # fmt: skip
    assert r.returncode == 1, r.stderr
    assert "auth token file" in r.stderr
    assert SECRET not in r.stdout + r.stderr


def test_serve_supervised_reports_a_config_error_event(tmp_path):
    f = _write(tmp_path / "t", "\n")
    r = _run([sys.executable, "-m", "tts_server", "serve", "--supervised", "--backend", "tone",
              "--host", "127.0.0.1", "--port", "0", "--auth-token-file", str(f)])  # fmt: skip
    assert r.returncode == 1, r.stderr
    assert '"code": "ConfigError"' in r.stdout or '"code":"ConfigError"' in r.stdout


@pytest.mark.skipif(
    not (REPO / ".venv/bin/python").exists(), reason="installer needs the repo venv"
)
@pytest.mark.parametrize(
    "mode, content, needle", [(0o600, "\n", "empty"), (0o644, SECRET, "group/other")]
)
def test_installer_refuses_a_bad_token_file_before_touching_launchd(
    tmp_path, mode, content, needle
):
    """A fake launchctl on PATH proves a regression could never load a real agent."""
    bindir = tmp_path / "bin"
    bindir.mkdir()
    called = tmp_path / "launchctl-called"
    fake = bindir / "launchctl"
    fake.write_text(f"#!/bin/sh\ntouch '{called}'\nexit 99\n")
    fake.chmod(0o755)
    token = _write(tmp_path / "t", content, mode)
    home = tmp_path / "home"
    home.mkdir()
    env = {
        "PATH": f"{bindir}:{os.environ['PATH']}",
        "HOME": str(home),
        "PIPECAT_TTS_LABEL": "pipecat.tts-server.token-test",
        "PIPECAT_TTS_LOG_DIR": str(tmp_path / "logs"),
        "PIPECAT_TTS_AUTH_TOKEN_FILE": str(token),
    }
    r = _run(["bash", str(REPO / "scripts/install_tts_agent.sh"), "install"], env=env)
    assert r.returncode == 1, r.stdout + r.stderr
    assert "PIPECAT_TTS_AUTH_TOKEN_FILE" in r.stderr and needle in r.stderr
    assert SECRET not in r.stdout + r.stderr
    assert not called.exists(), "launchctl was reached"
    assert not (home / "Library").exists() and not (tmp_path / "logs").exists()


# --- PIPECAT_TTS_AUTH_TOKEN (server env var) -----------------------------------------


def test_env_token_unset_or_empty_means_no_auth(monkeypatch):
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("PIPECAT_TTS_AUTH_TOKEN", raising=False)
    assert _resolve_auth_token(None) is None
    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", "")
    assert _resolve_auth_token(None) is None


@pytest.mark.parametrize("value", [" ", "\t", "  \n "])
def test_env_token_set_but_blank_is_refused(monkeypatch, value):
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", value)
    with pytest.raises(ConfigError, match="blank"):
        _resolve_auth_token(None)


def test_env_token_is_stripped_and_held_to_the_file_rules(monkeypatch):
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", f"  {SECRET}\n")
    assert _resolve_auth_token(None) == SECRET
    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", f"{SECRET} extra")
    with pytest.raises(ConfigError, match="visible ASCII") as exc:
        _resolve_auth_token(None)
    assert SECRET not in str(exc.value)


def test_client_token_stays_lenient(monkeypatch):
    """TTS_WS_TOKEN is the probe's bearer, not a gate: a blank one is just no token."""
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.setenv("TTS_WS_TOKEN", "  ")
    assert _resolve_auth_token(None, client=True) is None


def test_serve_exits_1_on_a_blank_env_token():
    env = {**os.environ, "PIPECAT_TTS_AUTH_TOKEN": " "}
    r = _run(
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
            "0",
        ],
        env=env,
    )
    assert r.returncode == 1, r.stderr
    assert "PIPECAT_TTS_AUTH_TOKEN" in r.stderr
