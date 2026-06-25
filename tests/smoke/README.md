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

`server.hello.capabilities.languages` advertises **8** languages, derived from
the Kokoro voice-name prefixes:

```
["en", "es", "fr", "hi", "it", "ja", "pt", "zh"]
```

That list reflects the **model's** voices, not what the default `kokoro` extra
can actually phonemize. The extra pins `misaki[en]` only. Verified live
(mlx-community/Kokoro-82M-bf16, mlx-audio 0.4.4):

| Lang | Voice tested | Result | G2P path |
|---|---|---|---|
| en | af_heart  | ✅ works | misaki[en] |
| es | em_alex   | ✅ works | espeak-ng (bundled with misaki[en]) |
| fr | ff_siwis  | ✅ works | espeak-ng |
| it | if_sara   | ✅ works | espeak-ng |
| pt | pf_dora   | ✅ works | espeak-ng |
| hi | hf_alpha  | ✅ works | espeak-ng (slow first call — needs a long client timeout) |
| ja | jf_alpha  | ❌ `backend_error` | needs **`misaki[ja]`** (`ModuleNotFoundError: pyopenjtalk`) |
| zh | zf_xiaoxiao| ❌ `backend_error` | needs **`misaki[zh]`** (`ModuleNotFoundError: ordered_set`) |

**Out of the box, ja and zh fail at synthesis time** with
`response.failed / code=backend_error`. The server handles this gracefully (no
crash; the session stays usable), but a client trusting the advertised language
list would hit a runtime failure for those two.

To enable them, install the extra G2P backends, e.g.:

```sh
uv pip install "misaki[ja]" "misaki[zh]"
```

`hi` works but its **first** call loads espeak-ng's Hindi G2P lazily and can
exceed the reference client's 60 s default timeout — the smoke driver uses 180 s
for kokoro for this reason.

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
