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
import stat
import urllib.parse
from collections.abc import Mapping
from pathlib import Path

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


class ConfigError(ValueError):
    """A rejected configuration value (an unusable auth token file).

    A ``ValueError`` subclass so a caller that already catches ``ValueError`` is
    unaffected. Messages name the source, never the token.
    """


def check_token_chars(token: str, what: str) -> str:
    """Refuse a token that can never match an ``Authorization`` header.

    ``token`` is already stripped and non-empty. Raises ``ConfigError`` naming
    ``what`` (the source, never the value) for internal whitespace, a control
    character or a non-ASCII character: only visible ASCII (0x21-0x7E) survives
    an HTTP header and the byte-for-byte bearer comparison.
    """
    if any(not 0x21 <= ord(c) <= 0x7E for c in token):
        raise ConfigError(
            f"{what} must hold one token of visible ASCII characters "
            "(no internal whitespace, newlines or non-ASCII); anything else can never "
            "match an Authorization header"
        )
    return token


def read_token_file(path: str | os.PathLike[str], *, strict: bool = False) -> str | None:
    """Read a bearer-token file: UTF-8, surrounding whitespace stripped.

    Strict (the ``serve`` path) refuses what would otherwise silently misbehave:
    an empty or whitespace-only file (the token would be ``None`` and auth
    disabled), a token with internal whitespace or a non-visible-ASCII character
    (it can never match a header), and a non-UTF-8 file. Non-strict (the ``status``
    probe) keeps the lenient ``None`` for an empty file. Raises ``ConfigError``;
    messages never include the token.
    """
    what = f"auth token file {path}"
    try:
        raw = Path(path).read_bytes()
    except OSError as exc:
        if not strict:
            raise
        raise ConfigError(f"{what} cannot be read ({exc.strerror or type(exc).__name__})") from exc
    try:
        token = raw.decode("utf-8").strip()
    except UnicodeDecodeError as exc:
        raise ConfigError(f"{what} is not valid UTF-8") from exc
    if not strict:
        return token or None
    if not token:
        raise ConfigError(f"{what} is empty; an empty token would disable auth")
    return check_token_chars(token, what)


def _refuse(path: str, problem: str, fix: str) -> ConfigError:
    return ConfigError(f"auth token file {path} {problem}; fix: {fix}")


def check_token_dir_chain(path: str | os.PathLike[str], *, uid: int | None = None) -> str:
    """Refuse a token file whose directory chain someone else could rewrite.

    Walks the symlink-free resolved parent directory up to ``/``: each must be
    owned by ``uid`` (default: the current user) or root, not be other-writable
    unless sticky, and not be group-writable unless root-owned or sticky. Returns
    the resolved directory. Raises ``ConfigError``.
    """
    uid = os.getuid() if uid is None else uid
    p = os.fspath(path)
    d = os.path.realpath(os.path.dirname(p))
    resolved = d
    while True:
        try:
            st = os.lstat(d)
        except OSError as exc:
            raise _refuse(
                p, f"has an unreadable parent directory {d} ({exc.strerror})", "check the path"
            ) from exc
        sticky = bool(st.st_mode & stat.S_ISVTX)
        if st.st_uid not in (uid, 0):
            raise _refuse(
                p,
                f"is in {d}, which is owned by uid {st.st_uid}",
                "keep the file under a directory only you or root own",
            )
        if st.st_mode & stat.S_IWOTH and not sticky:
            raise _refuse(p, f"is in {d}, which any user can write to", f"chmod o-w '{d}'")
        if st.st_mode & stat.S_IWGRP and not (st.st_uid == 0 or sticky):
            raise _refuse(p, f"is in {d}, which is group-writable", f"chmod g-w '{d}'")
        parent = os.path.dirname(d)
        if parent == d:
            return resolved
        d = parent


def check_token_file_policy(path: str | os.PathLike[str], *, uid: int | None = None) -> None:
    """The installer's checks on a token file (``serve`` itself checks content only).

    The file must be an absolute path to a regular file (not a symlink) owned by
    ``uid`` (default: the current user) with no group/other permission bits, in a
    directory chain ``check_token_dir_chain`` accepts. Raises ``ConfigError``.
    """
    uid = os.getuid() if uid is None else uid
    p = os.fspath(path)
    if not os.path.isabs(p):
        raise _refuse(p, "must be an absolute path", "pass the full path to the file")
    try:
        st = os.lstat(p)
    except FileNotFoundError:
        raise _refuse(p, "does not exist", "create it (install -m 600 /dev/null PATH)") from None
    except OSError as exc:
        raise _refuse(p, f"cannot be inspected ({exc.strerror})", "check the path") from exc
    if stat.S_ISLNK(st.st_mode):
        raise _refuse(p, "is a symlink", "point the setting at the real file")
    if not stat.S_ISREG(st.st_mode):
        raise _refuse(p, "is not a regular file", "use a plain file")
    if st.st_uid != uid:
        raise _refuse(p, f"is owned by uid {st.st_uid}, not you (uid {uid})", f"chown {uid} '{p}'")
    if st.st_mode & 0o077:
        raise _refuse(p, "is readable or writable by group/other", f"chmod 600 '{p}'")
    check_token_dir_chain(p, uid=uid)
