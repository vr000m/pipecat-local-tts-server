"""Phonon TTS backend (Gradium ``phonon-31m-en`` via mlx-audio 0.6.1's ``pocket_tts``).

Phonon has no mlx-audio module of its own: its checkpoint (``flow_lm`` + ``mimi``
keys, no ``model_type``) routes to ``mlx_audio.tts.models.pocket_tts``. Like Pocket
it is a genuine ``streaming:true`` sub-segment streamer, and its ``generate()``
carries ``ref_audio`` / ``frames_after_eos`` which this backend leaves UNWIRED
(decision #2: no cloning; the 31M has no speaker encoder anyway).

Lazy-imports ``mlx_audio`` / ``huggingface_hub`` INSIDE the module-level seams
(``_snapshot_download`` / ``_load_model`` / ``_download_voice``) — never at module
load (the lean-base invariant). Lean tests patch those seams to exercise
``start()`` without mlx.

Revision pin: HF HEAD of the model repo sets ``model_type: gradium_phonon_tts``,
which mlx-audio 0.6.1 cannot load. A repo in ``_REVISION_PINS`` is therefore
fetched with ``snapshot_download(revision=<sha>)`` and loaded from the returned
local path; there is NO fallback to HEAD (an unreachable pin is a startup error).
A model with no pin entry (another repo id, or an absolute local snapshot path --
also the recovery path if the sha disappears) loads as given with a warning, and
without the ~45 s chunk tripwire (its ceiling is measured only for the pinned model).

Quantized weights: ``--model phonon`` (fp, same as the default), ``phonon-q8`` and
``phonon-q4`` are aliases (``_MODEL_ALIASES``). A quantized alias fetches the same
pinned snapshot, then converts it ONCE with mlx-audio's ``pocket_tts`` ``convert()``
into a cache dir keyed by pin sha / bits / group size / mlx-audio version
(``_quantized_dir``) and loads that. Saves memory / disk / load time, not TTFB/RTF.
The reported ``model`` stays the alias string the operator passed.

Voices: ``default`` (the model's shipped voice; ``voice`` kwarg omitted) plus the
operator-enabled catalog voices (``PIPECAT_TTS_PHONON_VOICES``, comma-separated
slugs). Only enabled voices are downloaded (one file each, pinned voices sha) and
advertised; an unknown or unfetchable enabled voice is warned about and skipped
(Kokoro-style soft failure), never substituted. ``generate(voice=...)`` only ever
receives an absolute local ``.safetensors`` path resolved here -- no client
string, ``hf://`` URL or bare name reaches it.
"""

from __future__ import annotations

import asyncio
import logging
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Any

from ..backend import TTSStream
from . import phonon_voices
from ._bridge_stream import BridgedStream
from ._extras_util import (
    TEMPERATURE_MAX,
    TEMPERATURE_MIN,
    coerce_temperature,
    merge_extras,
    validate_extras,
)
from ._introspect_util import verify_generate_signature

logger = logging.getLogger("tts_server.backends.phonon")

DEFAULT_PHONON_MODEL = "gradium/phonon-31m-en"

# Per-repo revision pin table {repo_id: full 40-char sha} (Phase 0 Q1/Q2).
_REVISION_PINS: dict[str, str] = {
    DEFAULT_PHONON_MODEL: "52433c46975bfa13144c56204c9f4ee1c5b148aa",
}


def _pin_for(model_id: str) -> tuple[str, str] | None:
    """``(canonical_repo_id, sha)`` for a pinned repo, else ``None``. The key is
    normalised (strip, trailing slashes, casefold) for this lookup ONLY, so
    ``Gradium/phonon-31m-en`` / ``gradium/phonon-31m-en/`` cannot bypass the pin;
    local paths and unknown repos still miss and load as given."""
    key = model_id.strip().rstrip("/").casefold()
    for repo, sha in _REVISION_PINS.items():
        if repo.casefold() == key:
            return repo, sha
    return None


# Operator-facing ``--model`` aliases: alias -> (repo_id, quantization bits | None).
# A small explicit table on purpose; arbitrary ``-qN`` suffixes are NOT parsed.
_MODEL_ALIASES: dict[str, tuple[str, int | None]] = {
    "phonon": (DEFAULT_PHONON_MODEL, None),
    "phonon-q8": (DEFAULT_PHONON_MODEL, 8),
    "phonon-q4": (DEFAULT_PHONON_MODEL, 4),
}

