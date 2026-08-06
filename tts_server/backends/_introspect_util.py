"""Shared ``generate()`` signature-verification guard (stdlib-only, ``inspect``-based).

Extracted from dia's previously-private ``_verify_generate_signature`` per
dia's own docstring instruction: "If this guard is ever needed by a second
backend, lift it into a shared helper rather than copying it" (``dia.py``).
``fish_tts`` is that second backend — its ``generate()`` carries the live
voice-cloning channel (``ref_audio``/``ref_text``) and the new ``instruct``
surface, so the same "why introspect at all" rationale applies there too.

Best-effort: a mismatch is LOGGED (actionable for an operator), never raised —
an upstream signature reshape under the pinned wheel should surface as a
warning, not wedge serve.

Stdlib-only on purpose (same rule as ``_extras_util``/``_stream_util``):
backends import this at module load, and the lean-import tests forbid
heavyweight roots (``mlx_audio``/``numpy``) at import time.
"""

from __future__ import annotations

import inspect
import logging
from typing import Any

_DEFAULT_LOGGER = logging.getLogger("tts_server.backends._introspect_util")


def verify_generate_signature(
    model: Any,
    expected_params: list[str],
    backend_name: str,
    *,
    logger: logging.Logger | None = None,
) -> None:
    """Re-verify ``model.generate()`` still accepts every name in
    ``expected_params`` (the backend's advertised effective extras). A
    mismatch is logged, not raised, so an upstream reshape is actionable
    rather than fatal at serve time. A ``**kwargs``-catching signature
    (``VAR_KEYWORD``) satisfies every expected name, since an unknown kwarg
    would still be accepted (not TypeError) even if silently ignored
    downstream.
    """
    log = logger or _DEFAULT_LOGGER
    try:
        sig = inspect.signature(model.generate)
    except (TypeError, ValueError) as exc:  # pragma: no cover - upstream shape
        log.warning("%s: could not introspect generate() signature: %s", backend_name, exc)
        return
    params = sig.parameters
    has_kwargs = any(p.kind is inspect.Parameter.VAR_KEYWORD for p in params.values())
    for name in expected_params:
        if name not in params and not has_kwargs:
            log.warning(
                "%s: generate() does not accept advertised extra %r "
                "(signature reshape under the pinned wheel?) — it will be "
                "swallowed/error at synthesis",
                backend_name,
                name,
            )
