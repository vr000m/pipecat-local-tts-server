"""capabilities shape + extras validation (lean CI on ToneBackend).

Covers (R7 / Backend Protocol):
- capabilities() shape from server.hello.
- unknown extras keys are DROPPED (debug-logged), not errored -- the synthesis
  still runs.
- an extra colliding with a fixed param (voice/language) is REJECTED before the
  **extras call (it would otherwise raise TypeError at model.generate(**extras)).
"""

from __future__ import annotations

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import connected_client, next_event, running_server, synthesize_once

pytestmark = pytest.mark.asyncio


async def test_capabilities_full_shape():
    backend = ToneBackend(
        ideal_words=40,
        max_text_chars=2000,
        languages=["en", "ja"],
        extras=["speed"],
    )
    async with running_server(backend) as srv:
        async with connected_client(srv) as (_client, hello):
            caps = hello["capabilities"]
            assert caps["streaming"] is False
            assert caps["binary_audio"] is False
            assert caps["text_formats"] == ["plain"]
            assert caps["languages"] == ["en", "ja"]
            assert caps["voice_count"] == 1
            assert caps["extras"] == ["speed"]
            assert caps["ideal_words"] == 40
            assert caps["max_text_chars"] == 2000


async def test_tone_streaming_true_capability_and_no_split_path():
    """ToneBackend(streaming=True) exercises the ``streaming:true`` capabilities
    branch AND the client no-split path in LEAN CI (Phase 5a prerequisite),
    independent of the mlx-gated real streaming backends. A streaming:true
    backend advertises the flag and the server still synthesizes a larger
    single commit (the client need not pre-split) into multiple deltas."""
    backend = ToneBackend(streaming=True, segment_count=3, segment_delay_ms=0)
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, hello):
            assert hello["capabilities"]["streaming"] is True
            # No-split path: pass a longer single commit; it streams fine.
            resp = await synthesize_once(
                client,
                "The quick brown fox jumps over the lazy dog and keeps running.",
            )
            assert resp.error is None and resp.failed is None
            assert resp.done is not None
            assert len(resp.deltas) >= 2  # streamed incrementally, not one burst


async def test_unknown_extras_dropped_not_errored():
    """An extras key not in capabilities.extras is dropped; synthesis proceeds."""
    backend = ToneBackend(segment_count=1, segment_delay_ms=0, extras=["speed"])
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            # 'speed' is accepted; 'nonsense' is unknown -> dropped, not errored.
            resp = await synthesize_once(
                client, "drop unknown", extras={"speed": 1.1, "nonsense": 99}
            )
            assert resp.error is None
            assert resp.done is not None


async def test_unknown_extras_on_session_update_not_errored():
    backend = ToneBackend(extras=["speed"])
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(extras={"unknown_kwarg": 1})
            # Acked as a session event, NOT an error.
            ev = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED, "error"})
            assert ev["type"] != "error"


@pytest.mark.parametrize("colliding_key", ["voice", "language"])
async def test_extra_colliding_with_fixed_param_rejected(colliding_key: str):
    """An extra named like a fixed generate() param is rejected BEFORE the
    **extras call -- even on a backend that advertises it as an extra, the
    collision guard wins."""
    # Advertise the colliding key as an "accepted" extra to prove the collision
    # guard fires regardless of the advertised set.
    backend = ToneBackend(extras=[colliding_key])
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(extras={colliding_key: "x"})
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_extra_collision_rejected_on_commit_too():
    backend = ToneBackend(extras=["voice"])
    async with running_server(backend) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("text")
            await client.commit(extras={"voice": "boom"})
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


# --- dia capabilities (lean, no mlx — constructing the backend is lazy) --------


async def test_dia_capabilities_advertise_dialogue_contract():
    """dia is the segment-level DIALOGUE backend: ``streaming:false`` (uses
    ``split_pattern``, like Kokoro), extras the ordered ``["temperature", "top_p"]``
    (matching docs/protocol.md), ``text_formats:["plain"]`` ([S1]/[S2] ride inside
    plain — decision #2), and ``voice_count:0`` (speaker control is in-text only —
    decision #1). Constructing ``DiaBackend`` does NOT pull mlx_audio (lazy)."""
    from tts_server.backends.dia import DiaBackend

    caps = DiaBackend().capabilities()
    assert caps["streaming"] is False
    assert caps["extras"] == ["temperature", "top_p"]
    assert caps["text_formats"] == ["plain"]
    assert caps["voice_count"] == 0
