"""Render a pipecat.tts-server LaunchAgent plist safely (port transport).

Uses ``plistlib`` so XML escaping / quoting is handled by the stdlib instead of
``sed`` string substitution (which would let a hostile env value break out of
``<string>`` and inject arbitrary ``ProgramArguments`` — a login-time RCE). This
is the injection-sensitive component of the launchd ops surface, so EVERY
interpolated value is allowlist-validated *and* XML-escaped via ``plistlib``.

This mirrors the *structure* of the sibling stt repo's ``render_stt_plist.py``
but diverges by design: the tts server speaks a **port** transport, so the
``ProgramArguments`` carry ``--host``/``--port`` (not ``--socket-path``) and the
installer keys on ``PIPECAT_TTS_HOST``/``PIPECAT_TTS_PORT`` env vars.

Auth is **fail-closed**: when ``host`` is a non-loopback address and no
``auth_token_file`` is supplied, ``render_plist`` RAISES rather than emit a
token-less plist that would bind a cleartext TCP listener to a routable address.
On loopback the ``--auth-token-file`` flag is simply omitted.

The core is the pure function ``render_plist(...) -> str`` so it is unit-testable
with no launchctl / filesystem dependency. ``main()`` reads env vars (see
``scripts/install_tts_agent.sh``), allowlist-validates them, and writes the file.
"""

from __future__ import annotations

import os
import plistlib
import re
import sys
from pathlib import Path

# This script is always invoked by the project venv's interpreter (see
# ``scripts/install_tts_agent.sh``), which has ``tts_server`` installed, so the
# loopback helper imports cleanly regardless of CWD. Guard the import so a
# hand-run with the wrong interpreter fails with the same actionable hint the
# shell guard gives, not an opaque traceback.
try:
    from tts_server.env import is_loopback_host
except ImportError:
    print(
        "error: cannot import tts_server — run this with the project venv "
        "interpreter (.venv/bin/python after 'uv sync')",
        file=sys.stderr,
    )
    sys.exit(1)

DEFAULT_LABEL = "pipecat.tts-server"

# Absolute path. These values flow into plistlib (which XML-escapes them) and are
# passed to launchd as argv — never through a shell — so the only real constraints
# are "absolute" and "no control characters". Apostrophes, parentheses, commas,
# spaces, and non-ASCII (e.g. an accented macOS username like /Users/José) are all
# legitimate path characters and must not be rejected.
_ABSPATH_RE = re.compile(r"^/[^\x00-\x1f]+$")
_MODEL_RE = re.compile(r"^[A-Za-z0-9._/\-]+$")
# The four merge-time backends (see the justfile _resolve map + README port
# table). ``dia`` is reserved and intentionally NOT accepted here.
_BACKEND_RE = re.compile(r"^(tone|kokoro|voxtral_tts|pocket_tts)$")
_LABEL_RE = re.compile(r"^[A-Za-z0-9._\-]+$")
# A bare hostname / IP literal. Allows loopback names and IPv4/IPv6 literals;
# the loopback-vs-remote auth decision is made by ``is_loopback_host``, not this
# pattern. Brackets are excluded — pass the bare host (e.g. ``::1``), not a URI.
_HOST_RE = re.compile(r"^[A-Za-z0-9._:\-]+$")
# PIPECAT_TTS_KOKORO_EXTRA_LANGS — a comma-separated list of ISO codes (e.g.
# ``ja,zh``). Validated before being baked into the plist's EnvironmentVariables.
_EXTRA_LANGS_RE = re.compile(r"^[A-Za-z]{2,8}(,[A-Za-z]{2,8})*$")
# TTS_WS_PING_INTERVAL / TTS_WS_PING_TIMEOUT — websocket keepalive knobs the server
# reads via ``tts_server.__main__._resolve_keepalive``. Accept a disable token or a
# bounded positive number; the server re-validates, so this allowlist is
# defense-in-depth (it rejects ``inf``/``nan``/negatives, like the other patterns
# here). The digit count is CAPPED at 9 integer / 6 fractional: an unbounded run of
# digits overflows ``float()`` to ``+inf`` at server startup, which
# ``_resolve_keepalive`` rejects — a launchd boot loop from an install that
# "passed". Nine seconds-digits (~31 years) is absurdly generous for a timeout, so
# the cap rejects the overflow case here instead, keeping install-time validation
# in step with the server's runtime check.
_KEEPALIVE_RE = re.compile(
    r"^(none|off|disable|disabled|[0-9]{1,9}(\.[0-9]{1,6})?)$", re.IGNORECASE
)


