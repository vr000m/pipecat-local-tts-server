"""App-path smoke: drive the TTS server exactly the way the macOS menu bar app does.

``run_smoke.sh`` starts a plain ``serve`` on a temp Unix socket; the app never
does that. This script is a proxy for the app (``EnvironmentManager.swift``,
``ServiceDriver.swift``, ``Subprocess.swift``) against one backend, or every
backend in the registry with ``--all``:

1. ``prefetch-check``: ``python -m tts_server prefetch --backend B [--model M]
   --json --check``; every stdout line must be a contract event
   (``docs/supervised-contract.json``) ending in one ``summary``. With
   ``--download`` a real ``prefetch --json`` runs first (off by default: it can
   pull gigabytes).
2. ``ready``: ``serve --backend B [--model M] --host 127.0.0.1 --port P
   --supervised --log-level INFO`` on a free ephemeral port, stdin a pipe, the
   app's scrubbed environment and a temp cwd. The first stdout line must be a
   ``ready`` naming the backend, the resolved model, the real port and the
   child's own pid, within ``--ready-timeout``.
3. ``synth``: ``TTSClient`` over loopback TCP; int16 PCM at the advertised
   ``audio.rate`` (== ``ready.rate``), gapless ``seq`` from 0, ``duration_ms``
   matching the samples; TTFB / RTF / cadence printed (``latency_smoke``).
4. ``busy-port``: a second ``serve --supervised`` on the same port must print
   ``error{code: EADDRINUSE}`` before any model load (no ``starting`` log) and
   exit non-zero. Runs even when the weights are missing (the port is then held
   by a plain listener, and ``HF_HUB_OFFLINE=1`` guards against a download).
5. ``eof-stop``: closing the child's stdin, with no signal, must stop it with
   exit 0 within ``--stop-bound`` (the app's 10 s ``stopGrace``), stdout must have
   carried only JSON lines, the port must be released and no process may remain
   in the child's process group.
6. ``eof-during-startup``: stdin closed right after launch must also end the
   process with exit 0 (the "app quit mid-download" path).

A backend whose weights are not cached reports ``SKIP (needs weights)`` for the
serve phases; one whose extra is not installed in the chosen interpreter reports
``SKIP (extra not installed)`` from the ``ModuleNotFoundError`` line the app
would see. Point ``--python`` at an app-installed environment to test the env
the app built instead of this checkout's ``.venv``.

Usage:
  uv run --no-sync python tests/smoke/supervised_smoke.py [--backend tone] \\
      [--model M] [--all] [--download] [--python PATH] [--text "..."] \\
      [--ready-timeout S] [--stop-bound S] [--keep]
Exit code: 0 when no phase FAILed (SKIP is not a failure).
"""

from __future__ import annotations

import argparse
import asyncio
import os
import queue
import shutil
import socket
import subprocess
import sys
import tempfile
import threading
import time
from array import array
from dataclasses import dataclass, field
from pathlib import Path

# Same-directory imports (the script's dir is sys.path[0]).
from _supervised_contract import (
    app_child_env,
    canonical_ports,
    event_errors,
    load_contract,
    parse_json_lines,
    prefetch_errors,
    ready_errors,
    usable_smoke_port,
)
from latency_smoke import cadence_metrics, collect_response, format_metrics

from tts_server.backends import BACKENDS
from tts_server.client import TTSClient

HOST = "127.0.0.1"  # ServiceCatalog.host
_DEFAULT_TEXT = "Hello from the Pipecat menu bar smoke test."
# dia is a dialogue model: speakers ride in-text (see run_smoke.sh).
_TEXT_OVERRIDES = {"dia": "[S1] Hello from the Pipecat menu bar smoke test. [S2] It works."}
# The log line ``_run_serve`` writes before constructing/loading the backend.
_STARTING_LOG = "tts_server: starting (backend="
_CANONICAL = canonical_ports()


@dataclass
class Report:
    backend: str
    rows: list[tuple[str, str, str]] = field(default_factory=list)

    def add(self, phase: str, status: str, detail: str = "") -> None:
        self.rows.append((phase, status, detail))
        print(f"  [{status}] {phase}" + (f": {detail}" if detail else ""), flush=True)

    @property
    def failed(self) -> bool:
        return any(s == "FAIL" for _p, s, _d in self.rows)


