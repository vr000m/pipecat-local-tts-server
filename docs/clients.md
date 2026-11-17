# Client integration

Use `tts_server.client.TTSClient` from any Python 3.12+ application, or use the
checkout's `LocalTTSService` adapter in a Pipecat pipeline. The base package
installs only `websockets`; clients do not need model extras or Apple Silicon.

- [Write a WAV with the Python client](#write-a-wav-with-the-python-client)
- [Endpoints and authentication](#endpoints-and-authentication)
- [Discover capabilities](#discover-capabilities)
- [Persistent connections, retries, and cancellation](#persistent-connections-retries-and-cancellation)
- [Use the Pipecat adapter](#use-the-pipecat-adapter)

## Write a WAV with the Python client

In an existing project, run `uv add pipecat-local-tts-server`. For a new project,
run `uv init` first. Start a server as described in the [quickstart](../README.md#quickstart),
or use a synthetic tone without downloading a model:

```sh
uv run python -m tts_server serve --backend tone \
    --socket-path ~/Library/Caches/pipecat-tts/tts.sock
```

In another shell in the same project, save the following as `synthesize.py`.
This is the same example as the README. It buffers one short utterance, writes
`hello.wav` only after successful completion, and closes on success or failure.
`connect()` consumes and returns `server.hello`; it will not appear again in
`events()`.

```python
import asyncio
import base64
import os
import sys
import wave

from tts_server.client import TTSClient


async def main(socket_path, timeout=60):
    client = TTSClient(
        socket_path=socket_path, auth_token=os.environ.get("TTS_WS_TOKEN")
    )
    pcm = bytearray()
    try:
        async with asyncio.timeout(timeout):
            hello = await client.connect()
            rate = hello["audio"]["rate"]
            await client.append("Hello from the local TTS server.")
            await client.commit()
            async for event in client.events():
                if event["type"] == "response.audio.delta":
                    pcm.extend(base64.b64decode(event["audio"]))
                elif event["type"] == "response.audio.done":
                    break
                elif event["type"] in {"error", "response.failed", "response.cancelled"}:
                    raise RuntimeError(event)
            else:
                raise RuntimeError("Connection closed before audio completed")
    finally:
        await client.close()

    with wave.open("hello.wav", "wb") as output:
        output.setnchannels(1)
        output.setsampwidth(2)
        output.setframerate(rate)
        output.writeframes(pcm)
    print(f"Wrote hello.wav: {len(pcm) // 2} samples at {rate} Hz")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1]))
```

```sh
uv run python synthesize.py ~/Library/Caches/pipecat-tts/tts.sock
```

Expect a non-empty mono, 16-bit WAV and a printed sample count and rate. With
`tone`, the audio is a test signal; with a speech backend, it is speech. The
60-second budget includes connection and synthesis; increase `timeout` when
calling `main` for a slow or cold backend. A timeout, server error (including
`busy`), cancellation, or premature close fails the request. This one-shot
example does not retry. It overwrites `hello.wav` on success.

For wire inspection and configurable text/output, the checkout also contains
[`examples/reference_client.py`](../examples/reference_client.py).

## Endpoints and authentication

`TTSClient` and `LocalTTSService` accept explicit `uri`, `socket_path`, or
`host` plus `port` arguments, in that precedence order. Neither constructor
reads endpoint or token environment variables automatically. For the toolbar's
Kokoro server, use `TTSClient(host="127.0.0.1", port=8765)`.

To read the client environment in your application, resolve it explicitly:

```python
import os

from tts_server.client import TTSClient, resolve_endpoint_from_env

client = TTSClient(
    **resolve_endpoint_from_env(os.environ),
    auth_token=os.environ.get("TTS_WS_TOKEN"),
)
```

Set `TTS_WS_URI`, `TTS_WS_SOCKET`, or both `TTS_WS_HOST` and `TTS_WS_PORT` before
using this snippet. It constructs a client; call `connect()` and `close()` as in
the WAV example. The same resolved arguments can be passed to `LocalTTSService`.
`TTS_WS_DEFAULT_SOCKET` is a `status` fallback, not a constructor default.

The WAV example reads `TTS_WS_TOKEN` explicitly. This is the client credential;
it must match the server's configured token. Never read `PIPECAT_TTS_AUTH_TOKEN`
as a client fallback. See [operations](operations.md#environment-variables) for
token files and transport security.

## Discover capabilities

Use `hello["audio"]["rate"]` for playback/WAV metadata. All audio is mono PCM16
little-endian. The server does not negotiate a different sample rate.

Read `hello["capabilities"]` before selecting `language`, `voice`, or `extras`.
Languages use each model's vocabulary: Kokoro uses `en`, while Qwen3 uses
`english` and also offers `auto`. `voice_count == 0` means a supplied voice is
ignored; otherwise obtain the voice list from `server.status` (or the CLI's
`status` command). The `voices` CLI lists the Phonon catalogue, not a running
server's voice list. See [backend selection](backends.md#choose-a-backend).

`update()`, `status()`, `append()`, `commit()`, `clear()`, and `cancel()` send
commands; they do not wait for acknowledgements or raise server-side errors for
you. Read replies through one `events()` consumer, handle `error` and
`response.failed`, and wait for configuration acknowledgement before relying on
it. The [protocol event tables](protocol.md#4-client--server-events) define reply
shapes and correlation fields.

## Persistent connections, retries, and cancellation

A commit is one unit of synthesis. The server permits one active or queued
response per connection, and shares model capacity across connections.

- Assign `commit(event_id="request-1")` a unique ID per request and match
  `previous_event_id` on its acknowledgement or error. Track the returned
  `response_id` on audio and terminal events.
- On `error` with `event["error"]["code"] == "busy"`, wait for the supplied
  `retry_after_ms`, add bounded backoff/jitter, and retry only the commit.
  Re-appending would duplicate the retained text. Bound retry count and time.
- If you abandon an append/commit that was not admitted, send `clear()` before
  appending a new request. `cancel()` does not clear buffered text.
- Send `cancel(response_id=...)` after the commit it targets. Stop playback and
  discard locally buffered audio for that response. After `response.cancelled`,
  the server sends no further audio for it, but the backend worker may still
  hold the GPU lock until a yield boundary. A stale/idle cancel is a no-op and
  sends no acknowledgement; do not wait forever for one.
- `close_session()` asks the server to drain active synthesis before closing;
  `cancel_session()` discards it. `close()` tears down the connection. Reconnect
  with a new client instance after a connection failure and reapply settings.

Use sentence-sized commits for non-streaming backends. Even a streaming backend
can pause while generating audio; `response.created` means admission, not that
playback can begin without buffering. See the [session lifecycle](protocol.md#3-session-lifecycle)
and [backpressure rules](protocol.md#7-errors--backpressure).

## Use the Pipecat adapter

The adapter is a reference source file, not an installed module in the server
wheel. From a source checkout:

```sh
git clone https://github.com/vr000m/pipecat-local-tts-server.git
cd pipecat-local-tts-server
uv sync --extra examples
```

The examples extra pins `pipecat-ai==1.4.0`. Run your bot from this checkout so
`examples.pipecat_tts_service` is importable, or copy the adapter into your bot
project and adjust the import. If this environment also runs Kokoro, sync both
extras: `uv sync --extra examples --extra kokoro`.

The following is a **pipeline sketch**, not a complete bot. Your application
must create `llm` and `transport`, configure input/context processors, and run
the pipeline:

```python
from pipecat.pipeline.pipeline import Pipeline

from examples.pipecat_tts_service import LocalTTSService

tts = LocalTTSService(
    host="127.0.0.1",
    port=8765,
    voice="af_heart",  # Kokoro; consult status for another backend.
    language="en",
    params=LocalTTSService.InputParams(speed=1.1),
    busy_retries=3,
    busy_retry_budget_s=3.0,
)
pipeline = Pipeline([llm, tts, transport.output()])
```

The adapter learns the audio rate from the handshake and passes it to Pipecat's
TTS frames. It handles interruptions, clears abandoned text, and retries busy
commits within the configured count and waiting budget. Its `InputParams`
currently exposes only `speed`; other backend extras require your own adapter
extension or the lower-level client. Choose voice/language settings from the
connected backend's capabilities rather than copying Kokoro's values blindly.
