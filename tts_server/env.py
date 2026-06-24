"""Environment-variable helpers and endpoint resolution (stub).

Phase 0 scaffolding. Phase 1 implements endpoint resolution
(precedence ``URI > socket > host+port``) and the ``TTS_WS_*`` env vars
(mirroring ``STT_WS_*``); Phase 3 wires the optional bearer-token env vars
(server-side ``PIPECAT_TTS_AUTH_TOKEN``, client-side ``TTS_WS_TOKEN``).

stdlib-only.
"""

from __future__ import annotations
