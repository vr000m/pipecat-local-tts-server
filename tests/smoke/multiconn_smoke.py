#!/usr/bin/env python3
"""Live multi-connection smoke test for the pipecat-local-tts-server.

Two (or more) clients share one backend and interleave their requests, so this
exercises the server's concurrency + backpressure machinery — the bits the
single-client reference flow never touches. It depends only on ``websockets`` +
the stdlib and speaks the wire protocol directly (see ``docs/protocol.md``).

What it checks
--------------
1. **Interleaved turns** — N connections take strict round-robin turns
   (conn A turn 1, conn B turn 1, conn A turn 2, ...), ``--turns`` each. Each
   turn is fully synthesized and verified (frames > 0) before the next
   connection's turn, so two sessions provably share the backend without
   cross-talk or starvation.

2. **Max-buffer cap** — each round's sentence grows, scaled to the server's
   advertised ``max_text_chars``. The final round deliberately exceeds the cap,
   so the server MUST reject it with ``PAYLOAD_TOO_LARGE`` (the "max buffer"
   guard). A reject here is the expected, passing outcome.

3. **429 / BUSY** — one connection fires two commits back-to-back without
   waiting for the first to finish. The second exceeds the per-connection
   in-flight cap (K=1) and MUST come back ``BUSY`` (the websocket-native 429,
   ``error.type == rate_limit_error``, with ``retry_after_ms``).

4. **Connection refused** — a ``ConnectionRefusedError`` at connect time is
   caught and reported (e.g. server not up / wrong socket).

Exit code: 0 only if every expectation held (real syntheses succeeded AND the
two guards fired as required); non-zero otherwise.

Usage:
    python tests/smoke/multiconn_smoke.py --socket-path /tmp/tts.sock
    python tests/smoke/multiconn_smoke.py --uri ws://127.0.0.1:8765 --connections 2 --turns 5
"""

from __future__ import annotations

import argparse
import asyncio
import json
import sys
from typing import Any

try:
    import websockets
except ImportError:  # pragma: no cover - dependency hint
    sys.exit("This client needs the 'websockets' package: uv pip install websockets")


# --- wire helpers -----------------------------------------------------------
async def _connect(args: argparse.Namespace) -> Any:
    if args.uri:
        return await websockets.connect(args.uri)
    return await websockets.unix_connect(args.socket_path)


async def _hello(ws: Any) -> dict:
    """First server frame is always server.hello."""
    return json.loads(await ws.recv())


async def _drain_to_terminal(ws: Any, timeout: float) -> dict:
    """Read events for one committed turn until a terminal frame.

    Terminal: response.audio.done (success), response.failed / error (reject).
    Returns a normalized result dict. Each connection has its own socket, so a
    socket only ever carries its own session's events — no cross-connection
    correlation needed.
    """
    frames = 0
    audio_bytes = 0
    async with asyncio.timeout(timeout):
        while True:
            msg = json.loads(await ws.recv())
            t = msg.get("type")
            if t == "response.audio.delta":
                frames += 1
                audio_bytes += len(msg.get("audio", "")) * 3 // 4  # base64 → bytes (approx)
            elif t == "response.audio.done":
                return {"ok": True, "frames": frames, "bytes": audio_bytes}
            elif t == "response.failed":
                return {"ok": False, "kind": "failed", "error": msg.get("error", {})}
            elif t == "error":
                return {"ok": False, "kind": "error", "error": msg.get("error", {})}
            # committed / created / session.* — keep reading


async def _send(ws: Any, obj: dict) -> None:
    await ws.send(json.dumps(obj))


