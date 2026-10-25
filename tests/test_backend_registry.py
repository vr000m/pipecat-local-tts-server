"""The backend registry is the one source of truth for backend names — LEAN.

``tts_server.backends.BACKENDS`` drives ``make_backend``, the default-model
fallback, the ``prefetch`` hooks and the CLI ``--backend`` choices. Invariant:
every place that enumerates or dispatches on a backend name agrees with it,
across the whole space (every backend x serve / prefetch / Swift catalog /
justfile), and resolving any of it stays lean (no mlx / numpy / torch /
huggingface_hub at import or construction).
"""

from __future__ import annotations

import re
from pathlib import Path

import pytest

from tts_server import prefetch as PF
from tts_server.__main__ import BACKEND_CHOICES, _resolve_model, build_parser
from tts_server.backend import BackendPrefetch, TTSBackend
from tts_server.backends import BACKEND_NAMES, BACKENDS, get_backend, make_backend

from ._helpers import lean_import_offenders
from ._macos_catalog import macos_catalog

REPO = Path(__file__).resolve().parents[1]
BACKENDS_DIR = REPO / "tts_server" / "backends"
_RESOLVE = re.compile(r'^\s+(\w+)\)\s+printf .*?"127\.0\.0\.1"\s+"(\d+)"', re.MULTILINE)
_HEAVY = ("mlx_audio", "mlx", "numpy", "torch", "huggingface_hub")


def _parser_choices(sub: str) -> tuple[str, ...]:
    parser = build_parser()
    subparsers = next(a for a in parser._actions if a.dest == "cmd")
    action = next(a for a in subparsers.choices[sub]._actions if a.dest == "backend")
    return tuple(action.choices)


def _modules_with_prefetch_hooks() -> set[str]:
    """Backend modules on disk that implement ``prefetch_specs`` — a new backend
    module that is not registered shows up here but not in the registry."""
    return {
        p.stem
        for p in BACKENDS_DIR.glob("*.py")
        if re.search(r"^def prefetch_specs\(", p.read_text(), re.MULTILINE)
    }


def test_every_name_source_equals_the_registry():
    names = set(BACKENDS)
    swift = {e.name for e in macos_catalog().values() if e.kind == "tts" and not e.is_variant}
    justfile = {name for name, _port in _RESOLVE.findall((REPO / "justfile").read_text())}
    sources = {
        "BACKEND_NAMES": set(BACKEND_NAMES),
        "BACKEND_CHOICES": set(BACKEND_CHOICES),
        "serve --backend": set(_parser_choices("serve")),
        "prefetch --backend": set(_parser_choices("prefetch")),
        # tone is the one backend with nothing to fetch (hooks None).
        "prefetch dispatch": {n for n in names if get_backend(n).prefetch_hooks()} | {"tone"},
        "backend modules with prefetch_specs": _modules_with_prefetch_hooks() | {"tone"},
        "Swift catalog TTS families": swift,
        "justfile _resolve": justfile,
    }
    mismatched = {k: sorted(v ^ names) for k, v in sources.items() if v != names}
    assert mismatched == {}, f"registry {sorted(names)} disagrees with: {mismatched}"
    # The CLI keeps the registry order (it is what --help prints).
    assert BACKEND_CHOICES == BACKEND_NAMES == _parser_choices("serve")
    assert _parser_choices("prefetch") == BACKEND_NAMES


@pytest.mark.parametrize("name", BACKEND_NAMES)
def test_entry_resolves_factory_default_model_and_prefetch_hooks(name):
    entry = get_backend(name)
    default = entry.default_model()
    assert _resolve_model(name, None) == default
    assert _resolve_model(name, "x/y") == "x/y"

    backend = make_backend(name)
    assert isinstance(backend, TTSBackend)
    assert backend.backend_name == name
    assert backend.model == default
    if default is not None:
        assert make_backend(name, "org/other").model == "org/other"

    hooks = entry.prefetch_hooks()
    if name == "tone":
        assert hooks is None and default is None
        assert PF.specs_for(name, None) == []
    else:
        assert isinstance(hooks, BackendPrefetch)
        specs = PF.specs_for(name, None)
        assert specs and all(isinstance(s, PF.SnapshotSpec) for s in specs)
        # The first snapshot is the model ``serve`` loads by default.
        assert specs[0].repo_id == default


@pytest.mark.parametrize("name", BACKEND_NAMES)
def test_swift_model_repo_equals_registry_default(name):
    (entry,) = [e for e in macos_catalog().values() if e.name == name and not e.is_variant]
    assert entry.model_repo == get_backend(name).default_model()


def test_unknown_name_is_a_valueerror_everywhere():
    for call in (
        lambda: make_backend("bogus"),
        lambda: get_backend("bogus"),
        lambda: PF.specs_for("bogus", None),
    ):
        with pytest.raises(ValueError, match="unknown backend: 'bogus'"):
            call()
    assert _resolve_model("bogus", None) is None


def test_registered_module_without_prefetch_specs_is_a_clear_error(monkeypatch):
    from tts_server.backends import kokoro

    monkeypatch.delattr(kokoro, "prefetch_specs")
    with pytest.raises(TypeError, match="no prefetch_specs"):
        get_backend("kokoro").prefetch_hooks()


def test_resolving_every_backend_stays_lean():
    """Constructing every backend and listing its prefetch specs through the
    registry imports no heavy dependency (fresh interpreter)."""
    offenders = lean_import_offenders(
        "from tts_server.backends import BACKEND_NAMES, get_backend, make_backend\n"
        "from tts_server import prefetch\n"
        "for n in BACKEND_NAMES:\n"
        "    make_backend(n)\n"
        "    get_backend(n).default_model()\n"
        f"    if n != {_READS_INSTALLED_RUNTIME!r}:\n"
        "        prefetch.specs_for(n, None)\n",
        forbidden=_HEAVY,
    )
    assert offenders == []


# pocket_tts's prefetch_specs reads the voice-embedding pin from mlx_audio's
# PREDEFINED_VOICES when mlx_audio is installed (and falls back to its own copy
# when not), so in a full env listing its specs imports mlx_audio by design.
_READS_INSTALLED_RUNTIME = "pocket_tts"


def test_pocket_specs_need_no_heavy_dependency():
    """With every heavy root unimportable, pocket's specs still resolve (to the
    fallback pin) and pull nothing heavy in."""
    offenders = lean_import_offenders(
        "import sys\n"
        f"for m in {_HEAVY!r}:\n"
        "    sys.modules[m] = None\n"
        "from tts_server import prefetch\n"
        "from tts_server.backends import pocket_tts as P\n"
        f"specs = prefetch.specs_for({_READS_INSTALLED_RUNTIME!r}, None)\n"
        "assert (specs[-1].repo_id, specs[-1].revision) == "
        "(P._POCKET_VOICES_REPO, P._POCKET_VOICES_SHA)\n"
        f"for m in {_HEAVY!r}:\n"
        "    del sys.modules[m]\n",
        forbidden=_HEAVY,
    )
    assert offenders == []
