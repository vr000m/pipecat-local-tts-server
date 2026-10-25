"""Live latency / streaming-cadence smoke driver (Phase 5a/5b).

The pytest suite mocks the model and the WAV round-trip smoke only checks a
non-empty WAV — neither proves the R4 steady-stream contract end-to-end: that
first audio arrives quickly (low TTFB) and that ``response.audio.delta``s
DRIBBLE OUT during synthesis rather than landing in one burst at the end
(buffer-then-flush, the underrun/croak cause). This driver connects a real
client to a real server, synthesizes ONE no-newline sentence, records a
monotonic timestamp per delta, and asserts:

  1. >= 2 deltas (audio was streamed, not one shot);
  2. TTFB (commit -> first delta) <= --ttfb-bound;
  3. NOT all-at-end: the delta arrival span (first->last) is a meaningful
     fraction of the whole response time, and the first delta arrives well
     before ``response.audio.done`` — so the client's playback buffer is fed
     progressively.

Measured TTFB / RTF / cadence are printed for the phase report (no fabrication —
these are the real numbers from this run). Backend-agnostic: works for ``tone``
(deterministic, fast) and the streaming model backends.

Usage:
  uv run python tests/smoke/latency_smoke.py --socket-path /tmp/tts.sock \
      [--text "..."] [--voice V] [--ttfb-bound SECS] [--timeout SECS]
Exit code 0 only if every assertion holds.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import sys

from tts_server.client import TTSClient

# A single unbroken line (NO newline): a streaming backend must yield multiple
# native chunks for this purely from stream/streaming_interval — a newline would
# let a per-segment (Kokoro-style) yield satisfy the count falsely.
_DEFAULT_TEXT = (
    "The quick brown fox jumps over the lazy dog and then keeps on running for quite a while."
)


async def collect_response(
    client: TTSClient, text: str, *, voice: str | None, timeout: float
) -> dict:
    """Append + commit ``text`` on a connected client and record the response.

    Returns ``t_commit`` / ``delta_ts`` (monotonic loop time per delta),
    ``seqs``, ``pcm`` (the decoded audio bytes concatenated) and ``done`` (the
    ``response.audio.done`` event). Raises ``SystemExit`` on a server
    ``response.failed`` / ``error`` and ``TimeoutError`` past ``timeout``.
    Shared with ``supervised_smoke.py`` (the app-path smoke).
    """
    loop = asyncio.get_running_loop()
    await client.append(text)
    t_commit = loop.time()
    # voice is a top-level commit field (not an extra); default sampling is used.
    await client.commit(voice=voice or None)
    rec: dict = {"t_commit": t_commit, "delta_ts": [], "seqs": [], "done": None, "done_ts": None}
    pcm = bytearray()

    async def _drive() -> None:
        async for ev in client.events():
            t = ev.get("type")
            if t == "response.audio.delta":
                rec["delta_ts"].append(loop.time())
                rec["seqs"].append(ev.get("seq"))
                pcm.extend(base64.b64decode(ev["audio"]))
            elif t == "response.audio.done":
                rec["done_ts"] = loop.time()
                rec["done"] = ev
                return
            elif t in ("response.failed", "error"):
                raise SystemExit(f"server returned {t}: {ev}")

    await asyncio.wait_for(_drive(), timeout)
    rec["pcm"] = bytes(pcm)
    return rec


def cadence_metrics(rec: dict, rate: int) -> dict:
    """TTFB / span / total / max_gap / audio seconds / RTF of a ``collect_response``."""
    delta_ts = rec["delta_ts"]
    ttfb = delta_ts[0] - rec["t_commit"]
    span = delta_ts[-1] - delta_ts[0]
    total = rec["done_ts"] - rec["t_commit"]
    max_gap = max((b - a for a, b in zip(delta_ts, delta_ts[1:], strict=False)), default=0.0)
    audio_s = (len(rec["pcm"]) / 2) / rate  # int16 mono
    rtf = total / audio_s if audio_s else float("nan")
    return {
        "deltas": len(delta_ts),
        "ttfb": ttfb,
        "span": span,
        "total": total,
        "audio_s": audio_s,
        "rtf": rtf,
        "max_gap": max_gap,
    }


def format_metrics(m: dict) -> str:
    return (
        f"measured: deltas={m['deltas']} ttfb={m['ttfb']:.3f}s span={m['span']:.3f}s "
        f"total={m['total']:.3f}s audio={m['audio_s']:.2f}s rtf={m['rtf']:.3f} "
        f"max_gap={m['max_gap']:.3f}s"
    )


async def _run(args: argparse.Namespace) -> int:
    assert "\n" not in args.text, "precondition: --text must have no newline"
    if args.uri:
        client = TTSClient(uri=args.uri)
    elif args.socket_path:
        client = TTSClient(socket_path=args.socket_path)
    else:
        client = TTSClient(host=args.host, port=args.port)

    hello = await client.connect()
    rate = hello["audio"]["rate"]
    caps = hello.get("capabilities", {})
    print(
        f"connected: backend={hello.get('backend')} rate={rate} streaming={caps.get('streaming')}"
    )

    rc = 0
    try:
        rec = await collect_response(client, args.text, voice=args.voice, timeout=args.timeout)
    finally:
        await client.close()

    if not rec["delta_ts"] or rec["done"] is None:
        print(f"FAIL: no deltas/done (deltas={len(rec['delta_ts'])})")
        return 1

    m = cadence_metrics(rec, rate)
    delta_ts, ttfb, span, total = rec["delta_ts"], m["ttfb"], m["span"], m["total"]
    print(format_metrics(m))

    # 1. streamed, not one shot.
    if len(delta_ts) < 2:
        print(f"FAIL: expected >=2 deltas, got {len(delta_ts)}")
        rc = 1
    # 2. TTFB bound.
    if ttfb > args.ttfb_bound:
        print(f"FAIL: TTFB {ttfb:.3f}s exceeds bound {args.ttfb_bound}s")
        rc = 1
    # 3. not all-at-end: deltas span a meaningful fraction of the response, and
    #    the first delta arrives well before done. A buffer-then-flush backend
    #    would show span≈0 (all deltas bunched at the end) and ttfb≈total.
    if total > 0:
        if span < 0.3 * total:
            print(
                f"FAIL: deltas bunched (span {span:.3f}s < 30% of total {total:.3f}s) "
                "— looks like buffer-then-flush, not steady streaming"
            )
            rc = 1
        if ttfb > 0.6 * total:
            print(f"FAIL: first audio late (ttfb {ttfb:.3f}s > 60% of total {total:.3f}s)")
            rc = 1
    print("PASS: steady streaming + TTFB bound" if rc == 0 else "latency smoke FAILED")
    return rc


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--uri")
    ap.add_argument("--socket-path")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--text", default=_DEFAULT_TEXT)
    ap.add_argument("--voice")
    ap.add_argument(
        "--ttfb-bound",
        type=float,
        default=3.0,
        help="max acceptable commit->first-delta seconds (generous; model prefill dominates)",
    )
    ap.add_argument("--timeout", type=float, default=120.0)
    return asyncio.run(_run(ap.parse_args()))


if __name__ == "__main__":
    sys.exit(main())
