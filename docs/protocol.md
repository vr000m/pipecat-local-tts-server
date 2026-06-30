# pipecat-local-tts-server — WebSocket Protocol (v0.1)

**`PROTOCOL_VERSION = "0.1"`**

This is the wire contract for the local TTS server: **text in, audio out** over a
WebSocket. It is the authoritative reference that Phase 1 (`tts_server/protocol.py`)
implements and that clients (incl. the reference client in `examples/reference_client.py`)
speak. It mirrors the sibling `pipecat-local-stt-server` protocol philosophy
(OpenAI-Realtime-inspired event subset) inverted for synthesis.

> Status: design spec, authored ahead of implementation (dev plan
> `docs/dev_plans/20260624-feature-tts-server-v1.md`). Where a value is a backend fact it
> is marked **VERIFIED** (mlx-audio 0.4.4, 2026-06-24); where it is a chosen default it is
> marked so. Exact `ErrorCode` string values mirror stt's enum and are pinned in
> `protocol.py` at implementation; this doc lists their semantics.

---

## 1. Transport

- **Default:** WebSocket over a **Unix domain socket**.
- Also: `ws://host:port` and a full WebSocket URI.
- **Endpoint precedence:** `URI > socket > host+port`. Env vars `TTS_WS_*` mirror
  `STT_WS_*`.
