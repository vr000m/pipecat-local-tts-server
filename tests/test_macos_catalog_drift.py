"""The macOS app's Swift copies of server facts — LEAN drift guard.

``macos/Sources/PipecatToolbarCore/Service.swift`` repeats, per TTS backend, the
``serve --backend`` name (as the package extra), the canonical port, the
default model repo, the streaming capability and (for variants) the ``--model``
alias; ``PrefetchEvent.swift`` repeats the supervised error codes. Swift cannot
import Python, so these tests parse the Swift source (one parser,
``_macos_catalog``) and assert it equals the Python/justfile source of truth:

  * the TTS family set equals ``BACKEND_CHOICES``;
  * each family's port equals the justfile ``_resolve`` port, and every port
    (variants included) is unique;
  * each family's ``modelRepo`` equals the backend's ``DEFAULT_*_MODEL``
    (``tone`` has none);
  * each TTS entry's ``streaming`` equals its backend's ``capabilities()``;
  * each variant ``modelArgument`` is an alias its backend resolves to the
    family's repo;
  * ``ServiceCatalog.snapshots(for:)`` (the download-size table) equals each
    TTS service's ``prefetch_specs(model)`` and the STT helper's file filter,
    at the helper's ``MODEL_REVISIONS`` pins (``sttModelRevisions``);
  * ``SupervisedErrorCode`` raw values equal ``tts_server.supervise``'s ``CODE_*``;
  * the Try it wire fixture is what the server sends.
"""

from __future__ import annotations

import ast
import json
import re
from pathlib import Path

from tts_server import supervise
from tts_server.__main__ import BACKEND_CHOICES

from ._macos_catalog import (
    Snapshot,
    macos_catalog,
    macos_snapshots,
    macos_stt_model_revisions,
    mlx_audio_default_patterns,
)

REPO = Path(__file__).resolve().parents[1]
CORE = REPO / "macos" / "Sources" / "PipecatToolbarCore"

_RESOLVE = re.compile(r'^\s+(\w+)\)\s+printf .*?"127\.0\.0\.1"\s+"(\d+)"', re.MULTILINE)
_DEFAULT_MODEL = re.compile(r'^DEFAULT_\w+_MODEL = "([^"]+)"', re.MULTILINE)
_STREAMING = re.compile(r'^\s+"streaming": (True|False),', re.MULTILINE)


def _swift_families() -> dict[str, tuple[int, str | None]]:
    families = {}
    for entry in macos_catalog().values():
        if entry.kind == "tts" and not entry.is_variant:
            # The package extra is the backend name; only ``tone`` has none.
            assert entry.extra in (entry.name, None), entry
            families[entry.name] = (entry.port, entry.model_repo)
    return families


def test_swift_tts_families_match_backend_choices():
    assert sorted(_swift_families()) == sorted(BACKEND_CHOICES)


def test_swift_ports_match_justfile_resolve():
    resolve = {name: int(port) for name, port in _RESOLVE.findall((REPO / "justfile").read_text())}
    assert sorted(resolve) == sorted(BACKEND_CHOICES)
    assert {name: port for name, (port, _) in _swift_families().items()} == resolve


def test_swift_ports_are_unique_including_variants():
    ports: dict[int, list[str]] = {}
    for entry in macos_catalog().values():
        ports.setdefault(entry.port, []).append(entry.name)
    assert {port: names for port, names in ports.items() if len(names) > 1} == {}
    assert any(e.is_variant for e in macos_catalog().values()), "the parser sees variants"


def test_swift_model_repos_match_backend_defaults():
    for name, (_, repo) in _swift_families().items():
        if name == "tone":
            assert repo is None
            continue
        source = (REPO / "tts_server" / "backends" / f"{name}.py").read_text()
        defaults = _DEFAULT_MODEL.findall(source)
        assert len(defaults) == 1, f"{name}: expected one DEFAULT_*_MODEL"
        assert repo == defaults[0], f"{name}: Swift {repo!r} != Python {defaults[0]!r}"


def _backend_streaming(family: str) -> bool:
    if family == "tone":
        from tts_server.backend import ToneBackend

        return ToneBackend().capabilities()["streaming"]
    flags = _STREAMING.findall((REPO / "tts_server" / "backends" / f"{family}.py").read_text())
    assert len(flags) == 1, f"{family}: expected one capabilities() streaming flag"
    return flags[0] == "True"


def test_swift_streaming_flags_match_backend_capabilities():
    for entry in macos_catalog().values():
        if entry.kind == "tts":
            assert entry.streaming == _backend_streaming(entry.family), entry.name


