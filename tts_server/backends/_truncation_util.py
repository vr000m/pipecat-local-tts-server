"""Shared truncation-tripwire helpers (stdlib-only).

Two backends drain a ``model.generate()`` generator and must detect when a
batch/segment silently hit its token ceiling — the audio was cut off
mid-utterance but the generator otherwise looks like it completed cleanly.
Both wrap the model's generator in a pass-through iterator that raises a
backend-specific error the instant the ceiling is crossed, so the failure
propagates through ``_stream_util.stream_generate`` and the server reports a
client-visible ``response.failed`` instead of a clean ``completed`` with
missing tail audio.

The two backends differ in how the ceiling is scoped:

- ``fish_tts``: the ceiling is derived PER RESULT (each ``GenerationResult``
  is one whole batch; the ceiling is a function of that batch's own input
  token count) — see ``check_per_result_ceiling``.
- ``qwen3_tts``: the ceiling is a single constant, but must be summed PER
  SEGMENT (multiple ``GenerationResult``s share a ``segment_idx`` until the
  key changes) before comparing — see ``check_per_segment_ceiling``.

Stdlib-only on purpose (same rule as ``_extras_util``/``_stream_util``/
``_introspect_util``): backends import this at module load, and the
lean-import tests forbid heavyweight roots (``mlx_audio``/``numpy``) at
import time.
"""

from __future__ import annotations

from collections.abc import Callable, Iterator
from typing import Any


def _default_token_fn(result: Any) -> int:
    """Default token-count reader: mlx-audio's ``GenerationResult.token_count``
    is the batch/segment's own generated-audio token count. Duck-typed (no mlx
    import) so this module stays lean."""
    return int(getattr(result, "token_count", 0) or 0)


def _default_segment_key_fn(result: Any) -> Any:
    """Default segment-key reader: mlx-audio's ``GenerationResult.segment_idx``."""
    return getattr(result, "segment_idx", None)


def check_per_result_ceiling(
    gen: Iterator[Any],
    *,
    ceiling_fn: Callable[[Any], int],
    make_error: Callable[[Any, int, int], BaseException],
    token_fn: Callable[[Any], int] = _default_token_fn,
) -> Iterator[Any]:
    """Pass-through wrapper: yield each result from ``gen`` unchanged, raising
    ``make_error(result, token_count, ceiling)`` the instant a single result's
    own token count reaches its own ceiling.

    ``ceiling_fn(result)`` derives the ceiling PER RESULT — fish_tts's ceiling
    depends on that batch's own input-text token count, so it cannot be a
    single constant. Already-yielded results stay yielded (a caller that
    already streamed a ``delta`` for a prior, under-ceiling result keeps that
    delta); only the failing result's raise propagates, never a later
    ``completed``.
    """
    for result in gen:
        ceiling = ceiling_fn(result)
        token_count = token_fn(result)
        if token_count >= ceiling:
            raise make_error(result, token_count, ceiling)
        yield result


def check_per_segment_ceiling(
    gen: Iterator[Any],
    *,
    ceiling: int,
    make_error: Callable[[int], BaseException],
    segment_key_fn: Callable[[Any], Any] = _default_segment_key_fn,
    token_fn: Callable[[Any], int] = _default_token_fn,
) -> Iterator[Any]:
    """Pass-through wrapper: yield each result from ``gen`` unchanged, summing
    ``token_fn(result)`` PER SEGMENT (results sharing one
    ``segment_key_fn(result)`` value, in run order) and raising
    ``make_error(segment_total)`` as soon as a completed segment's sum reaches
    ``ceiling`` — checked when the segment key changes, and once more after
    the generator is exhausted for the final segment.

    A single constant ``ceiling`` (unlike ``check_per_result_ceiling``'s
    per-result derivation) — qwen3's ceiling is one flat ``max_tokens`` value,
    but multiple ``GenerationResult``s can share one segment (Base's
    ``split_pattern='\\n'`` multi-segment generations), so summing per key
    avoids a false alarm on a multi-segment commit whose segments each
    finished naturally on EOS.
    """
    _UNSET = object()
    segment_key: Any = _UNSET
    segment_total = 0
    for result in gen:
        key = segment_key_fn(result)
        if key != segment_key:
            if segment_key is not _UNSET and segment_total >= ceiling:
                raise make_error(segment_total)
            segment_key = key
            segment_total = 0
        segment_total += token_fn(result)
        yield result
    if segment_key is not _UNSET and segment_total >= ceiling:
        raise make_error(segment_total)