class Child:
    """A supervised child as the app runs it: stdin pipe, stdout lines, stderr to a file."""

    def __init__(self, argv: list[str], *, env: dict[str, str], cwd: Path, log: Path) -> None:
        self.log = log
        self._err = log.open("wb")
        self.proc = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=self._err,
            env=env,
            cwd=cwd,
            start_new_session=True,  # own process group, like the app's children
        )
        self.pgid = os.getpgid(self.proc.pid)
        self.lines: list[str] = []
        self._q: queue.Queue[str | None] = queue.Queue()
        threading.Thread(target=self._pump, daemon=True).start()

    def _pump(self) -> None:
        assert self.proc.stdout is not None
        for raw in self.proc.stdout:
            line = raw.decode("utf-8", "replace").rstrip("\n")
            self.lines.append(line)
            self._q.put(line)
        self._q.put(None)

    def next_line(self, timeout: float) -> str | None:
        """The next stdout line, or None on EOF/timeout."""
        try:
            return self._q.get(timeout=timeout)
        except queue.Empty:
            return None

    def close_stdin(self) -> None:
        if self.proc.stdin is not None and not self.proc.stdin.closed:
            self.proc.stdin.close()

    def wait(self, timeout: float) -> int | None:
        try:
            return self.proc.wait(timeout)
        except subprocess.TimeoutExpired:
            return None

    def stderr_text(self) -> str:
        self._err.flush()
        return self.log.read_text(errors="replace")

    def group_alive(self) -> bool:
        try:
            os.killpg(self.pgid, 0)
        except ProcessLookupError:
            return False
        except PermissionError:
            return True
        return True

    def kill(self) -> None:
        """Teardown only (never part of an assertion)."""
        self.close_stdin()
        for sig in (15, 9):
            if not self.group_alive():
                break
            try:
                os.killpg(self.pgid, sig)
            except ProcessLookupError:
                break
            self.wait(5)
        self.wait(5)
        self._err.close()


def _free_port() -> int:
    for _ in range(50):
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
            s.bind((HOST, 0))
            port = s.getsockname()[1]
        if usable_smoke_port(port, _CANONICAL):
            return port
    raise SystemExit("could not find a free ephemeral loopback port")


def _port_accepts(port: int) -> bool:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.settimeout(1.0)
        try:
            s.connect((HOST, port))
        except OSError:
            return False
        return True


def _python_argv(python: str, *args: str) -> list[str]:
    return [python, "-m", "tts_server", *args]


def _serve_argv(python: str, backend: str, model: str | None, port: int) -> list[str]:
    # EnvironmentManager.serveArguments: same flags, same order.
    args = ["serve", "--backend", backend]
    if model:
        args += ["--model", model]
    return _python_argv(
        python, *args, "--host", HOST, "--port", str(port), "--supervised", "--log-level", "INFO"
    )


def _prefetch_argv(python: str, backend: str, model: str | None, *, check: bool) -> list[str]:
    # EnvironmentManager.prefetchArguments.
    args = ["prefetch", "--backend", backend]
    if model:
        args += ["--model", model]
    args.append("--json")
    if check:
        args.append("--check")
    return _python_argv(python, *args)


def _run_prefetch(
    ctx: Ctx, backend: str, model: str | None, *, check: bool, timeout: float
) -> tuple[list[dict], list[str]]:
    """Run prefetch; returns (events, errors)."""
    proc = subprocess.run(
        _prefetch_argv(ctx.python, backend, model, check=check),
        capture_output=True,
        env=ctx.env,
        cwd=ctx.run_dir,
        timeout=timeout,
        stdin=subprocess.DEVNULL,
    )
    out = proc.stdout.decode("utf-8", "replace")
    events, bad = parse_json_lines(out)
    errors = [f"non-JSON stdout line: {b!r}" for b in bad]
    errors += prefetch_errors(events, check=check, backend=backend)
    if proc.returncode != 0:
        errors.append(f"exit {proc.returncode}; stderr tail: {proc.stderr.decode()[-400:]}")
    return events, errors


@dataclass
class Ctx:
    python: str
    env: dict[str, str]
    run_dir: Path
    args: argparse.Namespace


