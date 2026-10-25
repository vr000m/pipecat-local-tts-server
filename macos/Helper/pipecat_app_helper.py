"""Helper Pipecat Service Toolbar (the macOS app) runs inside its speech-to-text environments.

The TTS server ships ``prefetch`` and ``serve --supervised`` itself. The STT
engines run on ``pipecat-local-stt-server`` (from PyPI), which has neither, so
this script gives them the same contract without modifying that package:

    python pipecat_app_helper.py prefetch --repo R [--state-dir D] [--check] --json
    python pipecat_app_helper.py serve-stt --engine {whisper,kyutai} --port P [--model M]

``serve-stt`` builds the engine's backend and hands it to
``stt_server.server.serve``, so clients speak the standard stt wire protocol.
Kyutai is not an ``stt_server`` backend; its backend lives here and runs on
``moshi_mlx``.

Supervised contract (same as ``tts_server serve --supervised``):

- stdout carries only JSON lines: ``{"event":"ready",...}`` once listening and
  warm, or ``{"event":"error","code",...}`` on a fatal error;
- stdin EOF (the app quit or crashed) stops the server like SIGTERM.

Every event's fields and every error ``code`` are fixed in
``docs/supervised-contract.json``; ``tests/test_supervised_contract.py`` runs
this helper and ``tts_server`` on stub inputs and checks both against it.

Prefetch progress is measured from the Hugging Face cache on disk, so it works
with every ``huggingface_hub`` version (Kyutai's runtime pins ``<0.29``).

Stdlib-only at import; engine libraries load inside the commands.
"""

from __future__ import annotations

import argparse
import asyncio
import contextlib
import errno
import json
import logging
import os
import signal
import socket
import sys
import threading
from pathlib import Path

logger = logging.getLogger("pipecat_app_helper")

# Each engine's default model: the family default's ``modelRepo`` in
# macos/Sources/PipecatToolbarCore/Service.swift (drift-tested).
DEFAULT_MODELS = {
    "whisper": "mlx-community/whisper-large-v3-turbo",
    "kyutai": "kyutai/stt-1b-en_fr-mlx",
}

# The Hugging Face commit each model repo the app offers is pinned to, so the
# snapshot ``prefetch`` downloads is the one ``serve-stt`` loads (never a newer
# HEAD). Keys are exactly the STT ``modelRepo`` values in Service.swift, and
# ``ServiceCatalog.sttModelRevisions`` there repeats this table so the app sizes
# the same commit before an install (both drift-tested). Fetched from the HF API on 2026-10-24; the repos' last
# commits are 2024-03-09 (whisper-tiny), 2025-06-19 (kyutai) and 2026-04-12
# (other whisper sizes). A repo missing here (a user-supplied --repo/--model)
# resolves HEAD, as before.
MODEL_REVISIONS = {
    "mlx-community/whisper-large-v3-turbo": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
    "mlx-community/whisper-large-v3-mlx": "49e6aa286ad60c14352c404340ded53710378a11",
    "mlx-community/whisper-medium-mlx": "7fc08c4eac4c316526498f147dfdee6f6303f975",
    "mlx-community/whisper-small-mlx": "45f3915923c7a79a5a5b5a7d909d39aeb0e5630e",
    "mlx-community/whisper-base-mlx": "1e3e249fb8d01c655324bd6841b1deadffd6d04c",
    "mlx-community/whisper-tiny-mlx": "6caf9c55601caafbe6508a8b0d216bdf4783c4e8",
    "kyutai/stt-1b-en_fr-mlx": "2b995724eef1e964b7ccb6a762b35a665c4abe0d",
    "kyutai/stt-2.6b-en-mlx": "5ccfc8f844ab8abaf591c7954f70c07e72325554",
}

# The stt wire format's sample rate (``stt_server.protocol.AUDIO_SAMPLE_RATE_HZ``,
# Swift ``STTWire.rate``). Kyutai's resampler and the warmups assume it;
# ``serve-stt`` refuses to start if the installed stt_server disagrees.
WIRE_RATE = 16000

