"""Endpoint precedence (URI > socket > host+port) + cleartext-remote guard.

Pure-function coverage (no server needed) of the env-var resolution and the
cleartext-remote detection that the Phase-1 server/client share. Mirrors stt's
endpoint tests.
"""

from __future__ import annotations

import os

from tts_server.client import (
    TTSClient,
    format_host_for_uri,
    is_cleartext_remote,
    resolve_endpoint_from_env,
)
from tts_server.env import is_loopback_host


# --- precedence: URI > socket > host+port -----------------------------------


def test_precedence_uri_wins_over_everything():
    env = {
        "TTS_WS_URI": "ws://a/",
        "TTS_WS_SOCKET": "/tmp/s",
        "TTS_WS_HOST": "h",
        "TTS_WS_PORT": "1",
    }
    assert resolve_endpoint_from_env(env) == {
        "uri": "ws://a/",
        "socket_path": None,
        "host": None,
        "port": None,
    }


def test_precedence_socket_over_host_port():
    env = {"TTS_WS_SOCKET": "/tmp/s", "TTS_WS_HOST": "h", "TTS_WS_PORT": "1"}
    assert resolve_endpoint_from_env(env) == {
        "uri": None,
        "socket_path": "/tmp/s",
        "host": None,
        "port": None,
    }


def test_precedence_host_port_when_only_those_set():
    env = {"TTS_WS_HOST": "h", "TTS_WS_PORT": "1234"}
    assert resolve_endpoint_from_env(env) == {
        "uri": None,
        "socket_path": None,
        "host": "h",
        "port": 1234,
    }


def test_precedence_empty_returns_all_none():
    assert resolve_endpoint_from_env({}) == {
        "uri": None,
        "socket_path": None,
        "host": None,
        "port": None,
    }


# --- cleartext-remote guard -------------------------------------------------


def test_cleartext_remote_flags_non_loopback_ws():
    assert is_cleartext_remote("ws://example.com/") is True
    assert is_cleartext_remote("ws://8.8.8.8:9000/") is True


def test_cleartext_remote_allows_loopback_and_wss():
    assert is_cleartext_remote("ws://localhost:9000/") is False
    assert is_cleartext_remote("ws://127.0.0.1:9000/") is False
    assert is_cleartext_remote("ws://[::1]:9000/") is False
    assert is_cleartext_remote("wss://example.com/") is False
    assert is_cleartext_remote("") is False


def test_is_loopback_host():
    assert is_loopback_host("127.0.0.1") is True
    assert is_loopback_host("::1") is True
    assert is_loopback_host("localhost") is True
    assert is_loopback_host("example.com") is False
    assert is_loopback_host("8.8.8.8") is False
    assert is_loopback_host(None) is False


def test_format_host_for_uri_brackets_ipv6():
    assert format_host_for_uri("::1") == "[::1]"
    assert format_host_for_uri("fe80::1") == "[fe80::1]"


def test_format_host_for_uri_passes_hostnames_through():
    assert format_host_for_uri("127.0.0.1") == "127.0.0.1"
    assert format_host_for_uri("localhost") == "localhost"


# --- client endpoint validation ---------------------------------------------


def test_client_requires_some_endpoint():
    import pytest

    with pytest.raises(ValueError):
        TTSClient()


def test_client_expanduser_on_socket_path():
    c = TTSClient(socket_path="~/foo/bar.sock")
    assert c._socket_path == os.path.expanduser("~/foo/bar.sock")
    assert c._socket_path and not c._socket_path.startswith("~")
