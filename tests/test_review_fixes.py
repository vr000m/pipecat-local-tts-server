"""Regression tests for the medium-effort code-review fixes.

Each test pins a behavior a finder flagged as missing or wrong:

- #1 voice validation must FAIL CLOSED when the backend advertises voices
  (``voice_count`` > 0) but cannot enumerate them (``voices()`` empty — Kokoro's
  discovery-fallback shape). Skipping the check there forwarded an arbitrary
  voice string into mlx-audio's loader (arbitrary-file load / HF egress).
- #2 ``_KokoroStream.wait_closed`` must honour a ``timeout`` so a worker that
  never sets ``worker_done`` cannot hang the server's single dispatcher.
- #3 a malformed ``speed`` value must be rejected as ``INVALID_CONFIG`` at the
  commit/update boundary (via the optional ``validate_extras`` hook), not as a
  ``BACKEND_ERROR`` raised from ``open_stream`` after a slot was consumed.
"""

from __future__ import annotations

import threading

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio


# --- #1: voice validation fail-closed --------------------------------------


class _UnenumerableVoicesBackend(ToneBackend):
    """Advertises voices (count > 0) but returns an empty ``voices()`` list —
    exactly Kokoro's discovery-fallback shape (count 54, names unknown)."""

    def capabilities(self) -> dict:
        caps = super().capabilities()
        caps["voice_count"] = 54
        return caps

    def voices(self) -> list[str]:
        return []


class _NoVoiceConceptBackend(ToneBackend):
    """No voice concept at all: count 0 and an empty list. Voice validation has
    nothing to validate against, so any voice is accepted (skip, not reject)."""

    def capabilities(self) -> dict:
        caps = super().capabilities()
        caps["voice_count"] = 0
        return caps

    def voices(self) -> list[str]:
        return []


async def test_unenumerable_voices_rejects_client_voice_on_update():
    """A backend with voices it cannot enumerate must REJECT a client voice
    rather than forward an unvalidated string to the backend (fail closed)."""
    async with running_server(_UnenumerableVoicesBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="/etc/passwd.safetensors")
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_unenumerable_voices_rejects_client_voice_on_commit():
    async with running_server(_UnenumerableVoicesBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hello")
            await client.commit(voice="evil-repo/id")
            # Rejected at commit validation — no response is ever created.
            ev = await next_event(client, {"error", P.EVT_RESPONSE_CREATED})
            assert ev["type"] == "error"
            assert ev["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_advertised_voice_set_still_enforces_membership():
    """The happy path is unchanged: an unknown voice against a real advertised
    list is rejected; the advertised voice is accepted."""
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="not-a-real-voice")
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="tone")  # the only advertised voice
            ev = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED, "error"})
            assert ev["type"] != "error"


async def test_no_voice_concept_accepts_any_voice():
    """A backend with no voice concept (count 0) skips validation — a voice is
    accepted rather than spuriously rejected."""
    async with running_server(_NoVoiceConceptBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="anything")
            ev = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED, "error"})
            assert ev["type"] != "error"


# --- #2: bounded wait_closed -----------------------------------------------


async def test_kokoro_wait_closed_honours_timeout_when_worker_never_finishes():
    """``wait_closed(timeout=...)`` must return within the timeout even if the
    worker never sets ``worker_done`` — otherwise a wedged native ``generate``
    would hang the server's single dispatcher forever."""
    import asyncio

    from tts_server.backends.kokoro import _KokoroStream

    stream = _KokoroStream(
        model=object(),
        voice=None,
        lang_code="a",
        speed=None,
        metal_lock=threading.Lock(),
    )
    # Simulate a worker that started but never completes (worker_done unset).
    stream._worker_started = True
    loop = asyncio.get_running_loop()
    start = loop.time()
    await stream.wait_closed(timeout=0.1)
    elapsed = loop.time() - start
    assert elapsed < 1.0, f"wait_closed ignored its timeout (blocked {elapsed:.2f}s)"
    assert not stream._worker_done.is_set()


# --- #3: speed value validated at the commit boundary ----------------------


class _SpeedCheckingBackend(ToneBackend):
    """Implements the optional ``validate_extras`` hook to reject a non-numeric
    ``speed`` at admission (mirrors Kokoro's ``_coerce_speed`` rejection)."""

    def validate_extras(self, extras: dict) -> str | None:
        raw = extras.get("speed")
        if raw is not None and not isinstance(raw, (int, float)):
            return f"speed must be a number, got {raw!r}"
        return None


async def test_bad_speed_rejected_as_invalid_config_on_commit():
    """A malformed speed is an INVALID_CONFIG at commit — NOT a BACKEND_ERROR
    (response.failed) raised mid-synthesis after a slot was consumed."""
    async with running_server(_SpeedCheckingBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("speak")
            await client.commit(extras={"speed": "fast"})
            ev = await next_event(client, {"error", P.EVT_RESPONSE_CREATED, P.EVT_RESPONSE_FAILED})
            assert ev["type"] == "error", f"expected INVALID_CONFIG error, got {ev['type']}"
            assert ev["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_bad_speed_rejected_on_session_update():
    async with running_server(_SpeedCheckingBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(extras={"speed": "fast"})
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_valid_speed_still_accepted():
    async with running_server(_SpeedCheckingBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(extras={"speed": 1.25})
            ev = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED, "error"})
            assert ev["type"] != "error"


async def test_kokoro_validate_extras_unit():
    """Unit-level: KokoroBackend.validate_extras rejects non-numeric / non-finite
    speed and accepts a finite number — the exact values _coerce_speed guards."""
    from tts_server.backends.kokoro import KokoroBackend

    backend = KokoroBackend()
    assert backend.validate_extras({"speed": "fast"}) is not None
    assert backend.validate_extras({"speed": float("nan")}) is not None
    assert backend.validate_extras({"speed": float("inf")}) is not None
    assert backend.validate_extras({"speed": 1.5}) is None
    assert backend.validate_extras({"speed": 5.0}) is None  # out-of-range clamps, not rejected
    assert backend.validate_extras({}) is None
