"""``python -m tts_server`` entrypoint.

Subcommands (mirrors the sibling ``stt_server``):

- ``serve`` (default when no subcommand given) — runs the TTS server
  (``python -m tts_server serve --backend kokoro --model ... --socket-path ...``);
  logs the resolved backend + model at startup. Implicit when the first argv
  looks like a flag, so ``python -m tts_server --socket-path X`` keeps working.
- ``status`` — connect, send ``server.status``, print backend/model/rate/queue
  depth, exit 0 on success or 1 on failure (a preflight health probe). Useful for
  launchd keepalive scripts and humans checking "is my server up?" without
  writing a client.
- ``voices`` — list a backend's bundled voice catalog (``phonon`` only for now):
  slug, language, whether it is enabled via ``PIPECAT_TTS_PHONON_VOICES``, and
  whether its file is already in the local HF cache. ``--refresh`` diffs the live
  ``voices.jsonl`` against the bundled table and changes nothing.
"""

from __future__ import annotations

import argparse
import asyncio
import json
import logging
import math
import os
import sys
from pathlib import Path

from .backends import BACKEND_NAMES, BACKENDS, make_backend
from .server import serve

# Every backend name ``make_backend`` accepts; shared by ``serve`` and ``prefetch``.
# Derived from the registry (``tts_server.backends.BACKENDS``), never listed here.
BACKEND_CHOICES = BACKEND_NAMES

# ``TTSClient`` and ``protocol`` are imported lazily inside the status-subcommand
# helpers so the serve path (run at every launchd startup) doesn't pay for
# ``websockets.asyncio.client`` it never uses, and so the lean serve path stays
# free of any avoidable imports.


def _resolve_model(backend: str, model: str | None) -> str | None:
    """Resolve the effective model id for startup logging.

    An explicit ``--model`` always wins (passed through verbatim — the
    server-side ``--backend`` is the trust anchor). When unset, ``kokoro`` uses
    its repo default (read lazily from the backend module through the registry
    so the constant is not duplicated); ``tone`` has no model.
    """
    if model is not None:
        return model
    entry = BACKENDS.get(backend)
    return entry.default_model() if entry is not None else None


def _resolve_keepalive(env_name: str, default: float | None) -> float | None:
    """Resolve a websocket keepalive knob (seconds) from the environment.

    Unset → the code default. ``none``/``off``/``disable``/``disabled`` or any
    numeric zero (``0``, ``0.0``) → ``None`` (disable that knob). Otherwise a
    positive, finite float. An unparseable, non-finite, or negative value raises
    ``SystemExit`` rather than silently reverting to a default an operator did not
    intend.

    Keepalive is the one timing knob given env exposure (the sibling
    ``send_timeout_seconds`` / ``drain_timeout_seconds`` are code-only
    ``ServerConfig`` defaults): it's the value an operator may need to tune in the
    field to match their model's worst-case generation latency, and it must be
    reachable on a launchd-run server (baked into the plist by
    ``scripts/render_tts_plist.py``). The send/drain timeouts are internal safety
    bounds with no such tuning need, so they stay code-only by design.
    """
    raw = os.environ.get(env_name)
    if raw is None:
        return default
    val = raw.strip().lower()
    if val in {"", "none", "off", "disable", "disabled"}:
        return None
    try:
        parsed = float(val)
    except ValueError:
        raise SystemExit(f"tts_server: {env_name}={raw!r} is not a number")
    # ``float()`` accepts ``nan``/``inf``; reject them (a NaN would also slip past
    # the ``< 0`` guard below and reach websockets). Any zero disables the knob so
    # ``0`` and ``0.0`` agree with the docstring.
    if not math.isfinite(parsed):
        raise SystemExit(f"tts_server: {env_name}={raw!r} must be a finite number")
    if parsed == 0:
        return None
    if parsed < 0:
        raise SystemExit(f"tts_server: {env_name}={raw!r} must be > 0 (or 'none' to disable)")
    return parsed


