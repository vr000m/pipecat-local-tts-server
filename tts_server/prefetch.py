"""``python -m tts_server prefetch`` — fetch a backend's weights without serving.

``serve`` downloads weights implicitly inside ``backend.start()`` with no
progress reporting, so a first start can sit silent for minutes. ``prefetch``
does the same Hugging Face snapshot downloads up front, with optional JSON-lines
progress for a supervising app (the macOS menu bar app under ``macos/``), and
``--check`` answers "are the weights already cached?" without the network.

Each backend module declares what it needs through a module-level
``prefetch_specs(model) -> list[SnapshotSpec]`` placed next to its default model
constant, so a pin bump stays a one-file change. Two optional hooks:
``prefetch_finalize(model, emit)`` runs after the downloads (phonon converts its
quantized aliases there) and ``prefetch_check_extra(model) -> dict`` adds fields
to the ``--check`` summary. The hook protocols live in ``tts_server.backend``
(``BackendPrefetch`` / ``SupportsPrefetch*``); the module is found through the
backend registry (``tts_server.backends.BACKENDS``), so there is no separate
prefetch dispatch table.

Lean at import: ``huggingface_hub`` and ``tqdm`` (which arrive with any model
extra) are imported only inside the download seam and the progress class.

JSON events (one object per stdout line):

- fetch: ``start{repo,revision,kind}`` -> ``progress{repo,downloaded_bytes,
  total_bytes,files_done,files_total}``* -> ``done{repo,path,size_bytes}`` per
  snapshot, then ``complete{backend,model,cached,size_bytes}``. ``total_bytes``
  only counts files still being downloaded and grows as they are discovered.
- ``--check``: ``check{repo,revision,kind,required,cached,path,size_bytes}`` per
  snapshot, then ``summary{backend,model,cached,size_bytes,...}``.
- failure: ``error{code,message,repo}`` and exit status 1. A ``required=False``
  snapshot (optional voice files) logs ``warning{repo,message}`` and continues,
  matching ``serve``, which skips voices it cannot fetch.

Not covered: Metal kernel JIT / warmup (``serve`` still warms up before it
reports ready), and any revision drift for backends that load a repo's ``main``
(``prefetch`` and ``serve`` both resolve HEAD, so they agree with each other).
"""

from __future__ import annotations

import contextlib
import json
import logging
import os
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .backend import BackendPrefetch, SupportsPrefetchCheckExtra, SupportsPrefetchFinalize

logger = logging.getLogger("tts_server.prefetch")

# Mirrors ``mlx_audio.utils.DEFAULT_ALLOW_PATTERNS`` (mlx-audio 0.6.1): exactly
# what ``mlx_audio.tts.utils.load(repo)`` fetches, so prefetch and serve agree.
DEFAULT_ALLOW_PATTERNS: tuple[str, ...] = (
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
)

# A cached model/codec snapshot must hold at least one of these, so a folder left
# by an interrupted download that predates hf's tree cache is not reported cached.
_WEIGHT_SUFFIXES = (".safetensors", ".npz", ".pth")

_PROGRESS_MIN_INTERVAL_S = 0.2


@dataclass(frozen=True)
class SnapshotSpec:
    """One Hugging Face snapshot a backend needs before it can start offline."""

    repo_id: str
    revision: str | None = None  # None = the repo's main branch, as mlx_audio.load() uses
    allow_patterns: tuple[str, ...] = DEFAULT_ALLOW_PATTERNS
    kind: str = "model"  # model | codec | voice
    required: bool = True  # False: serve() also tolerates its absence


def is_local_model(model: str) -> bool:
    """True when ``model`` names a local path rather than a hub repo id."""
    return model.startswith(("/", "./", "../", "~")) or Path(model).expanduser().exists()


def model_specs(model: str | None, default: str) -> list[SnapshotSpec]:
    """The common case: one mlx-audio model repo (nothing to fetch for a local path)."""
    repo = model or default
    if is_local_model(repo):
        return []
    return [SnapshotSpec(repo)]


def _prefetch_hooks(backend: str) -> BackendPrefetch | None:
    """The backend's prefetch hooks, resolved through the backend registry (the
    same one ``serve`` and the CLI choices use). ``ValueError`` if unknown."""
    from .backends import get_backend

    return get_backend(backend).prefetch_hooks()


def specs_for(backend: str, model: str | None) -> list[SnapshotSpec]:
    """Every snapshot ``backend`` needs to start ``model`` without the network."""
    hooks = _prefetch_hooks(backend)
    if hooks is None:
        return []
    return list(hooks.prefetch_specs(model))


# --- patchable seams (tests stub these; heavy imports stay inside) -------------


