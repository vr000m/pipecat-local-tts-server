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


async def test_error_echoes_client_event_id_at_top_level():
    # Request correlation: an error MUST echo the offending frame's event_id as a
    # TOP-LEVEL previous_event_id (the field every other reply uses), not only as
    # the nested error.event_id. Otherwise a client cannot tell an error for THIS
    # command apart from a stale error left by an earlier command on a persistent
    # connection (adversarial-review finding).
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(
                client, {"type": "session.update", "pitch": 2, "event_id": "evt_corr_1"}
            )
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["previous_event_id"] == "evt_corr_1"
            assert ev["error"]["event_id"] == "evt_corr_1"  # nested kept for compat


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


# --- voice validation (security boundary) -----------------------------------
# An unadvertised voice must be rejected, not forwarded to the backend: for
# Kokoro an arbitrary voice string reaches mlx-audio's voice loader, which treats
# a ``*.safetensors`` value as a filesystem path (arbitrary-file load) and
# otherwise triggers a Hugging Face download (client-driven network egress).
# ToneBackend advertises voices == ["tone"].


async def test_unsupported_voice_rejected_on_update():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="/etc/passwd.safetensors")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "voice" in ev["error"]["message"]


async def test_supported_voice_accepted_on_update():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(voice="tone")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] in ("session.created", "session.updated")


async def test_unsupported_voice_rejected_on_commit():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hi")
            await client.commit(voice="bogus_voice")
            ev = await next_event(client, _ACK_OR_ERR_COMMIT)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"


# --- model validation (no silent wrong-model) -------------------------------
# session.update accepts a `model` field, but v1 loads ONE model at process
# start and synthesis has no per-request model parameter. Acking a model the
# server will not synthesize with is a silent wrong-model failure, so a model
# that does not match the loaded one MUST be rejected. ToneBackend.model is
# None (no selectable model), so any client-supplied model is rejected.


class _ModelToneBackend(ToneBackend):
    """ToneBackend that advertises a concrete model name, to exercise the
    accept-on-exact-match path of ``_validate_model``."""

    model = "tone-v1"


async def test_model_mismatch_rejected_on_update():
    async with running_server(_ModelToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(model="some-other-model")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "some-other-model" in ev["error"]["message"]


async def test_matching_model_accepted_on_update():
    async with running_server(_ModelToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(model="tone-v1")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] in ("session.created", "session.updated")
            assert ev["session"]["model"] == "tone-v1"


async def test_model_rejected_when_backend_has_no_model():
    # ToneBackend.model is None: no selectable model, so any model is rejected.
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(model="anything")
            ev = await next_event(client, _ACK_OR_ERR_UPDATE)
            assert ev["type"] == "error"
            assert ev["error"]["code"] == "invalid_config"
            assert "anything" in ev["error"]["message"]