# Quantization group size handed to convert() (part of the quantized-dir key).
Q_GROUP_SIZE = 32


def _alias_for(model_id: str) -> tuple[str, int | None] | None:
    """``(repo_id, bits)`` for a Phonon alias (strip + casefold), else ``None``."""
    return _MODEL_ALIASES.get(model_id.strip().casefold())


def _resolve_pin(model_id: str) -> tuple[tuple[str, str] | None, int | None]:
    """``(pin, bits)`` for ``model_id``: an alias maps to its repo's pin plus its
    quantization bits; anything else is looked up directly. Shared by ``start()``
    and ``prefetch`` so both fetch exactly the same revision."""
    alias = _alias_for(model_id)
    if alias is not None:
        repo_id, bits = alias
        return _pin_for(repo_id), bits
    return _pin_for(model_id), None


def _cache_root() -> Path:
    xdg = os.environ.get("XDG_CACHE_HOME")
    return Path(xdg) if xdg else Path.home() / ".cache"


def _mlx_audio_version() -> str:
    from importlib.metadata import PackageNotFoundError, version

    try:
        return version("mlx-audio")
    except PackageNotFoundError:
        return "unknown"


def _quantized_dir(sha: str, bits: int) -> Path:
    """Cache dir for one (pin, bits, group size, mlx-audio version) combination, so
    a pin bump or an mlx-audio upgrade lands in a fresh dir instead of stale weights."""
    key = f"{sha[:12]}-q{bits}-g{Q_GROUP_SIZE}-mlxaudio{_mlx_audio_version()}"
    return _cache_root() / "pipecat-tts-server" / "phonon" / key


# Mirrors mlx_audio.utils.DEFAULT_ALLOW_PATTERNS (verified in Phase 0 Q2); skips
# the two ``.gguf`` files MLX cannot load.
ALLOW_PATTERNS = [
    "*.json",
    "*.safetensors",
    "*.py",
    "*.model",
    "*.tiktoken",
    "*.txt",
    "*.jinja",
    "*.jsonl",
    "*.yaml",
    "*.npz",
    "*.pth",
]

VOICES_ENV = "PIPECAT_TTS_PHONON_VOICES"

# Params generate() accepts that this backend MUST NEVER forward (no cloning).
_FORBIDDEN_GENERATE_KWARGS = ("ref_audio", "frames_after_eos")

# Locked at 0.3 s (Phase 0 Q5: lowest TTFB, zero continuity violations).
_STREAMING_INTERVAL = 0.3
_BRIDGE_MAXSIZE = 32

# Chosen defaults, not model facts (pocket_tts values; Phase 0 Q8 saw no
# truncation to 5161 chars of PUNCTUATED text). mlx-audio generates per sentence chunk
# and never splits inside a sentence, and the model ends a chunk at ~45 s of audio
# (measured 2026-10-22: run-on sentences of 200/300/400 words all stop at 564 frames,
# EOS at step 562, with no error and a normal completion; ~160 words still fit at
# 36.6 s). ``max_text_chars`` does not protect against it; the chunk tripwire below does
# (pinned model only).
_IDEAL_WORDS = 40
_MAX_TEXT_CHARS = 2000

# Chunk tripwire: a chunk that yields this many 80 ms frames (560 = 44.8 s at the model's
# 12.5 Hz) ended at the model's ~45 s limit rather than on its own sentence end, so its
# tail audio was cut. Measured 564 frames for fp/q8/q4 x default/zoey (2026-10-22).
# Keyed by the exact ``(repo, sha)`` it was measured on, separately from ``_REVISION_PINS``
# (a loader-compat table): ``start()`` installs the tripwire only when the pin it resolved
# ALSO has a measured ceiling here, so pinning a new repo for loader reasons, or bumping
# an existing repo's pin sha, never switches on an unmeasured ceiling. A new repo or a
# new revision needs its own measurement before it gets an entry.
# The sha is spelled out (not read from ``_REVISION_PINS``) on purpose: a pin bump must
# not silently carry the old revision's measurement.
_DEFAULT_CEILING_KEY = (DEFAULT_PHONON_MODEL, "52433c46975bfa13144c56204c9f4ee1c5b148aa")
_CHUNK_FRAMES_CEILINGS: dict[tuple[str, str], int] = {_DEFAULT_CEILING_KEY: 560}
_CHUNK_FRAMES_CEILING = _CHUNK_FRAMES_CEILINGS[_DEFAULT_CEILING_KEY]

