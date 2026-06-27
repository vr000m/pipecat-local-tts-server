"""``status`` round-trip + missing-server nonzero exit (Phase 3, R6).

Lean-CI on ``ToneBackend`` — mirrors stt's status tests. The round-trip asserts
the ``server.status`` reply carries the operationally meaningful fields
(backend/model/rate via hello, plus queue-depth and voices on the status reply);
the subprocess test asserts ``python -m tts_server status`` against no server
exits nonzero.
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import connected_client, next_event, running_server

# asyncio_mode=auto runs the async tests; the sync subprocess test below must NOT
# carry an asyncio mark, so no module-level pytestmark here.


async def test_status_round_trip_carries_backend_model_rate_and_queue_depth():
    backend = ToneBackend(sample_rate=24000)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            # hello carries backend/model/rate (R1: rate is the wire contract).
            assert hello["backend"]["name"] == "tone"
            assert hello["backend"]["model"] is None
            assert hello["audio"]["rate"] == 24000
            assert hello["audio"]["format"] == P.AUDIO_FORMAT
            assert hello["audio"]["channels"] == P.AUDIO_CHANNELS

            await client.status()
            status = await next_event(client, P.EVT_SERVER_STATUS)

            # backend identity is surfaced on the status reply too.
            assert status["backend"]["name"] == "tone"
            assert status["backend"]["model"] is None
            # rate present and equal to the advertised hello rate (no drift).
            assert status["audio"]["rate"] == hello["audio"]["rate"] == 24000
            # queue depth is an idle integer (no synthesis in flight).
            assert isinstance(status["queue_depth"], int)
            assert status["queue_depth"] == 0
            # full voice list lives on status (decided default #4).
            assert status["voices"] == ["tone"]
            assert status["voice_count"] == 1
            assert isinstance(status["pid"], int) and status["pid"] > 0


async def test_status_queue_depth_is_zero_when_idle_after_a_response():
    # A completed synthesis must leave the global backlog drained back to 0.
    backend = ToneBackend(segment_count=2, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hello")
            await client.commit()
            await next_event(client, P.EVT_RESPONSE_AUDIO_DONE)
            await client.status()
            status = await next_event(client, P.EVT_SERVER_STATUS)
            assert status["queue_depth"] == 0


def _run_module(*args: str, env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    return subprocess.run(
        [sys.executable, "-m", "tts_server", *args],
        capture_output=True,
        text=True,
        timeout=20,
        env=env,
    )


def test_cli_status_against_missing_server_exits_nonzero(tmp_path: Path):
    missing = tmp_path / "does-not-exist.sock"
    # Clean env so a stray TTS_WS_* in the dev shell can't redirect the probe.
    env = {k: v for k, v in os.environ.items() if not k.startswith("TTS_WS_")}
    r = _run_module("status", "--socket-path", str(missing), "--timeout", "1.0", env=env)
    assert r.returncode != 0, f"stdout={r.stdout!r} stderr={r.stderr!r}"
    assert "tts_server:" in r.stderr
