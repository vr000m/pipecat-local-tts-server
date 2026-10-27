"""The supervised/prefetch JSON-lines contract: LEAN drift guard.

Two independent emitters speak one contract to the macOS app: ``tts_server``
(``serve --supervised``, ``prefetch --json``) and the upstream STT CLI
(``python -m stt_server``, pipecat-local-stt-server 0.5.0). ``docs/supervised-contract.json``
fixes every event's fields and types, the error ``code`` values per emitter, and the
stt wire rate. The lean job has no STT server installed, so:

  * the TTS emitter runs on stub inputs, and every line it writes conforms to its
    event's contract entry (exact required keys, optional keys only from the
    contract, JSON types); every contract event is exercised;
  * the STT emitter's lines are a recorded 0.5.0 fixture
    (``tests/fixtures/stt_supervised_lines.jsonl``: a real ``ready`` and ``error``
    line) and ``tests/fixtures/stt_prefetch_check_lines.jsonl`` (a real kyutai
    ``prefetch --check --json``: a ``check`` row then the ``summary``, recorded offline on
    an empty cache), checked against the same contract and against the key sets the TTS
    emitter writes for the same events; the lean job never imports ``stt_server``;
  * every ``"event": "<name>"`` literal in ``tts_server`` is a contract event;
  * error codes, per emitter: the ``tts`` list == ``supervise.CODE_*``; the ``stt``
    list == upstream ``stt_server.supervise.CODE_*``, read from a verbatim recorded
    excerpt of the release the app installs (``tests/_stt_upstream.py``) and from the
    live package when it is importable; Swift ``SupervisedErrorCode`` == the union;
  * the Swift decoder (``ServerCLIEvent.CodingKeys``) reads only contract fields;
  * wire rate: contract == fixture ``ready.rate`` == Swift ``STTWire.rate``;
  * the contract's ``version`` is pinned to a digest of its shape (``CONTRACT_SHAPES``), so
    a change to its keys, fields or types cannot ship without a version bump;
  * each STT engine's requirements are hash-pinned in ``macos/constraints`` and name
    ``pipecat-local-stt-server`` at exactly the Swift ``sttServerRequirement`` version.
"""

from __future__ import annotations

import errno
import hashlib
import importlib.util
import json
import os
import re
import select
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
from ._stt_upstream import FIXTURE as STT_EXCERPT
from ._stt_upstream import excerpt_drift, upstream_stt
from .smoke._supervised_contract import event_errors
from .test_prefetch_cli import PH, _run, fake_hub  # noqa: F401 - fake_hub is a fixture

REPO = Path(__file__).resolve().parents[1]
CONTRACT = json.loads((REPO / "docs" / "supervised-contract.json").read_text())
CORE = REPO / "macos" / "Sources" / "PipecatToolbarCore"
SERVICE_SWIFT = CORE / "Service.swift"
STT_FIXTURE = REPO / "tests" / "fixtures" / "stt_supervised_lines.jsonl"
STT_PREFETCH_FIXTURE = REPO / "tests" / "fixtures" / "stt_prefetch_check_lines.jsonl"
SCOPES = ("serve", "prefetch")
TTS_CODES = set(CONTRACT["error_codes"]["tts"])
STT_CODES = set(CONTRACT["error_codes"]["stt"])


def stt_fixture_lines() -> list[dict]:
    """The recorded 0.5.0 ``stt_server`` lines (``serve --supervised``), one object per line."""
    return [json.loads(line) for line in STT_FIXTURE.read_text().splitlines() if line.strip()]


def conform(scope: str, event: dict, emitter: str) -> None:
    """Assert ``event`` matches its contract entry exactly, with ``emitter``'s error codes."""
    errors = event_errors(scope, event, CONTRACT, emitter=emitter)
    assert not errors, errors


# --- emitters on stub inputs ---------------------------------------------------


def _lines(out: str) -> list[dict]:
    return [json.loads(line) for line in out.splitlines() if line.strip()]


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


def tts_serve_events() -> list[dict]:
    """``tts_server serve --supervised`` on a busy port: the ``EADDRINUSE`` error line."""
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as busy:
        busy.bind(("127.0.0.1", 0))
        busy.listen()
        port = str(busy.getsockname()[1])
        tts_error = _first_line(
            [sys.executable, "-m", "tts_server", "serve", "--backend", "tone"]
            + ["--host", "127.0.0.1", "--port", port, "--supervised"]
        )
    assert tts_error["code"] == "EADDRINUSE"
    return [tts_error]


