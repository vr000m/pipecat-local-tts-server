"""Optional backend implementations. Import lazily to avoid hard deps.

No module here may import ``mlx_audio`` or ``numpy`` at module load — the
lean-base invariant requires ``import tts_server`` (and resolving a backend
module) to succeed with only the lean base (``websockets``) installed. Heavy
deps are lazy-imported inside functions (e.g. inside a backend's ``start()`` /
``_get_model``).
"""