def _first_event(child: Child, timeout: float) -> tuple[dict | None, list[str]]:
    """The first stdout JSON event within ``timeout``; non-JSON lines are errors."""
    deadline = time.monotonic() + timeout
    errors: list[str] = []
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            return None, errors + [f"no event within {timeout:.0f}s"]
        line = child.next_line(remaining)
        if line is None:
            if child.proc.poll() is not None:
                return None, errors + [f"exited {child.proc.returncode} before any event"]
            continue
        events, bad = parse_json_lines(line)
        if bad:
            errors.append(f"non-JSON stdout line: {line!r}")
            continue
        if events:
            return events[0], errors


def _busy_port(ctx: Ctx, backend: str, model: str | None, port: int, rep: Report) -> None:
    """A second supervised serve on a held port fails fast with EADDRINUSE."""
    env = dict(ctx.env, HF_HUB_OFFLINE="1")  # belt and braces: never download here
    log = ctx.run_dir / f"{backend}-busy.stderr"
    child = Child(_serve_argv(ctx.python, backend, model, port), env=env, cwd=ctx.run_dir, log=log)
    t0 = time.monotonic()
    try:
        ev, errors = _first_event(child, ctx.args.busy_bound)
        code = child.wait(ctx.args.busy_bound)
        elapsed = time.monotonic() - t0
        if ev is not None:
            errors += event_errors("serve", ev, emitter="tts")
            if ev.get("event") != "error" or ev.get("code") != "EADDRINUSE":
                errors.append(f"expected error{{code: EADDRINUSE}}, got {ev}")
        if code is None:
            errors.append(f"still running {ctx.args.busy_bound:.0f}s after the busy port")
        elif code == 0:
            errors.append("exit 0 on a busy port (expected non-zero)")
        if _STARTING_LOG in child.stderr_text():
            errors.append("backend construction/load started before the port check")
        ready = [
            e for e in parse_json_lines("\n".join(child.lines))[0] if e.get("event") == "ready"
        ]
        if ready:
            errors.append(f"busy-port child reported ready: {ready[0]}")
        if errors:
            rep.add("busy-port", "FAIL", "; ".join(errors))
        else:
            rep.add("busy-port", "PASS", f"EADDRINUSE, exit {code}, {elapsed:.2f}s, no model load")
    finally:
        child.kill()


async def _synth(
    port: int, ready: dict, text: str, voice: str | None, timeout: float, ttfb_bound: float | None
) -> str:
    """Synthesize once over loopback TCP; returns the metrics line or raises AssertionError."""
    client = TTSClient(host=HOST, port=port)
    hello = await client.connect()
    try:
        rate = hello["audio"]["rate"]
        assert rate == ready["rate"], f"hello.audio.rate {rate} != ready.rate {ready['rate']}"
        assert hello["audio"].get("format") in (None, "pcm16"), f"format {hello['audio']}"
        rec = await collect_response(client, text, voice=voice, timeout=timeout)
    finally:
        await client.close()
    assert rec["delta_ts"] and rec["done"] is not None, "no audio deltas / no done"
    seqs = rec["seqs"]
    assert seqs == list(range(len(seqs))), f"seq not gapless from 0: {seqs[:10]}..."
    pcm = rec["pcm"]
    assert pcm and len(pcm) % 2 == 0, f"pcm16 byte length {len(pcm)} is not a whole sample count"
    samples = array("h")
    samples.frombytes(pcm)
    if sys.byteorder != "little":
        samples.byteswap()
    peak = max(abs(s) for s in samples)
    assert peak > 0, "all-zero audio"
    want_ms = len(samples) * 1000 / rate
    got_ms = rec["done"].get("duration_ms")
    assert isinstance(got_ms, int) and abs(got_ms - want_ms) <= 2, (
        f"done.duration_ms {got_ms} != {want_ms:.1f} from {len(samples)} samples @ {rate}"
    )
    m = cadence_metrics(rec, rate)
    if ttfb_bound is not None and m["ttfb"] > ttfb_bound:
        raise AssertionError(f"TTFB {m['ttfb']:.3f}s exceeds --ttfb-bound {ttfb_bound}s")
    return f"rate={rate} samples={len(samples)} peak={peak} " + format_metrics(m)