def _snapshot_download(spec: SnapshotSpec, *, local_files_only: bool, tqdm_class=None) -> str:
    from huggingface_hub import snapshot_download  # type: ignore

    kwargs: dict[str, Any] = {
        "revision": spec.revision,
        "allow_patterns": list(spec.allow_patterns),
        "local_files_only": local_files_only,
    }
    if tqdm_class is not None:
        kwargs["tqdm_class"] = tqdm_class
    return str(snapshot_download(spec.repo_id, **kwargs))


def cached_snapshot(spec: SnapshotSpec) -> str:
    """Local path of an already-downloaded snapshot (never the network); for a
    backend's ``prefetch_finalize``. Raises if ``spec`` is not fully cached."""
    return _snapshot_download(spec, local_files_only=True)


def _dir_size(path: str | Path) -> int:
    """Bytes under ``path`` (follows the HF cache's snapshot -> blob symlinks)."""
    total = 0
    for p in Path(path).rglob("*"):
        try:
            if p.is_file():
                total += p.stat().st_size
        except OSError:
            continue
    return total


def _has_weights(path: str | Path) -> bool:
    return any(p.name.endswith(_WEIGHT_SUFFIXES) for p in Path(path).rglob("*"))


def _snapshot_complete(path: str | Path) -> bool:
    """False when an interrupted download left the snapshot half-filled.

    ``snapshot_download(local_files_only=True)`` returns the snapshot folder as soon as
    it exists, and one finished shard satisfies ``_has_weights``, so a stopped multi-shard
    download would read as cached. Two signals say otherwise: an unfinished blob
    (``blobs/*.incomplete``, which huggingface_hub renames only when a file is done), and a
    sharded checkpoint whose index names a shard that is not there. An unreadable index is
    left to the loader to report."""
    snap = Path(path)
    blobs = snap.parent.parent / "blobs"
    if blobs.is_dir() and any(blobs.glob("*.incomplete")):
        return False
    for index in snap.rglob("*.safetensors.index.json"):
        try:
            shards = set(json.loads(index.read_text())["weight_map"].values())
        except (OSError, ValueError, KeyError, AttributeError):
            continue
        if any(not (index.parent / shard).exists() for shard in shards):  # broken symlink too
            return False
    return True


def _progress_class(repo: str, emit: Callable[[dict], None]):
    """A plain ``tqdm`` subclass that turns hf's aggregate bars into JSON events.

    ``snapshot_download(tqdm_class=...)`` (huggingface_hub 2.x) builds two byte
    bars (``Downloading bytes`` = network transfer, ``Reconstructing ...`` =
    bytes written to the cache) plus a file-count bar from its thread map. We
    report the bytes-written bar and the file count. Subclassing hf's own tqdm
    would inherit ``HF_HUB_DISABLE_PROGRESS_BARS``, which disables ``update()``.
    """
    import io

    from tqdm import tqdm  # type: ignore

    state = {"bytes": 0, "total": 0, "files_done": 0, "files_total": 0, "last": 0.0}

    def _report(force: bool = False) -> None:
        now = time.monotonic()
        if not force and now - state["last"] < _PROGRESS_MIN_INTERVAL_S:
            return
        state["last"] = now
        emit(
            {
                "event": "progress",
                "repo": repo,
                "downloaded_bytes": int(state["bytes"]),
                "total_bytes": int(state["total"]),
                "files_done": int(state["files_done"]),
                "files_total": int(state["files_total"]),
            }
        )

    class _JsonProgress(tqdm):  # type: ignore[misc]
        def __init__(self, *args, **kwargs):
            kwargs["disable"] = False
            kwargs["file"] = io.StringIO()
            super().__init__(*args, **kwargs)
            desc = str(kwargs.get("desc") or "")
            if self.unit == "B":
                self._role = "bytes" if desc.startswith("Reconstruct") else "transfer"
            else:
                self._role = "files"
                state["files_total"] = int(self.total or 0)

        def update(self, n=1):
            result = super().update(n)
            if self._role == "bytes":
                state["bytes"] = self.n
                state["total"] = max(int(self.total or 0), int(self.n))
                _report(force=bool(self.total) and self.n >= self.total)
            elif self._role == "files":
                state["files_done"] = self.n
                _report(force=True)
            return result

    return _JsonProgress


# --- check / fetch ---------------------------------------------------------------


def check_spec(spec: SnapshotSpec) -> dict[str, Any]:
    """Offline cache probe for one snapshot. ``ImportError`` propagates."""
    row: dict[str, Any] = {
        "event": "check",
        "repo": spec.repo_id,
        "revision": spec.revision,
        "kind": spec.kind,
        "required": spec.required,
        "cached": False,
        "path": None,
        "size_bytes": 0,
    }
    try:
        path = _snapshot_download(spec, local_files_only=True)
    except ImportError:
        raise
    except Exception as exc:  # noqa: BLE001 - any miss (incl. incomplete snapshot) = not cached
        logger.debug("prefetch: %s not cached (%s)", spec.repo_id, exc)
        return row
    if spec.kind in ("model", "codec") and not _has_weights(path):
        return row
    if not _snapshot_complete(path):
        return row
    row.update(cached=True, path=path, size_bytes=_dir_size(path))
    return row


