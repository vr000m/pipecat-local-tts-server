"""Server-side cleartext-remote guard (Phase 1).

A token-less TCP listener bound to a non-loopback address is reachable in the
clear; the server must log a loud warning. A loopback bind (and any UDS) must
NOT warn. This is the Phase-1 deliverable (auth *enforcement* is Phase 3).
"""

from __future__ import annotations

import logging

import pytest

from tts_server.backend import ToneBackend
from tts_server.server import ServerConfig, TTSServer

pytestmark = pytest.mark.asyncio

_GUARD_NEEDLE = "non-loopback"


async def _start_and_warnings(cfg: ServerConfig, caplog) -> list[str]:
    srv = TTSServer(ToneBackend(), cfg)
    with caplog.at_level(logging.WARNING, logger="tts_server"):
        await srv.start()
        try:
            return [r.getMessage() for r in caplog.records if r.levelno >= logging.WARNING]
        finally:
            await srv.shutdown()


async def test_tokenless_non_loopback_tcp_warns(caplog):
    # 0.0.0.0 is a non-loopback bind address; with no token this must warn.
    cfg = ServerConfig(host="0.0.0.0", port=0, auth_token=None, reject_browser_origins=False)
    warnings = await _start_and_warnings(cfg, caplog)
    assert any(_GUARD_NEEDLE in w for w in warnings), (
        f"expected a cleartext-remote warning, got: {warnings}"
    )


async def test_loopback_tcp_does_not_warn(caplog):
    cfg = ServerConfig(host="127.0.0.1", port=0, auth_token=None, reject_browser_origins=False)
    warnings = await _start_and_warnings(cfg, caplog)
    assert not any(_GUARD_NEEDLE in w for w in warnings), (
        f"loopback bind must not warn, got: {warnings}"
    )


async def test_non_loopback_with_token_does_not_warn(caplog):
    cfg = ServerConfig(host="0.0.0.0", port=0, auth_token="secret", reject_browser_origins=False)
    warnings = await _start_and_warnings(cfg, caplog)
    assert not any(_GUARD_NEEDLE in w for w in warnings), (
        f"token set must suppress the cleartext warning, got: {warnings}"
    )
