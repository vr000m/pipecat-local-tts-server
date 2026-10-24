"""``python -m tts_server prefetch`` — LEAN tests.

Nothing touches the network or the real HF cache: the download seam
``tts_server.prefetch._snapshot_download`` is stubbed to build fake snapshot
directories under ``tmp_path``. Invariants:

  * each backend's ``prefetch_specs`` names exactly what ``serve`` would fetch
    (dia's codec, pocket's voice embeddings, phonon's pin + enabled voices);
  * ``--check --json`` is offline and reports ``cached`` per snapshot plus a
    summary; a missing ``huggingface_hub`` is a clean error event, exit 1;
  * ``--json`` emits ``start`` -> ``progress`` -> ``done`` -> ``complete``;
  * an optional snapshot that fails is a ``warning``, a required one an ``error``.
"""

from __future__ import annotations

import json
import sys

import pytest

from tts_server import __main__ as M
from tts_server import prefetch as PF
from tts_server.backends import phonon as PH
from tts_server.backends import phonon_voices as PV


def _run(monkeypatch, capsys, *argv: str) -> tuple[int, list[dict], str]:
    monkeypatch.setattr(sys, "argv", ["tts_server", "prefetch", *argv])
    code = 0
    try:
        M.main()
    except SystemExit as exc:
        code = int(exc.code or 0)
    out, err = capsys.readouterr()
    events = [json.loads(line) for line in out.splitlines() if line.strip()]
    return code, events, err


@pytest.fixture
def fake_hub(tmp_path, monkeypatch):
    """Stub the download seam. ``cached`` holds repo ids already "on disk"."""
    cached: set[str] = set()
    calls: list[tuple[str, bool]] = []

    def fake(spec, *, local_files_only, tqdm_class=None):
        calls.append((spec.repo_id, local_files_only))
        snap = tmp_path / "hub" / spec.repo_id.replace("/", "--")
        if local_files_only and spec.repo_id not in cached:
            raise FileNotFoundError(f"{spec.repo_id} not cached")
        if not local_files_only:
            if tqdm_class is not None:
                files = tqdm_class(total=2, desc="Fetching 2 files")
                bytes_bar = tqdm_class(
                    total=0, desc="Reconstructing (incomplete total...)", unit="B"
                )
                bytes_bar.total = 1000
                bytes_bar.update(400)
                bytes_bar.update(600)
                files.update(2)
            snap.mkdir(parents=True, exist_ok=True)
            (snap / "model.safetensors").write_bytes(b"x" * 1000)
            cached.add(spec.repo_id)
        return str(snap)

    monkeypatch.setattr(PF, "_snapshot_download", fake)
    monkeypatch.delenv(PH.VOICES_ENV, raising=False)
    return cached, calls


def test_specs_tone_needs_nothing():
    assert PF.specs_for("tone", None) == []


def test_specs_kokoro_default_repo():
    (spec,) = PF.specs_for("kokoro", None)
    assert spec.repo_id == "mlx-community/Kokoro-82M-bf16"
    assert spec.revision is None and spec.required
    assert "*.safetensors" in spec.allow_patterns


def test_specs_dia_includes_codec():
    specs = PF.specs_for("dia", None)
    assert [s.kind for s in specs] == ["model", "codec"]
    assert specs[1].repo_id == "mlx-community/descript-audio-codec-44khz"


def test_specs_pocket_voices_are_optional():
    specs = PF.specs_for("pocket_tts", None)
    voice = specs[-1]
    assert voice.kind == "voice" and not voice.required
    assert voice.repo_id == "kyutai/pocket-tts-without-voice-cloning"
    assert voice.allow_patterns == ("embeddings/*.safetensors",)


def test_specs_phonon_pin_and_alias(monkeypatch):
    monkeypatch.delenv(PH.VOICES_ENV, raising=False)
    (default,) = PF.specs_for("phonon", None)
    assert default.repo_id == PH.DEFAULT_PHONON_MODEL
    assert default.revision == PH._REVISION_PINS[PH.DEFAULT_PHONON_MODEL]
    assert default.allow_patterns == tuple(PH.ALLOW_PATTERNS)
    assert PF.specs_for("phonon", "phonon-q8") == [default]


def test_specs_phonon_enabled_voices(monkeypatch):
    monkeypatch.setenv(PH.VOICES_ENV, "zoey,bogus")
    specs = PF.specs_for("phonon", None)
    voice = specs[-1]
    assert voice.kind == "voice" and not voice.required
    assert voice.repo_id == PV.VOICES_REPO and voice.revision == PV.VOICES_REPO_SHA
    assert voice.allow_patterns == (PV.voice_filename("zoey"),)


def test_specs_local_path_model(tmp_path):
    assert PF.specs_for("kokoro", str(tmp_path)) == []


def test_check_json_reports_uncached_then_cached(fake_hub, monkeypatch, capsys):
    cached, calls = fake_hub
    code, events, _ = _run(monkeypatch, capsys, "--backend", "dia", "--check", "--json")
    assert code == 0
    assert [e["event"] for e in events] == ["check", "check", "summary"]
    assert events[-1]["cached"] is False
    assert all(local for _repo, local in calls)  # never touched the network

    code, events, _ = _run(monkeypatch, capsys, "--backend", "dia", "--json")
    assert code == 0
    code, events, _ = _run(monkeypatch, capsys, "--backend", "dia", "--check", "--json")
    summary = events[-1]
    assert summary["event"] == "summary" and summary["cached"] is True
    assert summary["size_bytes"] == 2000


