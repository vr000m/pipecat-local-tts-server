"""Optional backend implementations. Import lazily to avoid hard deps.

No module here may import ``mlx_audio`` or ``numpy`` at module load — the
lean-base invariant requires ``import tts_server`` (and resolving a backend
module) to succeed with only the lean base (``websockets``) installed. Heavy
deps are lazy-imported inside functions (e.g. inside a backend's ``start()`` /
``_get_model``).

``make_backend`` is the single name->backend resolver (mirrors stt's
``_make_backend``): resolution stays LAZY — selecting ``"kokoro"`` imports
``tts_server.backends.kokoro`` (which does NOT pull ``mlx_audio`` at module load)
and constructs the backend; ``mlx_audio`` enters the process only when the
backend's ``start()`` runs. The CLI (``python -m tts_server serve --backend ...``)
calls this so a base install without the ``kokoro`` extra can still resolve and
construct ``tone``, and the missing-extra failure surfaces in ``start()``.
"""

from __future__ import annotations

from ..backend import TTSBackend


def make_backend(name: str, model: str | None = None) -> TTSBackend:
    """Resolve a backend name to a constructed ``TTSBackend`` instance.

    Resolution is lazy: heavy backend modules are imported only when their name
    is selected, and even then they do not pull ``mlx_audio`` until ``start()``.
    """
    if name == "tone":
        from ..backend import ToneBackend

        return ToneBackend()
    if name == "kokoro":
        # Lazy import so a base install without the ``kokoro`` extra still
        # resolves/constructs ``tone``. ``kokoro.py`` imports ``mlx_audio`` only
        # inside ``start()``, never at module load, so this import does NOT
        # transitively pull ``mlx_audio`` — the missing-extra failure surfaces
        # fast in ``start()``, not here at construction.
        from .kokoro import DEFAULT_KOKORO_MODEL, KokoroBackend

        return KokoroBackend(model=model or DEFAULT_KOKORO_MODEL)
    raise SystemExit(f"unknown backend: {name}")
