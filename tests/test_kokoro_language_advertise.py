"""Honest language advertisement (lean, no mlx).

The Kokoro model ships voices for 8 languages, but ``ja``/``zh`` synthesis needs
a dedicated misaki G2P package beyond the ``misaki[en]`` the ``kokoro`` extra
installs (verified by tests/smoke/README.md). Advertising a language that fails
at synthesis violates the capability contract, so ``_REQUIRES_EXTRA_G2P``
languages are dropped from the advertised set unless an operator opts them back
in via ``PIPECAT_TTS_KOKORO_EXTRA_LANGS`` (signalling they installed the package).

These are LEAN tests: the helper, the constant, and ``KokoroBackend``
construction are all importable/usable without ``mlx_audio`` (the lazy-import
invariant — see test_kokoro_lazy_import). Only ``start()`` needs mlx.
"""

from __future__ import annotations

from tts_server.backends.kokoro import (
    _REQUIRES_EXTRA_G2P,
    KokoroBackend,
    _filtered_languages,
)

_ALL = ["en", "es", "fr", "hi", "it", "ja", "pt", "zh"]


def test_default_drops_languages_needing_extra_g2p():
    # Out of the box (no opt-in) ja/zh are not advertised; the espeak-routed and
    # English languages stay.
    assert _filtered_languages(_ALL, set()) == ["en", "es", "fr", "hi", "it", "pt"]


def test_optin_retains_a_blocked_language():
    # An operator who installed misaki[ja] re-enables ja; zh stays dropped.
    assert _filtered_languages(_ALL, {"ja"}) == ["en", "es", "fr", "hi", "it", "ja", "pt"]


def test_optin_retains_all_blocked_languages():
    assert _filtered_languages(_ALL, {"ja", "zh"}) == _ALL


def test_optin_is_case_insensitive():
    assert "ja" in _filtered_languages(_ALL, {"JA"})


def test_optin_cannot_add_a_language_the_model_lacks():
    # Opt-in only RETAINS a discovered language; it never conjures one. A model
    # that only ships en/es voices stays en/es even if ja is opted in.
    assert _filtered_languages(["en", "es"], {"ja"}) == ["en", "es"]


def test_order_is_preserved():
    assert _filtered_languages(["pt", "en", "ja", "es"], set()) == ["pt", "en", "es"]


def test_blocklist_is_the_documented_set():
    # Guards against silently widening/narrowing what counts as "needs extra G2P".
    assert _REQUIRES_EXTRA_G2P == frozenset({"ja", "zh"})


def test_backend_reads_optin_from_env(monkeypatch):
    # Construction is lean (no mlx); the env opt-in is resolved at construction.
    monkeypatch.setenv("PIPECAT_TTS_KOKORO_EXTRA_LANGS", "ja, ZH")
    backend = KokoroBackend()
    assert backend._extra_languages == {"ja", "zh"}


def test_backend_optin_defaults_empty_when_env_unset(monkeypatch):
    monkeypatch.delenv("PIPECAT_TTS_KOKORO_EXTRA_LANGS", raising=False)
    backend = KokoroBackend()
    assert backend._extra_languages == set()


def test_backend_explicit_optin_overrides_env(monkeypatch):
    # An explicit set wins over the env (the test-injection seam).
    monkeypatch.setenv("PIPECAT_TTS_KOKORO_EXTRA_LANGS", "zh")
    backend = KokoroBackend(extra_languages={"ja"})
    assert backend._extra_languages == {"ja"}
