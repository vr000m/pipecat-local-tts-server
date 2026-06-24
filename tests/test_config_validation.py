"""Config validation: unknown fields and unsupported languages are rejected.

Lean CI (ToneBackend, no mlx). Covers Codex adversarial-review findings:
- #2: ``session.update`` / ``input_text.commit`` silently accepted unknown
  top-level fields (a typo'd config key looked applied but was ignored).
- #3: an unadvertised ``language`` was silently coerced (to English, via the
  Kokoro ``lang_code`` fallback) instead of being rejected against
  ``capabilities.languages``.
"""

from __future__ import annotations

import json

import pytest

from tts_server.backend import ToneBackend

from ._helpers import connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio

_ACK_OR_ERR_UPDATE = {"error", "session.created", "session.updated"}
_ACK_OR_ERR_COMMIT = {"error", "input_text.committed"}


async def _send_raw(client, payload: dict) -> None:
    """Send a raw frame the typed client API would not let us construct."""
    await client._ws.send(json.dumps(payload))


async def test_session_update_unknown_field_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(client, {"type": "session.update", "pitch": 2})
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "pitch" in ev["error"]["message"]


async def test_commit_unknown_field_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hi")
            await _send_raw(client, {"type": "input_text.commit", "bogus": 1})
            ev = await next_event(client, _ACK_OR_ERR_COMMIT)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "bogus" in ev["error"]["message"]


async def test_unsupported_language_rejected_on_update():
    # ToneBackend advertises languages == ["en"].
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(language="fr")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "fr" in ev["error"]["message"]


async def test_supported_language_accepted_on_update():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(language="en")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] in ("session.created", "session.updated")


async def test_unsupported_language_rejected_on_commit():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hi")
            await client.commit(language="de")
            ev = await next_event(client, _ACK_OR_ERR_COMMIT)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