async def tts_ready_event(capsys) -> dict:
    async with running_server(ToneBackend()) as srv:
        with supervise.json_channel():
            await supervise.emit_ready(srv)
    return _lines(capsys.readouterr().out)[0]


@pytest.fixture
async def emitted(monkeypatch, tmp_path, capsys, fake_hub):  # noqa: F811
    tts_ready = await tts_ready_event(capsys)
    return {
        "serve": [tts_ready, *tts_serve_events()],
        "prefetch": tts_prefetch_events(monkeypatch, capsys, tmp_path),
    }


# --- event shapes --------------------------------------------------------------


def test_every_emitted_line_conforms_to_the_contract(emitted):
    for scope, events in emitted.items():
        assert events, f"tts {scope}: nothing emitted"
        for event in events:
            conform(scope, event, "tts")
    # The TTS emitter exercises every contract event.
    for scope in SCOPES:
        seen = {e["event"] for e in emitted[scope]}
        assert seen == set(CONTRACT[scope]), f"{scope}: contract events never emitted"


def test_recorded_stt_lines_conform_to_the_contract(emitted):
    """The upstream 0.5.0 ``ready`` and ``error`` lines, byte for byte as recorded."""
    lines = stt_fixture_lines()
    assert [line["event"] for line in lines] == ["ready", "error"]
    for line in lines:
        conform("serve", line, "stt")
    ready, error = lines
    # Exact required keys: no field dropped, none added beyond the contract.
    assert set(ready) == set(CONTRACT["serve"]["ready"]["fields"])
    assert set(error) == set(CONTRACT["serve"]["error"]["fields"])
    assert error["code"] in STT_CODES
    # The same key sets the TTS emitter actually wrote for the same events (one Swift decoder reads both).
    tts = {line["event"]: set(line) for line in emitted["serve"]}
    assert set(ready) == tts["ready"]
    assert set(error) == tts["error"]


def test_tts_check_dialect_is_check_rows_then_summary(emitted):
    """``prefetch --check`` is check rows then a summary, so the Swift ``cacheStatus``
    reads snapshot paths from ``check`` rows only."""
    kinds = [e["event"] for e in emitted["prefetch"]]
    for i, kind in enumerate(kinds):
        if kind == "summary":
            assert i > 0 and kinds[i - 1] == "check", "summary without check rows"
    swift = (CORE / "EnvironmentManager.swift").read_text()
    body = swift.split("static func cacheStatus(checkOutput", 1)[1].split("\n    }\n", 1)[0]
    assert "summary.path" not in body


def stt_prefetch_check_lines() -> list[dict]:
    """The recorded 0.5.0 ``stt_server prefetch --backend kyutai --check --json`` lines."""
    return [
        json.loads(line) for line in STT_PREFETCH_FIXTURE.read_text().splitlines() if line.strip()
    ]


def test_recorded_stt_prefetch_check_conforms_to_the_contract(emitted):
    """``EnvironmentManager.cacheStatus`` reads the STT emitter's ``prefetch --check --json``:
    check rows then a summary, with the same key sets the TTS emitter writes."""
    lines = stt_prefetch_check_lines()
    assert [line["event"] for line in lines] == ["check", "summary"]
    for line in lines:
        conform("prefetch", line, "stt")
    check, summary = lines
    assert set(check) == set(CONTRACT["prefetch"]["check"]["fields"])
    assert set(summary) == set(CONTRACT["prefetch"]["summary"]["fields"])
    assert summary["backend"] == "kyutai" and summary["cached"] == check["cached"]
    tts = {
        kind: [set(e) for e in emitted["prefetch"] if e["event"] == kind]
        for kind in ("check", "summary")
    }
    assert set(check) in tts["check"]
    assert set(summary) in tts["summary"]


