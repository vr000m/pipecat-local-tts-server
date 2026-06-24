"""Server session loop and synthesis drain (stub).

Phase 0 scaffolding. Phase 1 implements the handshake (``server.hello``),
per-connection ``_SessionState`` isolation, append/commit, the 20 ms
re-chunker, ``response.cancel`` (barge-in), endpoint resolution, and the
cleartext-remote guard. Phase 3 adds auth enforcement, resource-limit caps, and
synthesis-backlog backpressure (``ErrorCode.BUSY`` + ``retry_after_ms``).

The drain loop runs in a tracked task (not inline in the recv loop) and is built
on ``backends/_stream_util.py`` (a per-chunk queue), emitting each segment's
audio as it lands — NOT the stt commit-then-drain shape.

stdlib + websockets only.
"""

from __future__ import annotations