def fetch_spec(spec: SnapshotSpec, emit: Callable[[dict], None] | None) -> dict[str, Any]:
    """Download one snapshot (resumable). ``emit`` set = JSON progress events."""
    if emit is not None:
        emit({"event": "start", "repo": spec.repo_id, "revision": spec.revision, "kind": spec.kind})
    tqdm_class = _progress_class(spec.repo_id, emit) if emit is not None else None
    path = _snapshot_download(spec, local_files_only=False, tqdm_class=tqdm_class)
    size = _dir_size(path)
    done = {"event": "done", "repo": spec.repo_id, "path": path, "size_bytes": size}
    if emit is not None:
        emit(done)
    return done


def run_prefetch(backend: str, model: str | None, *, check: bool, json_mode: bool) -> int:
    """CLI body; returns the process exit status."""
    from . import supervise

    if json_mode:
        # Our progress class is plain tqdm; silence hf's own bars on stderr too.
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
    ctx = supervise.json_channel() if json_mode else contextlib.nullcontext()
    with ctx:
        emit = supervise.emit if json_mode else None
        try:
            if check:
                return _run_check(backend, model, emit)
            return _run_fetch(backend, model, emit)
        except Exception as exc:  # noqa: BLE001 - CLI boundary: report, exit 1
            code, message = supervise.classify_startup_error(exc)
            if isinstance(exc, ImportError) and not isinstance(exc, ModuleNotFoundError):
                code = supervise.CODE_MODULE_NOT_FOUND
            if code == supervise.CODE_MODULE_NOT_FOUND:
                message = (
                    f"{message} — install the {backend!r} extra "
                    f"(uv sync --extra {backend}) to prefetch its weights"
                )
            _report_error(emit, code, message, repo=getattr(exc, "_prefetch_repo", None))
            return 1


def _report_error(emit, code: str, message: str, *, repo: str | None) -> None:
    if emit is not None:
        emit({"event": "error", "code": code, "message": message, "repo": repo})
    else:
        print(f"tts_server: prefetch failed: {message}", file=sys.stderr)


def _run_check(backend: str, model: str | None, emit) -> int:
    specs = specs_for(backend, model)
    rows = [check_spec(s) for s in specs]
    summary: dict[str, Any] = {
        "event": "summary",
        "backend": backend,
        "model": model,
        "cached": all(r["cached"] for r in rows if r["required"]),
        "size_bytes": sum(r["size_bytes"] for r in rows),
    }
    hooks = _prefetch_hooks(backend)
    if isinstance(hooks, SupportsPrefetchCheckExtra):
        summary.update(hooks.prefetch_check_extra(model))
    if emit is not None:
        for r in rows:
            emit(r)
        emit(summary)
        return 0
    for r in rows:
        state = "cached" if r["cached"] else ("missing" if r["required"] else "missing (optional)")
        print(f"{r['kind']:<6} {r['repo']}@{r['revision'] or 'main'}: {state}")
    print(
        f"{backend}: {'cached' if summary['cached'] else 'not cached'}"
        f" ({summary['size_bytes'] / 1e6:.1f} MB on disk)"
    )
    return 0


def _run_fetch(backend: str, model: str | None, emit) -> int:
    specs = specs_for(backend, model)
    total = 0
    for spec in specs:
        if emit is None:
            print(f"prefetch: {spec.kind} {spec.repo_id}@{spec.revision or 'main'}")
        try:
            done = fetch_spec(spec, emit)
        except ImportError:
            raise
        except Exception as exc:
            if spec.required:
                exc._prefetch_repo = spec.repo_id  # type: ignore[attr-defined]
                raise
            message = f"optional {spec.kind} {spec.repo_id} could not be fetched: {exc}"
            logger.warning("prefetch: %s", message)
            if emit is not None:
                emit({"event": "warning", "repo": spec.repo_id, "message": message})
            continue
        total += done["size_bytes"]
    hooks = _prefetch_hooks(backend)
    if isinstance(hooks, SupportsPrefetchFinalize):
        hooks.prefetch_finalize(model, emit)
    complete = {
        "event": "complete",
        "backend": backend,
        "model": model,
        "cached": True,
        "size_bytes": total,
    }
    if emit is not None:
        emit(complete)
    else:
        print(f"prefetch: {backend} ready ({total / 1e6:.1f} MB)")
    return 0