@pytest.mark.skipif(
    not os.environ.get("PIPECAT_STT_SERVER_SITE"),
    reason="opt-in: set PIPECAT_STT_SERVER_SITE to an installed pipecat-local-stt-server release",
)
def test_recorded_stt_prefetch_check_is_verbatim_upstream_output(tmp_path):
    """Re-records the prefetch fixture from the release at ``PIPECAT_STT_SERVER_SITE``, offline
    against an empty Hugging Face cache (``--check`` never downloads), and compares it."""
    pytest.importorskip("huggingface_hub")
    site = Path(os.environ["PIPECAT_STT_SERVER_SITE"])
    cache = tmp_path / "hf"
    env = {
        **os.environ,
        "HF_HOME": str(cache),
        "HF_HUB_CACHE": str(cache / "hub"),
        "XDG_CACHE_HOME": str(tmp_path / "xdg"),
        "HF_HUB_OFFLINE": "1",
    }
    run = (
        "import runpy, sys; sys.path.insert(0, sys.argv[1]);"
        " sys.argv = ['stt_server', 'prefetch', '--backend', 'kyutai', '--check', '--json'];"
        " runpy.run_module('stt_server', run_name='__main__')"
    )
    out = subprocess.run(
        [sys.executable, "-I", "-c", run, str(site)],
        env=env,
        cwd=tmp_path,
        capture_output=True,
        text=True,
        timeout=60,
        check=True,
    ).stdout
    assert out == STT_PREFETCH_FIXTURE.read_text()


_EVENT_LITERAL = re.compile(r'"event": "(\w+)"')


def test_every_event_literal_in_the_emitter_is_a_contract_event():
    contract_events = {name for scope in SCOPES for name in CONTRACT[scope]}
    sources = sorted((REPO / "tts_server").rglob("*.py"))
    found = {name for path in sources for name in _EVENT_LITERAL.findall(path.read_text())}
    assert found, "the pattern matches the emitter's source"
    assert found <= contract_events, sorted(found - contract_events)


# --- error codes (per emitter) -------------------------------------------------


def _swift_error_codes() -> set[str]:
    text = (CORE / "PrefetchEvent.swift").read_text()
    body = text.split("enum SupervisedErrorCode", 1)[1].split("}", 1)[0]
    return set(re.findall(r'case \w+ = "(\w+)"', body))


def test_error_codes_are_listed_per_emitter():
    assert sorted(CONTRACT["error_codes"]) == ["stt", "tts"]
    for emitter, codes in CONTRACT["error_codes"].items():
        assert codes and len(codes) == len(set(codes)), emitter


def contract_shape(contract: dict) -> dict:
    """The contract's structure: every key, each event's field names and types, and the
    emitters ``error_codes`` is keyed by. The members of the code and module-prefix lists and
    the wire rate's value are data, not shape (they change without a version bump)."""
    shape = {k: v for k, v in contract.items() if k not in ("_comment", "version")}
    shape["error_codes"] = {emitter: "list[str]" for emitter in contract["error_codes"]}
    shape["download_error_module_prefixes"] = "list[str]"
    shape["stt_wire_rate"] = "int"
    return shape


def contract_shape_digest(contract: dict) -> str:
    return hashlib.sha256(json.dumps(contract_shape(contract), sort_keys=True).encode()).hexdigest()


# One entry per contract ``version``: the sha256 of its shape (``contract_shape``). A shape
# change must add a NEW version here and bump ``version`` in docs/supervised-contract.json.
CONTRACT_SHAPES = {
    2: "4e0b62b2746f8e3c5906662bcb6a462f2b6b1c852ab509a8b9f3668e3a77a181",
}


def test_contract_version_is_pinned_to_its_shape():
    assert len(set(CONTRACT_SHAPES.values())) == len(CONTRACT_SHAPES), "two versions, one shape"
    assert CONTRACT["version"] == max(CONTRACT_SHAPES) == 2
    assert contract_shape_digest(CONTRACT) == CONTRACT_SHAPES[CONTRACT["version"]], (
        "docs/supervised-contract.json changed shape: bump its `version` and pin the new "
        "shape under that version in CONTRACT_SHAPES"
    )


def test_contract_shape_ignores_data_but_not_structure():
    data_only = json.loads(json.dumps(CONTRACT))
    data_only["error_codes"]["stt"].append("SomeNewCode")
    data_only["stt_wire_rate"] = 24000
    assert contract_shape_digest(data_only) == contract_shape_digest(CONTRACT)
    new_field = json.loads(json.dumps(CONTRACT))
    new_field["serve"]["ready"]["fields"]["extra"] = ["string"]
    assert contract_shape_digest(new_field) != contract_shape_digest(CONTRACT)
    new_emitter = json.loads(json.dumps(CONTRACT))
    new_emitter["error_codes"]["other"] = []
    assert contract_shape_digest(new_emitter) != contract_shape_digest(CONTRACT)


