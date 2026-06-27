"""Trip-wire pin for the frozen V1 wire protocol version.

``PROTOCOL_VERSION`` is part of the frozen V1 surface. Bumping it requires
editing this test explicitly — that is the intended friction (mirrors stt).
A protocol bump needs its own dev plan and a coordinated client upgrade; it
must never happen as a silent side effect of an unrelated change.

This is SEPARATE from the handshake round-trip in ``test_protocol.py``: a
constant-pin catches a bump even if the server still echoes the constant it was
given, which a hello round-trip would not.
"""

from __future__ import annotations

from tts_server import protocol


def test_protocol_version_is_pinned():
    assert protocol.PROTOCOL_VERSION == "0.1"