# Stable ``code`` values for ``{"event":"error"}`` lines: a subset of
# ``tts_server.supervise``'s ``CODE_*`` (this helper has no Unix socket and no
# config errors). Listed in docs/supervised-contract.json.
CODE_MODULE_NOT_FOUND = "ModuleNotFoundError"
CODE_ADDR_IN_USE = "EADDRINUSE"
CODE_ACCESS_DENIED = "EACCES"
CODE_MODEL_DOWNLOAD = "ModelDownloadError"
CODE_BACKEND_START = "BackendStartError"

# Exception modules that mean "fetching weights failed" (same as supervise.py).
_DOWNLOAD_MODULE_PREFIXES = ("huggingface_hub", "requests", "urllib3", "hf_xet", "httpx")

# --- JSON channel -------------------------------------------------------------

_OUT = sys.stdout


def emit(event: dict) -> None:
    _OUT.write(json.dumps(event, separators=(",", ":")) + "\n")
    _OUT.flush()


@contextlib.contextmanager
def json_channel():
    """Reserve stdout for ``emit``; route stray prints to stderr."""
    global _OUT
    prev_out, prev_stdout = _OUT, sys.stdout
    _OUT = sys.stdout
    sys.stdout = sys.stderr
    try:
        yield
    finally:
        sys.stdout = prev_stdout
        _OUT = prev_out


def classify(exc: BaseException) -> str:
    """The error ``code`` for a fatal exception: ``supervise.classify_startup_error``'s
    priority order over the cause chain, minus its Unix-socket cases."""
    seen = set()
    chain = []
    cur: BaseException | None = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        chain.append(cur)
        cur = cur.__cause__ or cur.__context__
    for e in chain:
        if isinstance(e, ModuleNotFoundError):
            return CODE_MODULE_NOT_FOUND
    for e in chain:
        if isinstance(e, OSError) and e.errno == errno.EADDRINUSE:
            return CODE_ADDR_IN_USE
    for e in chain:
        if isinstance(e, OSError) and e.errno == errno.EACCES:
            return CODE_ACCESS_DENIED
    for e in chain:
        module = type(e).__module__ or ""
        if module.startswith(_DOWNLOAD_MODULE_PREFIXES) or isinstance(
            e, (ConnectionError, TimeoutError)
        ):
            return CODE_MODEL_DOWNLOAD
    return CODE_BACKEND_START


# --- prefetch -----------------------------------------------------------------


def _repo_cache_dir(repo: str) -> Path:
    from huggingface_hub import constants  # type: ignore

    return Path(constants.HF_HUB_CACHE) / ("models--" + repo.replace("/", "--"))