def _resolve_auth_token(token_file: str | None, *, client: bool = False) -> str | None:
    # A plaintext ``--auth-token`` CLI flag is intentionally unsupported: any
    # local user could read the token via ``ps``.
    #
    # Serve path (client=False): --auth-token-file > PIPECAT_TTS_AUTH_TOKEN.
    # Probe path (client=True):  --auth-token-file > TTS_WS_TOKEN only.
    #
    # TTS_WS_TOKEN is the client-side bearer a consumer (e.g. the bot) reads to
    # authenticate against the tts_server. PIPECAT_TTS_AUTH_TOKEN is the
    # server-side bearer the launchd-run server expects. The probe MUST see
    # exactly what the bot sees — never the server-side secret:
    #   1. If the probe fell back to the server-side token it could report "ok"
    #      against a local server while the bot still 401s at startup, masking
    #      the misconfiguration this preflight exists to catch.
    #   2. If TTS_WS_URI points at a remote host, that fallback would transmit
    #      the local server-side secret to the remote endpoint.
    # The two paths stay strictly separate — never read TTS_WS_TOKEN here on the
    # serve path, and never read PIPECAT_TTS_AUTH_TOKEN on the probe path.
    if token_file:
        return Path(token_file).read_text(encoding="utf-8").strip() or None
    if client:
        client_val = (os.environ.get("TTS_WS_TOKEN") or "").strip()
        return client_val or None
    env_val = (os.environ.get("PIPECAT_TTS_AUTH_TOKEN") or "").strip()
    return env_val or None


def _load_dotenv_best_effort() -> None:
    """Load ``.env`` so ``tts_server status`` picks up the same ``TTS_WS_*``
    configuration a consumer would at startup. Optional (ImportError swallowed)
    so the serve path stays usable if python-dotenv is absent."""
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    # ``override=False`` so an already-exported env var always wins.
    load_dotenv(Path.cwd() / ".env", override=False)
    load_dotenv(Path.home() / ".secrets" / "ai.env", override=False)


def _resolve_probe_endpoint(args: argparse.Namespace) -> dict:
    """Endpoint kwargs for the status probe. If the caller passed any endpoint
    flag explicitly, honor exactly that (enforcing ``uri > socket_path >
    host+port``). Otherwise load dotenv and read ``TTS_WS_*`` via the shared
    resolver so this path stays in sync with every other client."""
    from .env import resolve_endpoint_from_env

    # Always load dotenv, even when the caller passed explicit endpoint flags:
    # auth resolution reads ``TTS_WS_TOKEN`` from ``os.environ``, so without this
    # the documented "token in .env" path gets a spurious 401 whenever the
    # operator points the probe at a specific socket/host.
    _load_dotenv_best_effort()

    cli_uri = getattr(args, "uri", None)
    cli_sock = args.socket_path
    cli_host = args.host
    cli_port = args.port
    if cli_uri or cli_sock or cli_host or cli_port is not None:
        uri = cli_uri
        sock = None if uri else cli_sock
        host = None if (uri or sock) else cli_host
        port = None if (uri or sock) else cli_port
        return {"uri": uri, "socket_path": sock, "host": host, "port": port}

    resolved = resolve_endpoint_from_env(os.environ)
    if not (resolved["uri"] or resolved["socket_path"] or resolved["host"]):
        # Library-level fallback: only honor the explicit escape hatch. No
        # app-specific default path is baked in here.
        default_sock = os.environ.get("TTS_WS_DEFAULT_SOCKET")
        if default_sock:
            resolved["socket_path"] = default_sock
    return resolved


def _add_endpoint_flags(p: argparse.ArgumentParser, *, include_uri: bool = False) -> None:
    p.add_argument("--socket-path", default=None)
    p.add_argument("--host", default=None)
    p.add_argument("--port", type=int, default=None)
    if include_uri:
        # ``--uri`` is only meaningful for the client-side probe; the serve path
        # builds its listener from socket-path/host+port directly.
        p.add_argument(
            "--uri",
            default=None,
            help="Full ws:// or wss:// URI (client-side override; wins over --socket-path/--host).",
        )
    p.add_argument(
        "--auth-token-file",
        default=None,
        help="Path to a file containing the auth token (whitespace-stripped).",
    )


def _preflight_listener(args: argparse.Namespace) -> None:
    """Fail in milliseconds, not after a model load, when the listener can't bind.

    ``TTSServer.start()`` loads the backend BEFORE binding (the rate comes from
    the model), so a busy port would otherwise surface only after a multi-GB
    download. Mirrors what the real bind will do: the stale-socket probe for a
    UDS, and a ``SO_REUSEADDR`` bind (what asyncio sets on POSIX) for TCP. The
    TOCTOU window is accepted; the real bind still reports through the same
    error classifier.
    """
    import socket

    from .server import _clear_stale_unix_socket

    if args.socket_path:
        _clear_stale_unix_socket(Path(args.socket_path))
        return
    if not args.host or not args.port:
        return  # missing endpoint (ServerConfig reports it) or port 0 (ephemeral)
    for family, socktype, proto, _canon, addr in socket.getaddrinfo(
        args.host, args.port, type=socket.SOCK_STREAM
    ):
        with socket.socket(family, socktype, proto) as probe:
            probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            probe.bind(addr)


