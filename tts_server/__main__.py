"""``python -m tts_server`` entrypoint (stub).

Phase 0 scaffolding. The real CLI lands in Phase 1 (``serve``) and Phase 3
(``status``), mirroring the stt server:

- ``serve`` — runs the TTS server
  (``python -m tts_server serve --backend kokoro --model ... --socket-path ...``);
  logs the resolved backend + model at startup.
- ``status`` — connect, send ``server.status``, print backend/model/rate/queue
  depth, exit 0 on success or 1 on failure (a preflight health probe).
"""

from __future__ import annotations
