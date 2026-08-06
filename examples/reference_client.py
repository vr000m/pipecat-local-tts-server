#!/usr/bin/env python3
"""Lightweight reference client for the pipecat-local-tts-server WebSocket protocol.

This is a *testing* client, not the packaged `tts_server.client` (Phase 1) nor the
pipecat-framework `InterruptibleTTSService` adapter (Phase 4 `examples/pipecat_tts_service.py`).
It depends only on `websockets` + the stdlib so it runs without installing the server
package or pipecat, and it speaks the wire protocol exactly as written in `docs/protocol.md`:

    connect → server.hello → session.update → input_text.append → input_text.commit
            → response.created → response.audio.delta* → response.audio.done

It reassembles the base64 pcm16 frames by `seq` and writes a mono int16 WAV at the
server-advertised `hello.audio.rate` (the rate contract — the client never resamples here).

Usage:
    # Unix domain socket (default transport)
    python examples/reference_client.py --socket-path /tmp/tts.sock --text "Goal!" --out goal.wav

    # ws:// endpoint, pick a voice + speed extra
    python examples/reference_client.py --uri ws://127.0.0.1:8765 \
        --text "The quick brown fox." --voice af_heart --speed 1.1 --out fox.wav

Endpoint precedence mirrors the protocol: --uri > --socket-path > --host/--port.
"""

from __future__ import annotations

import argparse
import asyncio
import base64
import json
import sys
import wave
from typing import Any

try:
    import websockets
except ImportError:  # pragma: no cover - dependency hint
    sys.exit("This client needs the 'websockets' package: uv pip install websockets")


class ProtocolError(RuntimeError):
    """Server sent an `error`/`response.failed`, or the stream ended unexpectedly."""


async def _recv_json(ws: Any) -> dict:
    return json.loads(await ws.recv())


async def synthesize(
    ws: Any,
    text: str,
    *,
    voice: str | None = None,
    language: str | None = None,
    extras: dict | None = None,
    timeout: float = 60.0,
) -> tuple[bytes, int, int]:
    """Run one synthesis round-trip on an open connection.

    Returns (pcm_bytes, sample_rate, channels). Raises ProtocolError on a server error
    or if audio frames arrive out of order / with gaps.
    """
    hello = await asyncio.wait_for(_recv_json(ws), timeout)
    if hello.get("type") != "server.hello":
        raise ProtocolError(f"expected server.hello, got {hello.get('type')!r}")
    audio = hello.get("audio", {})
    rate = int(audio.get("rate", 0))
    channels = int(audio.get("channels", 1))
    if rate <= 0:
        raise ProtocolError(f"server.hello did not advertise a usable rate: {audio!r}")
    print(
        f"hello: backend={hello.get('backend')} rate={rate} caps={hello.get('capabilities')}",
        file=sys.stderr,
    )

    # Optional session.update for voice/language/extras. Skip if nothing to set.
    update: dict[str, Any] = {}
    if voice is not None:
        update["voice"] = voice
    if language is not None:
        update["language"] = language
    if extras:
        update["extras"] = extras
    if update:
        await ws.send(json.dumps({"type": "session.update", **update}))
        ack = await asyncio.wait_for(_recv_json(ws), timeout)
        if ack.get("type") not in ("session.created", "session.updated"):
            raise ProtocolError(f"session.update not acked: {ack!r}")

    await ws.send(json.dumps({"type": "input_text.append", "text": text}))
    # commit carries no audio_format field (see docs/protocol.md §4).
    commit: dict[str, Any] = {"type": "input_text.commit"}
    if extras:
        commit["extras"] = extras
    await ws.send(json.dumps(commit))

    frames: dict[int, bytes] = {}
    expected_seq = 0
    response_id: str | None = None
    while True:
        msg = await asyncio.wait_for(_recv_json(ws), timeout)
        kind = msg.get("type")
        if kind == "input_text.committed":
            response_id = msg.get("response_id")
        elif kind == "response.created":
            response_id = msg.get("response_id", response_id)
        elif kind == "response.audio.delta":
            seq = msg["seq"]
            if seq != expected_seq:
                raise ProtocolError(f"seq gap: expected {expected_seq}, got {seq}")
            frames[seq] = base64.b64decode(msg["audio"])
            expected_seq += 1
        elif kind == "response.audio.done":
            break
        elif kind in ("error", "response.failed"):
            raise ProtocolError(f"{kind}: {msg!r}")
        elif kind == "response.cancelled":
            raise ProtocolError("response cancelled by server")
        # ignore other event types (status, etc.)

    pcm = b"".join(frames[i] for i in range(expected_seq))
    print(
        f"done: response_id={response_id} frames={expected_seq} "
        f"bytes={len(pcm)} (~{len(pcm) / 2 / rate * 1000:.0f} ms)",
        file=sys.stderr,
    )
    return pcm, rate, channels


def write_wav(path: str, pcm: bytes, rate: int, channels: int) -> None:
    with wave.open(path, "wb") as w:
        w.setnchannels(channels)
        w.setsampwidth(2)  # pcm16
        w.setframerate(rate)
        w.writeframes(pcm)


async def _connect(args: argparse.Namespace) -> Any:
    headers = {"Authorization": f"Bearer {args.token}"} if args.token else None
    # Endpoint precedence: URI > socket > host+port.
    if args.uri:
        return await websockets.connect(args.uri, additional_headers=headers)
    if args.socket_path:
        return await websockets.unix_connect(args.socket_path, additional_headers=headers)
    return await websockets.connect(f"ws://{args.host}:{args.port}", additional_headers=headers)


async def _main(args: argparse.Namespace) -> int:
    extras: dict[str, Any] = {}
    if args.speed is not None:
        extras["speed"] = args.speed

    async with await _connect(args) as ws:
        pcm, rate, channels = await synthesize(
            ws,
            args.text,
            voice=args.voice,
            language=args.language,
            extras=extras or None,
            timeout=args.timeout,
        )
    if args.out:
        write_wav(args.out, pcm, rate, channels)
        print(f"wrote {args.out} ({rate} Hz, {channels}ch, {len(pcm)} bytes)")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--uri", help="full ws:// URI (highest precedence)")
    ap.add_argument("--socket-path", help="Unix domain socket path")
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", type=int, default=8765)
    ap.add_argument("--text", required=True, help="text to synthesize")
    ap.add_argument("--voice", help="voice name (e.g. af_heart)")
    ap.add_argument("--language", help="ISO language code (e.g. en)")
    ap.add_argument(
        "--speed",
        type=float,
        help="Kokoro 'speed' extra (server clamps to [0.5, 2.0]; non-finite is rejected as invalid_config)",
    )
    ap.add_argument("--out", help="output WAV path")
    ap.add_argument("--token", help="bearer token (else $TTS_WS_TOKEN)")
    ap.add_argument("--timeout", type=float, default=60.0)
    args = ap.parse_args()
    if args.token is None:
        import os

        args.token = os.environ.get("TTS_WS_TOKEN")
    try:
        return asyncio.run(_main(args))
    except ProtocolError as exc:
        print(f"protocol error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