- **Auth (optional):** bearer token. Server reads `PIPECAT_TTS_AUTH_TOKEN`; client reads
  `TTS_WS_TOKEN` (the client MUST NOT fall back to the server's env var). A server with a
  token set rejects unauthenticated connections (`unauthorized`). A token-less server bound
  to a **non-loopback TCP** address logs a cleartext-remote warning; a Unix socket does not.

## 2. Message envelope & encoding

Every message is a **JSON text frame**, an object with a `type` field naming the event,
plus event-specific fields:

```jsonc
{ "type": "input_text.commit", "event_id": "evt_123", /* …event fields… */ }
```

- `type` (string, required) — the event name (tables below).
- `event_id` (string, optional on client→server; always present server→client) — server
  mints its own ids. If a client supplies `event_id`, the server echoes it as
  `previous_event_id` on the correlated reply so the client can match request→response
  without tracking server ids.
- **Audio is base64-in-JSON for v1** (`binary_audio: false`); binary frames are a later
  optimization. Audio bytes are carried in `response.audio.delta.audio` as base64.

### Audio format (the rate contract)

- **Format:** `pcm16` — signed 16-bit little-endian PCM, **mono**.
- **Rate:** the single value advertised in `server.hello.audio.rate` (per-backend; Kokoro
  = **24000**, VERIFIED). This is a **correctness contract**: every `response.audio.delta`
  frame for the session is int16-LE mono at *exactly* that rate, constant across an
  utterance (no per-utterance drift). The client resamples model-rate → device-rate off this
  one value; a wrong/variable rate distorts pitch/speed.
- **Wire frame size:** 20 ms (chosen default) — the server re-chunks native model segments
  into fixed 20 ms frames. The **final frame of a response MAY be short**; no silence
  padding is added.
- **float→int16 mapping (asymmetric, full-range):** clip the model's float32 sample to
  `[-1.0, 1.0]`, then map **negative samples ×32768, non-negative ×32767** so
  `-1.0 → -32768` and `+1.0 → +32767`. (The `[-1,1]` range is observed for Kokoro, not a
  decoder-guaranteed bound — clipping prevents int16 overflow/clicks on an outlier.)

---

## 3. Session lifecycle

```
connect ─▶ server.hello ─▶ [session.update ⇄ session.updated]*
        ─▶ input_text.append* ─▶ input_text.commit
        ◀─ input_text.committed{response_id} ◀─ response.created{response_id}
        ◀─ response.audio.delta{seq=0..N} … ◀─ response.audio.done{duration_ms}
```

1. **Connect** (optionally with bearer auth).
2. Server sends **`server.hello`** with the protocol version, backend identity, audio
   format/rate, and `capabilities`. (The rate is read from the loaded model, so the server
   completes model load **before** sending `hello`.)
3. Client optionally sends **`session.update`** to set voice/model/language/extras; server
   replies `session.created` (first) / `session.updated`.
4. Client streams text with **`input_text.append`** (accumulates in a per-session buffer).
5. Client sends **`input_text.commit`** to synthesize the buffered text. The server
   allocates a `response_id`, emits `input_text.committed` then `response.created`, streams
   `response.audio.delta` frames (`seq` from 0, +1 per frame, no gaps), and finishes with
   `response.audio.done`. The buffer is consumed by the commit.
6. **Barge-in:** `response.cancel` stops the active response (`response.cancelled`); no
   further `delta` for that `response_id` follows.

**The client segments the text; the commit is the unit of work.** Using
`capabilities.streaming` and `capabilities.ideal_words`, the client splits long text into
commits, **rounding `ideal_words` up to the next sentence boundary — never splitting
mid-sentence** (a half-sentence commit makes the model apply sentence-final prosody
mid-phrase: measured +22% duration and a ~389 ms spurious pause on Kokoro). `max_text_chars`
is the hard server cap (reject beyond it).

**Per-connection isolation:** each connection has its own session state (text buffer,
config, `response_id` space). Connections never see each other's text or audio. The model and
its GPU (Metal) lock are shared; the server schedules commits round-robin across connections,
holding the lock for the duration of one commit.

---

## 4. Client → server events

| `type` | Fields | Meaning |
|---|---|---|
| `session.update` | `{voice?, model?, language?, audio_format?, extras?}` | Set session config. **Unknown top-level fields → `error{code: invalid_config}`** (a typo'd key is not silently ignored). `audio_format` (if present) MUST equal the advertised pcm16-at-rate; any other value → `error{code: unsupported_format}`. `language` (if present) MUST be one of `capabilities.languages` → else `invalid_config`. `model` (if present) MUST equal the loaded `server.hello.backend.model` — v1 loads one model at process start and has **no per-session model switching**, so any other value → `invalid_config` (the server never silently acks a model it will not synthesize with). `extras` keys MUST be a subset of `capabilities.extras`; unknown *extras* keys are dropped (debug-logged), not errored. |
| `input_text.append` | `{text, text_format?}` | Append text to the session buffer. `text_format` defaults to `"plain"`; any non-advertised format (e.g. `"ssml"`) → error. |
| `input_text.commit` | `{voice?, language?, extras?}` | Synthesize the buffered text as one response. **No `audio_format` field** — sending one is an unknown-field protocol error (`invalid_config`); any other unknown top-level field is likewise `invalid_config`. `language` (if present) MUST be one of `capabilities.languages` → else `invalid_config`. |
| `input_text.clear` | `{}` | Drop uncommitted buffered text. Replies `input_text.cleared`. |
| `response.cancel` | `{response_id?}` | Cancel the active response (barge-in). With v1 `K=1` (one active/queued response per connection) `response_id` is optional and unambiguous. If no active response matches (idle session, or a stale/mismatched `response_id` — e.g. a cancel that races a just-finished response), this is a **no-op**: no `response.cancelled` is emitted. |
| `session.cancel` | `{}` | Discard the in-flight response and any queued work (discard semantics). Server replies `session.closed{reason: "client_cancel"}`, then closes the socket. |
| `session.close` | `{}` | Graceful close: drain the in-flight response, then close. Server replies `session.closed{reason: "client_close"}`, then closes the socket. |
| `server.status` | `{}` | Request a `server.status` snapshot. |

## 5. Server → client events

| `type` | Fields | Meaning |
|---|---|---|
| `server.hello` | `{protocol_version, backend:{name,model}, audio:{format,rate,channels}, capabilities}` | Sent once on connect. `audio.rate` is the canonical rate (§2). |
| `session.created` / `session.updated` | `{…}` | Ack of the session config (created on first `session.update`, updated after). |
| `input_text.committed` | `{response_id}` | The commit was accepted; synthesis starts. |
| `input_text.cleared` | `{}` | The uncommitted buffer was cleared. |
| `response.created` | `{response_id}` | A response has begun. |
| `response.audio.delta` | `{response_id, seq, audio}` | One audio frame. `seq` starts at 0 and increments by 1 with no gaps per `response_id`. `audio` is base64 pcm16 (20 ms, last frame MAY be short). |
| `response.audio.done` | `{response_id, duration_ms}` | Synthesis finished. `duration_ms` is from the original sample count (not `frames × 20 ms`). Fired on generator exhaustion. |
| `response.cancelled` | `{response_id}` | The response was cancelled; no further `delta` for it. Emitted **only** when an active response was actually cancelled (see `response.cancel` in §4) — `response_id` is always a concrete id, never null. |
| `response.failed` | `{response_id, error?}` | The response errored mid-synthesis; carries `{code, message}`. The session stays usable. |
| `session.closed` | `{session_id, reason}` | Sent in reply to `session.cancel` (`reason: "client_cancel"`) or `session.close` (`reason: "client_close"`) immediately before the server closes the socket. |
| `server.status` | `{backend:{name,model}, audio:{…}, …queue/voice info}` | Health/status snapshot. |
| `error` | `{code, message, retry_after_ms?}` | Session-level error. `retry_after_ms` is present iff `code == busy` (synthesis-backlog backpressure, §7). |

---

## 6. `capabilities` (in `server.hello`)

Built **per backend** — never copied across backends. **Shipped backends:** `kokoro`
(`streaming:false`, Apache-2.0), `voxtral_tts` (`streaming:true`, CC-BY-NC weights),
`pocket_tts` (`streaming:true`, CC-BY-4.0 weights), `dia` (`streaming:false`,
multi-speaker **dialogue**, `voice_count:0`, Apache-2.0 weights — see README →
*Backends & licenses*), and the dependency-free `tone` reference. Kokoro example
(fields VERIFIED via `scripts/verify_mlx_tts_api.py --load`, 2026-06-24, mlx-audio 0.4.4):

```jsonc
{
  "streaming": false,            // no sub-segment streaming (segment-level still streams)
  "binary_audio": false,         // base64-in-JSON for v1
  "text_formats": ["plain"],     // ssml/ipa not yet supported for Kokoro
  "languages": ["en","es","fr","hi","it","pt"],  // synthesizable set; ja/zh off by default (need extra G2P — opt in via PIPECAT_TTS_KOKORO_EXTRA_LANGS)
  "voice_count": 54,             // VERIFIED (mlx-community/Kokoro-82M-bf16)
  "extras": ["speed"],           // Kokoro's effective generate() kwargs ONLY
  "ideal_words": 40,             // soft target; client rounds UP to a sentence boundary (chosen default)
  "max_text_chars": 2000         // hard server cap (chosen default)
}
```

| Field | Type | Meaning |
|---|---|---|
| `streaming` | bool | `true` ⇒ the backend streams sub-segment audio; client MAY send larger commits. `false` ⇒ client SHOULD chunk at sentences (else slow generation *and* no audio until the segment finishes). Either way the server emits each native segment as it completes. |
| `binary_audio` | bool | `false` for v1 (audio is base64-in-JSON). |
| `text_formats` | string[] | Accepted `text_format` values. Only `"plain"` for Kokoro v1. |
| `languages` | string[] | ISO codes the backend supports (backend maps ISO → its own code, e.g. Kokoro `lang_code`). A `language` outside this list is rejected with `invalid_config` — the server validates before synthesis; it is **not** silently coerced to a default. |
| `voice_count` | int | Number of distinct voices. Full list via `server.status`. `0` ⇒ the backend has **no voice concept** (e.g. `dia`, whose speakers are addressed in-text); the server then **accepts** a supplied `voice` rather than rejecting it, and the backend ignores it. |
| `extras` | string[] | Names of `generate()` kwargs the backend forwards. **Per-backend, real-and-effective only** (a kwarg the model ignores is dropped, never advertised). Kokoro→`["speed"]`; voxtral_tts→`["temperature","top_k","top_p"]`; pocket_tts→`["temperature"]`; dia→`["temperature","top_p"]`. `ref_audio` is **never** advertised (no voice cloning in v1). |
| `ideal_words` | int | Soft per-commit size hint; client rounds **up to the next sentence boundary**. Not a hard limit. |
| `max_text_chars` | int | Hard cap on buffered text per commit; over-limit → error. |

### `dia` dialogue text + the `text_formats` overload (Option A, and the Option B upgrade path)

`dia` is a multi-speaker **dialogue** backend: a client addresses speakers purely
in-text with `[S1]`/`[S2]` tags inside an ordinary `text_format: "plain"` payload
(`voice_count: 0`; `voice` is ignored). The server does **not** parse or interpret
the tags — it forwards the committed buffer to `generate()` untouched, so the
dialogue contract lives **only in client convention** (this is the deliberate
"Option A — no server-side change"; `text_formats` stays `["plain"]`).

**Accepted cost (prominent on purpose):** because dialogue text rides inside
`plain`, the wire format is undocumented and the server cannot tell dialogue text
from ordinary plain text. It therefore **cannot reject** `[S1]`/`[S2]` tags aimed at
a non-dialogue backend — Kokoro would read them aloud literally (e.g. "bracket S
one"). This is a silent-misrender vector the moment a second dialogue-aware consumer
or a mixed-backend deployment appears.

**Option B (deferred upgrade path):** if a fail-loud guarantee is later wanted, make
`text_formats` a genuine per-backend capability and the server's text-format
validation capability-driven (advertise e.g. `dialogue` for `dia`, reject it for
backends that don't list it). This is the documented upgrade from the Option A
overload — not optional once mixed-backend or multi-consumer deployments arrive.

---

## 7. Errors & backpressure

`error {code, message, retry_after_ms?}`. Codes mirror stt's `ErrorCode` enum plus TTS
additions:

The wire envelope is **nested**, mirroring OpenAI-Realtime: the top-level frame carries
`type: "error"` and an `error` object that repeats an OpenAI-style `type` (derived from the
code) alongside `code`/`message`. When the offending client frame supplied an `event_id`, the
error echoes it **both** at the top level as `previous_event_id` (the same request→response
correlation field every other reply uses — so a client can tell an error for *this* command
apart from a stale error left by an earlier command on a persistent connection) and inside the
`error` object as `event_id` (for OpenAI-shaped readers). For `busy`, `retry_after_ms` appears
**both** at the top level and inside the `error` object:

```json
{
  "type": "error",
  "event_id": "evt_a1b2c3",
  "previous_event_id": "<client frame id, if any>",
  "error": {
    "type": "rate_limit_error",
    "code": "busy",
    "message": "synthesis backlog full",
    "retry_after_ms": 1200,
    "event_id": "<client frame id, if any>"
  },
  "retry_after_ms": 1200
}
```

A non-`busy` error omits both `retry_after_ms` fields, e.g. `error.type:
"invalid_request_error"`, `code: "unsupported_format"`. The `error.type` values are
`invalid_request_error` (the `invalid_*`/`buffer_empty`/`payload_too_large`/`unsupported_format`
codes), `rate_limit_error` (`busy`), `authentication_error` (`unauthorized`), and `server_error`
(`backend_error`/`internal_error`). `response.failed` carries the same `error` object (without
the top-level `error`-frame wrapper) under its `response_id`.

| Code | When |
|---|---|
| `invalid_json` | Frame is not valid JSON. |
| `invalid_event` / `unsupported_event` | Missing/unknown `type`. |
| `invalid_config` | Bad `session.update`/`commit` field — incl. an **unknown field** like `audio_format` on `commit`, or an extra colliding with a fixed param. |
| `buffer_empty` | `input_text.commit` with no buffered text. |
| `payload_too_large` | Text exceeds `max_text_chars`. |
| `unsupported_format` | **TTS-specific.** `session.update.audio_format` is not the advertised pcm16-at-rate. |
| `busy` | **TTS-specific.** Synthesis backlog full (see below); carries `retry_after_ms`. |
| `backend_error` | Synthesis raised (also surfaced as `response.failed` when a response was in flight). |
| `unauthorized` | Auth required/failed. |
| `internal_error` | Unexpected server fault. |

**Two distinct backpressure mechanisms (do not conflate):**

1. **Outbound (slow reader):** if the client stops reading, the per-connection send queue
   hits its high-water mark and the server **closes the connection** rather than buffering
   unboundedly. A stalled reader is a client bug.
2. **Inbound (synthesis backlog):** there is one shared model + Metal lock. A bounded global
   synthesis queue admits commits round-robin across connections. When it is full, a new
   `input_text.commit` is **rejected, not enqueued**, with `error {code: busy, retry_after_ms}`.
   A per-connection in-flight cap (v1 `K=1`) stops one app from starving others.

**Recommended client retry (outside the wire contract):** on `busy`, hold the text and retry
after `retry_after_ms` with capped backoff + jitter, giving up after ~5 retries. The server's
queue cap protects it regardless of client behavior.

**Slot accounting on cancel (server-internal guarantee):** the server holds a commit's
synthesis-queue slot until the backend worker has fully **exited and released the process-wide
GPU/Metal lock** — not merely until the drain task was cancelled. `response.cancel` only
*requests* a break, honoured at the next yield boundary, so a long single-segment `generate()`
can keep the lock for tens of seconds after `response.cancelled` was sent. By deferring the
slot release until the lock is actually free, `queue_depth` and `busy` admission never advertise
free capacity that a subsequent `commit` would immediately block on. Backends with no
worker/lock (e.g. the tone backend) release the slot immediately. This is observable only as
honest `queue_depth` in `server.status`; it does not change any wire frame.

---

## 8. Notes for implementers / clients

- **Steady stream:** once `response.created` fires, audio must arrive continuously — the
  server emits each segment as it completes (does not buffer the whole utterance) and never
  stalls mid-response. Clients carry a deep playback buffer (gamealerts uses 8192 frames) to
  absorb normal jitter.
- **Cancel latency:** cancellation lands at the next model yield/segment boundary. The hard
  guarantee is "no more `delta` after `response.cancelled`"; sub-segment promptness for long
  single-segment utterances depends on the backend.
- **Reordering:** reassemble audio strictly by `(response_id, seq)`.
- **Versioning:** clients SHOULD check `server.hello.protocol_version`; `"0.1"` is the
  current contract.