def _log_basename(label: str) -> str:
    """Derive a per-agent log-file basename from the launchd label.

    This is the **single source** for the log basename: the renderer bakes the
    resulting ``StandardOutPath``/``StandardErrorPath`` into the plist, and
    ``scripts/install_tts_agent.sh logs`` reads those paths back out of the
    installed plist (it does NOT recompute the basename), so there is no second
    copy to drift. The branch matches the string literal, NOT ``DEFAULT_LABEL`` —
    keying on the constant would silently remap the new default if the constant
    ever moved. Any other label gets a collision-free basename by replacing
    ``.`` separators with ``-`` (e.g. ``pipecat.tts-server.kokoro`` ->
    ``pipecat-tts-server-kokoro``).
    """
    if label == "pipecat.tts-server":
        return "pipecat-tts"
    return label.replace(".", "-")


def render_plist(
    backend: str,
    label: str,
    host: str,
    port: int,
    *,
    python: str,
    repo_root: str,
    home: str,
    log_dir: str,
    model: str | None = None,
    auth_token_file: str | None = None,
    extra_env: dict[str, str] | None = None,
) -> str:
    """Return the plist XML for a port-bound tts-server LaunchAgent.

    Pure function: no env reads, no filesystem writes, no launchctl. Every
    interpolated value is placed through ``plistlib`` (XML-escaped). Auth is
    fail-closed: a non-loopback ``host`` with no ``auth_token_file`` raises
    ``ValueError`` rather than emit a token-less remote plist; on loopback the
    ``--auth-token-file`` flag is omitted.
    """
    if not is_loopback_host(host) and not auth_token_file:
        raise ValueError(
            f"refusing to render a token-less plist for non-loopback host {host!r}: "
            "bind a routable TCP listener only with --auth-token-file (fail-closed)"
        )

    program_args = [
        python,
        "-m",
        "tts_server",
        "serve",
        "--backend",
        backend,
        "--host",
        host,
        "--port",
        str(port),
    ]
    if model:
        program_args += ["--model", model]
    if auth_token_file:
        program_args += ["--auth-token-file", auth_token_file]
    program_args += ["--log-level", "INFO"]

    log_basename = _log_basename(label)
    plist: dict = {
        "Label": label,
        "ProgramArguments": program_args,
        "WorkingDirectory": repo_root,
        # Run at login and keep alive. ThrottleInterval guards against restart
        # storms from a fast-failing server (e.g. a missing model download).
        "RunAtLoad": True,
        "KeepAlive": True,
        "ThrottleInterval": 10,
        # launchd does NOT inherit the installer shell's environment, so any
        # server-runtime env the operator relies on MUST be baked in here.
        # Secrets (PIPECAT_TTS_AUTH_TOKEN) are deliberately NOT carried this way —
        # they would land in a plaintext plist; main() rejects that path and
        # steers the operator to --auth-token-file. ``extra_env`` carries only the
        # allowlisted, non-secret pass-through vars.
        "EnvironmentVariables": {
            "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin",
            "HOME": home,
            **(extra_env or {}),
        },
        "StandardOutPath": str(Path(log_dir) / f"{log_basename}.out"),
        "StandardErrorPath": str(Path(log_dir) / f"{log_basename}.err"),
    }
    # plistlib.dumps returns bytes; decode to a str so the function is a pure
    # text producer (the caller writes bytes under a restrictive umask).
    return plistlib.dumps(plist).decode("utf-8")


def _require(name: str, value: str | None, pattern: re.Pattern[str], hint: str) -> str:
    if not value:
        print(f"error: {name} is required", file=sys.stderr)
        sys.exit(2)
    if not pattern.match(value):
        print(
            f"error: {name}={value!r} rejected by allowlist ({hint})",
            file=sys.stderr,
        )
        sys.exit(2)
    return value


