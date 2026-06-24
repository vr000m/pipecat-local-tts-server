"""Wire protocol constants, events, and error codes.

This is the implementation of the wire contract written up in
``docs/protocol.md`` (the authoritative spec, authored ahead of code) and spoken
by ``examples/reference_client.py``. It mirrors the sibling ``stt_server``
protocol philosophy (an OpenAI-Realtime-inspired event subset) inverted for
synthesis: **text in, audio out**.

Key differences from stt's protocol (correctness, not style):

- **Rate is a per-backend contract, not a wire constant.** stt pins
  ``AUDIO_SAMPLE_RATE_HZ = 16000`` as a module constant because every backend
  shares one input rate. TTS rate comes from the *loaded model*
  (``backend.sample_rate``) and is advertised in ``server.hello.audio.rate``;
  every ``response.audio.delta`` frame for the session is int16-LE mono at
  exactly that rate (R1). Only ``AUDIO_FORMAT`` / ``AUDIO_CHANNELS`` /
  ``AUDIO_SAMPLE_WIDTH_BYTES`` are pinned here.
- **``ErrorCode`` adds ``UNSUPPORTED_FORMAT`` and ``BUSY``.** ``BUSY`` is the
  websocket-native analog of HTTP 429 — a commit rejected for synthesis-backlog
  backpressure (R4); the ``error`` event then carries ``retry_after_ms``.
  (``BUSY`` *enforcement* lands in Phase 3; the enum value and the optional
  ``retry_after_ms`` field on ``error`` belong to the protocol now.)

stdlib-only.
"""

from __future__ import annotations

from enum import Enum

PROTOCOL_VERSION = "0.1"

# Wire format is pinned in V1 except the rate, which is the per-backend
# correctness contract advertised in ``server.hello.audio.rate`` (R1).
AUDIO_CHANNELS = 1
AUDIO_SAMPLE_WIDTH_BYTES = 2  # PCM16LE
AUDIO_FORMAT = "pcm16"

# Wire frame size for the 20 ms re-chunker (decided default #3). The session
# layer slices native model segments into fixed frames at ``backend.sample_rate``
# so barge-in latency is bounded regardless of a model's segment length.
FRAME_DURATION_MS = 20

# Per-session outbound-write high-water mark (bytes). When the socket's pending
# write buffer exceeds this, the server closes the session rather than blocking
# the drain loop on a slow consumer. Enforcement lives in the send helper; the
# *backpressure cap* (synthesis backlog → ``BUSY``) is Phase 3.
SEND_QUEUE_HIGH_WATER_BYTES = 1 * 1024 * 1024
SHUTDOWN_DRAIN_TIMEOUT_SECONDS = 10.0


# --- Client -> server event types ---
EVT_SESSION_UPDATE = "session.update"
EVT_TEXT_APPEND = "input_text.append"
EVT_TEXT_COMMIT = "input_text.commit"
EVT_TEXT_CLEAR = "input_text.clear"
EVT_RESPONSE_CANCEL = "response.cancel"
EVT_SESSION_CANCEL = "session.cancel"
EVT_SESSION_CLOSE = "session.close"
EVT_SERVER_STATUS_REQ = "server.status"

CLIENT_EVENT_TYPES = frozenset(
    {
        EVT_SESSION_UPDATE,
        EVT_TEXT_APPEND,
        EVT_TEXT_COMMIT,
        EVT_TEXT_CLEAR,
        EVT_RESPONSE_CANCEL,
        EVT_SESSION_CANCEL,
        EVT_SESSION_CLOSE,
        EVT_SERVER_STATUS_REQ,
    }
)

# --- Server -> client event types ---
EVT_SERVER_HELLO = "server.hello"
EVT_SESSION_CREATED = "session.created"
EVT_SESSION_UPDATED = "session.updated"
EVT_SESSION_CLOSED = "session.closed"
EVT_TEXT_COMMITTED = "input_text.committed"
EVT_TEXT_CLEARED = "input_text.cleared"
EVT_RESPONSE_CREATED = "response.created"
EVT_RESPONSE_AUDIO_DELTA = "response.audio.delta"
EVT_RESPONSE_AUDIO_DONE = "response.audio.done"
EVT_RESPONSE_CANCELLED = "response.cancelled"
EVT_RESPONSE_FAILED = "response.failed"
EVT_SERVER_STATUS = "server.status"
EVT_ERROR = "error"

# The only ``text_format`` value v1 accepts. A non-``plain`` format
# (e.g. ``"ssml"``) is rejected with ``INVALID_CONFIG``.
TEXT_FORMAT_PLAIN = "plain"
SUPPORTED_TEXT_FORMATS = (TEXT_FORMAT_PLAIN,)


class ErrorCode(str, Enum):
    """Session-level error codes. Values mirror stt's enum, plus the two
    TTS-specific additions ``UNSUPPORTED_FORMAT`` and ``BUSY``."""

    INVALID_JSON = "invalid_json"
    INVALID_EVENT = "invalid_event"
    UNSUPPORTED_EVENT = "unsupported_event"
    INVALID_CONFIG = "invalid_config"
    BUFFER_EMPTY = "buffer_empty"
    PAYLOAD_TOO_LARGE = "payload_too_large"
    # TTS-specific: a requested audio_format is not the advertised
    # pcm16-at-model-rate.
    UNSUPPORTED_FORMAT = "unsupported_format"
    # TTS-specific: synthesis backlog full; ``error`` carries ``retry_after_ms``
    # (enforcement is Phase 3).
    BUSY = "busy"
    BACKEND_ERROR = "backend_error"
    UNAUTHORIZED = "unauthorized"
    INTERNAL_ERROR = "internal_error"


# OpenAI Realtime groups errors into a coarse ``type`` alongside the narrower
# ``code``; mirror that taxonomy so OpenAI-shaped clients can branch on
# ``error.type`` without parsing strings (parity with stt).
ERROR_TYPE_FOR_CODE: dict[ErrorCode, str] = {
    ErrorCode.INVALID_JSON: "invalid_request_error",
    ErrorCode.INVALID_EVENT: "invalid_request_error",
    ErrorCode.UNSUPPORTED_EVENT: "invalid_request_error",
    ErrorCode.INVALID_CONFIG: "invalid_request_error",
    ErrorCode.BUFFER_EMPTY: "invalid_request_error",
    ErrorCode.PAYLOAD_TOO_LARGE: "invalid_request_error",
    ErrorCode.UNSUPPORTED_FORMAT: "invalid_request_error",
    ErrorCode.BUSY: "rate_limit_error",
    ErrorCode.UNAUTHORIZED: "authentication_error",
    ErrorCode.BACKEND_ERROR: "server_error",
    ErrorCode.INTERNAL_ERROR: "server_error",
}