def test_swift_model_arguments_are_backend_aliases():
    from tts_server.backends import phonon

    aliases = {"phonon": phonon._MODEL_ALIASES}
    seen = set()
    for entry in macos_catalog().values():
        if entry.kind != "tts" or entry.model_argument is None:
            continue
        table = aliases.get(entry.family)
        assert table is not None, f"{entry.name}: {entry.family} has no --model aliases"
        assert entry.model_argument in table, (
            f"{entry.name}: {entry.model_argument!r} is not an alias"
        )
        repo, _bits = table[entry.model_argument]
        assert repo == entry.model_repo, f"{entry.name}: alias fetches {repo!r}"
        seen.add(entry.model_argument)
    # Every quantized alias is offered in the app; the bare default needs no argument.
    assert seen == {alias for alias, (_, bits) in phonon._MODEL_ALIASES.items() if bits is not None}


TRY_IT_FIXTURE = (
    REPO / "macos" / "Tests" / "PipecatServiceToolbarTests" / "Fixtures" / "tts_wire_frames.json"
)
# Per-frame values the server mints fresh on every run.
_VOLATILE = {"event_id", "response_id"}


# The frames ``TTSClientFrame.request`` sends for request ``tryit-1`` ("Hello",
# default voice); the Swift tests compare against the fixture's copy.
_TRY_IT_REQUEST = [
    {"type": "input_text.clear", "event_id": "tryit-1.clear"},
    {"type": "input_text.append", "text": "Hello", "event_id": "tryit-1.append"},
    {"type": "input_text.commit", "event_id": "tryit-1"},
]


def _try_it_frames(n: int, text: str, voice: str | None = None) -> list[dict]:
    """Request ``tryit-<n>`` as the app's ``TTSRequestMachine`` sends it."""
    commit = {"type": "input_text.commit", "event_id": f"tryit-{n}"}
    if voice is not None:
        commit["voice"] = voice
    return [
        {"type": "input_text.clear", "event_id": f"tryit-{n}.clear"},
        {"type": "input_text.append", "text": text, "event_id": f"tryit-{n}.append"},
        commit,
    ]


async def _try_it_exchange() -> dict:
    """The frames the real server sends for the exchanges the app's Try it runs:
    each request is an ``input_text.clear`` (event id ``<id>.clear``), an
    ``input_text.append`` (``<id>.append``) and an ``input_text.commit``
    (``<id>``); Stop sends ``response.cancel`` after the commit."""
    from tts_server.backend import ToneBackend

    from ._helpers import connected_client, next_event, running_server

    async def send(client, frame: dict) -> None:
        await client._ws.send(json.dumps(frame))

    assert _try_it_frames(1, "Hello") == _TRY_IT_REQUEST
    frames: dict = {"request": _TRY_IT_REQUEST}
    async with running_server(ToneBackend()) as srv:
        async with connected_client(srv) as (client, _hello):
            for frame in _TRY_IT_REQUEST:
                await send(client, frame)
            frames["cleared"] = await next_event(client, "input_text.cleared")
            frames["committed"] = await next_event(client, "input_text.committed")
            frames["created"] = await next_event(client, "response.created")
            # A second request while the first is in flight is refused (K=1).
            for frame in _try_it_frames(2, "Again"):
                await send(client, frame)
            await next_event(client, "input_text.cleared")
            frames["error_busy"] = await next_event(client, "error")
            await send(client, {"type": "input_text.append", "event_id": "tryit-3.append"})
            frames["error_append"] = await next_event(client, "error")
            frames["audio"] = await next_event(client, "response.audio.delta")
            await send(client, {"type": "response.cancel"})
            frames["cancelled"] = await next_event(client, "response.cancelled")
        # A fresh connection: a voice the server does not advertise is refused,
        # then a request plays to the end.
        async with connected_client(srv) as (client, _hello):
            for frame in _try_it_frames(4, "Hello", voice="nope"):
                await send(client, frame)
            frames["error_voice"] = await next_event(client, "error")
            for frame in _try_it_frames(5, "Hello"):
                await send(client, frame)
            await next_event(client, "input_text.committed")
            frames["done"] = await next_event(client, "response.audio.done")
    frames["audio"]["audio"] = "AID/fw=="  # four pcm16 bytes: -32768 then 32767
    frames["audio"]["seq"] = 0
    return frames


def _shape(value, key=None):
    """``value`` with the volatile ids reduced to their type."""
    if isinstance(value, dict):
        return {k: _shape(v, k) for k, v in value.items()}
    if key in _VOLATILE:
        return type(value).__name__
    return value


