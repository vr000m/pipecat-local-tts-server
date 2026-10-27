"""The macOS app's Swift copies of server facts — LEAN drift guard.

``macos/Sources/PipecatToolbarCore/Service.swift`` repeats, per TTS backend, the
``serve --backend`` name (as the package extra), the canonical port, the
default model repo, the streaming capability and (for variants) the ``--model``
alias. (``PrefetchEvent.swift``'s supervised error codes are checked once, in
``tests/test_supervised_contract.py``.) Swift cannot
import Python, so these tests parse the Swift source (one parser,
``_macos_catalog``) and assert it equals the Python/justfile source of truth:

  * the TTS family set equals ``BACKEND_CHOICES``;
  * each family's port equals the justfile ``_resolve`` port, and every port
    (variants included) is unique;
  * each family's ``modelRepo`` equals the backend's ``DEFAULT_*_MODEL``
    (``tone`` has none);
  * each TTS entry's expected hello ``backend.name`` equals its backend's static
    ``backend_name`` and the model it expects equals what the backend reports
    (default repo, or the raw ``--model`` alias), read from source;
  * each TTS entry's ``streaming`` equals its backend's ``capabilities()``;
  * each variant ``modelArgument`` is an alias its backend resolves to the
    family's repo;
  * ``ServiceCatalog.snapshots(for:)`` (the download-size table) equals each
    TTS service's ``prefetch_specs(model)``; an STT service sizes its one model
    repo at upstream's ``PINNED_REVISIONS`` commit for a pinned default, else with no
    revision (the app passes none: upstream 0.5.0 pins the default models itself);
  * the four STT families (Whisper, Kyutai, Parakeet, Nemotron) keep the STT
    repo's LaunchAgent labels and ports (written out here), and backend names and
    default model repos that equal the upstream registry, read from the recorded
    excerpt of the installed release (``_stt_upstream``; the lean job never imports
    ``stt_server``);
  * the Try it wire fixture is what the server sends.
"""

from __future__ import annotations

import json
import re
from pathlib import Path

from tts_server.__main__ import BACKEND_CHOICES

from ._macos_catalog import (
    Snapshot,
    macos_catalog,
    macos_snapshots,
    macos_stt_pinned_revisions,
    mlx_audio_default_patterns,
)
from ._stt_upstream import upstream_stt

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


def test_swift_stt_snapshots_are_the_model_repo_at_upstreams_pin():
    """An STT service downloads its one model repo through the upstream
    ``stt_server prefetch --backend <b> --model <repo>``, which takes no revision flag:
    upstream pins its default models itself (``PINNED_REVISIONS``, read from the recorded
    excerpt of the release the app installs). So one required model snapshot of the entry's
    ``modelRepo``, at upstream's pin for a pinned default and ``revision`` nil (``main``) for
    any other model. Whisper and Kyutai take everything but docs."""
    pinned = upstream_stt().pinned_revisions
    stt = {n: e for n, e in macos_catalog().items() if e.kind == "stt"}
    assert {"parakeet", "nemotron", "whisper", "kyutai"} <= set(stt)
    snapshots = macos_snapshots()
    for name, entry in stt.items():
        if entry.model_repo is None:
            assert snapshots[name] == [], name
            continue
        assert len(snapshots[name]) == 1, name
        (snap,) = snapshots[name]
        assert (snap.repo, snap.revision, snap.kind, snap.required) == (
            entry.model_repo,
            pinned.get(entry.model_repo),
            "model",
            True,
        ), name
        assert snap.files, f"{name}: nothing to download"
        if entry.family in ("whisper", "kyutai"):
            assert snap.files == "allButDocs", name
    # Every upstream pin is a catalog model the app sizes at that pin, and the Swift table holds
    # nothing else (a stale or extra entry would size the wrong commit).
    sized = {s.repo: s.revision for name in stt for s in snapshots[name]}
    assert {repo: sized.get(repo) for repo in pinned} == pinned
    assert macos_stt_pinned_revisions() == pinned


_BACKEND_NAME = re.compile(r'^\s+backend_name = "(\w+)"', re.MULTILINE)
_REPORTS_RAW_MODEL = re.compile(r"^\s+self\.model = model$", re.MULTILINE)


def _backend_source(family: str) -> str:
    """The module that defines ``family``'s backend class (``tone`` lives in ``backend.py``)."""
    path = REPO / "tts_server" / ("backend.py" if family == "tone" else f"backends/{family}.py")
    return path.read_text()


def _static_backend_name(family: str) -> str:
    if family == "tone":
        text = _backend_source("tone")
        # ToneBackend's: ``backend.py`` also holds the protocol's annotation, which has no value.
        names = _BACKEND_NAME.findall(text)
    else:
        names = _BACKEND_NAME.findall(_backend_source(family))
    assert len(names) == 1, f"{family}: expected one static backend_name, got {names}"
    return names[0]


def test_swift_expected_backend_names_match_backend_name():
    """The hello's ``backend.name`` is the backend class's static ``backend_name``
    (``server.py`` sends ``self._backend.backend_name``); the app matches a hello on it,
    so each TTS catalog entry, variants included, must expect exactly that."""
    for entry in macos_catalog().values():
        if entry.kind != "tts":
            continue
        assert entry.expected_backend_name == _static_backend_name(entry.family), entry.name
        # The ``serve --backend`` name is the static name for every shipped backend.
        assert entry.expected_backend_name == entry.family, entry.name
    assert "backend_name" in (REPO / "tts_server" / "server.py").read_text()


