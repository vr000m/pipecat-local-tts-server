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
```

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