def test_check_json_tone_is_always_cached(monkeypatch, capsys):
    code, events, _ = _run(monkeypatch, capsys, "--backend", "tone", "--check", "--json")
    assert code == 0
    assert events == [
        {"event": "summary", "backend": "tone", "model": None, "cached": True, "size_bytes": 0}
    ]


def test_fetch_json_event_order(fake_hub, monkeypatch, capsys):
    code, events, _ = _run(monkeypatch, capsys, "--backend", "kokoro", "--json")
    assert code == 0
    kinds = [e["event"] for e in events]
    assert kinds[0] == "start" and kinds[-2:] == ["done", "complete"]
    progress = [e for e in events if e["event"] == "progress"]
    assert progress, "expected progress events from the tqdm hook"
    last = progress[-1]
    assert last["downloaded_bytes"] == 1000 and last["total_bytes"] == 1000
    assert last["files_done"] == 2 and last["files_total"] == 2
    assert events[-1] == {
        "event": "complete",
        "backend": "kokoro",
        "model": "mlx-community/Kokoro-82M-bf16",
        "cached": True,
        "size_bytes": 1000,
    }


def test_optional_failure_is_a_warning(fake_hub, monkeypatch, capsys):
    real = PF._snapshot_download

    def flaky(spec, *, local_files_only, tqdm_class=None):
        if spec.kind == "voice":
            raise OSError("voice repo unreachable")
        return real(spec, local_files_only=local_files_only, tqdm_class=tqdm_class)

    monkeypatch.setattr(PF, "_snapshot_download", flaky)
    code, events, _ = _run(monkeypatch, capsys, "--backend", "pocket_tts", "--json")
    assert code == 0
    assert any(e["event"] == "warning" for e in events)
    assert events[-1]["event"] == "complete"


def test_required_failure_is_an_error(monkeypatch, capsys):
    class _HubError(Exception):
        pass

    _HubError.__module__ = "huggingface_hub.errors"

    def broken(spec, *, local_files_only, tqdm_class=None):
        raise _HubError("503 Service Unavailable")

    monkeypatch.setattr(PF, "_snapshot_download", broken)
    code, events, _ = _run(monkeypatch, capsys, "--backend", "kokoro", "--json")
    assert code == 1
    err = events[-1]
    assert err["event"] == "error" and err["code"] == "ModelDownloadError"
    assert err["repo"] == "mlx-community/Kokoro-82M-bf16"


def test_missing_huggingface_hub_is_clean_error(monkeypatch, capsys):
    def no_hub(spec, *, local_files_only, tqdm_class=None):
        raise ModuleNotFoundError("No module named 'huggingface_hub'", name="huggingface_hub")

    monkeypatch.setattr(PF, "_snapshot_download", no_hub)
    code, events, _ = _run(monkeypatch, capsys, "--backend", "kokoro", "--check", "--json")
    assert code == 1
    assert events[-1]["event"] == "error"
    assert events[-1]["code"] == "ModuleNotFoundError"
    assert "kokoro" in events[-1]["message"]


def test_phonon_alias_converts_and_reports_quantized(fake_hub, monkeypatch, capsys, tmp_path):
    monkeypatch.setenv("XDG_CACHE_HOME", str(tmp_path / "xdg"))
    converted: list[tuple[str, int]] = []

    def fake_ensure(snapshot, sha, bits):
        converted.append((sha, bits))
        qdir = PH._quantized_dir(sha, bits)
        qdir.mkdir(parents=True)
        return str(qdir)

    monkeypatch.setattr(PH, "_ensure_quantized", fake_ensure)

    code, events, _ = _run(
        monkeypatch, capsys, "--backend", "phonon", "--model", "phonon-q8", "--check", "--json"
    )
    assert code == 0 and events[-1]["quantized"] is False

    code, events, _ = _run(
        monkeypatch, capsys, "--backend", "phonon", "--model", "phonon-q8", "--json"
    )
    assert code == 0
    convert = [e for e in events if e["event"] == "convert"]
    assert [e["state"] for e in convert] == ["start", "done"]
    assert converted == [(PH._REVISION_PINS[PH.DEFAULT_PHONON_MODEL], 8)]

    code, events, _ = _run(
        monkeypatch, capsys, "--backend", "phonon", "--model", "phonon-q8", "--check", "--json"
    )
    assert events[-1]["cached"] is True and events[-1]["quantized"] is True


def test_human_check_output(fake_hub, monkeypatch, capsys):
    monkeypatch.setattr(sys, "argv", ["tts_server", "prefetch", "--backend", "kokoro", "--check"])
    M.main()
    out = capsys.readouterr().out
    assert "mlx-community/Kokoro-82M-bf16@main: missing" in out
    assert "kokoro: not cached" in out


def test_prefetch_requires_backend(monkeypatch, capsys):
    code, _events, err = _run(monkeypatch, capsys)
    assert code == 2
    assert "--backend" in err
