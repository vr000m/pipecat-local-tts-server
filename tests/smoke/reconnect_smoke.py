#!/usr/bin/env python3
"""Live single-endpoint reconnect smoke test for the pipecat-local-tts-server.

Exercises the crash-restart-reconnect cycle the unit suite skips: a real server
process is started, synthesized against, **SIGKILLed** (leaving a stale socket),
restarted on the same socket, and a SINGLE client reconnects with capped backoff
and synthesizes again. It compares the audio returned before the kill vs. after
the reconnect, so a backend whose restart/reload path returns no audio (or a
different rate) is caught — not just "the socket rebinds".

Why SIGKILL, not SIGINT: a graceful Ctrl-C unlinks the socket on exit, so the
restart never touches the auto-clear path. SIGKILL leaves the socket file behind
(the crash / power-loss case the server's stale-socket reclaim exists FOR), so
the restart must clear it. This is the stricter test.

Why the driver owns the server: one client must observe the disconnect and then
reconnect-with-backoff across a real process restart. `TTSClient` is connect-once
by design (reconnect-with-backoff is the consumer's responsibility — see R4), so
the backoff loop lives HERE, doubling as a reference for how a consumer reconnects.

Per-backend extension: add a row to ``DEFAULT_VOICE`` (and, if needed, a
backend-specific ``--model``) when voxtral_tts / pocket_tts land. The same
before/after sample-count comparison then catches reload-logic errors specific to
each backend's implementation differences.

Usage:
    python tests/smoke/reconnect_smoke.py --backend tone
    python tests/smoke/reconnect_smoke.py --backend kokoro --voice af_heart
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import shutil
import signal
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import Any

try:
    import websockets
except ImportError:  # pragma: no cover - dependency hint
    sys.exit("This client needs the 'websockets' package: uv pip install websockets")

# Per-backend default voice. Extend as new streaming backends land (voxtral_tts,
# pocket_tts) so the reconnect cycle is verified per-backend.
DEFAULT_VOICE = {
    "tone": "tone",
    "kokoro": "af_heart",
    # "voxtral_tts": "casual_male",
    # "pocket_tts": None,
}

TEXT = "The quick brown fox jumps over the lazy dog."


async def _synthesize(sock: str, text: str, voice: str | None, timeout: float) -> dict[str, Any]:
    """One full round-trip on a fresh connection; return audio accounting."""
    async with websockets.unix_connect(sock) as ws:
        hello = json.loads(await ws.recv())
        rate = hello.get("audio", {}).get("rate")
        if voice is not None:
            await ws.send(json.dumps({"type": "session.update", "voice": voice}))
        await ws.send(json.dumps({"type": "input_text.append", "event_id": "r", "text": text}))
        await ws.send(json.dumps({"type": "input_text.commit", "event_id": "r-commit"}))
        frames = 0
        audio_bytes = 0
        duration_ms = None
        async with asyncio.timeout(timeout):
            while True:
                msg = json.loads(await ws.recv())
                t = msg.get("type")
                if t == "response.audio.delta":
                    frames += 1
                    audio_bytes += len(base64.b64decode(msg.get("audio", "")))
                elif t == "response.audio.done":
                    duration_ms = msg.get("duration_ms")
                    break
                elif t in ("error", "response.failed"):
                    raise RuntimeError(f"synthesis rejected: {msg.get('error')}")
    return {
        "frames": frames,
        "bytes": audio_bytes,
        "samples": audio_bytes // 2,  # int16 mono
        "duration_ms": duration_ms,
        "rate": rate,
    }


def _start_server(backend: str, model: str | None, sock: str, log_path: Path) -> subprocess.Popen:
    """Spawn the server with the SAME interpreter the driver runs under (venv has
    the backend deps available, so no nested `uv run` is needed)."""
    cmd = [sys.executable, "-m", "tts_server", "serve", "--backend", backend, "--socket-path", sock]
    if model:
        cmd += ["--model", model]
    log = open(log_path, "w")
    return subprocess.Popen(cmd, stdout=log, stderr=subprocess.STDOUT)


def _wait_socket(sock: str, proc: subprocess.Popen, timeout: float) -> bool:
    """Poll for the socket; fail fast if the server process dies first."""
    deadline = time.monotonic() + timeout
    p = Path(sock)
    while time.monotonic() < deadline:
        if p.is_socket():
            return True
        if proc.poll() is not None:
            return False
        time.sleep(0.25)
    return p.is_socket()


async def _connect_with_backoff(
    sock: str,
    text: str,
    voice: str | None,
    *,
    attempts: int,
    base: float,
    cap: float,
    timeout: float,
) -> tuple[dict[str, Any], int, float]:
    """Reconnect-with-backoff: retry a full round-trip until it succeeds. Returns
    (result, attempts_used, elapsed_s). Capped exponential backoff; tolerates the
    socket not existing yet (server still reloading its model)."""
    start = time.monotonic()
    last_exc: Exception | None = None
    for i in range(1, attempts + 1):
        try:
            res = await _synthesize(sock, text, voice, timeout)
            return res, i, time.monotonic() - start
        except (ConnectionRefusedError, FileNotFoundError, OSError) as exc:
            last_exc = exc
            delay = min(cap, base * (2 ** (i - 1)))
            print(
                f"   reconnect attempt {i} failed ({type(exc).__name__}); backing off {delay:.2f}s"
            )
            await asyncio.sleep(delay)
    raise RuntimeError(f"reconnect failed after {attempts} attempts: {last_exc}")


async def main(args: argparse.Namespace) -> int:
    voice = args.voice if args.voice is not None else DEFAULT_VOICE.get(args.backend)
    run_dir = Path(tempfile.mkdtemp(prefix="tts-reconnect."))
    sock = str(run_dir / "tts.sock")
    proc: subprocess.Popen | None = None
    fails = 0
    try:
        # --- phase 1: start + first round-trip ---------------------------------
        print(f"== start {args.backend} server (run 1) ==")
        proc = _start_server(args.backend, args.model, sock, run_dir / "server1.log")
        if not _wait_socket(sock, proc, args.load_timeout):
            print("server 1 never listened; log tail:")
            print((run_dir / "server1.log").read_text()[-1500:])
            return 1
        r1 = await _synthesize(sock, TEXT, voice, args.timeout)
        print(
            f"   round-trip 1 (voice={voice}): frames={r1['frames']} samples={r1['samples']} "
            f"({r1['duration_ms']}ms @ {r1['rate']}Hz)"
        )

        # --- phase 2: SIGKILL (leaves a stale socket) --------------------------
        print("== SIGKILL server (simulates crash; leaves stale socket) ==")
        proc.send_signal(signal.SIGKILL)
        proc.wait(timeout=10)
        stale = Path(sock).is_socket()
        print(f"   server dead; socket file still present (stale)={stale}")
        # The client's next connect must be refused while the server is down.
        try:
            await _synthesize(sock, TEXT, voice, 3.0)
            print("   UNEXPECTED: synthesis succeeded with server down")
            fails += 1
        except (ConnectionRefusedError, FileNotFoundError, OSError):
            print("   confirmed: connect refused while server down (as expected)")

        # --- phase 3: restart + reconnect-with-backoff -------------------------
        print(f"== restart {args.backend} server (run 2) — must reclaim the stale socket ==")
        proc = _start_server(args.backend, args.model, sock, run_dir / "server2.log")
        r2, used, elapsed = await _connect_with_backoff(
            sock,
            TEXT,
            voice,
            attempts=args.attempts,
            base=args.backoff,
            cap=8.0,
            timeout=args.timeout,
        )
        print(f"   reconnected after {used} attempt(s) in {elapsed:.1f}s")
        print(
            f"   round-trip 2 (voice={voice}): frames={r2['frames']} samples={r2['samples']} "
            f"({r2['duration_ms']}ms @ {r2['rate']}Hz)"
        )

        # --- verdict: real audio both times, same rate, comparable volume ------
        print("== verdict ==")
        if r1["samples"] == 0 or r2["samples"] == 0:
            print(f"   FAIL: empty audio (r1={r1['samples']} r2={r2['samples']} samples)")
            fails += 1
        if r1["rate"] != r2["rate"]:
            print(f"   FAIL: rate changed across restart ({r1['rate']} -> {r2['rate']})")
            fails += 1
        if r2["samples"] > 0 and r1["samples"] > 0:
            ratio = r2["samples"] / r1["samples"]
            print(
                f"   post-reconnect/pre-kill sample ratio = {ratio:.2f} "
                f"(r1={r1['samples']} r2={r2['samples']} samples)"
            )
            # Same text + model should yield a comparable sample count; a wildly
            # different count hints at a reload/logic difference worth a look.
            if not (0.5 <= ratio <= 2.0):
                print(
                    "   WARN: sample count differs >2x across restart — inspect backend reload path"
                )
        print(
            f"== summary [{args.backend}]: {'PASS' if fails == 0 else 'FAIL'} (failures={fails}) =="
        )
        return 0 if fails == 0 else 1
    finally:
        if proc is not None and proc.poll() is None:
            proc.send_signal(signal.SIGKILL)
            proc.wait(timeout=10)
        if args.keep:
            print(f"kept artifacts in {run_dir}")
        else:
            shutil.rmtree(run_dir, ignore_errors=True)


def _parse() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--backend", default="tone", choices=tuple(DEFAULT_VOICE))
    ap.add_argument("--model", default=None, help="optional model id override")
    ap.add_argument("--voice", default=None, help="voice (defaults per backend)")
    ap.add_argument("--timeout", type=float, default=180.0, help="per-synthesis timeout (s)")
    ap.add_argument("--load-timeout", type=float, default=180.0, help="model-load/socket wait (s)")
    ap.add_argument("--attempts", type=int, default=40, help="max reconnect attempts")
    ap.add_argument(
        "--backoff", type=float, default=0.5, help="base backoff (s), capped exponential"
    )
    ap.add_argument("--keep", action="store_true", help="keep temp run dir")
    return ap.parse_args()


if __name__ == "__main__":
    sys.exit(asyncio.run(main(_parse())))