def _cmd_serve(args: argparse.Namespace) -> None:
    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    if not args.supervised:
        _run_serve(args)
        return

    # Supervised mode (driven by the macOS app): stdout carries only JSON
    # lifecycle events; logs stay on stderr; stdin EOF stops the server. The
    # policy lives in ``supervise``; this just supplies the serve run.
    from . import supervise

    def _run(**hooks) -> None:
        _preflight_listener(args)
        _run_serve(args, **hooks)

    supervise.run_supervised(_run)


def _run_serve(args: argparse.Namespace, **serve_kwargs) -> None:
    resolved_model = _resolve_model(args.backend, args.model)
    # Startup model logging (R6): log the resolved backend + model BEFORE the
    # (potentially slow) model load so an operator sees what is being loaded.
    logging.getLogger("tts_server").info(
        "tts_server: starting (backend=%s model=%s)", args.backend, resolved_model
    )
    try:
        backend = make_backend(args.backend, resolved_model)
    except ValueError as exc:
        # ``make_backend`` raises ValueError for an unknown name; the CLI turns
        # that into a clean exit rather than a traceback. (``--backend`` choices
        # normally prevent this, but the translation keeps the contract honest.)
        raise SystemExit(f"tts_server: {exc}")
    from . import protocol as P

    asyncio.run(
        serve(
            backend,
            socket_path=args.socket_path,
            host=args.host,
            port=args.port,
            auth_token=_resolve_auth_token(args.auth_token_file),
            ping_interval_seconds=_resolve_keepalive(
                "TTS_WS_PING_INTERVAL", P.KEEPALIVE_PING_INTERVAL_SECONDS
            ),
            ping_timeout_seconds=_resolve_keepalive(
                "TTS_WS_PING_TIMEOUT", P.KEEPALIVE_PING_TIMEOUT_SECONDS
            ),
            **serve_kwargs,
        )
    )


async def _probe_status(args: argparse.Namespace) -> dict:
    from . import protocol as P
    from .client import TTSClient, format_host_for_uri, is_cleartext_remote

    endpoint = _resolve_probe_endpoint(args)
    auth_token = _resolve_auth_token(args.auth_token_file, client=True)

    # Same cleartext-token guard as the client's runtime resolver: if a bearer is
    # configured and the effective endpoint is cleartext-ws to a non-loopback
    # host, warn before opening the connection.
    if auth_token:
        effective_uri = endpoint.get("uri")
        if (
            not effective_uri
            and not endpoint.get("socket_path")
            and endpoint.get("host")
            and endpoint.get("port") is not None
        ):
            effective_uri = f"ws://{format_host_for_uri(endpoint['host'])}:{endpoint['port']}/"
        if effective_uri and is_cleartext_remote(effective_uri):
            print(
                f"tts_server: warning — auth token will be sent in cleartext to {effective_uri}. "
                "Use wss:// for remote hosts, or bind to loopback (127.0.0.1 / ::1 / UDS).",
                file=sys.stderr,
            )

    client = TTSClient(**endpoint, auth_token=auth_token)

    async def _run() -> dict:
        hello = await client.connect()
        await client.status()
        # Drain until the server.status reply, ignoring any session.* that may
        # arrive first.
        async for ev in client.events():
            if ev.get("type") == P.EVT_SERVER_STATUS:
                return {"hello": hello, "status": ev}
        raise RuntimeError("socket closed before server.status reply")

    try:
        # Single wall-clock budget for the whole probe (connect + status
        # round-trip) so ``--timeout`` means what ``--help`` says.
        return await asyncio.wait_for(_run(), timeout=args.timeout)
    finally:
        try:
            await client.close_session()
        except Exception:  # noqa: BLE001, S110
            # Best-effort teardown after the probe: any close failure here is
            # moot, we still proceed to close the socket below.
            pass
        try:
            await client.close()
        except Exception:  # noqa: BLE001, S110
            # Best-effort: nothing left to do with the underlying socket
            # once we've already reported the probe's outcome.
            pass


