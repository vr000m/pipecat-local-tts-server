"""Tests for the port-transport ``scripts/render_tts_plist.py`` renderer.

The renderer is the injection-sensitive component of the launchd ops surface:
it interpolates operator-supplied values (label, model, auth-token path, host,
port) into a launchd plist. It uses ``plistlib`` so XML escaping / quoting is
handled by the stdlib, and it allowlist-validates every value. These tests lock:

* the ``ProgramArguments`` shape (``serve --backend <b> --host <h> --port <p>``
  in order), ``RunAtLoad``/``KeepAlive``, the ``Label``, and the label-derived
  ``StandardOutPath``/``StandardErrorPath`` under the given ``log_dir``;
* the fail-closed auth contract BOTH ways — loopback omits ``--auth-token-file``,
  non-loopback with no token file RAISES, non-loopback + token file emits it;
* XML-escape / injection safety — hostile values containing ``& < > " '`` survive
  intact as plist DATA and never break out of ``<string>`` (the output still
  round-trips through ``plistlib.loads``).

The tests call ``render_plist(...)`` directly (a pure function) and parse its
output with ``plistlib.loads`` since the renderer emits via ``plistlib.dumps``.
"""

from __future__ import annotations

import importlib.util
import os
import plistlib
import subprocess
import sys
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parent.parent
SCRIPT = REPO_ROOT / "scripts" / "render_tts_plist.py"


def _load_renderer():
    """Import ``scripts/render_tts_plist.py`` as a module (it is not a package).

    The script imports ``tts_server.env.is_loopback_host``, which is on the lean
    base, so this import is safe in lean CI (no mlx / model weights)."""
    spec = importlib.util.spec_from_file_location("render_tts_plist", SCRIPT)
    assert spec is not None and spec.loader is not None
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


render_tts_plist = _load_renderer()
render_plist = render_tts_plist.render_plist

# A baseline set of keyword args every render needs; tests override per-case.
_BASE = dict(
    python="/Users/test/repo/.venv/bin/python",
    repo_root="/Users/test/repo",
    home="/Users/test",
    log_dir="/Users/test/Library/Logs/pipecat-tts",
)


def _render(**overrides) -> dict:
    """Render with sensible loopback defaults + overrides; return parsed plist."""
    kwargs = dict(
        backend="tone",
        label="pipecat.tts-server.tone",
        host="127.0.0.1",
        port=8665,
        **_BASE,
    )
    kwargs.update(overrides)
    xml = render_plist(**kwargs)
    return plistlib.loads(xml.encode("utf-8"))


# ---------------------------------------------------------------------------
# ProgramArguments shape + RunAtLoad/KeepAlive + Label + log paths
# ---------------------------------------------------------------------------


def test_program_arguments_carry_serve_backend_host_port_in_order():
    plist = _render(backend="kokoro", host="127.0.0.1", port=8765)
    args = plist["ProgramArguments"]
    # serve subcommand present, and the flag/value pairs appear in order.
    assert "serve" in args
    assert args[args.index("--backend") + 1] == "kokoro"
    assert args[args.index("--host") + 1] == "127.0.0.1"
    assert args[args.index("--port") + 1] == "8765"  # port is stringified
    # ordering: serve < --backend < --host < --port
    assert args.index("serve") < args.index("--backend")
    assert args.index("--backend") < args.index("--host")
    assert args.index("--host") < args.index("--port")


def test_run_at_load_and_keep_alive_are_true():
    plist = _render()
    assert plist["RunAtLoad"] is True
    assert plist["KeepAlive"] is True


def test_label_matches():
    plist = _render(label="pipecat.tts-server.voxtral_tts")
    assert plist["Label"] == "pipecat.tts-server.voxtral_tts"


def test_log_paths_resolve_under_log_dir_with_label_basename():
    log_dir = "/Users/test/Library/Logs/pipecat-tts"
    plist = _render(label="pipecat.tts-server.kokoro", log_dir=log_dir)
    basename = render_tts_plist._log_basename("pipecat.tts-server.kokoro")
    assert plist["StandardOutPath"] == str(Path(log_dir) / f"{basename}.out")
    assert plist["StandardErrorPath"] == str(Path(log_dir) / f"{basename}.err")
    # out != err so two streams never interleave.
    assert plist["StandardOutPath"] != plist["StandardErrorPath"]