def test_tts_codes_equal_what_supervise_can_emit():
    emittable = {v for k, v in vars(supervise).items() if k.startswith("CODE_")}
    assert TTS_CODES == emittable
    # ``ModelInvalidError`` is the STT emitter's alone: TTS never carries it.
    assert "ModelInvalidError" not in TTS_CODES


def test_stt_codes_equal_what_the_recorded_upstream_release_can_emit():
    """The ``stt`` list is upstream's ``CODE_*`` set, from the recorded excerpt of the
    release the app installs (not a hand-typed copy), so a code upstream adds or drops
    fails here once the excerpt is re-recorded for a new pin."""
    upstream = upstream_stt()
    assert upstream.version == _swift_stt_server_version(), (
        "re-record the STT excerpt for the new pin, then check it against that release's source:"
        " PIPECAT_STT_SERVER_SITE=<dir with stt_server/ and its dist-info> uv run pytest"
        " tests/test_supervised_contract.py -k verbatim"
    )
    assert STT_CODES == upstream.error_codes
    fixture_codes = {line["code"] for line in stt_fixture_lines() if line["event"] == "error"}
    assert fixture_codes and fixture_codes <= STT_CODES


def test_stt_codes_equal_the_live_upstream_package_when_installed():
    """Where ``stt_server`` is importable (not the lean job), the recorded excerpt is checked
    against it too."""
    stt_supervise = pytest.importorskip("stt_server.supervise")
    live = {v for k, v in vars(stt_supervise).items() if k.startswith("CODE_")}
    assert live == upstream_stt().error_codes == STT_CODES


@pytest.mark.skipif(
    not os.environ.get("PIPECAT_STT_SERVER_SITE"),
    reason="opt-in: set PIPECAT_STT_SERVER_SITE to an installed pipecat-local-stt-server release",
)
def test_recorded_stt_excerpt_is_verbatim_upstream_source():
    """The recorded excerpt is a verbatim copy of the release it names (no CI job has that
    source; run it locally when re-recording, see ``tests/_stt_upstream.py``)."""
    site = Path(os.environ["PIPECAT_STT_SERVER_SITE"])
    version = upstream_stt().version
    assert (site / f"pipecat_local_stt_server-{version}.dist-info").is_dir(), (
        f"{site} does not hold pipecat-local-stt-server {version}"
    )
    assert excerpt_drift(site) == []


def _fake_stt_site(
    tmp_path: Path, *, extra_code: str = "", extra_backend: str = "", extra_pin: str = ""
) -> Path:
    """A site whose ``## <path>`` files hold the excerpt's lines, plus anything extra."""
    files: dict[str, list[str]] = {}
    current: list[str] = []
    for line in STT_EXCERPT.read_text().splitlines():
        if line.startswith("## "):
            current = files.setdefault(line[3:], [])
        elif not line.startswith("#"):
            current.append(line)
    files["stt_server/supervise.py"].append(extra_code)
    backends = files["stt_server/backends/__init__.py"]
    # Each dict's closing brace: PINNED_REVISIONS's, then BACKENDS's.
    pins_end = backends.index("}", backends.index("PINNED_REVISIONS: dict[str, str] = {"))
    registry_end = backends.index("}", backends.index("BACKENDS: dict[str, BackendEntry] = {"))
    backends.insert(registry_end, extra_backend)
    backends.insert(pins_end, extra_pin)
    for rel, lines in files.items():
        (tmp_path / rel).parent.mkdir(parents=True, exist_ok=True)
        (tmp_path / rel).write_text("\n".join(lines) + "\n")
    return tmp_path


def test_excerpt_drift_catches_what_the_excerpt_leaves_out(tmp_path):
    """The opt-in check compares the ``CODE_*`` set, the ``BACKENDS`` registry and the
    ``PINNED_REVISIONS`` pins, not only that each excerpt line exists upstream: a code,
    backend or pin the excerpt omits is drift."""
    assert excerpt_drift(_fake_stt_site(tmp_path / "same")) == []
    code = _fake_stt_site(tmp_path / "code", extra_code='CODE_NEW = "NewError"')
    assert [d for d in excerpt_drift(code) if d.startswith("CODE_*")], excerpt_drift(code)
    backend = _fake_stt_site(
        tmp_path / "backend", extra_backend='    "new": BackendEntry("m", "C", None),'
    )
    assert [d for d in excerpt_drift(backend) if d.startswith("BACKENDS")], excerpt_drift(backend)
    pin = _fake_stt_site(
        tmp_path / "pin",
        extra_pin='    DEFAULT_NEW_MODEL: "0123456789abcdef0123456789abcdef01234567",',
    )
    (pin / "stt_server/backends/__init__.py").write_text(
        'DEFAULT_NEW_MODEL = "org/new"\n' + (pin / "stt_server/backends/__init__.py").read_text()
    )
    assert [d for d in excerpt_drift(pin) if d.startswith("PINNED_REVISIONS")], excerpt_drift(pin)