def _cmd_status(args: argparse.Namespace) -> None:
    logging.basicConfig(level=logging.WARNING)
    try:
        result = asyncio.run(_probe_status(args))
    except (FileNotFoundError, ConnectionRefusedError) as exc:
        print(f"tts_server: not reachable ({exc})", file=sys.stderr)
        raise SystemExit(1)
    except TimeoutError:
        print(f"tts_server: timed out after {args.timeout}s", file=sys.stderr)
        raise SystemExit(1)
    except OSError as exc:
        print(f"tts_server: socket error ({exc})", file=sys.stderr)
        raise SystemExit(1)
    except Exception as exc:  # noqa: BLE001
        # Deliberate top-level catch-all: this is a CLI entry point, and any
        # exception the specific cases above don't cover must still surface
        # as a clean CLI failure, not a raw traceback.
        print(f"tts_server: probe failed ({exc})", file=sys.stderr)
        raise SystemExit(1)

    if args.json:
        print(json.dumps(result, indent=2, sort_keys=True))
        return

    hello = result["hello"]
    status = result["status"]
    caps = hello.get("capabilities", {})
    audio = hello.get("audio", {})
    print("tts_server: ok")
    print(f"  protocol_version: {hello.get('protocol_version')}")
    backend = hello.get("backend") or {}
    print(f"  backend: {backend.get('name')} (model: {backend.get('model')})")
    print(
        "  audio: {fmt} @ {rate} Hz / {ch}ch".format(
            fmt=audio.get("format"),
            rate=audio.get("rate"),
            ch=audio.get("channels"),
        )
    )
    print(
        "  capabilities: streaming={st} binary_audio={b} voice_count={vc}".format(
            st=caps.get("streaming"),
            b=caps.get("binary_audio"),
            vc=caps.get("voice_count"),
        )
    )
    print(f"  session_id: {status.get('session_id')}")
    print(f"  queue_depth: {status.get('queue_depth')}")
    # Decided default #4: the full voice list is exposed via server.status only.
    voices = status.get("voices")
    if isinstance(voices, list) and voices:
        preview = ", ".join(voices[:8])
        more = "" if len(voices) <= 8 else f", ... (+{len(voices) - 8} more)"
        print(f"  voices ({len(voices)}): {preview}{more}")
    print(f"  buffered_chars: {status.get('buffered_chars')}")
    uptime = status.get("uptime_seconds")
    if isinstance(uptime, (int, float)):
        print(f"  session_uptime: {uptime:.1f}s")
    pid = status.get("pid")
    if pid is not None:
        print(f"  pid: {pid}")


def _cmd_voices(args: argparse.Namespace) -> None:
    """``voices`` subcommand: list (and optionally ``--refresh``-diff) the catalog.

    Formatting only; the catalog logic lives in ``backends.phonon`` (lean at module
    load — it imports ``huggingface_hub`` only inside its download seam) and the
    stdlib-only ``backends.phonon_voices`` (the drift diff)."""
    if args.backend != "phonon":
        print(f"tts_server: no voice catalog for backend {args.backend!r}", file=sys.stderr)
        raise SystemExit(2)
    from .backends import phonon, phonon_voices

    rows = phonon.voice_catalog_rows()
    if args.language:
        rows = [r for r in rows if r["language"] == args.language]
    if args.json:
        print(json.dumps(rows))
    else:
        print(f"{'slug':<28} {'lang':<5} {'enabled':<8} cached")
        for r in rows:
            print(
                f"{r['slug']:<28} {r['language']:<5} "
                f"{'yes' if r['enabled'] else 'no':<8} "
                f"{'?' if r['cached'] is None else 'yes' if r['cached'] else 'no'}"
            )
    if args.refresh:
        try:
            drift = phonon_voices.voice_catalog_drift(phonon.fetch_live_voice_catalog())
        except Exception as e:
            print(f"tts_server: --refresh failed: {e}", file=sys.stderr)
            raise SystemExit(1)
        out = sys.stderr if args.json else sys.stdout
        print(
            "refresh: "
            + ", ".join(f"{len(items)} {label}" for label, items in drift.items())
            + " vs the bundled catalog (nothing modified)",
            file=out,
        )
        for label, items in drift.items():
            for item in items:
                print(f"  {label}: {item}", file=out)