def test_swift_expected_models_match_what_the_backends_report():
    """The hello's ``backend.model`` is the backend's ``model`` attribute, which every
    backend sets to the ``--model`` it was given (``self.model = model``): the default
    repo for a family default, the raw alias (``phonon-q8``) for a quantized variant,
    never the repo the alias resolves to. The app matches on ``modelArgument ??
    modelRepo``; this pins that to the source of each side."""
    for family in sorted(BACKEND_CHOICES):
        if family == "tone":
            assert "model = None" in _backend_source("tone")
            continue
        assert _REPORTS_RAW_MODEL.search(_backend_source(family)), f"{family}: no raw self.model"
    for entry in macos_catalog().values():
        if entry.kind != "tts":
            continue
        expected = entry.model_argument or entry.model_repo
        if entry.family == "tone":
            assert expected is None, entry.name
            continue
        if entry.model_argument is None:
            defaults = _DEFAULT_MODEL.findall(_backend_source(entry.family))
            assert expected == defaults[0], f"{entry.name}: expects {expected!r}"
        else:
            # A variant's hello carries its alias verbatim, which differs from its repo.
            assert expected == entry.model_argument != entry.model_repo, entry.name


# The STT repo's (pipecat-local-stt-server 0.5.0) LaunchAgents, which the app's STT entries
# agree with: ``backend.name`` the server reports, port, launchd label and default model repo
# per catalog family. Whisper is the ``mlx`` backend; the ``.sttHelper`` engine name is the
# app's own (it names the environment and the constraints file). The backend names and
# default models are checked against the recorded upstream registry
# (``test_stt_families_match_the_recorded_upstream_registry``); the ports and labels are the
# STT repo's LaunchAgent plists (PR #16), which no released source carries yet.
_STT_FAMILIES = {
    "whisper": ("mlx", 9565, "pipecat.stt-server", "mlx-community/whisper-large-v3-turbo"),
    "kyutai": ("kyutai", 9665, "pipecat.stt-server.kyutai", "kyutai/stt-1b-en_fr-mlx"),
    "parakeet": (
        "parakeet",
        9765,
        "pipecat.stt-server.parakeet",
        "mlx-community/parakeet-tdt-0.6b-v3",
    ),
    "nemotron": (
        "nemotron",
        9865,
        "pipecat.stt-server.nemotron",
        "mlx-community/nemotron-3.5-asr-streaming-0.6b",
    ),
}


def test_stt_families_match_the_recorded_upstream_registry():
    """Each family's ``backend.name`` is an upstream ``BACKENDS`` name whose default model is the
    family's repo, read from the recorded excerpt of the release the app installs (and the live
    registry when ``stt_server`` is importable), so an upstream rename or a new default fails here."""
    upstream = upstream_stt().default_models
    for family, (backend, _, _, repo) in _STT_FAMILIES.items():
        assert upstream.get(backend) == repo, family
    # Every upstream backend but the test-only ``echo`` is a catalog family.
    assert {name for name in upstream if name != "echo"} == {b for b, *_ in _STT_FAMILIES.values()}
    try:
        from stt_server.backends import BACKENDS as live
    except ImportError:
        return
    assert {name: entry.default_model for name, entry in live.items()} == upstream


def _swift_launchd_labels() -> dict[str, str]:
    """``{service raw name: label}`` of the STT cases in ``ServiceInfo.launchdLabel``."""
    text = (CORE / "Service.swift").read_text()
    body = text.split("var launchdLabel", 1)[1].split("\n        }\n", 1)[0]
    return dict(re.findall(r'case \.(\w+): "(pipecat\.stt-server[\w.\-]*)"', body))


def test_swift_stt_expected_backend_names():
    """Every STT variant of a family reports the family's backend name (all Whisper
    sizes are ``mlx``). Apple Speech is in-process, never probed, and has no entry here."""
    seen = set()
    for entry in macos_catalog().values():
        if entry.kind != "stt" or entry.family == "apple_speech":
            continue
        assert entry.expected_backend_name == _STT_FAMILIES[entry.family][0], entry.name
        seen.add(entry.family)
    assert seen == set(_STT_FAMILIES)


def test_swift_stt_ports_and_labels_match_the_stt_launchagents():
    catalog = macos_catalog()
    labels = _swift_launchd_labels()
    for family, (_, port, label, _) in _STT_FAMILIES.items():
        assert catalog[family].port == port, family
        assert labels.get(family) == label, family
    # A label belongs to the family default only: variants are not LaunchAgents.
    assert set(labels) == set(_STT_FAMILIES)
    # Variants continue the family's port series (+1, +2, ...) and stay unique (checked above).
    for entry in catalog.values():
        if entry.kind == "stt" and entry.is_variant:
            assert entry.port > catalog[entry.family].port, entry.name


def test_swift_stt_model_repos_match_the_launchagents_and_defaults():
    """The family entries' ``modelRepo``: Parakeet and Nemotron the models their
    LaunchAgents serve, Whisper and Kyutai the upstream defaults. Each STT entry has
    its own repo (variants differ from their family's)."""
    catalog = macos_catalog()
    for family, (_, _, _, repo) in _STT_FAMILIES.items():
        assert catalog[family].model_repo == repo, family
    repos = [e.model_repo for e in catalog.values() if e.kind == "stt" and e.model_repo]
    assert len(repos) == len(set(repos)), "each STT service has its own repo"
    assert catalog["apple_speech"].model_repo is None


def test_swift_stt_server_requirement_is_one_release():
    """Every STT environment installs the one release ``sttServerRequirement`` names."""
    version = re.search(
        r'static let sttServerRequirement = "pipecat-local-stt-server==([^"]+)"',
        (CORE / "Service.swift").read_text(),
    ).group(1)
    for entry in macos_catalog().values():
        if entry.engine:
            assert any(
                re.fullmatch(rf"pipecat-local-stt-server(\[[^\]]+\])?=={re.escape(version)}", r)
                for r in entry.requirements
            ), entry.name
