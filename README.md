# pipecat-local-tts-server

Standalone, local WebSocket **text-to-speech (TTS) server** — text in, audio
out — for the Pipecat ecosystem. It mirrors the sibling
[`pipecat-local-stt-server`](https://github.com/vr000m/pipecat-local-stt-server):
same websocket transport, an OpenAI-Realtime-inspired protocol subset, a
pluggable backend abstraction, and lazy-imported per-model backends behind
optional extras so a client-only consumer never pulls the heavy TTS runtime.

> **Status:** scaffolding (Phase 0). The protocol, `ToneBackend`, server session
> loop, async client, and the Kokoro (mlx-audio) backend land in subsequent
> phases. This README is a placeholder; the full usage guide is a Phase 4
> deliverable. The wire contract is already authored in
> [`docs/protocol.md`](docs/protocol.md), with a runnable oracle at
> [`examples/reference_client.py`](examples/reference_client.py).

## Install

```sh
# client-only (lean base: websockets only)
uv sync --extra client

# Kokoro backend (Apple Silicon; pulls mlx-audio==0.4.4 and its heavy deps)
uv sync --extra kokoro
```

## Layout

- `tts_server/` — protocol, backend abstraction, server, async client, CLI.
- `tts_server/backends/` — lazy-imported per-model backends (Kokoro first).
- `examples/` — reference client and (Phase 4) the Pipecat service adapter.
- `docs/protocol.md` — the wire protocol specification.