def test_default_label_log_basename_is_short_slug():
    log_dir = "/Users/test/Library/Logs/pipecat-tts"
    plist = _render(label="pipecat.tts-server", log_dir=log_dir)
    assert plist["StandardOutPath"] == str(Path(log_dir) / "pipecat-tts.out")
    assert plist["StandardErrorPath"] == str(Path(log_dir) / "pipecat-tts.err")


def test_model_flag_emitted_only_when_supplied():
    no_model = _render()
    assert "--model" not in no_model["ProgramArguments"]
    with_model = _render(model="mlx-community/Kokoro-82M-bf16")
    args = with_model["ProgramArguments"]
    assert args[args.index("--model") + 1] == "mlx-community/Kokoro-82M-bf16"


# ---------------------------------------------------------------------------
# Fail-closed auth contract — both ways
# ---------------------------------------------------------------------------


def test_loopback_host_omits_auth_token_file():
    for host in ("127.0.0.1", "::1", "localhost"):
        plist = _render(host=host)
        assert "--auth-token-file" not in plist["ProgramArguments"], host


@pytest.mark.parametrize("host", ["0.0.0.0", "192.168.1.10", "10.0.0.5"])
def test_non_loopback_without_token_raises(host: str):
    with pytest.raises(ValueError, match="token-less"):
        _render(host=host, auth_token_file=None)


@pytest.mark.parametrize("host", ["0.0.0.0", "192.168.1.10"])
def test_non_loopback_with_token_emits_flag(host: str):
    token = "/Users/test/.config/pipecat-tts/token"
    plist = _render(host=host, auth_token_file=token)
    args = plist["ProgramArguments"]
    assert args[args.index("--auth-token-file") + 1] == token


# ---------------------------------------------------------------------------
# Injection / XML-escape safety
# ---------------------------------------------------------------------------

_HOSTILE = "x</string><key>RunAtLoad</key><false/><string>& < > \" '"


def test_hostile_label_does_not_break_out_of_string():
    """A hostile Label must survive as plist data and not inject new keys.

    render_plist does not allowlist-validate its args (main() does that); the
    plistlib defence-in-depth must still produce a well-formed plist where the
    hostile value is the DATA of Label, not a key/element breakout."""
    plist = _render(label=_HOSTILE)
    # Round-trips cleanly, and the hostile value is the verbatim Label value.
    assert plist["Label"] == _HOSTILE
    # The injection attempt did NOT flip RunAtLoad/KeepAlive via a breakout.
    assert plist["RunAtLoad"] is True
    assert plist["KeepAlive"] is True


def test_hostile_model_survives_intact_as_data():
    plist = _render(model=_HOSTILE)
    args = plist["ProgramArguments"]
    assert args[args.index("--model") + 1] == _HOSTILE


def test_hostile_auth_path_survives_intact_as_data():
    # Non-loopback host so the auth-token-file flag is emitted; hostile path.
    plist = _render(host="192.168.1.10", auth_token_file=_HOSTILE)
    args = plist["ProgramArguments"]
    assert args[args.index("--auth-token-file") + 1] == _HOSTILE


def test_hostile_values_keep_plist_well_formed():
    """The raw XML round-trips through plistlib regardless of hostile content —
    proving no ``<string>`` breakout corrupted the document structure."""
    xml = render_plist(
        backend="tone",
        label=_HOSTILE,
        host="192.168.1.10",
        port=8665,
        model=_HOSTILE,
        auth_token_file=_HOSTILE,
        **_BASE,
    )
    # plistlib raises on malformed XML; a clean parse proves well-formedness.
    parsed = plistlib.loads(xml.encode("utf-8"))
    assert parsed["Label"] == _HOSTILE
    # The literal characters were XML-escaped on the wire (no raw breakout).
    assert "&lt;" in xml or "&amp;" in xml