def main() -> None:
    label = os.environ.get("PIPECAT_TTS_LABEL") or DEFAULT_LABEL
    if not _LABEL_RE.match(label):
        print(
            f"error: PIPECAT_TTS_LABEL={label!r} rejected by allowlist (alphanumerics / . _ -)",
            file=sys.stderr,
        )
        sys.exit(2)

    python = _require("PYTHON", os.environ.get("PYTHON"), _ABSPATH_RE, "absolute path")
    repo_root = _require("REPO_ROOT", os.environ.get("REPO_ROOT"), _ABSPATH_RE, "absolute path")
    backend = _require(
        "BACKEND",
        os.environ.get("BACKEND"),
        _BACKEND_RE,
        "tone|kokoro|voxtral_tts|pocket_tts",
    )
    host = _require("HOST", os.environ.get("HOST"), _HOST_RE, "hostname or IP literal")
    port_raw = _require("PORT", os.environ.get("PORT"), re.compile(r"^[0-9]+$"), "integer")
    port = int(port_raw)
    if not (1 <= port <= 65535):
        print(f"error: PORT={port_raw!r} out of range (1-65535)", file=sys.stderr)
        sys.exit(2)
    home = _require("HOME", os.environ.get("HOME"), _ABSPATH_RE, "absolute path")
    log_dir = _require("LOG_DIR", os.environ.get("LOG_DIR"), _ABSPATH_RE, "absolute path")
    plist_dst = _require("PLIST_DST", os.environ.get("PLIST_DST"), _ABSPATH_RE, "absolute path")

    # MODEL and AUTH_TOKEN_FILE are optional. Validate when present.
    model = os.environ.get("MODEL") or None
    if model is not None and not _MODEL_RE.match(model):
        print(
            f"error: MODEL={model!r} rejected by allowlist (alphanumerics / . _ / -)",
            file=sys.stderr,
        )
        sys.exit(2)
    auth_token_file = os.environ.get("AUTH_TOKEN_FILE") or None
    if auth_token_file is not None and not _ABSPATH_RE.match(auth_token_file):
        print(
            f"error: AUTH_TOKEN_FILE={auth_token_file!r} rejected by allowlist (absolute path)",
            file=sys.stderr,
        )
        sys.exit(2)

    # Silent-config-drop guard: launchd does not inherit the installer shell's
    # environment, so a server-runtime env var set for `just tts-install` would be
    # silently lost in the agent. For the AUTH token that is a trust-boundary
    # regression (auth would be quietly disabled), and the secret must NOT be
    # baked into a plaintext plist either — so fail loudly and steer to the file.
    if os.environ.get("PIPECAT_TTS_AUTH_TOKEN"):
        if auth_token_file is None:
            print(
                "error: PIPECAT_TTS_AUTH_TOKEN is set, but a launchd agent does not "
                "inherit it — the agent would run with auth DISABLED. Write the token "
                "to a file and pass PIPECAT_TTS_AUTH_TOKEN_FILE (path) instead so the "
                "agent enforces auth; the token is never written into the plist.",
                file=sys.stderr,
            )
            sys.exit(2)
        # Token file supplied: the env token is redundant/ignored under launchd.
        # The file is authoritative; warn so the operator isn't misled.
        print(
            "warning: PIPECAT_TTS_AUTH_TOKEN is ignored for launchd agents; the agent "
            "uses --auth-token-file. Unset it to avoid confusion.",
            file=sys.stderr,
        )

    # Non-secret server-runtime env that must survive into the agent. launchd does
    # not inherit it, so bake the allowlisted vars into EnvironmentVariables.
    extra_env: dict[str, str] = {}
    extra_langs = os.environ.get("PIPECAT_TTS_KOKORO_EXTRA_LANGS")
    if extra_langs:
        if not _EXTRA_LANGS_RE.match(extra_langs):
            print(
                f"error: PIPECAT_TTS_KOKORO_EXTRA_LANGS={extra_langs!r} rejected by "
                "allowlist (comma-separated ISO codes, e.g. ja,zh)",
                file=sys.stderr,
            )
            sys.exit(2)
        extra_env["PIPECAT_TTS_KOKORO_EXTRA_LANGS"] = extra_langs

    # Websocket keepalive overrides. Baked under the SAME names the server reads
    # (not a PIPECAT_TTS_* alias), so the launchd process env drives
    # ``_resolve_keepalive`` directly. Unset → nothing baked → the 120s code
    # default applies.
    for ping_var in ("TTS_WS_PING_INTERVAL", "TTS_WS_PING_TIMEOUT"):
        ping_val = os.environ.get(ping_var)
        if ping_val:
            if not _KEEPALIVE_RE.match(ping_val):
                print(
                    f"error: {ping_var}={ping_val!r} rejected by allowlist "
                    "(a positive number, or none/off/disable to disable)",
                    file=sys.stderr,
                )
                sys.exit(2)
            extra_env[ping_var] = ping_val

    try:
        xml = render_plist(
            backend,
            label,
            host,
            port,
            python=python,
            repo_root=repo_root,
            home=home,
            log_dir=log_dir,
            model=model,
            auth_token_file=auth_token_file,
            extra_env=extra_env or None,
        )
    except ValueError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(2)

    out = Path(plist_dst)
    out.parent.mkdir(parents=True, exist_ok=True)
    # Write under a restrictive umask so a plist that may reference an auth
    # token file path is 0o600 from the start (defence in depth even though the
    # token itself lives in a separate file, not inline).
    prev_umask = os.umask(0o077)
    try:
        out.write_text(xml, encoding="utf-8")
    finally:
        os.umask(prev_umask)
    os.chmod(out, 0o600)
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
