"""Wire protocol constants, events, and error codes (stub).

Phase 0 scaffolding. Phase 1 implements this module against ``docs/protocol.md``
(the authored wire contract) and the ``examples/reference_client.py`` oracle:
``PROTOCOL_VERSION = "0.1"``, pcm16 mono at the per-backend rate, the
client->server / server->client event set, and the ``ErrorCode`` enum
(mirroring stt, plus ``BUSY`` for synthesis-backlog backpressure).

stdlib-only.
"""

from __future__ import annotations
