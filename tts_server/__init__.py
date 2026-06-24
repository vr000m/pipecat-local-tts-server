"""Standalone local text-to-speech (TTS) WebSocket server and client.

Repo-neutral package mirroring the sibling ``stt_server``: same websocket
transport, OpenAI-Realtime-inspired protocol subset, pluggable lazy-extra
backends, and ``python -m tts_server`` CLI.

**Lean-base invariant:** ``import tts_server`` must succeed with ONLY the lean
base dependency (``websockets``) installed — no ``mlx_audio`` and no ``numpy``
at module load. Heavy backend dependencies are lazy-imported inside functions
(never at module load), so a client-only consumer can talk to a running server
without pulling the TTS runtime.

This is Phase 0 scaffolding: the modules below are stubs. Protocol events,
backend Protocols + ``ToneBackend``, the streaming bridge, server session loop,
and client land in Phase 1+. Public symbols are intentionally NOT re-exported
here yet so that importing this package stays trivially side-effect free until
those modules carry real content.
"""

from __future__ import annotations

__all__: list[str] = []
