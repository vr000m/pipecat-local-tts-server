"""Protocol round-trip + per-ErrorCode error paths on ToneBackend (lean CI).

Covers: handshake (``hello.protocol_version == "0.1"`` and the rate/format/
capabilities shape), and the error paths for each reachable Phase-1 ``ErrorCode``
-- unknown event, invalid JSON, empty-buffer commit, bad extras, unsupported
``audio_format``, unknown ``commit.audio_format`` field, and a non-``plain``
``text_format``.
"""

from __future__ import annotations

import json

import pytest

from tts_server import protocol as P
from tts_server.backend import ToneBackend

from ._helpers import connected_client, next_event, running_server

pytestmark = pytest.mark.asyncio


# --- handshake round-trip ---------------------------------------------------


async def test_hello_advertises_protocol_version_and_audio_contract():
    async with running_server(ToneBackend(sample_rate=24000)) as srv:
        async with connected_client(srv) as (_client, hello):
            assert hello["type"] == P.EVT_SERVER_HELLO
            assert hello["protocol_version"] == "0.1"
            assert hello["backend"]["name"] == "tone"
            assert hello["backend"]["model"] is None
            audio = hello["audio"]
            assert audio["format"] == P.AUDIO_FORMAT == "pcm16"
            assert audio["rate"] == 24000
            assert audio["channels"] == P.AUDIO_CHANNELS == 1


async def test_hello_capabilities_shape():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (_client, hello):
            caps = hello["capabilities"]
            # All R7-required capability keys present.
            for key in (
                "streaming",
                "binary_audio",
                "text_formats",
                "languages",
                "voice_count",
                "extras",
                "ideal_words",
                "max_text_chars",
            ):
                assert key in caps, f"missing capability key {key!r}"
            assert caps["text_formats"] == ["plain"]
            assert isinstance(caps["extras"], list)
            assert caps["binary_audio"] is False


# --- error paths, one per ErrorCode ----------------------------------------


async def _send_raw(client, raw: str) -> None:
    await client._ws.send(raw)


async def test_unknown_event_type_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(client, json.dumps({"type": "not.a.real.event"}))
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.UNSUPPORTED_EVENT.value


async def test_invalid_json_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(client, "{not valid json")
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.INVALID_JSON.value


async def test_missing_type_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(client, json.dumps({"text": "no type field"}))
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.INVALID_EVENT.value


async def test_empty_buffer_commit_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.commit()
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.BUFFER_EMPTY.value


async def test_bad_extras_non_dict_rejected():
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await _send_raw(
                client,
                json.dumps({"type": P.EVT_SESSION_UPDATE, "extras": "not-an-object"}),
            )
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_session_update_audio_format_reject():
    """Any audio_format other than the advertised pcm16 -> UNSUPPORTED_FORMAT."""
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(audio_format="mp3")
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.UNSUPPORTED_FORMAT.value


async def test_session_update_correct_audio_format_accepted():
    """The advertised pcm16 format is accepted (acks, no error)."""
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.update(audio_format=P.AUDIO_FORMAT)
            ev = await next_event(client, {P.EVT_SESSION_CREATED, P.EVT_SESSION_UPDATED, "error"})
            assert ev["type"] != "error"


async def test_commit_with_audio_format_field_rejected():
    """commit has NO audio_format field in v1 -> unknown-field protocol error."""
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("hello")
            await _send_raw(
                client,
                json.dumps({"type": P.EVT_TEXT_COMMIT, "audio_format": "pcm16"}),
            )
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_non_plain_text_format_rejected():
    """A non-advertised text_format (e.g. ssml) -> INVALID_CONFIG."""
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.append("<speak>hi</speak>", text_format="ssml")
            ev = await next_event(client, "error")
            assert ev["error"]["code"] == P.ErrorCode.INVALID_CONFIG.value


async def test_session_stays_usable_after_error():
    """An error is session-level, not fatal: a subsequent valid synth works."""
    async with running_server(ToneBackend(segment_count=1, segment_delay_ms=0)) as srv:
        async with connected_client(srv) as (client, _hello):
            await client.commit()  # empty-buffer error
            err = await next_event(client, "error")
            assert err["error"]["code"] == P.ErrorCode.BUFFER_EMPTY.value
            # session still usable
            await client.append("now with text")
            await client.commit()
            done = await next_event(client, "response.audio.done")
            assert done["type"] == "response.audio.done"