def _sentence(target_chars: int) -> str:
    """A grammatical-ish sentence padded to ~target_chars."""
    base = "The quick brown fox jumps over the lazy dog "
    n = max(1, target_chars // len(base) + 1)
    return (base * n)[:target_chars].strip() + "."


def _err_code(res: dict) -> str:
    return (res.get("error") or {}).get("code", "?")


# --- phases -----------------------------------------------------------------
async def run_interleaved(conns: list[Any], turns: int, max_chars: int, timeout: float) -> int:
    """Round-robin turns; sentence length grows each round; final round > cap."""
    fails = 0
    # Length targets scaled to the cap. The last is >cap to trip PAYLOAD_TOO_LARGE.
    fracs = [0.02, 0.2, 0.5, 0.85, 1.25]
    while len(fracs) < turns:
        fracs.insert(-1, (fracs[-2] + 0.85) / 2)
    fracs = fracs[:turns]
    targets = [max(10, int(f * max_chars)) for f in fracs]

    print(f"== interleaved: {len(conns)} conns x {turns} turns (max_text_chars={max_chars}) ==")
    for r in range(turns):
        target = targets[r]
        over_cap = target > max_chars
        text = _sentence(target)
        for ci, ws in enumerate(conns):
            label = f"conn{ci} turn{r + 1} chars={len(text)}"
            evid = f"c{ci}-t{r}"
            try:
                await _send(ws, {"type": "input_text.append", "event_id": evid, "text": text})
                # An over-cap append is rejected (payload_too_large) on its own;
                # sending a commit too would leave a stale buffer_empty frame on
                # the socket. Only commit when the append was accepted.
                if not over_cap:
                    await _send(ws, {"type": "input_text.commit", "event_id": evid + "-commit"})
                res = await _drain_to_terminal(ws, timeout)
            except ConnectionRefusedError:
                print(f"   {label}: CONNECTION REFUSED")
                fails += 1
                continue
            except (asyncio.TimeoutError, websockets.ConnectionClosed) as exc:
                print(f"   {label}: FAIL ({type(exc).__name__})")
                fails += 1
                continue

            if over_cap:
                # Expected: the max-buffer guard rejects this oversized turn.
                if not res["ok"] and _err_code(res) == "payload_too_large":
                    print(f"   {label}: OK-REJECTED payload_too_large (max-buffer guard fired)")
                else:
                    print(f"   {label}: UNEXPECTED {res} (cap not enforced?)")
                    fails += 1
            else:
                if res["ok"]:
                    print(f"   {label}: OK frames={res['frames']} ~{res['bytes']}B")
                else:
                    print(f"   {label}: FAIL {res.get('kind')} {_err_code(res)}")
                    fails += 1
    return fails


async def run_busy_probe(ws: Any, max_chars: int, timeout: float) -> int:
    """Two back-to-back commits on one connection; 2nd must come back BUSY."""
    print("== 429 / BUSY probe (two in-flight on one connection) ==")
    text = _sentence(min(800, max_chars // 2))
    # Fire two commits without reading the first's terminal frame in between.
    await _send(ws, {"type": "input_text.append", "event_id": "b1", "text": text})
    await _send(ws, {"type": "input_text.commit", "event_id": "b1-commit"})
    await _send(ws, {"type": "input_text.append", "event_id": "b2", "text": text})
    await _send(ws, {"type": "input_text.commit", "event_id": "b2-commit"})

    # Collect terminal frames for both commits. One should succeed, one BUSY.
    saw_busy = False
    saw_ok = False
    try:
        async with asyncio.timeout(timeout):
            results: list[dict] = []
            frames = 0
            while len(results) < 2:
                msg = json.loads(await ws.recv())
                t = msg.get("type")
                if t == "response.audio.delta":
                    frames += 1
                elif t == "response.audio.done":
                    results.append({"ok": True, "frames": frames})
                    frames = 0
                elif t in ("error", "response.failed"):
                    results.append({"ok": False, "error": msg.get("error", {})})
    except (asyncio.TimeoutError, websockets.ConnectionClosed) as exc:
        print(f"   FAIL ({type(exc).__name__}) waiting for BUSY/done")
        return 1

    for res in results:
        if res["ok"]:
            saw_ok = True
        elif _err_code(res) == "busy":
            saw_busy = True
            retry = (res.get("error") or {}).get("retry_after_ms")
            print(f"   got BUSY (429 analog), retry_after_ms={retry}")
    if saw_ok:
        print("   first commit synthesized OK")
    if saw_busy and saw_ok:
        print("   PASS (per-connection in-flight cap enforced)")
        return 0
    print(f"   UNEXPECTED: saw_ok={saw_ok} saw_busy={saw_busy} results={results}")
    return 1


async def main(args: argparse.Namespace) -> int:
    # Connect all clients (this is also the connection-refused probe).
    conns: list[Any] = []
    try:
        for _ in range(args.connections):
            conns.append(await _connect(args))
    except (ConnectionRefusedError, FileNotFoundError, OSError) as exc:
        print(f"CONNECTION REFUSED / unreachable: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1

    try:
        hello = await _hello(conns[0])
        for ws in conns[1:]:
            await _hello(ws)
        caps = hello.get("capabilities", {})
        max_chars = caps.get("max_text_chars", 2000)
        rate = hello.get("audio", {}).get("rate")
        print(f"connected {len(conns)} clients; rate={rate} max_text_chars={max_chars}")

        fails = 0
        fails += await run_interleaved(conns, args.turns, max_chars, args.timeout)
        if not args.no_busy_probe:
            fails += await run_busy_probe(conns[0], max_chars, args.timeout)

        print(f"== summary: {'PASS' if fails == 0 else 'FAIL'} (failures={fails}) ==")
        return 0 if fails == 0 else 1
    finally:
        for ws in conns:
            await ws.close()


def _parse() -> argparse.Namespace:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--uri", help="full ws:// URI (highest precedence)")
    ap.add_argument("--socket-path", help="Unix domain socket path")
    ap.add_argument("--connections", type=int, default=2)
    ap.add_argument("--turns", type=int, default=5, help="turns per connection")
    ap.add_argument("--timeout", type=float, default=60.0, help="per-turn timeout (s)")
    ap.add_argument("--no-busy-probe", action="store_true", help="skip the 429/BUSY probe")
    args = ap.parse_args()
    if not args.uri and not args.socket_path:
        ap.error("one of --uri or --socket-path is required")
    return args


if __name__ == "__main__":
    sys.exit(asyncio.run(main(_parse())))
