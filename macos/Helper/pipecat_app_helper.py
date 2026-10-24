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

DEFAULT_MODELS = {
    "whisper": "mlx-community/whisper-large-v3-turbo",
    "kyutai": "kyutai/stt-1b-en_fr-mlx",
}

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
    seen = set()
    chain = []
    cur: BaseException | None = exc
    while cur is not None and id(cur) not in seen:
        seen.add(id(cur))
        chain.append(cur)
        cur = cur.__cause__ or cur.__context__
    for e in chain:
        if isinstance(e, ModuleNotFoundError):
            return "ModuleNotFoundError"
    for e in chain:
        if isinstance(e, OSError) and e.errno == errno.EADDRINUSE:
            return "EADDRINUSE"
    for e in chain:
        module = type(e).__module__ or ""
        if module.startswith(
            ("huggingface_hub", "requests", "urllib3", "httpx", "hf_xet")
        ) or isinstance(e, (ConnectionError, TimeoutError)):
            return "ModelDownloadError"
    return "BackendStartError"


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


def cmd_prefetch(args: argparse.Namespace) -> int:
    repo, revision = args.repo, args.revision
    state = _state_file(args.state_dir, repo)
    if args.check:
        # Offline: trust only a completion record whose files are all still present.
        if state and state.exists():
            try:
                record = json.loads(state.read_text())
                snap = Path(record["path"])
                if snap.is_dir() and all((snap / f).exists() for f in record["files"]):
                    emit(
                        {
                            "event": "summary",
                            "repo": repo,
                            "cached": True,
                            "path": str(snap),
                            "size_bytes": record["size_bytes"],
                        }
                    )
                    return 0
            except (OSError, ValueError, KeyError):
                pass
        emit({"event": "summary", "repo": repo, "cached": False, "path": None, "size_bytes": 0})
        return 0

    try:
        from huggingface_hub import HfApi, snapshot_download  # type: ignore
    except ImportError as exc:
        emit({"event": "error", "code": "ModuleNotFoundError", "message": str(exc), "repo": repo})
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
                "files": len(names),
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
                json.dumps({"repo": repo, "path": str(path), "files": names, "size_bytes": size})
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
        emit({"event": "complete", "repo": repo, "cached": True, "size_bytes": size})
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
    """Polyphase 2:3 resample (zero-stuff x3, windowed-sinc low-pass, keep every 2nd)."""
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

    def __init__(self, model: str) -> None:
        self.model = model
        self._lock = threading.Lock()
        self._prefix_samples = 0
        self._flush_samples = 2 * 24000

    async def start(self) -> None:
        await asyncio.get_running_loop().run_in_executor(None, self._load)

    def _load(self) -> None:
        import mlx.core as mx  # type: ignore
        import mlx.nn as nn  # type: ignore
        import sentencepiece  # type: ignore
        from huggingface_hub import hf_hub_download  # type: ignore
        from moshi_mlx import models, utils  # type: ignore

        config_path = hf_hub_download(self.model, "config.json")
        raw = json.loads(Path(config_path).read_text())
        mimi_weights = hf_hub_download(self.model, raw["mimi_name"])
        moshi_weights = hf_hub_download(self.model, raw.get("moshi_name", "model.safetensors"))
        tokenizer = hf_hub_download(self.model, raw["tokenizer_name"])

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
        self.transcribe(b"\x00\x00" * 16000)  # JIT the Mimi + LM path once
        logger.info("kyutai: loaded %s", self.model)

    def transcribe(self, pcm16: bytes) -> str:
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
        self._cancelled = False

    async def feed(self, chunk: bytes) -> None:
        self._buf.extend(chunk)

    async def end(self) -> None:
        return None

    async def cancel(self) -> None:
        self._cancelled = True

    async def events(self):
        from stt_server.backend import TranscriptEvent  # type: ignore

        if self._cancelled or not self._buf:
            return
        text = await asyncio.get_running_loop().run_in_executor(
            None, self._backend.transcribe, bytes(self._buf)
        )
        if self._cancelled:
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


def _make_backend(engine: str, model: str):
    if engine == "whisper":
        from stt_server.backends.mlx_whisper import MLXWhisperBackend  # type: ignore

        return MLXWhisperBackend(model=model)
    if engine == "kyutai":
        return KyutaiBackend(model)
    raise SystemExit(f"unknown engine {engine!r}")


async def _warm(backend) -> None:
    """Decode 1 s of silence so the first real request doesn't pay for the load."""
    stream = await backend.open_stream(language=None)
    await stream.feed(b"\x00\x00" * 16000)
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

            logger.info("starting %s (model=%s)", args.engine, model)
            backend = _make_backend(args.engine, model)

            async def ready(server) -> None:
                if args.engine == "whisper":
                    await _warm(backend)
                port = args.port
                for s in getattr(getattr(server, "_server", None), "sockets", None) or []:
                    name = s.getsockname()
                    if isinstance(name, tuple):
                        port = name[1]
                        break
                logger.info(
                    "listening on %s:%s (engine=%s model=%s)", args.host, port, args.engine, model
                )
                emit(
                    {
                        "event": "ready",
                        "backend": args.engine,
                        "model": model,
                        "host": args.host,
                        "port": port,
                        "rate": 16000,
                        "pid": os.getpid(),
                    }
                )

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