_TEMPERATURE_MIN = TEMPERATURE_MIN
_TEMPERATURE_MAX = TEMPERATURE_MAX
_coerce_temperature = coerce_temperature

_EXTRA_COERCERS = {"temperature": _coerce_temperature}
_PHONON_EXTRAS = list(_EXTRA_COERCERS)

_STATIC_LANGUAGES = ["en"]


# --- Module-level patchable seams (lazy heavy imports inside each) -------------


def _snapshot_download(repo_id: str, revision: str) -> str:
    """Fetch ``repo_id`` at exactly ``revision`` and return the local snapshot dir."""
    from huggingface_hub import snapshot_download  # type: ignore

    return str(snapshot_download(repo_id, revision=revision, allow_patterns=ALLOW_PATTERNS))


def _quantize(snapshot_path: str, dest: str, bits: int) -> None:
    """Quantize the snapshot at ``snapshot_path`` into ``dest`` (mlx-audio's
    pocket_tts converter; the repo's prebuilt ``.gguf`` files do not load in MLX)."""
    from mlx_audio.tts.models.pocket_tts.convert import convert  # type: ignore

    convert(snapshot_path, dest, quantize=True, q_bits=bits, q_group_size=Q_GROUP_SIZE)


# ``_ensure_quantized`` builds into ``.<final>.tmp-<pid>-<tid>`` and renames it into
# place, so a crash (kill -9, power loss) mid-convert strands only that sibling dir.
# Age, not pid liveness, decides what is stale: a convert takes seconds (a few minutes
# at worst), so a 10-minute-old dir cannot belong to a live one, and a pid check is
# wrong across hosts sharing a home directory or after pid reuse. Kept short because a
# convert that is killed on every start (launchd restarts it every 10 s) strands one
# ~60 MB dir per start, and this age bounds how many pile up (~60 dirs, not ~360).
_STALE_TMP_RE = re.compile(r"\..+\.tmp-\d+-\d+")
_STALE_TMP_AGE_S = 600.0


def _newest_mtime(path: str) -> float:
    newest = os.stat(path).st_mtime
    with os.scandir(path) as it:
        for entry in it:
            newest = max(newest, entry.stat(follow_symlinks=False).st_mtime)
    return newest


def _sweep_stale_tmp(parent: Path, max_age_s: float = _STALE_TMP_AGE_S) -> None:
    """Best-effort removal of orphaned quantize temp dirs under ``parent``. Only real
    (non-symlink) directories named exactly ``.<name>.tmp-<int>-<int>`` whose newest
    mtime is older than ``max_age_s`` go; any error leaves the entry in place."""
    try:
        entries = list(os.scandir(parent))
    except OSError:
        return
    now = time.time()
    for entry in entries:
        try:
            if not _STALE_TMP_RE.fullmatch(entry.name) or entry.is_symlink():
                continue
            if not entry.is_dir(follow_symlinks=False):
                continue
            if now - _newest_mtime(entry.path) <= max_age_s:
                continue
            logger.info("phonon: removing stale quantize temp dir %s", entry.path)
            shutil.rmtree(entry.path, ignore_errors=True)
        except OSError:
            continue


def _ensure_quantized(snapshot_path: str, sha: str, bits: int) -> str:
    """Return a complete quantized dir, building it if absent. Crash-safe: convert
    into a sibling temp dir, then atomically rename; a dir that already exists (a
    prior run or a concurrent start) is reused without converting. Any failure
    removes the temp dir, leaves no final dir and propagates (no fp fallback)."""
    final = _quantized_dir(sha, bits)
    _sweep_stale_tmp(final.parent)
    if final.is_dir():
        return str(final)
    final.parent.mkdir(parents=True, exist_ok=True)
    tmp = final.parent / f".{final.name}.tmp-{os.getpid()}-{threading.get_ident()}"
    shutil.rmtree(tmp, ignore_errors=True)
    try:
        _quantize(snapshot_path, str(tmp), bits)
        try:
            os.rename(tmp, final)
        except OSError:
            if not final.is_dir():  # not a lost race: a real failure
                raise
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return str(final)


