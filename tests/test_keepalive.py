"""Websocket keepalive (ping/pong) configuration.

Regression coverage for the 1011 "keepalive ping timeout" mid-generation
truncation: the library defaults (ping_interval=20s, ping_timeout=20s) close a
live connection when GIL-holding Metal compute starves the asyncio loop past 20s.
The server and client both default to keeping the periodic ping but DISABLING the
pong timeout, and expose both knobs.

These assertions are behavioral: they read ``ping_interval`` / ``ping_timeout``
off the live ``websockets`` connection objects (both directions), so a regression
that drops the wiring — not just the config default — is caught.
"""

from __future__ import annotations

import asyncio

import pytest

from tts_server import protocol as P
from tts_server.__main__ import _resolve_keepalive
from tts_server.backends import make_backend
from tts_server.client import TTSClient
from tts_server.server import ServerConfig, TTSServer


def test_serverconfig_keepalive_defaults() -> None:
    cfg = ServerConfig(host="127.0.0.1", port=0)
    assert cfg.ping_interval_seconds == P.KEEPALIVE_PING_INTERVAL_SECONDS == 20.0
    # The crux: the default DISABLES the pong timeout so a starved loop can't
    # drop a live connection mid-generation.
    assert cfg.ping_timeout_seconds is P.KEEPALIVE_PING_TIMEOUT_SECONDS is None


def test_client_keepalive_defaults_and_override() -> None:
    c = TTSClient(host="127.0.0.1", port=1)
    assert c._ping_interval == 20.0
    assert c._ping_timeout is None
    c2 = TTSClient(host="127.0.0.1", port=1, ping_interval=None, ping_timeout=45.0)
    assert c2._ping_interval is None
    assert c2._ping_timeout == 45.0


@pytest.mark.asyncio
async def test_server_threads_keepalive_onto_connection() -> None:
    """The server's ping config reaches the live server-side connection."""
    srv = TTSServer(
        make_backend("tone"),
        ServerConfig(
            host="127.0.0.1",
            port=0,
            reject_browser_origins=False,
            ping_interval_seconds=17.0,
            ping_timeout_seconds=None,
        ),
    )
    await srv.start()
    try:
        c = TTSClient(host="127.0.0.1", port=srv.listening_port())
        await c.connect()
        try:
            await asyncio.sleep(0.05)  # let the server accept register the conn
            conns = list(srv._server.connections)
            assert len(conns) == 1
            assert conns[0].ping_interval == 17.0
            assert conns[0].ping_timeout is None
        finally:
            await c.close()
    finally:
        await srv.shutdown()


@pytest.mark.asyncio
async def test_client_threads_keepalive_onto_connection() -> None:
    """The client's ping config reaches the live client-side connection."""
    srv = TTSServer(
        make_backend("tone"),
        ServerConfig(host="127.0.0.1", port=0, reject_browser_origins=False),
    )
    await srv.start()
    try:
        c = TTSClient(
            host="127.0.0.1",
            port=srv.listening_port(),
            ping_interval=13.0,
            ping_timeout=None,
        )
        await c.connect()
        try:
            assert c._ws is not None
            assert c._ws.ping_interval == 13.0
            assert c._ws.ping_timeout is None
        finally:
            await c.close()
    finally:
        await srv.shutdown()


@pytest.mark.parametrize(
    "raw, expected",
    [
        (None, 20.0),  # unset -> code default
        ("none", None),
        ("off", None),
        ("disable", None),
        ("disabled", None),
        ("0", None),
        ("", None),
        ("  NONE  ", None),  # trimmed + case-insensitive
        ("120", 120.0),
        ("45.5", 45.5),
    ],
)
def test_resolve_keepalive(monkeypatch, raw, expected) -> None:
    if raw is None:
        monkeypatch.delenv("TTS_WS_PING_TIMEOUT", raising=False)
    else:
        monkeypatch.setenv("TTS_WS_PING_TIMEOUT", raw)
    assert _resolve_keepalive("TTS_WS_PING_TIMEOUT", 20.0) == expected


@pytest.mark.parametrize("raw", ["abc", "-5", "-1.0"])
def test_resolve_keepalive_rejects_bad_values(monkeypatch, raw) -> None:
    monkeypatch.setenv("TTS_WS_PING_INTERVAL", raw)
    with pytest.raises(SystemExit):
        _resolve_keepalive("TTS_WS_PING_INTERVAL", 20.0)
