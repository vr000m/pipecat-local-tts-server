"""Lean tests for the pure parts of the app-path smoke (tests/smoke/supervised_smoke.py).

The smoke itself is live (``just smoke-supervised``); what it judges by lives in
``tests/smoke/_supervised_contract.py`` and is pinned here: the contract-shape
validator, the strict stdout JSON-lines parser, the ``ready`` checks, the
app-environment mirror (drift-tested against ToolLocator.swift) and the port
guard. Stdlib only, no tts_server runtime.
"""

from __future__ import annotations

import re

import pytest

from tests.smoke import _supervised_contract as sc

READY = {
    "event": "ready",
    "backend": "tone",
    "model": None,
    "host": "127.0.0.1",
    "port": 51234,
    "socket_path": None,
    "rate": 24000,
    "pid": 4242,
}
EXPECT = {"backend": "tone", "model": None, "host": "127.0.0.1", "port": 51234, "pid": 4242}


def test_valid_events_conform():
    assert sc.event_errors("serve", READY) == []
    err = {"event": "error", "code": "EADDRINUSE", "message": "busy", "exc_type": "OSError"}
    assert sc.event_errors("serve", err) == []
    summary = {
        "event": "summary",
        "backend": "phonon",
        "model": "m",
        "cached": True,
        "size_bytes": 1,
        "quantized": False,
    }
    assert sc.event_errors("prefetch", summary) == []


@pytest.mark.parametrize(
    ("event", "needle"),
    [
        ({k: v for k, v in READY.items() if k != "pid"}, "missing ['pid']"),
        ({**READY, "extra": 1}, "not in the contract ['extra']"),
        ({**READY, "port": "51234"}, "ready.port"),
        ({**READY, "rate": True}, "ready.rate"),  # a bool is not an integer
        ({"event": "listening"}, "not a contract event"),
        (["ready"], "not a JSON object"),
        (
            {"event": "error", "code": "EBUSY", "message": "x", "exc_type": "OSError"},
            "not a contract error code",
        ),
    ],
)
def test_contract_violations_are_reported(event, needle):
    errors = sc.event_errors("serve", event)
    assert any(needle in e for e in errors), errors


def test_parse_json_lines_flags_every_non_object_line():
    events, bad = sc.parse_json_lines('{"event":"ready"}\n\nloading weights...\n[1]\n"s"\n')
    assert events == [{"event": "ready"}]
    assert bad == ["loading weights...", "[1]", '"s"']


def test_ready_errors_accepts_the_expected_line():
    assert sc.ready_errors(READY, **EXPECT) == []


@pytest.mark.parametrize(
    ("override", "needle"),
    [
        ({"port": 8665}, "ready.port"),
        ({"pid": 1}, "ready.pid"),
        ({"backend": "kokoro"}, "ready.backend"),
        ({"host": "0.0.0.0"}, "ready.host"),
        ({"socket_path": "/tmp/x.sock"}, "ready.socket_path"),
        ({"rate": 0}, "ready.rate"),
    ],
)
def test_ready_errors_catches_a_wrong_value(override, needle):
    errors = sc.ready_errors({**READY, **override}, **EXPECT)
    assert any(needle in e for e in errors), errors


def test_ready_errors_rejects_an_error_line():
    err = {"event": "error", "code": "ConfigError", "message": "x", "exc_type": "SystemExit"}
    assert sc.ready_errors(err, **EXPECT)


def _check(cached=True):
    return {
        "event": "check",
        "repo": "r",
        "revision": None,
        "kind": "model",
        "required": True,
        "cached": cached,
        "path": None,
        "size_bytes": 0,
    }


def _summary(name="summary", backend="tone"):
    return {"event": name, "backend": backend, "model": None, "cached": True, "size_bytes": 0}


def test_prefetch_errors_check_run():
    assert sc.prefetch_errors([_check(), _summary()], check=True, backend="tone") == []
    assert sc.prefetch_errors([_summary()], check=True, backend="tone") == []
    assert sc.prefetch_errors([_check()], check=True, backend="tone")  # no summary
    assert sc.prefetch_errors([_summary(), _check()], check=True, backend="tone")  # not last
    assert sc.prefetch_errors([_summary(backend="dia")], check=True, backend="tone")
    err = {"event": "error", "code": "ModuleNotFoundError", "message": "x", "repo": None}
    assert sc.prefetch_errors([err], check=True, backend="tone")


def test_prefetch_errors_fetch_run():
    start = {"event": "start", "repo": "r", "revision": None, "kind": "model"}
    done = {"event": "done", "repo": "r", "path": "/p", "size_bytes": 1}
    good = [start, done, _summary("complete")]
    assert sc.prefetch_errors(good, check=False, backend="tone") == []
    # a --check summary does not end a fetch
    assert sc.prefetch_errors([start, done, _summary()], check=False, backend="tone")
    # a check row inside a fetch run is stray
    assert sc.prefetch_errors([start, _check(), _summary("complete")], check=False, backend="tone")


def _swift_base_env_keys() -> set[str]:
    text = (sc.REPO / "macos" / "Sources" / "PipecatToolbarCore" / "ToolLocator.swift").read_text()
    body = text[text.index("public static func base()") :]
    body = body[: body.index("return env")]
    keys = set(re.findall(r'"([A-Z][A-Z0-9_]+)":', body))  # the literal dict
    keys |= set(re.findall(r'env\["([A-Z][A-Z0-9_]+)"\]', body))  # env["TMPDIR"] = ...
    for listed in re.findall(r"for key in \[([^\]]*)\]", body):  # inherited keys
        keys |= set(re.findall(r'"([A-Z][A-Z0-9_]+)"', listed))
    return keys


def test_app_env_mirrors_toollocator_base():
    """The smoke's child env is the app's ``ProcessEnvironment.base()`` key for key."""
    assert sc.APP_BASE_ENV_KEYS == _swift_base_env_keys()


def test_app_child_env_scrubs_and_passes_hf():
    env = sc.app_child_env(
        {"HOME": "/h", "TMPDIR": "/t", "HF_TOKEN": "tok", "VIRTUAL_ENV": "/v", "PATH": "/x"}
    )
    assert env["PATH"] == "/usr/bin:/bin:/usr/sbin:/sbin"
    assert env["HF_TOKEN"] == "tok" and env["HOME"] == "/h" and env["TMPDIR"] == "/t"
    assert "VIRTUAL_ENV" not in env
    assert env["PYTHONUNBUFFERED"] == "1"


def test_canonical_ports_cover_the_operator_map():
    ports = sc.canonical_ports()
    assert {8665, 8765, 9365} <= ports
    assert set(range(8665, 8673)) <= ports
    assert not sc.usable_smoke_port(9365, ports)
    assert not sc.usable_smoke_port(8080, ports)
    assert sc.usable_smoke_port(51234, ports)


def test_error_codes_are_checked_against_the_named_emitter():
    only_stt = {"event": "error", "code": "ModelInvalidError", "message": "x", "exc_type": "E"}
    assert sc.event_errors("serve", only_stt) == []  # either emitter's code
    assert sc.event_errors("serve", only_stt, emitter="stt") == []
    assert any("code" in e for e in sc.event_errors("serve", only_stt, emitter="tts"))
