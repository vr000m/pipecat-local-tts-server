"""Environment-variable helpers and endpoint resolution.

Mirrors the sibling ``stt_server`` env handling with ``TTS_WS_*`` names. The
coercion helpers are resolved at call time so tests/operators can monkeypatch
without re-importing. Endpoint resolution enforces the precedence
``URI > socket > host+port`` (the wire contract) and the cleartext-remote guard
is here so both the client and the server can reuse it.

stdlib-only.
"""

from __future__ import annotations

import ipaddress
import logging
import os
import urllib.parse
from typing import Mapping

logger = logging.getLogger("tts_server.env")

_TRUTHY = {"1", "true", "yes", "on"}

_LOOPBACK_HOSTS = {"localhost", "127.0.0.1", "::1"}


def env_bool(name: str, default: bool) -> bool:
    """Truthy: ``"1"``/``"true"``/``"yes"``/``"on"`` (case/space-insensitive).
    Anything else that is set is False; only ``unset`` falls through to
    ``default``."""
    val = os.environ.get(name)
    if val is None:
        return default
    return val.strip().lower() in _TRUTHY


def env_int(name: str, default: int) -> int:
    val = os.environ.get(name)
    if val is None or val.strip() == "":
        return default
    try:
        return int(val)
    except ValueError:
        logger.warning("invalid int for %s=%r; using default %s", name, val, default)
        return default


def env_float(name: str, default: float) -> float:
    val = os.environ.get(name)
    if val is None or val.strip() == "":
        return default
    try:
        return float(val)
    except ValueError:
        logger.warning("invalid float for %s=%r; using default %s", name, val, default)
        return default


def env_str_set(name: str) -> set[str]:
    """Parse a comma-separated env var into a set of lowercased, stripped tokens.

    Empty / unset → empty set. Blank entries (e.g. trailing comma) are dropped.
    Used for opt-in lists like ``PIPECAT_TTS_KOKORO_EXTRA_LANGS=ja,zh``.
    """
    val = os.environ.get(name)
    if not val:
        return set()
    return {tok.strip().lower() for tok in val.split(",") if tok.strip()}


def is_cleartext_remote(uri: str) -> bool:
    """True if ``uri`` is ``ws://`` pointing at a non-loopback host.

    Used to guard against attaching a bearer token to a cleartext connection to
    a remote peer (the token would be captured by any on-path observer) and to
    warn an operator who binds a token-less TCP listener to a non-loopback
    address.
    """
    try:
        parsed = urllib.parse.urlsplit(uri)
    except ValueError:
        return False
    if parsed.scheme.lower() != "ws":
        return False
    host = (parsed.hostname or "").lower()
    if not host or host in _LOOPBACK_HOSTS:
        return False
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return True  # a non-loopback DNS name counts as remote
    return not addr.is_loopback


def is_loopback_host(host: str | None) -> bool:
    """True if ``host`` is a loopback address/name (``127.0.0.1``/``::1``/
    ``localhost``). A non-loopback DNS name or routable IP is NOT loopback."""
    if not host:
        return False
    h = host.lower()
    if h in _LOOPBACK_HOSTS:
        return True
    try:
        return ipaddress.ip_address(h).is_loopback
    except ValueError:
        return False


def format_host_for_uri(host: str) -> str:
    """Bracket IPv6 literals so ``ws://[::1]:port/`` is a valid URI."""
    try:
        addr = ipaddress.ip_address(host)
    except ValueError:
        return host  # hostname / "localhost"
    if isinstance(addr, ipaddress.IPv6Address):
        return f"[{host}]"
    return host


def resolve_endpoint_from_env(env: Mapping[str, str]) -> dict:
    """Resolve ``TTS_WS_*`` env vars into endpoint kwargs.

    Enforces precedence ``TTS_WS_URI > TTS_WS_SOCKET > TTS_WS_HOST+PORT`` by
    zeroing lower-priority fields. Returns a dict with keys ``uri``,
    ``socket_path``, ``host``, ``port`` — all ``None`` if nothing is set.
    Callers supply their own default when every field is ``None``.
    """
    uri = (env.get("TTS_WS_URI") or "").strip() or None
    sock = (env.get("TTS_WS_SOCKET") or "").strip() or None
    host = (env.get("TTS_WS_HOST") or "").strip() or None
    port_raw = (env.get("TTS_WS_PORT") or "").strip()
    port: int | None = int(port_raw) if port_raw else None
    if uri:
        sock = None
        host = None
        port = None
    elif sock:
        host = None
        port = None
    return {"uri": uri, "socket_path": sock, "host": host, "port": port}