def _load_model(path: str) -> Any:
    from mlx_audio.tts.utils import load  # type: ignore

    return load(path, lazy=False, strict=True)


def _download_voice(
    repo_id: str,
    filename: str,
    revision: str,
    *,
    local_files_only: bool,
    cache_dir: str | None = None,
) -> str:
    """Fetch one voice file; with ``local_files_only`` a cache miss raises.
    ``cache_dir`` redirects the fetch away from the shared HF cache (used by
    ``voices --refresh`` so a live look never writes into the operator's cache)."""
    from huggingface_hub import hf_hub_download  # type: ignore

    return str(
        hf_hub_download(
            repo_id,
            filename,
            revision=revision,
            local_files_only=local_files_only,
            cache_dir=cache_dir,
        )
    )


class PhononTruncationError(RuntimeError):
    """One sentence chunk hit the model's ~45 s limit and its audio was cut off."""


def _make_truncation_error(frames: int) -> PhononTruncationError:
    return PhononTruncationError(
        f"phonon: a sentence chunk hit the model's ~45 s limit ({frames} frames, "
        f"{frames / 12.5:.1f} s) — its audio was silently truncated; failing the "
        "response instead of reporting a clean completion (split the text into "
        "shorter sentences)"
    )


def _cap_chunk_frames(chunk_fn, ceiling: int, make_error):
    """Wrap a per-chunk generator function: pass every frame through unchanged, and once
    the chunk is exhausted raise ``make_error(frames)`` if it yielded ``ceiling`` or more.
    Counted PER CALL (one call per sentence chunk), never summed across chunks. Frames
    already yielded stay yielded; an early close (barge-in) never raises."""

    def wrapped(*args, **kwargs):
        frames = 0
        for frame in chunk_fn(*args, **kwargs):
            frames += 1
            yield frame
        if frames >= ceiling:
            raise make_error(frames)

    wrapped._phonon_tripwire = True  # type: ignore[attr-defined]
    return wrapped


def _install_chunk_tripwire(model: Any, ceiling: int) -> bool:
    """Wrap ``model._generate_audio_stream_short_text`` (mlx-audio 0.6.1, pinned; the
    only place a sentence chunk's boundary is visible) with the frame cap. Idempotent.
    Returns False when the method is absent (an mlx-audio change), so the caller can say
    the guard is off."""
    fn = getattr(model, "_generate_audio_stream_short_text", None)
    if fn is None:
        return False
    if not getattr(fn, "_phonon_tripwire", False):
        model._generate_audio_stream_short_text = _cap_chunk_frames(
            fn, ceiling, _make_truncation_error
        )
    return True


class _PhononStream(BridgedStream):
    """Adapts one Phonon utterance to ``TTSStream``. ``voice`` is either ``None``
    (default voice -> kwarg omitted) or an absolute local ``.safetensors`` path
    resolved by the backend; ``ref_audio``/``frames_after_eos`` are never added."""

    def __init__(
        self,
        *,
        model: Any,
        voice: str | None,
        extras: dict[str, Any],
        metal_lock: threading.Lock,
    ) -> None:
        super().__init__(metal_lock=metal_lock, bridge_maxsize=_BRIDGE_MAXSIZE)
        self._model = model
        self._voice = voice
        self._extras = extras

    def _gen_factory(self):
        kwargs: dict[str, Any] = {}
        if self._voice is not None:
            kwargs["voice"] = self._voice
        kwargs.update(self._extras)
        return self._model.generate(
            self._text,
            stream=True,
            streaming_interval=_STREAMING_INTERVAL,
            **kwargs,
        )


def _enabled_from_env() -> list[str]:
    """Enabled slugs from ``PIPECAT_TTS_PHONON_VOICES`` in the operator's order:
    stripped, lowercased, blanks and duplicates dropped (same normalisation as
    ``env_str_set``, but ordered, which a set cannot be)."""
    ordered: list[str] = []
    for tok in os.environ.get(VOICES_ENV, "").split(","):
        tok = tok.strip().lower()
        if tok and tok not in ordered:
            ordered.append(tok)
    return ordered


