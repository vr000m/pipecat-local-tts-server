"""The supervised/prefetch JSON-lines contract — LEAN drift guard.

Two independent emitters speak one contract to the macOS app:
``tts_server`` (``serve --supervised``, ``prefetch --json``) and the STT helper
(``macos/Helper/pipecat_app_helper.py``). ``docs/supervised-contract.json``
fixes every event's fields and types, the error ``code`` values, and the stt
wire rate. These tests run BOTH emitters on stub inputs and check every line
against it, so a field added, dropped or retyped on one side fails here:

  * every line either emitter writes conforms to its event's contract entry
    (exact required keys, optional keys only from the contract, JSON types);
  * the events both emitters write have identical key sets;
  * every ``"event": "<name>"`` literal in either emitter's source is a
    contract event, and every contract event is exercised by some emitter;
  * error codes: contract == ``supervise.CODE_*`` == Swift
    ``SupervisedErrorCode``; the helper's codes are a subset, and its
    ``classify`` agrees with ``supervise.classify_startup_error`` on every
    exception class both handle (cause chains included);
  * the Swift decoder (``ServerCLIEvent.CodingKeys``) reads only contract fields;
  * wire rate: contract == helper ``WIRE_RATE`` == Swift ``STTWire.rate``;
  * catalog: helper ``DEFAULT_MODELS`` == Service.swift engine defaults, and
    ``MODEL_REVISIONS`` pins exactly the STT repos the app offers;
  * each STT engine's requirements are hash-pinned in ``macos/constraints``.
"""

from __future__ import annotations

import errno
import importlib.util
import json
import re
import select
import shutil
import socket
import subprocess
import sys
import types
from pathlib import Path

import pytest

from tts_server import supervise
from tts_server.backend import ToneBackend

from ._helpers import running_server
from ._macos_catalog import macos_catalog
from .smoke._supervised_contract import event_errors
from .test_prefetch_cli import PH, _run, fake_hub  # noqa: F401 - fake_hub is a fixture

REPO = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((REPO / "docs" / "supervised-contract.json").read_text())
HELPER_PATH = REPO / "macos" / "Helper" / "pipecat_app_helper.py"
CORE = REPO / "macos" / "Sources" / "PipecatToolbarCore"
SCOPES = ("serve", "prefetch")