def _cmd_prefetch(args: argparse.Namespace) -> None:
    """``prefetch`` subcommand: download (or ``--check``) a backend's weights."""
    logging.basicConfig(
        level=args.log_level,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    from . import prefetch

    model = _resolve_model(args.backend, args.model)
    code = prefetch.run_prefetch(args.backend, model, check=args.check, json_mode=args.json)
    if code:
        raise SystemExit(code)


def build_parser() -> argparse.ArgumentParser:
    """Construct the ``tts_server`` argument parser (serve + status + voices subcommands).

    Extracted from ``main()`` so tests can assert the ``--backend`` choices tuple
    accepts a wired backend and rejects an unknown one — the choices half of the
    dual-wire (resolver + argparse) that a ``make_backend`` unit test alone does
    NOT cover (R7 / Phase-5 per-sub-phase checklist)."""
    parser = argparse.ArgumentParser(prog="tts_server")
    subparsers = parser.add_subparsers(dest="cmd")

    p_serve = subparsers.add_parser("serve", help="run the server (default)")
    _add_endpoint_flags(p_serve)
    p_serve.add_argument("--backend", choices=BACKEND_CHOICES, default="tone")
    # Default None so ``_resolve_model`` applies a backend-aware fallback
    # (the Kokoro repo for ``kokoro``; no model for ``tone``). An explicit value
    # always wins and is passed through verbatim.
    p_serve.add_argument("--model", default=None)
    p_serve.add_argument("--log-level", default="INFO")
    p_serve.add_argument(
        "--supervised",
        action="store_true",
        help=(
            "for a supervising app: print JSON lifecycle events (ready/error) on "
            "stdout and stop when stdin reaches EOF"
        ),
    )

    p_prefetch = subparsers.add_parser(
        "prefetch", help="download a backend's model weights without serving"
    )
    p_prefetch.add_argument("--backend", choices=BACKEND_CHOICES, required=True)
    p_prefetch.add_argument("--model", default=None)
    p_prefetch.add_argument(
        "--check",
        action="store_true",
        help="report whether the weights are already cached (never touches the network)",
    )
    p_prefetch.add_argument("--json", action="store_true", help="emit JSON-lines events on stdout")
    p_prefetch.add_argument("--log-level", default="WARNING")

    p_status = subparsers.add_parser(
        "status", help="probe a running server with server.status and print its reply"
    )
    _add_endpoint_flags(p_status, include_uri=True)
    p_status.add_argument(
        "--timeout", type=float, default=3.0, help="overall probe timeout in seconds"
    )
    p_status.add_argument("--json", action="store_true", help="emit raw JSON instead of text")

    p_voices = subparsers.add_parser(
        "voices", help="list a backend's bundled voice catalog (phonon only)"
    )
    p_voices.add_argument("--backend", default="phonon")
    p_voices.add_argument("--language", default=None, help="filter by language code (e.g. en)")
    p_voices.add_argument("--json", action="store_true", help="emit JSON rows")
    p_voices.add_argument(
        "--refresh",
        action="store_true",
        help="diff the live voices.jsonl against the bundled table (changes nothing)",
    )
    return parser


def main() -> None:
    # Accept both ``python -m tts_server <flags>`` (legacy serve path) and
    # ``python -m tts_server <subcommand> <flags>``. Detect the latter by a
    # non-flag first argv; otherwise dispatch to ``serve``. Top-level
    # ``-h``/``--help`` is NOT reinterpreted as a serve flag.
    argv = sys.argv[1:]
    top_level_help = argv and argv[0] in {"-h", "--help"}
    if (
        argv
        and not argv[0].startswith("-")
        and argv[0] in {"serve", "status", "voices", "prefetch"}
    ):
        sub, rest = argv[0], argv[1:]
    elif top_level_help:
        sub, rest = None, argv
    else:
        sub, rest = "serve", argv

    parser = build_parser()

    if sub is None:
        # Top-level --help path: argparse prints both subcommands and exits.
        parser.parse_args(rest)
        return
    args = parser.parse_args([sub, *rest])
    if args.cmd == "status":
        _cmd_status(args)
    elif args.cmd == "voices":
        _cmd_voices(args)
    elif args.cmd == "prefetch":
        _cmd_prefetch(args)
    else:
        _cmd_serve(args)


if __name__ == "__main__":
    main()