def voice_catalog_rows() -> list[dict]:
    """Rows for ``voices``: ``slug``/``language``/``enabled``/``cached`` per catalog voice.

    ``cached`` is probed through ``_download_voice(..., local_files_only=True)``
    (the download seam; a cache miss raises and counts as not cached). If
    ``huggingface_hub`` is not installed the probe cannot tell, so ``cached`` is
    ``None`` (unknown), not ``False``. The seam is looked up as a module global
    at call time so tests can patch it.
    """
    enabled = set(_enabled_from_env())
    rows = []
    for slug, _vid, lang in phonon_voices.VOICE_CATALOG:
        try:
            _download_voice(
                phonon_voices.VOICES_REPO,
                phonon_voices.voice_filename(slug),
                phonon_voices.VOICES_REPO_SHA,
                local_files_only=True,
            )
            cached: bool | None = True
        except ImportError:
            cached = None  # no huggingface_hub: unknown, not "not cached"
        except Exception:
            cached = False
        rows.append({"slug": slug, "language": lang, "enabled": slug in enabled, "cached": cached})
    return rows


def fetch_live_voice_catalog() -> list[dict]:
    """Fetch the current ``voices.jsonl`` (revision ``main``, via the
    ``_download_voice`` seam) as parsed rows. Read-only: the fetch goes to a
    throwaway cache dir so the operator's HF cache is untouched. Diff the result
    with ``phonon_voices.voice_catalog_drift`` (pure catalog logic, no seam)."""
    import json
    import tempfile

    with tempfile.TemporaryDirectory(prefix="phonon-voices-refresh-") as tmp:
        path = _download_voice(
            phonon_voices.VOICES_REPO,
            "voices.jsonl",
            "main",
            local_files_only=False,
            cache_dir=tmp,
        )
        text = Path(path).read_text()
    return [json.loads(line) for line in text.splitlines() if line.strip()]