@pytest.fixture(scope="module")
def helper():
    spec = importlib.util.spec_from_file_location("pipecat_app_helper_contract", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def conform(scope: str, event: dict) -> None:
    """Assert ``event`` matches its contract entry exactly (shared with the app-path smoke)."""
    errors = event_errors(scope, event, CONTRACT)
    assert not errors, errors


def required_keys(scope: str, event: dict) -> frozenset[str]:
    return frozenset(set(event) - set(CONTRACT[scope][event["event"]].get("optional", {})))


# --- emitters on stub inputs ---------------------------------------------------


def _lines(out: str) -> list[dict]:
    return [json.loads(line) for line in out.splitlines() if line.strip()]


class _File:
    def __init__(self, path: str, size: int) -> None:
        self.path, self.size, self.lfs = path, size, None


def _fake_hub(monkeypatch, tmp_path, *, fail: bool = False):
    """A ``huggingface_hub`` stand-in for the helper's prefetch."""
    hub = types.ModuleType("huggingface_hub")
    constants = types.ModuleType("huggingface_hub.constants")
    constants.HF_HUB_CACHE = str(tmp_path / "hub")
    hub.constants = constants

    class HubError(Exception):
        pass

    HubError.__module__ = "huggingface_hub.errors"

    class HfApi:
        def list_repo_tree(self, repo, revision=None, recursive=True):
            if fail:
                raise HubError("503 Service Unavailable")
            return [
                _File("config.json", 10),
                _File("weights.safetensors", 990),
                _File("README.md", 5),
            ]

    def snapshot_download(repo, revision=None, allow_patterns=None, **_kw):
        folder = Path(constants.HF_HUB_CACHE) / ("models--" + repo.replace("/", "--"))
        snap = folder / "snapshots" / (revision or "0" * 40)
        snap.mkdir(parents=True, exist_ok=True)
        for name in allow_patterns or []:
            (snap / name).write_bytes(b"x" * 10)
        return str(snap)

    hub.HfApi, hub.snapshot_download = HfApi, snapshot_download
    monkeypatch.setitem(sys.modules, "huggingface_hub", hub)
    monkeypatch.setitem(sys.modules, "huggingface_hub.constants", constants)


def helper_prefetch_events(helper, monkeypatch, tmp_path, capsys) -> list[dict]:
    repo = helper.DEFAULT_MODELS["whisper"]
    state = str(tmp_path / "env")
    events: list[dict] = []
    _fake_hub(monkeypatch, tmp_path)
    for argv in (["--check"], [], ["--check"]):  # uncached check, fetch, cached check
        assert helper.main(["prefetch", "--repo", repo, "--state-dir", state, "--json", *argv]) == 0
        events += _lines(capsys.readouterr().out)
    _fake_hub(monkeypatch, tmp_path, fail=True)
    assert helper.main(["prefetch", "--repo", "org/other", "--json"]) == 1
    events += _lines(capsys.readouterr().out)
    return events


class _Tqdm:
    """The slice of ``tqdm.tqdm`` that ``prefetch._progress_class`` subclasses (a
    lean env has no tqdm; every model extra brings the real one)."""

    def __init__(self, *_args, total=None, unit="it", **_kwargs) -> None:
        self.n, self.total, self.unit = 0, total, unit

    def update(self, n=1):
        self.n += n


def tts_prefetch_events(monkeypatch, capsys, tmp_path) -> list[dict]:
    events: list[dict] = []
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    if importlib.util.find_spec("tqdm") is None:
        monkeypatch.setitem(sys.modules, "tqdm", types.SimpleNamespace(tqdm=_Tqdm))

    def fake_ensure(snapshot, sha, bits):
        qdir = PH._quantized_dir(sha, bits)
        qdir.mkdir(parents=True, exist_ok=True)
        return str(qdir)

    monkeypatch.setattr(PH, "_ensure_quantized", fake_ensure)
    for argv in (
        ["--backend", "kokoro", "--check", "--json"],
        ["--backend", "kokoro", "--json"],
        ["--backend", "kokoro", "--check", "--json"],
        ["--backend", "phonon", "--model", "phonon-q8", "--json"],
        ["--backend", "phonon", "--model", "phonon-q8", "--check", "--json"],
    ):
        code, out, _ = _run(monkeypatch, capsys, *argv)
        assert code == 0, argv
        events += out
    # An optional snapshot that fails is a warning; a required one an error.
    from tts_server import prefetch as PF

    real = PF._snapshot_download

    def flaky(spec, *, local_files_only, tqdm_class=None):
        if spec.kind == "voice":
            raise OSError("voice repo unreachable")
        return real(spec, local_files_only=local_files_only, tqdm_class=tqdm_class)

    monkeypatch.setattr(PF, "_snapshot_download", flaky)
    events += _run(monkeypatch, capsys, "--backend", "pocket_tts", "--json")[1]

    def broken(spec, *, local_files_only, tqdm_class=None):
        raise ConnectionError("offline")

    monkeypatch.setattr(PF, "_snapshot_download", broken)
    code, out, _ = _run(monkeypatch, capsys, "--backend", "kokoro", "--json")
    assert code == 1
    return events + out


def _first_line(cmd: list[str]) -> dict:
    """The first stdout line of a supervised process (stdin held open: EOF stops it)."""
    proc = subprocess.Popen(
        cmd, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE
    )
    try:
        ready, _, _ = select.select([proc.stdout], [], [], 60)
        assert ready, "no stdout line within 60 s"
        return json.loads(proc.stdout.readline())
    finally:
        proc.kill()
        proc.communicate()


def serve_events(helper) -> tuple[list[dict], list[dict]]:
    """(tts, helper) ``serve`` lines: a ready line each, and the busy-port error."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        port = str(busy.getsockname()[1])
        tts_error = _first_line(
            [sys.executable, "-m", "tts_server", "serve", "--backend", "tone"]
            + ["--host", "127.0.0.1", "--port", port, "--supervised"]
        )
        helper_error = _first_line(
            [sys.executable, str(HELPER_PATH), "serve-stt", "--engine", "whisper"]
            + ["--host", "127.0.0.1", "--port", port]
        )
    assert tts_error["code"] == helper_error["code"] == "EADDRINUSE"
    # A lean env has no stt_server: past the port probe, the helper's import fails.
    helper_missing = _first_line(
        [sys.executable, str(HELPER_PATH), "serve-stt", "--engine", "kyutai", "--port", "0"]
    )
    assert helper_missing["code"] == "ModuleNotFoundError"

    class _Server:  # stt_server.server.TranscriptionServer's public surface
        def listening_port(self) -> int:
            return 9565

    helper_ready = helper.ready_event(
        _Server(), engine="whisper", model="m", host="127.0.0.1", port=0, rate=helper.WIRE_RATE
    )
    assert helper_ready["port"] == 9565
    return [tts_error], [helper_error, helper_missing, helper_ready]


async def tts_ready_event(capsys) -> dict:
    async with running_server(ToneBackend()) as srv:
        with supervise.json_channel():
            await supervise.emit_ready(srv)
    return _lines(capsys.readouterr().out)[0]


@pytest.fixture
async def emitted(helper, monkeypatch, tmp_path, capsys, fake_hub):  # noqa: F811
    tts_ready = await tts_ready_event(capsys)
    tts_serve, helper_serve = serve_events(helper)
    return {
        "tts": {
            "serve": [tts_ready, *tts_serve],
            "prefetch": tts_prefetch_events(monkeypatch, capsys, tmp_path),
        },
        "helper": {
            "serve": helper_serve,
            "prefetch": helper_prefetch_events(helper, monkeypatch, tmp_path / "h", capsys),
        },
    }


# --- event shapes --------------------------------------------------------------


def test_every_emitted_line_conforms_to_the_contract(emitted):
    for side, scopes in emitted.items():
        for scope, events in scopes.items():
            assert events, f"{side} {scope}: nothing emitted"
            for event in events:
                conform(scope, event)


def test_both_emitters_write_identical_shapes(emitted):
    for scope in SCOPES:
        shapes = {
            side: {
                e["event"]: {
                    required_keys(scope, x)
                    for x in emitted[side][scope]
                    if x["event"] == e["event"]
                }
                for e in emitted[side][scope]
            }
            for side in emitted
        }
        for name in shapes["tts"].keys() & shapes["helper"].keys():
            assert shapes["tts"][name] == shapes["helper"][name], f"{scope}.{name}"
            assert len(shapes["tts"][name]) == 1, f"{scope}.{name} has several shapes"
    # The helper exercises its whole event space; tts every other contract event.
    assert {e["event"] for e in emitted["helper"]["prefetch"]} == {
        "start", "progress", "done", "complete", "check", "summary", "error",
    }  # fmt: skip
    assert {e["event"] for e in emitted["helper"]["serve"]} == {"ready", "error"}
    for scope in SCOPES:
        seen = {e["event"] for side in emitted for e in emitted[side][scope]}
        assert seen == set(CONTRACT[scope]), f"{scope}: contract events never emitted"


def test_helper_check_dialect_is_the_tts_dialect(emitted):
    """``prefetch --check`` is check rows then a summary on both sides, so the
    Swift ``cacheStatus`` reads snapshot paths from ``check`` rows only."""
    for side in emitted:
        kinds = [e["event"] for e in emitted[side]["prefetch"]]
        for i, kind in enumerate(kinds):
            if kind == "summary":
                assert i > 0 and kinds[i - 1] == "check", f"{side}: summary without check rows"
    cached = [e for e in emitted["helper"]["prefetch"] if e["event"] == "check" and e["cached"]]
    assert cached and all(e["path"] for e in cached)
    swift = (CORE / "EnvironmentManager.swift").read_text()
    body = swift.split("static func cacheStatus(checkOutput", 1)[1].split("\n    }\n", 1)[0]
    assert "summary.path" not in body


_EVENT_LITERAL = re.compile(r'"event": "(\w+)"')


def test_every_event_literal_in_the_emitters_is_a_contract_event():
    contract_events = {name for scope in SCOPES for name in CONTRACT[scope]}
    sources = [HELPER_PATH, *sorted((REPO / "tts_server").rglob("*.py"))]
    found = {name for path in sources for name in _EVENT_LITERAL.findall(path.read_text())}
    assert found, "the pattern matches the emitters' source"
    assert found <= contract_events, sorted(found - contract_events)


# --- error codes ------------------------------------------------------------------


def _swift_error_codes() -> set[str]:
    text = (CORE / "PrefetchEvent.swift").read_text()
    body = text.split("enum SupervisedErrorCode", 1)[1].split("}", 1)[0]
    return set(re.findall(r'case \w+ = "(\w+)"', body))


def test_error_codes_contract_equals_supervise_and_swift(helper):
    contract = set(CONTRACT["error_codes"])
    assert contract == {v for k, v in vars(supervise).items() if k.startswith("CODE_")}
    assert contract == _swift_error_codes()
    helper_codes = {v for k, v in vars(helper).items() if k.startswith("CODE_")}
    assert helper_codes and helper_codes <= contract


def test_download_module_prefixes_match(helper):
    contract = set(CONTRACT["download_error_module_prefixes"])
    assert set(supervise._DOWNLOAD_MODULE_PREFIXES) == contract
    assert set(helper._DOWNLOAD_MODULE_PREFIXES) == contract


def _hub_error() -> Exception:
    cls = type("HfHubHTTPError", (Exception,), {"__module__": "huggingface_hub.errors"})
    return cls("503")


def _chain(outer: Exception, inner: BaseException) -> Exception:
    outer.__cause__ = inner
    return outer


# Every exception class both classifiers handle, bare and inside a cause chain,
# plus the priority cases (an earlier rule wins over a later one in the chain).
_STATE_SPACE = [
    ModuleNotFoundError("No module named 'x'", name="x"),
    OSError(errno.EADDRINUSE, "Address already in use"),
    OSError(errno.EACCES, "Permission denied"),
    _hub_error(),
    type("ReadTimeout", (Exception,), {"__module__": "httpx._exceptions"})("t"),
    type("ConnErr", (Exception,), {"__module__": "requests.exceptions"})("c"),
    type("MaxRetry", (Exception,), {"__module__": "urllib3.exceptions"})("m"),
    type("XetErr", (Exception,), {"__module__": "hf_xet"})("x"),
    ConnectionError("refused"),
    TimeoutError("slow"),
    RuntimeError("boom"),
    ValueError(""),
    _chain(RuntimeError("wrapped"), OSError(errno.EADDRINUSE, "busy")),
    _chain(RuntimeError("wrapped"), _hub_error()),
    _chain(_hub_error(), ModuleNotFoundError("hub dep", name="y")),
    _chain(OSError(errno.EACCES, "denied"), OSError(errno.EADDRINUSE, "busy")),
    _chain(ConnectionError("x"), OSError(errno.EACCES, "denied")),
]


@pytest.mark.parametrize("exc", _STATE_SPACE, ids=lambda e: f"{type(e).__name__}:{e}")
def test_helper_classify_agrees_with_supervise(helper, exc):
    code = helper.classify(exc)
    assert code in CONTRACT["error_codes"]
    assert code == supervise.classify_startup_error(exc)[0]


# --- Swift consumer --------------------------------------------------------------


def _swift_coding_keys() -> set[str]:
    text = (CORE / "PrefetchEvent.swift").read_text()
    body = text.split("enum CodingKeys: String, CodingKey {", 1)[1].split("}", 1)[0]
    keys = set()
    for line in body.splitlines():
        line = line.strip()
        if not line.startswith("case "):
            continue
        if m := re.fullmatch(r'case \w+ = "(\w+)"', line):
            keys.add(m.group(1))
        else:
            keys.update(name.strip() for name in line[len("case ") :].split(","))
    return keys


def test_swift_decoder_reads_only_contract_fields():
    fields = {
        key
        for scope in SCOPES
        for entry in CONTRACT[scope].values()
        for key in (*entry["fields"], *entry.get("optional", {}))
    }
    swift = _swift_coding_keys()
    assert {"event", "size_bytes", "quantized_path", "rate"} <= swift, "the parser sees the keys"
    assert swift <= fields, sorted(swift - fields)


def test_stt_wire_rate_is_one_constant(helper):
    swift = re.search(
        r"enum STTWire \{.*?public static let rate = (\d+)",
        (CORE / "PCMStreamConverter.swift").read_text(),
        re.DOTALL,
    )
    assert swift, "the parser sees STTWire.rate"
    assert CONTRACT["stt_wire_rate"] == helper.WIRE_RATE == int(swift.group(1))
    # No other literal rate in the helper: everything derives from WIRE_RATE.
    assert "16000" not in HELPER_PATH.read_text().split("WIRE_RATE = 16000", 1)[1]


def test_helper_reads_the_bound_port_through_public_api():
    """``stt_server``'s private ``server._server`` is never touched: the ready
    line uses ``TranscriptionServer.listening_port()`` (public in 0.3.3)."""
    source = HELPER_PATH.read_text()
    assert "._server" not in source and "listening_port()" in source


# --- catalog ----------------------------------------------------------------------


def _stt_entries():
    return [e for e in macos_catalog().values() if e.engine]


def test_helper_default_models_match_service_swift(helper):
    swift = {e.engine: e.model_repo for e in _stt_entries() if not e.is_variant}
    assert swift and helper.DEFAULT_MODELS == swift


def test_model_revisions_pin_every_stt_repo_the_app_offers(helper):
    repos = {e.model_repo for e in _stt_entries()}
    assert len(repos) == len(_stt_entries()), "each STT service has its own repo"
    assert set(helper.MODEL_REVISIONS) == repos
    for repo, sha in helper.MODEL_REVISIONS.items():
        assert re.fullmatch(r"[0-9a-f]{40}", sha), f"{repo}: {sha!r} is not a commit sha"


def test_prefetch_and_serve_use_the_same_pin(helper, monkeypatch, tmp_path, capsys):
    """The commit ``prefetch`` downloads is the one ``serve-stt`` loads, and a
    record of another commit is not reported cached."""
    _fake_hub(monkeypatch, tmp_path)
    repo = helper.DEFAULT_MODELS["kyutai"]
    pin = helper.MODEL_REVISIONS[repo]
    state = tmp_path / "env"
    assert helper.main(["prefetch", "--repo", repo, "--state-dir", str(state), "--json"]) == 0
    events = _lines(capsys.readouterr().out)
    assert events[0]["revision"] == pin
    assert Path(events[-2]["path"]).name == pin  # done: the pinned snapshot
    # serve-stt: kyutai fetches every file at the pin...
    assert helper._make_backend("kyutai", repo).revision == pin

    # ...and whisper is handed the pinned snapshot's folder, reporting the repo id.
    class FakeWhisper:
        def __init__(self, *, model):
            self._model = self.model = model

    whisper = types.ModuleType("stt_server.backends.mlx_whisper")
    whisper.MLXWhisperBackend = FakeWhisper
    monkeypatch.setitem(sys.modules, "stt_server", types.ModuleType("stt_server"))
    monkeypatch.setitem(sys.modules, "stt_server.backends", types.ModuleType("stt_server.backends"))
    monkeypatch.setitem(sys.modules, "stt_server.backends.mlx_whisper", whisper)
    wrepo = helper.DEFAULT_MODELS["whisper"]
    assert helper.main(["prefetch", "--repo", wrepo, "--json"]) == 0
    wdone = [e for e in _lines(capsys.readouterr().out) if e["event"] == "done"][0]
    backend = helper._make_backend("whisper", wrepo)
    assert (
        backend._model == wdone["path"]
        and Path(wdone["path"]).name == helper.MODEL_REVISIONS[wrepo]
    )
    assert backend.model == wrepo

    check = ["prefetch", "--repo", repo, "--state-dir", str(state), "--check"]
    assert helper.main(check) == 0
    assert _lines(capsys.readouterr().out)[-1]["cached"] is True
    record = next(state.glob(".prefetch-*.json"))
    data = json.loads(record.read_text())
    other = Path(data["path"]).with_name("f" * 40)  # the same files at another commit
    shutil.copytree(data["path"], other)
    record.write_text(json.dumps({**data, "path": str(other)}))
    assert helper.main(["prefetch", "--repo", repo, "--state-dir", str(state), "--check"]) == 0
    assert _lines(capsys.readouterr().out)[-1]["cached"] is False


# --- STT constraints --------------------------------------------------------------


def _pins(text: str) -> dict[str, str]:
    return {
        name.lower().replace("_", "-"): version
        for name, version in re.findall(r"^([A-Za-z0-9_.\-]+)==(\S+)", text, re.MULTILINE)
    }


def test_every_stt_engine_has_hash_pinned_constraints():
    engines = {e.engine: e.requirements for e in _stt_entries() if not e.is_variant}
    folder = REPO / "macos" / "constraints"
    assert {p.name for p in folder.glob("stt-*.txt")} == {f"stt-{e}.txt" for e in engines}
    swift_python = re.search(
        r'pythonVersion = "([\d.]+)"', (CORE / "EnvironmentManager.swift").read_text()
    ).group(1)
    for engine, requirements in engines.items():
        text = (folder / f"stt-{engine}.txt").read_text()
        assert f"# python-version: {swift_python}\n" in text, engine
        # Regenerated from exactly these requirements...
        assert re.findall(r"^# requirement: (.+)$", text, re.MULTILINE) == list(requirements)
        pins = _pins(text)
        for requirement in requirements:
            name, version = re.fullmatch(
                r"([A-Za-z0-9_.\-]+)(?:\[[^\]]+\])?==(\S+)", requirement
            ).groups()
            assert pins.get(name.lower().replace("_", "-")) == version, f"{engine}: {requirement}"
        # ...and every pin carries a hash (uv pip install --require-hashes).
        blocks = re.split(r"^(?=[A-Za-z0-9])", text, flags=re.MULTILINE)[1:]
        assert len(blocks) == len(pins) > len(requirements)
        for block in blocks:
            pin, first, *_ = block.splitlines()
            # A hash only counts as the pin's own when the line continues into it.
            assert pin.endswith(" \\") and first.startswith("    --hash=sha256:"), (
                f"{engine}: {pin}"
            )
