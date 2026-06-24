"""Optional bearer auth + token precedence (Phase 3, R9).

Lean-CI on ``ToneBackend`` — mirrors stt's auth surface:

- token-required reject: a server with ``auth_token`` set 401s a missing/wrong
  bearer and accepts the correct one;
- token-absent startup warning over non-loopback TCP, and no-warn over a UDS
  (the cleartext-remote guard — UDS is the local trust boundary);
- token precedence: the client reads ``TTS_WS_TOKEN`` and MUST NOT fall back to
  the server-side ``PIPECAT_TTS_AUTH_TOKEN`` (a probe that fell back could report
  "ok" while a real consumer still 401s, masking the misconfiguration).
"""

from __future__ import annotations

import logging

import pytest
import websockets

from tts_server.backend import ToneBackend
from tts_server.client import TTSClient
from tts_server.server import ServerConfig, TTSServer

from ._helpers import running_server

# asyncio_mode=auto runs the async tests; the sync token-resolution tests below
# must NOT carry an asyncio mark, so no module-level pytestmark here.

_GUARD_NEEDLE = "non-loopback"


# --- token-required reject / accept ----------------------------------------


async def test_token_required_rejects_missing_and_wrong_accepts_correct():
    srv = TTSServer(
        ToneBackend(),
        ServerConfig(host="127.0.0.1", port=0, auth_token="s3cret", reject_browser_origins=False),
    )
    await srv.start()
    try:
        port = srv.listening_port()
        assert port is not None

        # Missing token → 401.
        no_token = TTSClient(host="127.0.0.1", port=port)
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_missing:
            await no_token.connect()
        assert exc_missing.value.response.status_code == 401

        # Wrong token → 401.
        bad = TTSClient(host="127.0.0.1", port=port, auth_token="wrong")
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc_wrong:
            await bad.connect()
        assert exc_wrong.value.response.status_code == 401

        # Correct token → handshake succeeds, hello arrives.
        good = TTSClient(host="127.0.0.1", port=port, auth_token="s3cret")
        hello = await good.connect()
        try:
            assert hello["type"] == "server.hello"
        finally:
            await good.close()
    finally:
        await srv.shutdown()


async def test_no_token_set_accepts_any_connection():
    # Sanity: with no server token, a plain client connects (no auth gate).
    async with running_server(ToneBackend()) as srv:
        port = srv.listening_port()
        c = TTSClient(host="127.0.0.1", port=port)
        hello = await c.connect()
        try:
            assert hello["type"] == "server.hello"
        finally:
            await c.close()


# --- token-absent startup warning (cleartext-remote guard) -----------------


async def _start_and_warnings(cfg: ServerConfig, caplog) -> list[str]:
    srv = TTSServer(ToneBackend(), cfg)
    with caplog.at_level(logging.WARNING, logger="tts_server"):
        await srv.start()
        try:
            return [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
        finally:
            await srv.shutdown()


async def test_tokenless_non_loopback_tcp_warns(caplog):
    cfg = ServerConfig(host="0.0.0.0", port=0, auth_token=None, reject_browser_origins=False)
    warnings = await _start_and_warnings(cfg, caplog)
    assert any(_GUARD_NEEDLE in w for w in warnings), (
        f"expected a token-absent cleartext-remote warning, got: {warnings}"
    )


async def test_uds_no_warn(caplog):
    # A Unix socket is the local trust boundary (0o600) — no token, no warning.
    # Use a short tmp dir: AF_UNIX paths are capped (~104 bytes on macOS), and
    # pytest's tmp_path is too deep.
    import os
    import tempfile

    with tempfile.TemporaryDirectory(dir="/tmp") as d:
        sock = os.path.join(d, "tts.sock")
        cfg = ServerConfig(socket_path=sock, auth_token=None, reject_browser_origins=False)
        warnings = await _start_and_warnings(cfg, caplog)
        assert not any(_GUARD_NEEDLE in w for w in warnings), (
            f"a UDS must not emit the cleartext-remote warning, got: {warnings}"
        )


# --- client TTS_WS_TOKEN vs server PIPECAT_TTS_AUTH_TOKEN precedence --------


def test_probe_client_uses_tts_ws_token(monkeypatch):
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("PIPECAT_TTS_AUTH_TOKEN", raising=False)
    monkeypatch.setenv("TTS_WS_TOKEN", "client-secret")
    assert _resolve_auth_token(None, client=True) == "client-secret"


def test_probe_client_does_not_fall_back_to_server_token(monkeypatch):
    # Only the SERVER-side var is set: the client probe MUST NOT authenticate
    # (no fallback) — else it could mask a real consumer's 401.
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("TTS_WS_TOKEN", raising=False)
    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", "server-secret")
    assert _resolve_auth_token(None, client=True) is None


def test_serve_reads_server_token(monkeypatch):
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("TTS_WS_TOKEN", raising=False)
    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", "server-secret")
    assert _resolve_auth_token(None, client=False) == "server-secret"


async def test_client_with_only_server_var_does_not_authenticate(monkeypatch):
    # End-to-end: a server requires a token; a probe-style client that has ONLY
    # the server var set resolves no client token and is therefore rejected.
    from tts_server.__main__ import _resolve_auth_token

    monkeypatch.delenv("TTS_WS_TOKEN", raising=False)
    monkeypatch.setenv("PIPECAT_TTS_AUTH_TOKEN", "server-secret")
    resolved = _resolve_auth_token(None, client=True)
    assert resolved is None

    srv = TTSServer(
        ToneBackend(),
        ServerConfig(
            host="127.0.0.1", port=0, auth_token="server-secret", reject_browser_origins=False
        ),
    )
    await srv.start()
    try:
        port = srv.listening_port()
        # Client built from the (None) resolved client token → no Authorization
        # header → 401.
        c = TTSClient(host="127.0.0.1", port=port, auth_token=resolved)
        with pytest.raises(websockets.exceptions.InvalidStatus) as exc:
            await c.connect()
        assert exc.value.response.status_code == 401
    finally:
        await srv.shutdown()