class PhononBackend:
    """mlx-audio Phonon backend (Apple Silicon). Lazy-imports ``mlx_audio``."""

    backend_name = "phonon"

    def __init__(
        self,
        *,
        model: str = DEFAULT_PHONON_MODEL,
        enabled_voices: list[str] | None = None,
    ) -> None:
        self._model_id = model
        self.model = model
        self._enabled_voices = list(
            dict.fromkeys(enabled_voices) if enabled_voices is not None else _enabled_from_env()
        )
        self._loaded_model: Any = None
        self.sample_rate = 0
        self._metal_lock = threading.Lock()
        # Advertised name -> absolute local .safetensors path (None = default voice).
        self._voice_paths: dict[str, str | None] = {phonon_voices.DEFAULT_VOICE: None}
        self._languages: list[str] = list(_STATIC_LANGUAGES)

    # -- startup ----------------------------------------------------------------

    async def start(self) -> None:
        loop = asyncio.get_running_loop()

        pin, bits = _resolve_pin(self._model_id)
        if pin is not None:
            repo, sha = pin
            # An unreachable/unknown pinned sha raises here: startup error, no HEAD fallback.
            local_path = await loop.run_in_executor(None, lambda: _snapshot_download(repo, sha))
            if bits is not None:
                snapshot = local_path
                local_path = await loop.run_in_executor(
                    None, lambda: _ensure_quantized(snapshot, sha, bits)
                )
            logger.info(
                "phonon: repo=%s revision=%s bits=%s path=%s",
                repo,
                sha,
                bits if bits is not None else "fp",
                local_path,
            )
        else:
            local_path = self._model_id
            logger.warning(
                "phonon: model %r has no revision pin; loading as given (the pinned "
                "default is %s@%s)",
                self._model_id,
                DEFAULT_PHONON_MODEL,
                _REVISION_PINS[DEFAULT_PHONON_MODEL],
            )

        self._loaded_model = await loop.run_in_executor(None, lambda: _load_model(local_path))
        rate = getattr(self._loaded_model, "sample_rate", None)
        if not rate:
            raise RuntimeError(
                "phonon: model.sample_rate is missing after load() — cannot advertise "
                "the rate contract"
            )
        self.sample_rate = int(rate)
        ceiling = _CHUNK_FRAMES_CEILINGS.get(pin) if pin is not None else None
        if pin is None:
            # The 560-frame / 12.5 Hz ceiling was measured only on the pinned model
            # (fp/q8/q4); another model could end valid chunks past it.
            logger.warning(
                "phonon: model %r has no revision pin; the ~45 s sentence-chunk truncation "
                "guard is OFF (its ceiling is measured only for %s)",
                self._model_id,
                DEFAULT_PHONON_MODEL,
            )
        elif ceiling is None:
            logger.warning(
                "phonon: pinned repo %s@%s has no measured chunk-frame ceiling; the ~45 s "
                "sentence-chunk truncation guard is OFF",
                pin[0],
                pin[1],
            )
        elif not _install_chunk_tripwire(self._loaded_model, ceiling):
            logger.warning(
                "phonon: model has no _generate_audio_stream_short_text (mlx-audio changed?); "
                "the ~45 s sentence-chunk truncation guard is OFF"
            )

        self._voice_paths = await loop.run_in_executor(None, self._resolve_voices)

        verify_generate_signature(self._loaded_model, list(_PHONON_EXTRAS), "phonon", logger=logger)
        logger.info(
            "phonon: voices voices_revision=%s advertised=%s",
            phonon_voices.VOICES_REPO_SHA,
            list(self._voice_paths),
        )

        await loop.run_in_executor(None, self._warmup)

    def _resolve_voices(self) -> dict[str, str | None]:
        """``default`` first, then each enabled catalog voice that resolved to an
        existing absolute local ``.safetensors`` file with no '@' in its path.
        Unknown / unfetchable / unusable names are skipped with a warning (never
        fatal, never substituted)."""
        paths: dict[str, str | None] = {phonon_voices.DEFAULT_VOICE: None}
        resolved, unknown = phonon_voices.resolve_enabled(self._enabled_voices)
        for name in unknown:
            if name == phonon_voices.DEFAULT_VOICE:
                continue  # always advertised; listing it explicitly is harmless
            logger.warning(
                "phonon: %s: unknown voice %r skipped (not in catalog)", VOICES_ENV, name
            )
        for slug in resolved:
            filename = phonon_voices.voice_filename(slug)
            path = self._fetch_voice(slug, filename)
            if path is None:
                continue
            if not os.path.isabs(path) or not os.path.isfile(path):
                logger.warning(
                    "phonon: voice %r resolved to %r which is not an absolute existing file; skipped",
                    slug,
                    path,
                )
                continue
            if not path.endswith(".safetensors"):
                # generate(voice=...) only ever gets a voice-embedding file; mlx-audio's
                # check is the same case-sensitive suffix test, anything else it would
                # try to decode as audio.
                logger.warning(
                    "phonon: voice %r resolved to %r which is not a .safetensors file; skipped",
                    slug,
                    path,
                )
                continue
            if "@" in path:
                # mlx-audio's pocket_tts takes everything after '@' in a voice path as a
                # revision suffix when deciding whether it is a ``.safetensors`` file, so a
                # path with '@' (e.g. an HF cache under such a directory) is decoded as audio
                # and fails at synthesis time. Fail here, at start, instead.
                logger.warning(
                    "phonon: voice %r resolved to %r which contains '@' and cannot be loaded "
                    "by mlx-audio; skipped (move the HF cache to a path without '@')",
                    slug,
                    path,
                )
                continue
            if phonon_voices.voice_language(slug) != "en":
                logger.warning(
                    "phonon: voice %r is %r but the model is -en; output may not be intelligible",
                    slug,
                    phonon_voices.voice_language(slug),
                )
            paths[slug] = path
        return paths

    def _fetch_voice(self, slug: str, filename: str) -> str | None:
        repo, rev = phonon_voices.VOICES_REPO, phonon_voices.VOICES_REPO_SHA
        try:
            # Warm cache first: no network call.
            return _download_voice(repo, filename, rev, local_files_only=True)
        except Exception:  # noqa: BLE001 - cache miss; try the network
            pass
        try:
            return _download_voice(repo, filename, rev, local_files_only=False)
        except Exception as exc:  # noqa: BLE001 - soft failure
            logger.warning("phonon: voice %r could not be fetched (%s); skipped", slug, exc)
            return None

    def _warmup(self) -> None:
        try:
            with self._metal_lock:
                for _ in self._loaded_model.generate(
                    "Hello there.",
                    stream=True,
                    streaming_interval=_STREAMING_INTERVAL,
                ):
                    pass
        except Exception as exc:  # noqa: BLE001 - warmup is non-critical
            logger.warning("phonon: warmup generate failed (non-fatal): %s", exc)

    # -- TTSBackend surface -----------------------------------------------------

    def capabilities(self) -> dict:
        return {
            "streaming": True,
            "binary_audio": False,
            "text_formats": ["plain"],
            "languages": list(self._languages),
            "voice_count": len(self._voice_paths),
            "extras": list(_PHONON_EXTRAS),
            "ideal_words": _IDEAL_WORDS,
            "max_text_chars": _MAX_TEXT_CHARS,
        }

    def voices(self) -> list[str]:
        return list(self._voice_paths)

    def validate_extras(self, extras: dict) -> str | None:
        return validate_extras(_EXTRA_COERCERS, extras)

    async def open_stream(
        self,
        *,
        voice: str | None = None,
        language: str | None = None,
        extras: dict | None = None,
    ) -> TTSStream:
        if self._loaded_model is None:
            raise RuntimeError("phonon: open_stream() called before start()")
        # Only advertised names map; anything else (hf:// URL, path, bare/unknown
        # name, a catalog slug that was not enabled) is rejected here as defence in
        # depth behind ``server._validate_voice``.
        if voice is None or voice == phonon_voices.DEFAULT_VOICE:
            voice_arg: str | None = None
        elif voice in self._voice_paths:
            voice_arg = self._voice_paths[voice]
        else:
            raise ValueError(f"phonon: unknown voice {voice!r}")
        effective = merge_extras(_EXTRA_COERCERS, extras)
        return _PhononStream(
            model=self._loaded_model,
            voice=voice_arg,
            extras=effective,
            metal_lock=self._metal_lock,
        )

    async def close(self) -> None:
        self._loaded_model = None


