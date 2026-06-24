"""Shared helpers for Phase-1 lean-CI tests (ToneBackend, no mlx).

A small toolkit on top of ``TTSServer``/``TTSClient`` so each test file reads as
intent, not transport plumbing. Everything here is stdlib + websockets — no mlx,
no numpy — so it runs on plain lean CI.
"""

from __future__ import annotations

import asyncio
import base64
import contextlib
from dataclasses import dataclass, field

from tts_server.client import TTSClient
from tts_server.server import ServerConfig, TTSServer


@contextlib.asynccontextmanager
async def running_server(backend):
    """Run ``backend`` behind a TTSServer on an ephemeral loopback TCP port."""
    srv = TTSServer(
        backend,
        ServerConfig(host="127.0.0.1", port=0, reject_browser_origins=False),
    )
    await srv.start()
    try:
        yield srv
    finally:
        await srv.shutdown()


@contextlib.asynccontextmanager
async def connected_client(srv: TTSServer):
    """Connect a TTSClient to a running server; yields ``(client, hello)``."""
    port = srv.listening_port()
    assert port is not None
    c = TTSClient(host="127.0.0.1", port=port)
    hello = await c.connect()
    try:
        yield c, hello
    finally:
        await c.close()


async def next_event(client: TTSClient, types, *, timeout: float = 3.0) -> dict:
    """Return the next server event whose ``type`` is in ``types``."""
    if isinstance(types, str):
        types = {types}

    async def _read() -> dict:
        async for ev in client.events():
            if ev.get("type") in types:
                return ev
        raise AssertionError(f"socket closed before any of {types} arrived")

    return await asyncio.wait_for(_read(), timeout)


@dataclass
class CollectedResponse:
    """The full event trace of one synthesis response, reassembled by ``seq``."""

    response_id: str | None = None
    deltas: list[dict] = field(default_factory=list)  # raw delta events in arrival order
    done: dict | None = None
    cancelled: dict | None = None
    failed: dict | None = None
    error: dict | None = None
    delta_monotonic_ts: list[float] = field(default_factory=list)

    @property
    def pcm(self) -> bytes:
        """PCM reassembled strictly by ``seq`` (the client's contract)."""
        by_seq = {d["seq"]: base64.b64decode(d["audio"]) for d in self.deltas}
        return b"".join(by_seq[i] for i in range(len(by_seq)))

    @property
    def seqs(self) -> list[int]:
        return [d["seq"] for d in self.deltas]

    @property
    def frame_byte_lengths(self) -> list[int]:
        return [len(base64.b64decode(d["audio"])) for d in self.deltas]


async def collect_response(
    client: TTSClient,
    *,
    terminal=("response.audio.done", "response.cancelled", "response.failed"),
    timeout: float = 5.0,
) -> CollectedResponse:
    """Drive the event stream until a terminal response event, recording deltas.

    Records a monotonic timestamp per delta so timing assertions (TTFF, the
    inter-delta gap bound) can be made off the same trace.
    """
    out = CollectedResponse()

    async def _read() -> None:
        async for ev in client.events():
            t = ev.get("type")
            if t == "input_text.committed":
                out.response_id = ev.get("response_id")
            elif t == "response.created":
                out.response_id = ev.get("response_id", out.response_id)
            elif t == "response.audio.delta":
                out.deltas.append(ev)
                out.delta_monotonic_ts.append(asyncio.get_running_loop().time())
            elif t == "response.audio.done":
                out.done = ev
                return
            elif t == "response.cancelled":
                out.cancelled = ev
                return
            elif t == "response.failed":
                out.failed = ev
                return
            elif t == "error":
                out.error = ev
                return

    await asyncio.wait_for(_read(), timeout)
    return out


async def synthesize_once(client: TTSClient, text: str, **commit_kwargs) -> CollectedResponse:
    """append(text) -> commit -> collect the full response."""
    await client.append(text)
    await client.commit(**commit_kwargs)
    return await collect_response(client)
