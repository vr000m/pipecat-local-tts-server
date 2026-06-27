# Smoke tests

Live, end-to-end checks that start a **real server**, drive it with the
reference client over a real socket, and verify the full wire path
(`server.hello` → `session.update` → `input_text.commit` →
`response.audio.delta*` → WAV). The pytest suite mocks the model, so it does not
exercise this; these scripts do.

They run on an **isolated temp socket** (under `mktemp`), so they never touch a
running operator/launchd server on the canonical
`~/Library/Caches/pipecat-tts/tts.sock`.

## Running

```sh
# tone backend — no model, fast; verifies the protocol + rate contract
tests/smoke/run_smoke.sh

# kokoro backend, English (auto-runs `uv sync --extra kokoro` if needed)
tests/smoke/run_smoke.sh --backend kokoro

# kokoro, one utterance per supported language
tests/smoke/run_smoke.sh --backend kokoro --multilingual

# also play the audio through the speakers (macOS afplay)
tests/smoke/run_smoke.sh --backend kokoro --multilingual --play
```

Or via `just`:

```sh
just smoke-tone
just smoke-kokoro
just smoke-multilingual
just smoke-multiconn
```

## Multi-connection / backpressure (`run_multiconn.sh` + `multiconn_smoke.py`)

Two (or more) clients share one backend and **interleave** their requests, so
this exercises the server's concurrency + backpressure machinery that the
single-client flow never touches. Defaults to the **tone** backend: the
scheduler/caps live in the server (backend-agnostic), and tone is fast and
deterministic. `--backend kokoro` also works.

```sh
just smoke-multiconn                                  # 2 conns x 5 turns, tone
tests/smoke/run_multiconn.sh --connections 3 --turns 8
tests/smoke/run_multiconn.sh --backend kokoro
```

It asserts three things, and exits non-zero unless all hold:

1. **Interleaved turns** — N connections take strict round-robin turns
   (conn A turn 1, conn B turn 1, conn A turn 2, …), each fully synthesized and
   verified before the next, proving two sessions share the backend without
   cross-talk or starvation.
2. **Max-buffer guard** — each round's sentence grows (scaled to the advertised
   `max_text_chars`, default 2000); the final round exceeds the cap and MUST be
   rejected with `PAYLOAD_TOO_LARGE`. (The cap is enforced at `input_text.append`
   time, so the oversized turn never reaches synthesis.)
3. **429 / BUSY** — one connection fires two commits back-to-back without
   waiting for the first to finish. The second exceeds the **per-connection
   in-flight cap** (`PER_CONNECTION_INFLIGHT_MAX = 1`, checked before the global
   `SYNTHESIS_QUEUE_MAX = 8`) and MUST come back `BUSY` — the websocket-native
   429 (`error.type == rate_limit_error`, `retry_after_ms = 250`).

Note on "connection refused": there is **no max-connection cap** — the server
accepts unbounded sessions, so a true TCP refusal only happens if the server
isn't listening. The driver catches `ConnectionRefusedError` at connect and
reports it; the in-band overload signal is `BUSY`, not a refused connection.

Exit code is `0` only if every **required** case passed. Known-gap cases
(ja/zh, see below) report as `SKIP`, not failure.

## Language support: advertised vs. as-shipped

`server.hello.capabilities.languages` advertises only the languages this
deployment can actually synthesize. With the default `kokoro` extra
(`misaki[en]` only) that is **6**:

```
["en", "es", "fr", "hi", "it", "pt"]
```

`ja` and `zh` are dropped by default — the model ships voices for them, but their
G2P needs a package the extra does not install (see below). The table below was
verified live (mlx-community/Kokoro-82M-bf16, mlx-audio 0.4.4):