def test_swift_supervised_error_codes_are_the_union_of_both_lists():
    swift = _swift_error_codes()
    assert swift == TTS_CODES | STT_CODES
    # The codes only the STT emitter has are the ones the TTS emitter can never write.
    assert swift - TTS_CODES == STT_CODES - TTS_CODES == {"ModelInvalidError"}


def test_download_module_prefixes_match():
    contract = set(CONTRACT["download_error_module_prefixes"])
    assert set(supervise._DOWNLOAD_MODULE_PREFIXES) == contract


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
def test_classify_only_emits_tts_contract_codes(exc):
    assert supervise.classify_startup_error(exc)[0] in TTS_CODES


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


def test_stt_wire_rate_is_one_constant():
    swift = re.search(
        r"enum STTWire \{.*?public static let rate = (\d+)",
        (CORE / "PCMStreamConverter.swift").read_text(),
        re.DOTALL,
    )
    assert swift, "the parser sees STTWire.rate"
    ready = next(line for line in stt_fixture_lines() if line["event"] == "ready")
    assert CONTRACT["stt_wire_rate"] == ready["rate"] == int(swift.group(1))


# --- catalog ----------------------------------------------------------------------


def _stt_entries():
    return [e for e in macos_catalog().values() if e.engine]


def _swift_stt_server_version() -> str:
    m = re.search(
        r'static let sttServerRequirement = "pipecat-local-stt-server==([^"]+)"',
        SERVICE_SWIFT.read_text(),
    )
    assert m, "the parser sees ServiceCatalog.sttServerRequirement"
    return m.group(1)


def _pins(text: str) -> dict[str, str]:
    return {
        name.lower().replace("_", "-"): version
        for name, version in re.findall(r"^([A-Za-z0-9_.\-]+)==(\S+)", text, re.MULTILINE)
    }


def test_every_stt_family_has_its_own_engine():
    families = {e.family for e in macos_catalog().values() if e.kind == "stt"}
    engines = {e.engine for e in _stt_entries() if not e.is_variant}
    assert engines == {"whisper", "kyutai", "parakeet", "nemotron"}
    assert families == engines | {"apple_speech"}
    # Variants share their family's engine (one environment); no two families share one.
    by_family = {e.family: e.engine for e in _stt_entries()}
    assert len(set(by_family.values())) == len(by_family) == 4


def test_every_stt_engine_has_hash_pinned_constraints():
    engines = {e.engine: e.requirements for e in _stt_entries() if not e.is_variant}
    folder = REPO / "macos" / "constraints"
    assert {p.name for p in folder.glob("stt-*.txt")} == {f"stt-{e}.txt" for e in engines}
    swift_python = re.search(
        r'pythonVersion = "([\d.]+)"', (CORE / "EnvironmentManager.swift").read_text()
    ).group(1)
    server_version = _swift_stt_server_version()
    for engine, requirements in engines.items():
        text = (folder / f"stt-{engine}.txt").read_text()
        assert text.strip(), f"{engine}: empty constraints"
        assert f"# python-version: {swift_python}\n" in text, engine
        # Regenerated from exactly these requirements...
        listed = re.findall(r"^# requirement: (.+)$", text, re.MULTILINE)
        assert listed == list(requirements)
        # ...of which one names the upstream server at exactly the Swift release.
        servers = [r for r in listed if r.startswith("pipecat-local-stt-server")]
        assert len(servers) == 1, f"{engine}: {listed}"
        assert re.fullmatch(
            rf"pipecat-local-stt-server(\[[^\]]+\])?=={re.escape(server_version)}", servers[0]
        ), f"{engine}: {servers[0]} != sttServerRequirement {server_version}"
        pins = _pins(text)
        assert pins.get("pipecat-local-stt-server") == server_version, engine
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