async def test_swift_try_it_fixture_is_what_the_server_sends():
    """``tts_wire_frames.json`` (decoded by the Swift ``TTSEvent`` tests) holds
    the real server frames, so the app's decoder is tested against the wire
    format ``server._error`` / ``_error_object`` actually write."""
    fixture = json.loads(TRY_IT_FIXTURE.read_text())
    live = await _try_it_exchange()
    assert sorted(fixture) == sorted(live)
    for name, frame in live.items():
        assert _shape(fixture[name]) == _shape(frame), name
    # The Swift tests rely on these correlations holding in the fixture itself.
    assert fixture["committed"]["previous_event_id"] == "tryit-1"
    assert fixture["committed"]["response_id"] == fixture["created"]["response_id"]
    assert fixture["error_busy"]["previous_event_id"] == "tryit-2"
    assert fixture["error_append"]["previous_event_id"] == "tryit-3.append"
    assert fixture["cleared"]["previous_event_id"] == "tryit-1.clear"
    assert fixture["error_voice"]["previous_event_id"] == "tryit-4"
    assert fixture["request"] == _TRY_IT_REQUEST


HELPER = REPO / "macos" / "Helper" / "pipecat_app_helper.py"


def test_swift_snapshots_match_prefetch_specs(monkeypatch):
    """``ServiceCatalog.snapshots(for:)`` (what Add Models sizes before an install)
    is, per TTS service, exactly ``prefetch_specs(model)`` for the ``--model`` the
    app passes (repo, pinned revision, allow patterns, kind, required): Phonon's
    pin, dia's codec, pocket's voice embeddings. The app's environment sets no
    ``PIPECAT_TTS_PHONON_VOICES``, so no Phonon voice snapshot."""
    from tts_server import prefetch

    monkeypatch.delenv("PIPECAT_TTS_PHONON_VOICES", raising=False)
    assert mlx_audio_default_patterns() == prefetch.DEFAULT_ALLOW_PATTERNS
    snapshots = macos_snapshots()
    catalog = macos_catalog()
    for name, entry in catalog.items():
        if entry.kind != "tts":
            continue
        python = [
            Snapshot(s.repo_id, s.revision, tuple(s.allow_patterns), s.kind, s.required)
            for s in prefetch.specs_for(entry.family, entry.model_argument)
        ]
        assert snapshots[name] == python, name
    assert snapshots["phonon_q8"][0].revision, "the parser sees the Phonon pin"


def _helper_model_revisions() -> dict[str, str]:
    """The helper's ``MODEL_REVISIONS`` literal, read without importing it."""
    for node in ast.parse(HELPER.read_text()).body:
        if isinstance(node, ast.Assign) and any(
            isinstance(t, ast.Name) and t.id == "MODEL_REVISIONS" for t in node.targets
        ):
            return ast.literal_eval(node.value)
    raise AssertionError("MODEL_REVISIONS not found in the helper")


def test_swift_stt_pins_match_the_helper():
    """``ServiceCatalog.sttModelRevisions`` is the helper's ``MODEL_REVISIONS``:
    the app sizes the very commit ``prefetch --repo`` downloads."""
    assert macos_stt_model_revisions() == _helper_model_revisions()


def test_swift_stt_snapshots_match_the_helper_filter():
    """An STT service downloads its one model repo at its pinned commit
    (``MODEL_REVISIONS``) through the helper's ``prefetch --repo`` (no
    ``--revision``), which takes every file but top-level dotfiles, ``*.md`` and
    ``.gitattributes``: ``HubSnapshot.Files.allButDocs``."""
    source = HELPER.read_text()
    assert 'not f.path.startswith(".")' in source
    assert 'endswith((".md", ".gitattributes"))' in source
    assert "args.revision or MODEL_REVISIONS.get(repo)" in source
    pins = _helper_model_revisions()
    for name, entry in macos_catalog().items():
        if entry.kind == "stt":
            if entry.model_repo is None:
                assert macos_snapshots()[name] == [], name
                continue
            expected = [
                Snapshot(entry.model_repo, pins[entry.model_repo], "allButDocs", "model", True)
            ]
            assert macos_snapshots()[name] == expected, name


def test_swift_supervised_error_codes_match_supervise():
    swift = set(
        re.findall(
            r'case \w+ = "(\w+)"',
            (CORE / "PrefetchEvent.swift")
            .read_text()
            .split("enum SupervisedErrorCode", 1)[1]
            .split("}", 1)[0],
        )
    )
    python = {v for k, v in vars(supervise).items() if k.startswith("CODE_")}
    assert swift == python