| Lang | Voice tested | Result | G2P path |
|---|---|---|---|
| en | af_heart  | ✅ works | misaki[en] |
| es | em_alex   | ✅ works | espeak-ng (bundled with misaki[en]) |
| fr | ff_siwis  | ✅ works | espeak-ng |
| it | if_sara   | ✅ works | espeak-ng |
| pt | pf_dora   | ✅ works | espeak-ng |
| hi | hf_alpha  | ✅ works | espeak-ng (slow first call — needs a long client timeout) |
| ja | jf_alpha  | ⛔ not advertised | needs **`misaki[ja]`** (`ModuleNotFoundError: pyopenjtalk`) |
| zh | zf_xiaoxiao| ⛔ not advertised | needs **`misaki[zh]`** (`ModuleNotFoundError: ordered_set`) |

**Out of the box, ja and zh are not advertised**, so a request for them is
rejected up front with `invalid_config` (before a synthesis slot is consumed)
rather than failing mid-response with `backend_error`. The smoke driver reports
them as `SKIP`.

To enable them — a two-step, build-time decision:

```sh
# 1. install the extra G2P backend(s)
uv pip install "misaki[ja]" "misaki[zh]"
# 2. opt the language(s) into the advertised set
export PIPECAT_TTS_KOKORO_EXTRA_LANGS=ja,zh
```

`hi` works but its **first** call loads espeak-ng's Hindi G2P lazily and can
exceed the reference client's 60 s default timeout — the smoke driver uses 180 s
for kokoro for this reason.

## Reconnect (`run_reconnect.sh` + `reconnect_smoke.py`)

The single-endpoint crash-restart-reconnect cycle the unit suite skips. The
driver owns the server lifecycle: start → synthesize → **SIGKILL** → restart →
client **reconnect-with-backoff** → synthesize again, then compares the audio
returned before the kill vs. after.

```sh
just smoke-reconnect                              # tone (fast)
tests/smoke/run_reconnect.sh --backend kokoro     # real voice samples
```

Design notes:

- **SIGKILL, not SIGINT.** A graceful Ctrl-C unlinks the socket on exit, so the
  restart never touches the auto-clear path. SIGKILL leaves the socket file
  behind (the crash / power-loss case the server's stale-socket reclaim exists
  FOR), so the restart must clear it — the stricter test. The driver asserts the
  socket is left stale and that a connect is refused while the server is down.
- **The backoff loop lives in the driver, not `TTSClient`.** `TTSClient` is
  connect-once by design — reconnect-with-backoff is the consumer's
  responsibility (R4). The driver's capped-exponential loop doubles as a
  reference for how a consumer reconnects, and it must ride out the **model
  reload on restart** (≈40 s for Kokoro; larger for voxtral/pocket — hence the
  180 s / 40-attempt defaults).
- **Per-backend, extensible.** Add a row to `DEFAULT_VOICE` in
  `reconnect_smoke.py` as new backends land. The before/after **sample-count**
  comparison (verified identical, 78000=78000, for Kokoro `af_heart`) is what
  catches reload-logic errors specific to each backend's implementation — a
  restart that returns no audio, fewer samples, or a different rate fails the
  verdict. Extending it to voxtral_tts/pocket_tts when they ship will surface any
  reconnect regressions from their streaming differences.

## Future work — streaming backends (Phase 5a/5b)

Every script here currently runs against a **`streaming:false`** backend (tone,
Kokoro), where each model segment is emitted as one delta. Once the streaming
backends land — **Phase 5a `voxtral_tts`** and **Phase 5b `pocket_tts`**, both
`streaming:true` — these smoke tests should be **re-run and extended**:

- Run `run_smoke.sh --backend voxtral_tts` / `pocket_tts` and `run_multiconn.sh
  --backend voxtral_tts`.
- Add a **streaming-cadence** assertion: `response.audio.delta` frames should
  arrive incrementally at roughly `streaming_interval`, not all at the end (the
  R4 steady-stream contract). The current drivers only check frames > 0.
- Re-confirm interleaving, the 429/BUSY in-flight cap, and the max-buffer guard
  still hold when audio streams sub-segment (the `streaming:true` client
  **no-split** path changes how much text a single commit carries).

Tracked as checkboxes under Phase 5b in
`docs/dev_plans/20260624-feature-tts-server-v1.md`.