# --- prefetch hooks (``python -m tts_server prefetch --backend phonon``) -----------


def prefetch_specs(model: str | None) -> list:
    """The pinned model snapshot (same resolution as ``start()``) plus the voice files
    enabled via ``PIPECAT_TTS_PHONON_VOICES`` (optional, as at startup)."""
    from ..prefetch import SnapshotSpec, model_specs

    model_id = model or DEFAULT_PHONON_MODEL
    pin, _bits = _resolve_pin(model_id)
    if pin is not None:
        repo, sha = pin
        specs = [SnapshotSpec(repo, revision=sha, allow_patterns=tuple(ALLOW_PATTERNS))]
    else:
        # Unpinned: ``start()`` hands the id straight to mlx-audio's ``load()``.
        specs = model_specs(model_id, DEFAULT_PHONON_MODEL)
    resolved, _unknown = phonon_voices.resolve_enabled(_enabled_from_env())
    if resolved:
        specs.append(
            SnapshotSpec(
                phonon_voices.VOICES_REPO,
                revision=phonon_voices.VOICES_REPO_SHA,
                allow_patterns=tuple(phonon_voices.voice_filename(s) for s in resolved),
                kind="voice",
                required=False,
            )
        )
    return specs


def prefetch_finalize(model: str | None, emit) -> None:
    """For the ``phonon-q8``/``phonon-q4`` aliases, build the quantized cache now so
    the first ``serve`` does not pay for the one-time conversion (imports mlx)."""
    from .. import prefetch

    pin, bits = _resolve_pin(model or DEFAULT_PHONON_MODEL)
    if pin is None or bits is None:
        return
    repo, sha = pin
    if emit is not None:
        emit({"event": "convert", "repo": repo, "bits": bits, "state": "start", "path": None})
    snapshot = prefetch.cached_snapshot(
        prefetch.SnapshotSpec(repo, revision=sha, allow_patterns=tuple(ALLOW_PATTERNS))
    )
    path = _ensure_quantized(snapshot, sha, bits)
    if emit is not None:
        emit({"event": "convert", "repo": repo, "bits": bits, "state": "done", "path": path})


def prefetch_check_extra(model: str | None) -> dict:
    """``--check`` summary fields: whether a quantized alias is already converted."""
    pin, bits = _resolve_pin(model or DEFAULT_PHONON_MODEL)
    if pin is None or bits is None:
        return {}
    qdir = _quantized_dir(pin[1], bits)
    return {"quantized": qdir.is_dir(), "quantized_path": str(qdir)}
