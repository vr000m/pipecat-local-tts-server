"""Optional backend implementations. Import lazily to avoid hard deps.

No module here may import ``mlx_audio`` or ``numpy`` at module load — the
lean-base invariant requires ``import tts_server`` (and resolving a backend
module) to succeed with only the lean base (``websockets``) installed. Heavy
deps are lazy-imported inside functions (e.g. inside a backend's ``start()`` /
``_get_model``).

:data:`BACKENDS` is the single source of truth for backend names. Everything
that enumerates or dispatches on a backend name derives from it: the CLI
``--backend`` choices (``serve`` and ``prefetch``), ``make_backend`` (mirrors
stt's ``_make_backend``), the default-model fallback, and the ``prefetch``
hooks. A :class:`BackendEntry` names its module and attributes as strings, so
resolution stays LAZY: selecting ``"kokoro"`` imports
``tts_server.backends.kokoro`` (which does NOT pull ``mlx_audio`` at module
load) and constructs the backend; ``mlx_audio`` enters the process only when the
backend's ``start()`` runs. A base install without the ``kokoro`` extra can
therefore still resolve and construct ``tone``, and the missing-extra failure
surfaces in ``start()``.

To add a backend: write ``tts_server/backends/<name>.py`` (a ``TTSBackend``
class taking ``model=``, a ``DEFAULT_*_MODEL`` constant and the module-level
``prefetch_specs(model)`` hook, see ``tts_server.backend.BackendPrefetch``) and
append one :class:`BackendEntry` below.
"""

from __future__ import annotations

import importlib
from dataclasses import dataclass
from types import ModuleType

from ..backend import BackendPrefetch, TTSBackend


@dataclass(frozen=True)
class BackendEntry:
    """One registered backend: where its class, default model and prefetch hooks live.

    Attributes are looked up on the module at call time (never cached), so the
    module stays unimported until a name is selected and a test's monkeypatch of
    a module attribute is honoured.
    """

    name: str
    # Absolute module path holding ``factory`` (and the prefetch hooks).
    module: str
    # ``TTSBackend`` class name. Constructed with ``model=`` unless
    # ``default_model_attr`` is None (a backend with no model, i.e. ``tone``).
    factory: str
    # Module-level ``DEFAULT_*_MODEL`` constant, or None for no model.
    default_model_attr: str | None = None
    # False only for a backend with nothing to download (``tone``).
    prefetches: bool = True

    def load(self) -> ModuleType:
        return importlib.import_module(self.module)

    def default_model(self) -> str | None:
        """The model ``serve``/``prefetch`` use when ``--model`` is not given."""
        if self.default_model_attr is None:
            return None
        return getattr(self.load(), self.default_model_attr)

    def create(self, model: str | None = None) -> TTSBackend:
        """Construct the backend (cheap; heavy deps load in ``start()``)."""
        cls = getattr(self.load(), self.factory)
        if self.default_model_attr is None:
            return cls()
        return cls(model=model or self.default_model())

    def prefetch_hooks(self) -> BackendPrefetch | None:
        """The module implementing ``BackendPrefetch``; None = nothing to fetch."""
        if not self.prefetches:
            return None
        mod = self.load()
        if not isinstance(mod, BackendPrefetch):
            raise TypeError(
                f"backend {self.name!r} is registered with prefetch hooks but "
                f"{self.module} defines no prefetch_specs(model)"
            )
        return mod


def _entry(name: str, factory: str, default_model_attr: str) -> BackendEntry:
    return BackendEntry(name, f"{__name__}.{name}", factory, default_model_attr)


# Order is the CLI ``--backend`` choices order (shown in ``--help``).
BACKENDS: dict[str, BackendEntry] = {
    e.name: e
    for e in (
        BackendEntry("tone", "tts_server.backend", "ToneBackend", prefetches=False),
        _entry("kokoro", "KokoroBackend", "DEFAULT_KOKORO_MODEL"),
        _entry("voxtral_tts", "VoxtralBackend", "DEFAULT_VOXTRAL_MODEL"),
        _entry("pocket_tts", "PocketBackend", "DEFAULT_POCKET_MODEL"),
        _entry("dia", "DiaBackend", "DEFAULT_DIA_MODEL"),
        _entry("qwen3_tts", "Qwen3Backend", "DEFAULT_QWEN3_MODEL"),
        _entry("fish_tts", "FishBackend", "DEFAULT_FISH_MODEL"),
        _entry("phonon", "PhononBackend", "DEFAULT_PHONON_MODEL"),
    )
}

#: Every backend name, in registry order.
BACKEND_NAMES: tuple[str, ...] = tuple(BACKENDS)


def get_backend(name: str) -> BackendEntry:
    """The registry entry for ``name``; ``ValueError`` for an unknown name."""
    try:
        return BACKENDS[name]
    except KeyError:
        # ``ValueError`` (not ``SystemExit``): this is a library-level resolver also
        # callable outside the CLI, so it must not terminate the process. The CLI
        # entry point (``__main__._run_serve``) translates it to a clean exit.
        raise ValueError(f"unknown backend: {name!r}") from None


def make_backend(name: str, model: str | None = None) -> TTSBackend:
    """Resolve a backend name to a constructed ``TTSBackend`` instance.

    Resolution is lazy: heavy backend modules are imported only when their name
    is selected, and even then they do not pull ``mlx_audio`` until ``start()``.
    """
    return get_backend(name).create(model)
