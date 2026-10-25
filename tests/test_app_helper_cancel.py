"""Kyutai cancellation in the toolbar's STT helper (macos/Helper/pipecat_app_helper.py).

`run_in_executor` threads cannot be interrupted, so a cancelled or disconnected
request must stop the decode loop cooperatively, or it keeps the backend-wide
lock (and the GPU) until the whole utterance has been decoded.
"""

from __future__ import annotations

import asyncio
import importlib.util
import sys
import threading
import time
import types
from pathlib import Path

import pytest

HELPER = Path(__file__).resolve().parent.parent / "macos" / "Helper" / "pipecat_app_helper.py"


@pytest.fixture(scope="module")
def helper():
    spec = importlib.util.spec_from_file_location("pipecat_app_helper_under_test", HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


@pytest.fixture(autouse=True)
def fake_stt_server(monkeypatch):
    """`events()` imports TranscriptEvent from stt_server, which a lean env lacks."""
    backend = types.ModuleType("stt_server.backend")
    backend.TranscriptEvent = lambda kind, text: (kind, text)
    package = types.ModuleType("stt_server")
    monkeypatch.setitem(sys.modules, "stt_server", package)
    monkeypatch.setitem(sys.modules, "stt_server.backend", backend)


class SlowBackend:
    """Stands in for KyutaiBackend: one lock, a per-frame loop that polls `cancel`."""

    def __init__(self, frames: int) -> None:
        self.frames = frames
        self._lock = threading.Lock()
        self.started = threading.Event()
        self.aborted = False

    def transcribe(self, pcm16: bytes, cancel: threading.Event | None = None) -> str:
        with self._lock:
            self.started.set()
            for _ in range(self.frames):
                if cancel is not None and cancel.is_set():
                    self.aborted = True
                    return ""
                time.sleep(0.01)
        return "done"


async def _collect(stream) -> list:
    return [event async for event in stream.events()]


async def test_cancelled_request_releases_the_backend(helper):
    backend = SlowBackend(frames=1000)  # ~10 s if nothing stops it
    first = helper._KyutaiStream(backend)
    await first.feed(b"\x00\x00" * 160)
    task = asyncio.create_task(_collect(first))
    assert await asyncio.to_thread(backend.started.wait, 2)

    await first.cancel()
    assert await asyncio.wait_for(task, 2) == []
    assert backend.aborted

    # A queued second request is served promptly, not after the first finishes.
    backend.frames = 3
    second = helper._KyutaiStream(backend)
    await second.feed(b"\x00\x00" * 160)
    began = time.monotonic()
    events = await asyncio.wait_for(_collect(second), 2)
    assert time.monotonic() - began < 1
    assert [kind for kind, _ in events] == ["delta", "completed"]


async def test_cancelling_the_consumer_stops_the_decode(helper):
    backend = SlowBackend(frames=1000)
    stream = helper._KyutaiStream(backend)
    await stream.feed(b"\x00\x00" * 160)
    task = asyncio.create_task(_collect(stream))
    assert await asyncio.to_thread(backend.started.wait, 2)

    task.cancel()  # a dropped connection cancels the handler task
    with pytest.raises(asyncio.CancelledError):
        await task

    deadline = time.monotonic() + 2
    while not backend.aborted and time.monotonic() < deadline:
        await asyncio.sleep(0.01)
    assert backend.aborted
    assert backend._lock.acquire(timeout=1)  # the lock is free again
    backend._lock.release()
