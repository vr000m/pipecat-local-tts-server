"""Backend abstraction (stub).

Phase 0 scaffolding. Phase 1 defines the ``TTSBackend`` and ``TTSStream``
Protocols (see the plan's "Backend Protocol" section) plus a dependency-free,
**stdlib-only** ``ToneBackend`` (sine) reference that emits multiple segments
with a configurable per-segment delay to drive the streaming contract and the
20 ms re-chunker. The shared float->pcm16 converter (clip to [-1, 1], map
asymmetrically so -1.0 -> -32768 and +1.0 -> +32767) also lives here and is
stdlib-only (no numpy).

stdlib-only at module load; backends lazy-import heavy deps inside functions.
"""

from __future__ import annotations