def _dir_bytes(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for p in path.rglob("*"):
        try:
            if p.is_file() and not p.is_symlink():
                total += p.stat().st_size
        except OSError:
            pass
    return total


def _state_file(state_dir: str | None, repo: str) -> Path | None:
    if not state_dir:
        return None
    return Path(state_dir) / f".prefetch-{repo.replace('/', '--')}.json"


def _check_row(repo: str, revision: str | None, path: str | None, size: int) -> dict:
    """``prefetch --check``'s per-snapshot row, as ``tts_server prefetch`` writes it."""
    return {
        "event": "check",
        "repo": repo,
        "revision": revision,
        "kind": "model",
        "required": True,
        "cached": path is not None,
        "path": path,
        "size_bytes": size,
    }


def _cached_record(state: Path | None, revision: str | None) -> tuple[str, int] | None:
    """``(snapshot path, size)`` of a completed prefetch whose files are all still
    present and whose snapshot is the pinned commit (a snapshot folder is named
    after its commit, so records written before the pins are judged the same way)."""
    if not state or not state.exists():
        return None
    try:
        record = json.loads(state.read_text())
        snap = Path(record["path"])
        if revision is not None and snap.name != revision:
            return None
        if snap.is_dir() and all((snap / f).exists() for f in record["files"]):
            return str(snap), int(record["size_bytes"])
    except (OSError, ValueError, KeyError, TypeError):
        pass
    return None


def cmd_prefetch(args: argparse.Namespace) -> int:
    repo = args.repo
    revision = args.revision or MODEL_REVISIONS.get(repo)
    state = _state_file(args.state_dir, repo)
    if args.check:
        # Offline: trust only a completion record whose files are all still present.
        found = _cached_record(state, revision)
        path, size = found if found else (None, 0)
        emit(_check_row(repo, revision, path, size))
        emit(
            {
                "event": "summary",
                "backend": None,
                "model": repo,
                "cached": path is not None,
                "size_bytes": size,
            }
        )
        return 0

    try:
        from huggingface_hub import HfApi, snapshot_download  # type: ignore
    except ImportError as exc:
        emit({"event": "error", "code": CODE_MODULE_NOT_FOUND, "message": str(exc), "repo": repo})
        return 1

    try:
        files = [
            f
            for f in HfApi().list_repo_tree(repo, revision=revision, recursive=True)
            if getattr(f, "size", None) is not None and not f.path.startswith(".")
        ]
        names = [f.path for f in files if not f.path.lower().endswith((".md", ".gitattributes"))]
        total = sum(
            (f.lfs.size if getattr(f, "lfs", None) else f.size) for f in files if f.path in names
        )
        repo_dir = _repo_cache_dir(repo)
        baseline = _dir_bytes(repo_dir / "blobs")
        emit(
            {
                "event": "start",
                "repo": repo,
                "revision": revision,
                "kind": "model",
            }
        )

        done = threading.Event()

        def report() -> None:
            while not done.wait(0.3):
                grown = _dir_bytes(repo_dir / "blobs") - baseline
                emit(
                    {
                        "event": "progress",
                        "repo": repo,
                        "downloaded_bytes": max(0, min(grown, total)),
                        "total_bytes": total,
                        "files_done": 0,
                        "files_total": len(names),
                    }
                )

        reporter = threading.Thread(target=report, daemon=True)
        reporter.start()
        try:
            path = snapshot_download(repo, revision=revision, allow_patterns=names)
        finally:
            done.set()
            reporter.join(timeout=1)
        size = sum(
            (Path(path) / n).resolve().stat().st_size for n in names if (Path(path) / n).exists()
        )
        if state:
            state.parent.mkdir(parents=True, exist_ok=True)
            state.write_text(
                json.dumps(
                    {
                        "repo": repo,
                        "revision": revision,
                        "path": str(path),
                        "files": names,
                        "size_bytes": size,
                    }
                )
            )
        emit(
            {
                "event": "progress",
                "repo": repo,
                "downloaded_bytes": total,
                "total_bytes": total,
                "files_done": len(names),
                "files_total": len(names),
            }
        )
        emit({"event": "done", "repo": repo, "path": str(path), "size_bytes": size})
        emit(
            {
                "event": "complete",
                "backend": None,
                "model": repo,
                "cached": True,
                "size_bytes": size,
            }
        )
        return 0
    except Exception as exc:  # noqa: BLE001 - CLI boundary
        logger.exception("prefetch failed")
        emit(
            {
                "event": "error",
                "code": classify(exc),
                "message": f"model download failed: {exc}",
                "repo": repo,
            }
        )
        return 1


# --- Kyutai backend (moshi_mlx) ---------------------------------------------------


def _resample_16k_to_24k(audio):
    """WIRE_RATE -> Mimi's 24 kHz: polyphase 2:3 resample (zero-stuff x3,
    windowed-sinc low-pass, keep every 2nd)."""
    import numpy as np

    if audio.size == 0:
        return audio
    up = np.zeros(audio.size * 3, dtype=np.float32)
    up[::3] = audio
    n = np.arange(-48, 49, dtype=np.float64)
    fc = 8000 / 48000  # source Nyquist at the 48 kHz intermediate rate
    taps = 2 * fc * np.sinc(2 * fc * n) * np.hamming(n.size) * 3
    return np.convolve(up, taps.astype(np.float32), mode="same")[::2]


class KyutaiBackend:
    """``stt_server`` backend for Kyutai's streaming STT models on MLX.

    Commit-oriented like the other stt backends: on commit the buffered 16 kHz
    audio is resampled to 24 kHz, padded as the model's ``stt_config`` asks
    (leading silence; trailing silence to flush the text the model emits
    ``audio_delay_seconds`` behind the audio), run through Mimi + the LM frame by
    frame (80 ms each), and returned as one delta + completed. The LM's KV cache
    is a rotating window, so an utterance can be any length.
    """

    backend_name = "kyutai"

    def __init__(self, model: str, revision: str | None = None) -> None:
        self.model = model
        self.revision = revision
        self._lock = threading.Lock()
        self._prefix_samples = 0
        self._flush_samples = 2 * 24000

    async def start(self) -> None:
        await asyncio.get_running_loop().run_in_executor(None, self._load)

    def _load(self) -> None:
        import mlx.core as mx  # type: ignore
        import sentencepiece  # type: ignore
        from huggingface_hub import hf_hub_download  # type: ignore
        from mlx import nn  # type: ignore
        from moshi_mlx import models, utils  # type: ignore

        def fetch(name: str) -> str:
            return hf_hub_download(self.model, name, revision=self.revision)

        raw = json.loads(Path(fetch("config.json")).read_text())
        mimi_weights = fetch(raw["mimi_name"])
        moshi_weights = fetch(raw.get("moshi_name", "model.safetensors"))
        tokenizer = fetch(raw["tokenizer_name"])

        stt = raw.get("stt_config") or {}
        self._prefix_samples = int(float(stt.get("audio_silence_prefix_seconds", 0.0)) * 24000)
        delay = float(stt.get("audio_delay_seconds", 0.5))
        self._flush_samples = int(max(2.0, delay + 1.0) * 24000)
        lm_config = models.LmConfig.from_config_dict(raw)
        model = models.Lm(lm_config)
        model.set_dtype(mx.bfloat16)
        if moshi_weights.endswith(".q4.safetensors"):
            nn.quantize(model, bits=4, group_size=32)
        elif moshi_weights.endswith(".q8.safetensors"):
            nn.quantize(model, bits=8, group_size=64)
        model.load_weights(moshi_weights, strict=True)
        self._models, self._utils, self._mx = models, utils, mx
        self._lm = model
        self._tokenizer = sentencepiece.SentencePieceProcessor(tokenizer)  # type: ignore
        self._mimi_codebooks = 32
        self._mimi = models.mimi.Mimi(models.mimi_202407(self._mimi_codebooks))
        self._mimi.load_pytorch_weights(str(mimi_weights), strict=True)
        model.warmup()
        self.transcribe(b"\x00\x00" * WIRE_RATE)  # JIT the Mimi + LM path once
        logger.info("kyutai: loaded %s", self.model)

    def transcribe(self, pcm16: bytes, cancel: threading.Event | None = None) -> str:
        """Decode one utterance. `cancel` is polled once per 80 ms frame so a
        cancelled/disconnected request releases the backend lock promptly
        (run_in_executor threads cannot be interrupted otherwise); returns ""
        when cancelled. State is reset at the start of every call, so an
        aborted pass leaves nothing behind for the next request."""
        import numpy as np

        mx, models, utils = self._mx, self._models, self._utils
        audio = np.frombuffer(pcm16, dtype="<i2").astype(np.float32) / 32768.0
        audio = np.concatenate(
            [
                np.zeros(self._prefix_samples, dtype=np.float32),
                _resample_16k_to_24k(audio),
                np.zeros(self._flush_samples, dtype=np.float32),
            ]
        )
        frames = audio.size // 1920
        x = mx.array(audio[None, : frames * 1920])
        with self._lock:
            # Fresh streaming state per utterance: Mimi's encoder state and the
            # LM's KV cache (LmGen does not reset it).
            mimi = self._mimi
            mimi.reset_all()
            for cache in self._lm.transformer_cache:
                cache.reset()
            gen = models.LmGen(
                model=self._lm,
                max_steps=frames + 8,
                text_sampler=utils.Sampler(top_k=25, temp=0),
                audio_sampler=utils.Sampler(top_k=250, temp=0.8),
                check=False,
            )
            pieces: list[str] = []
            for start in range(0, frames * 1920, 1920):
                if cancel is not None and cancel.is_set():
                    return ""
                block = x[:, None, start : start + 1920]
                tokens = mimi.encode_step(block).transpose(0, 2, 1)
                token = gen.step(tokens[0])[0].item()
                if token not in (0, 3):
                    pieces.append(self._tokenizer.id_to_piece(token).replace("▁", " "))
        return "".join(pieces).strip()

    async def open_stream(self, *, language: str | None = None):
        return _KyutaiStream(self)

    async def close(self) -> None:
        return None


class _KyutaiStream:
    def __init__(self, backend: KyutaiBackend) -> None:
        self._backend = backend
        self._buf = bytearray()
        self._cancel = threading.Event()

    async def feed(self, chunk: bytes) -> None:
        self._buf.extend(chunk)

    async def end(self) -> None:
        return None

    async def cancel(self) -> None:
        self._cancel.set()

    async def events(self):
        from stt_server.backend import TranscriptEvent  # type: ignore

        if self._cancel.is_set() or not self._buf:
            return
        try:
            text = await asyncio.get_running_loop().run_in_executor(
                None, self._backend.transcribe, bytes(self._buf), self._cancel
            )
        except asyncio.CancelledError:
            # The executor thread can't be killed; tell it to stop at the next frame.
            self._cancel.set()
            raise
        if self._cancel.is_set():
            return
        yield TranscriptEvent(kind="delta", text=text)
        yield TranscriptEvent(kind="completed", text=text)


# --- serve-stt ------------------------------------------------------------------


def _watch_stdin_eof() -> None:
    """Parent gone (stdin EOF) -> SIGTERM ourselves: graceful once serving,
    immediate during the model load (default SIGTERM action)."""

    def run() -> None:
        fd = sys.stdin.fileno()
        while True:
            try:
                if not os.read(fd, 4096):
                    break
            except InterruptedError:
                continue
            except OSError:
                break
        logger.info("stdin closed (supervisor gone); stopping")
        os.kill(os.getpid(), signal.SIGTERM)

    if sys.stdin is not None:
        threading.Thread(target=run, name="stdin-watch", daemon=True).start()


def _pinned_snapshot(repo: str, revision: str) -> str:
    """Local folder of ``repo`` at ``revision``: the cached snapshot ``prefetch``
    left, else downloaded now (what an unpinned load would also do)."""
    from huggingface_hub import snapshot_download  # type: ignore

    try:
        return str(snapshot_download(repo, revision=revision, local_files_only=True))
    except Exception:  # noqa: BLE001 - any cache miss: fetch the pinned commit
        return str(snapshot_download(repo, revision=revision))


def _make_backend(engine: str, model: str):
    revision = MODEL_REVISIONS.get(model)
    if engine == "whisper":
        from stt_server.backends.mlx_whisper import MLXWhisperBackend  # type: ignore

        if revision is None:
            return MLXWhisperBackend(model=model)
        # mlx_whisper loads a repo id at its HEAD; hand it the pinned snapshot's
        # folder instead, and keep the repo id as the backend's public identity
        # (``model`` is what server.hello reports, so no local path leaks).
        backend = MLXWhisperBackend(model=_pinned_snapshot(model, revision))
        backend.model = model
        return backend
    if engine == "kyutai":
        return KyutaiBackend(model, revision)
    raise SystemExit(f"unknown engine {engine!r}")


def _wire_rate() -> int:
    """The installed stt_server's wire rate; refuses one this helper doesn't speak."""
    from stt_server.protocol import AUDIO_SAMPLE_RATE_HZ  # type: ignore

    if AUDIO_SAMPLE_RATE_HZ != WIRE_RATE:
        raise RuntimeError(
            f"stt_server speaks {AUDIO_SAMPLE_RATE_HZ} Hz but this helper expects {WIRE_RATE} Hz"
        )
    return AUDIO_SAMPLE_RATE_HZ


def ready_event(server, *, engine: str, model: str, host: str, port: int, rate: int) -> dict:
    """The ``ready`` line for a listening ``stt_server.server.TranscriptionServer``;
    the bound port comes from its public ``listening_port()`` (``port`` 0 = ephemeral)."""
    return {
        "event": "ready",
        "backend": engine,
        "model": model,
        "host": host,
        "port": server.listening_port() or port,
        "socket_path": None,
        "rate": rate,
        "pid": os.getpid(),
    }


async def _warm(backend) -> None:
    """Decode 1 s of silence so the first real request doesn't pay for the load."""
    stream = await backend.open_stream(language=None)
    await stream.feed(b"\x00\x00" * WIRE_RATE)
    await stream.end()
    async for _ in stream.events():
        pass


def cmd_serve_stt(args: argparse.Namespace) -> int:
    logging.basicConfig(
        level=args.log_level, format="%(asctime)s %(levelname)s %(name)s: %(message)s"
    )
    model = args.model or DEFAULT_MODELS[args.engine]
    with json_channel():
        try:
            _watch_stdin_eof()
            if args.port:
                with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as probe:
                    probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                    probe.bind((args.host, args.port))
            from stt_server.server import serve  # type: ignore

            rate = _wire_rate()
            logger.info("starting %s (model=%s)", args.engine, model)
            backend = _make_backend(args.engine, model)

            async def ready(server) -> None:
                if args.engine == "whisper":
                    await _warm(backend)
                event = ready_event(
                    server,
                    engine=args.engine,
                    model=model,
                    host=args.host,
                    port=args.port,
                    rate=rate,
                )
                logger.info(
                    "listening on %s:%s (engine=%s model=%s)",
                    args.host,
                    event["port"],
                    args.engine,
                    model,
                )
                emit(event)

            asyncio.run(serve(backend, host=args.host, port=args.port, ready=ready))
            return 0
        except KeyboardInterrupt:
            return 0
        except SystemExit:
            raise
        except Exception as exc:  # noqa: BLE001 - CLI boundary
            logger.exception("fatal error")
            emit(
                {
                    "event": "error",
                    "code": classify(exc),
                    "message": str(exc) or type(exc).__name__,
                    "exc_type": type(exc).__name__,
                }
            )
            return 1


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(prog="pipecat_app_helper")
    sub = parser.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("prefetch")
    p.add_argument("--repo", required=True)
    p.add_argument("--revision", default=None)
    p.add_argument("--state-dir", default=None)
    p.add_argument("--check", action="store_true")
    p.add_argument("--json", action="store_true")
    s = sub.add_parser("serve-stt")
    s.add_argument("--engine", choices=sorted(DEFAULT_MODELS), required=True)
    s.add_argument("--host", default="127.0.0.1")
    s.add_argument("--port", type=int, required=True)
    s.add_argument("--model", default=None)
    s.add_argument("--log-level", default="INFO")
    args = parser.parse_args(argv)
    if args.cmd == "prefetch":
        logging.basicConfig(level=logging.WARNING)
        os.environ.setdefault("HF_HUB_DISABLE_PROGRESS_BARS", "1")
        with json_channel():
            return cmd_prefetch(args)
    return cmd_serve_stt(args)


if __name__ == "__main__":
    sys.exit(main())