# ---------------------------------------------------------------------------
# Server-runtime env that launchd does not inherit: it must be baked into the
# plist (non-secret) or rejected loudly (secret), never silently dropped.
# ---------------------------------------------------------------------------


def test_extra_env_baked_into_environment_variables():
    """``extra_env`` is merged into EnvironmentVariables alongside PATH+HOME."""
    plist = _render(extra_env={"PIPECAT_TTS_KOKORO_EXTRA_LANGS": "ja,zh"})
    env = plist["EnvironmentVariables"]
    assert env["PIPECAT_TTS_KOKORO_EXTRA_LANGS"] == "ja,zh"
    assert "PATH" in env and env["HOME"] == _BASE["home"]


def _run_main(tmp_path: Path, env_extra: dict[str, str]):
    """Run the renderer's ``main()`` as a subprocess with an ISOLATED env (no
    inheritance, so a stray PIPECAT_TTS_* in the test runner can't leak in).
    Returns ``(CompletedProcess, plist_path)``."""
    plist_dst = tmp_path / "agent.plist"
    env = {
        "PATH": os.environ.get("PATH", ""),
        "PYTHON": sys.executable,
        "REPO_ROOT": str(REPO_ROOT),
        "BACKEND": "kokoro",
        "HOST": "127.0.0.1",
        "PORT": "8765",
        "HOME": str(tmp_path),
        "LOG_DIR": str(tmp_path / "logs"),
        "PLIST_DST": str(plist_dst),
        "PIPECAT_TTS_LABEL": "pipecat.tts-server.kokoro",
    }
    env.update(env_extra)
    proc = subprocess.run(
        [sys.executable, str(SCRIPT)],
        env=env,
        cwd=str(REPO_ROOT),
        capture_output=True,
        text=True,
    )
    return proc, plist_dst


def test_main_rejects_env_auth_token_without_file(tmp_path):
    """PIPECAT_TTS_AUTH_TOKEN set without a token file would silently disable auth
    under launchd — main() must fail loudly and write NO plist."""
    proc, plist_dst = _run_main(tmp_path, {"PIPECAT_TTS_AUTH_TOKEN": "server-secret"})
    assert proc.returncode == 2
    assert "PIPECAT_TTS_AUTH_TOKEN" in proc.stderr
    assert not plist_dst.exists()


def test_main_env_auth_token_with_file_warns_and_never_writes_secret(tmp_path):
    """With a token file the install proceeds (the file is authoritative), warns
    that the env token is ignored, and the secret never lands in the plist."""
    proc, plist_dst = _run_main(
        tmp_path,
        {
            "PIPECAT_TTS_AUTH_TOKEN": "server-secret",
            "AUTH_TOKEN_FILE": "/Users/op/Library/Application Support/pipecat-tts/token",
        },
    )
    assert proc.returncode == 0, proc.stderr
    assert "ignored" in proc.stderr.lower()
    text = plist_dst.read_text()
    assert "server-secret" not in text
    assert "--auth-token-file" in text


def test_main_bakes_kokoro_extra_langs_into_plist(tmp_path):
    """PIPECAT_TTS_KOKORO_EXTRA_LANGS survives into the agent via the plist."""
    proc, plist_dst = _run_main(tmp_path, {"PIPECAT_TTS_KOKORO_EXTRA_LANGS": "ja,zh"})
    assert proc.returncode == 0, proc.stderr
    plist = plistlib.loads(plist_dst.read_bytes())
    assert plist["EnvironmentVariables"]["PIPECAT_TTS_KOKORO_EXTRA_LANGS"] == "ja,zh"


def test_main_rejects_malformed_extra_langs(tmp_path):
    """A non-ISO-code-list value is rejected (not blindly baked into the plist)."""
    proc, plist_dst = _run_main(tmp_path, {"PIPECAT_TTS_KOKORO_EXTRA_LANGS": "ja;rm -rf /"})
    assert proc.returncode == 2
    assert not plist_dst.exists()