def _eof_during_startup(ctx: Ctx, backend: str, model: str | None, rep: Report) -> None:
    port = _free_port()
    log = ctx.run_dir / f"{backend}-eof-startup.stderr"
    child = Child(
        _serve_argv(ctx.python, backend, model, port), env=ctx.env, cwd=ctx.run_dir, log=log
    )
    try:
        child.close_stdin()
        code = child.wait(ctx.args.stop_bound)
        time.sleep(0.2)
        events, bad = parse_json_lines("\n".join(child.lines))
        errors = [f"non-JSON stdout line: {b!r}" for b in bad]
        errors += [e for ev in events for e in event_errors("serve", ev, emitter="tts")]
        reached = "ready" if any(e.get("event") == "ready" for e in events) else "loading"
        if code is None:
            errors.append(f"still running {ctx.args.stop_bound:.0f}s after stdin EOF")
        elif code != 0:
            errors.append(f"exit {code} (expected 0)")
        if child.group_alive():
            errors.append(f"process group {child.pgid} still has members")
        if errors:
            rep.add("eof-during-startup", "FAIL", "; ".join(errors))
        else:
            rep.add("eof-during-startup", "PASS", f"exit 0 (EOF seen while {reached})")
    finally:
        child.kill()


def smoke_backend(ctx: Ctx, backend: str) -> Report:
    rep = Report(backend)
    print(f"== {backend} ==", flush=True)
    model = ctx.args.model or BACKENDS[backend].default_model()
    text = ctx.args.text or _TEXT_OVERRIDES.get(backend, _DEFAULT_TEXT)

    # 1. prefetch (--download) then prefetch --check.
    if ctx.args.download:
        events, errors = _run_prefetch(ctx, backend, ctx.args.model, check=False, timeout=7200)
        rep.add(
            "prefetch", "FAIL" if errors else "PASS", "; ".join(errors) or f"{len(events)} events"
        )
    events, errors = _run_prefetch(ctx, backend, ctx.args.model, check=True, timeout=120)
    cached = False
    if errors:
        rep.add("prefetch-check", "FAIL", "; ".join(errors))
    else:
        summary = events[-1]
        cached = summary["cached"]
        missing = [
            e["repo"] for e in events if e["event"] == "check" and e["required"] and not e["cached"]
        ]
        detail = f"cached={cached} size_bytes={summary['size_bytes']}"
        if missing:
            detail += f" missing={missing}"
        rep.add("prefetch-check", "PASS", detail)

    port = _free_port()
    if not cached:
        why = "needs weights (rerun with --download)" if not errors else "prefetch --check failed"
        for phase in ("ready", "synth", "eof-stop", "eof-during-startup"):
            rep.add(phase, "SKIP", why)
        # The port check never loads a model: hold the port with a plain listener.
        with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as holder:
            holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            holder.bind((HOST, port))
            holder.listen()
            _busy_port(ctx, backend, ctx.args.model, port, rep)
        return rep

    # 2. supervised serve -> ready.
    log = ctx.run_dir / f"{backend}.stderr"
    child = Child(
        _serve_argv(ctx.python, backend, ctx.args.model, port),
        env=ctx.env,
        cwd=ctx.run_dir,
        log=log,
    )
    try:
        t0 = time.monotonic()
        ev, errors = _first_event(
            child, ctx.args.ready_timeout or (30 if backend == "tone" else 600)
        )
        if (
            ev is not None
            and ev.get("event") == "error"
            and ev.get("code") == "ModuleNotFoundError"
        ):
            why = f"extra not installed (uv sync --extra {backend}, or --python <app env>): {ev['message']}"
            for phase in ("ready", "synth", "eof-stop", "eof-during-startup"):
                rep.add(phase, "SKIP", why)
            child.kill()
            with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as holder:
                holder.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                holder.bind((HOST, port))
                holder.listen()
                _busy_port(ctx, backend, ctx.args.model, port, rep)
            return rep
        if ev is not None:
            errors += ready_errors(
                ev, backend=backend, model=model, host=HOST, port=port, pid=child.proc.pid
            )
        if errors:
            rep.add("ready", "FAIL", "; ".join(errors) + f" (stderr: {log})")
            return rep
        rep.add(
            "ready",
            "PASS",
            f"port={port} pid={ev['pid']} rate={ev['rate']} in {time.monotonic() - t0:.2f}s",
        )

        # 3. synthesize over loopback TCP.
        try:
            line = asyncio.run(
                _synth(port, ev, text, ctx.args.voice, ctx.args.synth_timeout, ctx.args.ttfb_bound)
            )
            rep.add("synth", "PASS", line)
        except (AssertionError, SystemExit, OSError, TimeoutError) as exc:
            rep.add("synth", "FAIL", f"{type(exc).__name__}: {exc}")

        # 4. a second server on the live port.
        _busy_port(ctx, backend, ctx.args.model, port, rep)

        # 5. stdin EOF alone stops it.
        t1 = time.monotonic()
        child.close_stdin()
        code = child.wait(ctx.args.stop_bound)
        elapsed = time.monotonic() - t1
        time.sleep(0.2)  # let the pump thread drain the last lines
        events, bad = parse_json_lines("\n".join(child.lines))
        errors = [f"non-JSON stdout line: {b!r}" for b in bad]
        errors += [e for e2 in events for e in event_errors("serve", e2, emitter="tts")]
        if [e["event"] for e in events] != ["ready"]:
            errors.append(f"stdout events {[e.get('event') for e in events]} (expected only ready)")
        if code is None:
            errors.append(f"still running {ctx.args.stop_bound:.0f}s after stdin EOF")
        elif code != 0:
            errors.append(f"exit {code} after stdin EOF (expected 0)")
        if code is not None:
            try:
                os.kill(child.proc.pid, 0)
                errors.append(f"pid {child.proc.pid} still exists after exit")
            except ProcessLookupError:
                pass
            if child.group_alive():
                errors.append(f"process group {child.pgid} still has members (orphan)")
            if _port_accepts(port):
                errors.append(f"port {port} still accepts connections")
        if errors:
            rep.add("eof-stop", "FAIL", "; ".join(errors) + f" (stderr: {log})")
        else:
            rep.add("eof-stop", "PASS", f"exit 0 in {elapsed:.2f}s, no orphan, port released")
    finally:
        child.kill()

    # 6. stdin EOF during startup.
    _eof_during_startup(ctx, backend, ctx.args.model, rep)
    return rep


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    ap.add_argument("--backend", choices=tuple(BACKENDS), default="tone")
    ap.add_argument(
        "--all", action="store_true", help="every backend in tts_server.backends.BACKENDS"
    )
    ap.add_argument("--model", help="as the app's --model (default: the backend's default)")
    ap.add_argument(
        "--download", action="store_true", help="run a real `prefetch --json` first (can be GBs)"
    )
    ap.add_argument(
        "--python", default=sys.executable, help="interpreter of the environment under test"
    )
    ap.add_argument("--text")
    ap.add_argument("--voice")
    ap.add_argument(
        "--ready-timeout",
        type=float,
        help="default 30s for tone, 600s otherwise (the app's readyTimeout)",
    )
    ap.add_argument("--synth-timeout", type=float, default=300.0)
    ap.add_argument(
        "--stop-bound", type=float, default=10.0, help="stdin EOF -> exit (the app's stopGrace)"
    )
    ap.add_argument("--busy-bound", type=float, default=30.0, help="busy port -> error + exit")
    ap.add_argument("--ttfb-bound", type=float, help="optional TTFB assertion (seconds)")
    ap.add_argument("--keep", action="store_true", help="keep the temp dir (stderr logs)")
    args = ap.parse_args()
    if args.all and args.model:
        ap.error("--model applies to one backend; drop it with --all")
    load_contract()  # fail early on a missing/broken contract file

    run_dir = Path(tempfile.mkdtemp(prefix="tts-supervised-smoke."))
    ctx = Ctx(python=args.python, env=app_child_env(), run_dir=run_dir, args=args)
    backends = list(BACKENDS) if args.all else [args.backend]
    reports: list[Report] = []
    try:
        for backend in backends:
            reports.append(smoke_backend(ctx, backend))
    finally:
        if args.keep:
            print(f"kept logs in {run_dir}")
        else:
            shutil.rmtree(run_dir, ignore_errors=True)

    print("\n== summary ==")
    for rep in reports:
        counts = {s: sum(1 for _p, st, _d in rep.rows if st == s) for s in ("PASS", "SKIP", "FAIL")}
        print(f"  {rep.backend:<12} " + " ".join(f"{k}={v}" for k, v in counts.items()))
    failed = [r.backend for r in reports if r.failed]
    print("FAILED: " + ", ".join(failed) if failed else "OK (no failures)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
