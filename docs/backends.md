# Backends

Choose a backend by latency, language, voice, model license, and text-control needs.
The root [README](../README.md) keeps the shortest install path; this guide is the
canonical reference for shipped backend behavior.

> Model licenses are third-party terms, not this package's license. The wording
> below preserves the repository's documented snapshot and qualifiers; it is not
> legal advice or a fresh legal review. Re-check upstream terms before deployment.

## Install a backend

Choose the extra that matches the backend name:

```sh
# PyPI consumer
uv add "pipecat-local-tts-server[kokoro]"
uv add "pipecat-local-tts-server[voxtral_tts]"
uv add "pipecat-local-tts-server[pocket_tts]"
uv add "pipecat-local-tts-server[dia]"
uv add "pipecat-local-tts-server[qwen3_tts]"
uv add "pipecat-local-tts-server[fish_tts]"
uv add "pipecat-local-tts-server[phonon]"

# Source checkout: use the same extra name
uv sync --extra kokoro
```

The base package is the lean client install. `uv sync --extra examples` adds the
reference Pipecat adapter and its pinned framework dependency. Model extras are
Apple-Silicon MLX runtimes; `tone` stays dependency-free for protocol testing.
Every model extra pins `mlx-audio==0.6.1`. Kokoro also installs `misaki[en]`,
whose G2P stack brings heavier packages such as spaCy, num2words, and Torch;
Voxtral TTS additionally installs `mistral-common[audio]`. These dependencies
remain isolated from the lean base by design.

## Backends & licenses

Each backend is its own extra; weights have their own licenses — **the package
ships only runtime code, never weights** (they download on first `serve`).
Operators are responsible for honouring each model's license.

| Backend | Extra | `streaming` | Model | Weights license |
|---|---|---|---|---|
| `tone` | (base) | `false` | none (synthetic sine) | — |
| `kokoro` | `kokoro` | `false` | mlx-community/Kokoro-82M-bf16 | Apache-2.0 (commercial-safe) |
| `voxtral_tts` | `voxtral_tts` | `true` | mlx-community/Voxtral-4B-TTS-2603-mlx-bf16 | **CC-BY-NC (non-commercial)** |
| `pocket_tts` | `pocket_tts` | `true` | mlx-community/pocket-tts | CC-BY-4.0 (commercial OK w/ attribution) |
| `dia` | `dia` | `false` | mlx-community/Dia-1.6B-fp16 | Apache-2.0 (commercial-safe) |
| `qwen3_tts` | `qwen3_tts` | `true` | mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16 | apache-2.0 (HF card tag; no LICENSE file in the repo) |
| `fish_tts` | `fish_tts` | `false` | mlx-community/fish-audio-s2-pro | **Fish Audio Research License (non-commercial; commercial requires separate agreement)** |
| `phonon` | `phonon` | `true` | gradium/phonon-31m-en | Apache-2.0 (weights, tokenizer and voices; commercial use allowed) |

> **Kokoro is the default commercial-safe backend.** `voxtral_tts` weights are
> **CC-BY-NC** — do not use them in a commercial deployment. `pocket_tts`
> (CC-BY-4.0), `dia` (Apache-2.0), and Kokoro (Apache-2.0) are commercial-safe
> (pocket needs attribution). The choice of backend (and thus of model license)
> is the operator's. `fish_tts` is the **second** backend under restrictive
> terms (`voxtral_tts`'s CC-BY-NC being the first) and the first under a
> *research-only* license: free for research and non-commercial use, royalty-
> free, worldwide, non-exclusive, non-transferable, non-sublicensable, and
> revocable — **no commercial rights are granted** without a separate written
> license agreement from Fish Audio (contact: `business@fish.audio`). See
> *fish_tts capabilities* below.

> **Phonon**: the model card for `gradium/phonon-31m-en` states the weights,
> tokenizer and voices are released under Apache-2.0, which allows commercial
> use. The larger `gradium/phonon-40m-*` siblings are **CC-BY-NC-4.0 and gated**
> (their Hugging Face card metadata as of 2026-10-21, recorded in the Phonon dev plan's
> Phase 0 findings; re-check the cards before relying on it); they are not supported
> here (the backend targets the 31M English model only).

## Phonon capabilities and voice selection

`phonon` is `streaming:true`, 24 kHz, `languages: ["en"]`, `max_text_chars: 2000`,
with `default` (the model's own shipped voice) always advertised; `voice_count` is
`default` plus the enabled voices that resolved (1 when `PIPECAT_TTS_PHONON_VOICES` is
unset). Latency/RTF: see the [profiling results](../scripts/profiling/README.md).

**Keep sentences short.** mlx-audio generates per sentence and never splits inside
one, and the model ends a sentence chunk at about 45 s of audio. Rather than return a
clipped response as a clean completion, the server fails it: a run-on sentence of ~200+
words ends in `response.failed` (`BACKEND_ERROR`, with the generic client message
"backend synthesis failed"; the "a sentence chunk hit the model's ~45 s limit" detail is
in the server log only), after the first ~45 s of audio has already streamed. Measured 2026-10-22 on the
full-precision weights (default voice), one-sentence run-ons of 100 / 160 / 200 / 400 words
returned 24.8 / 36.6 / 45.1 / 45.1 s of audio, so roughly 160 words fit (approximate; it
depends on the words). Punctuated text is unaffected: in the Phase 0 gate
([`phonon_phase0_gate.py`](../tests/smoke/phonon_phase0_gate.py), recorded in the Phonon dev plan's findings) a
2008-character, 376-word commit returned the full 112.4 s.
`max_text_chars` does not guard this, so chunk text at sentence boundaries. The guard is
on only for the pinned model revision (the default repo id and the `phonon` / `phonon-q8` /
`phonon-q4` aliases). It starts OFF, with a warning, for an unpinned `--model` (another
repo id or a local path), for a pinned repo or revision without a measured ceiling, and
when the installed mlx-audio lacks the chunk method; the ~45 s ceiling was measured only
on the pinned weights, so such a model can still return a clipped sentence as a clean
completion.

**Quantized weights.** `--model` also accepts three aliases: `phonon` (the pinned
`gradium/phonon-31m-en`, full precision, same as the default), `phonon-q8` and
`phonon-q4`. The quantized aliases convert the same pinned snapshot once (about a
second) and load the result. This lowers memory, disk and load time only; TTFB and RTF
are unchanged. The quality of `phonon-q4` has not been judged by ear; full precision
stays the default. The converted weights are cached under
`$XDG_CACHE_HOME/pipecat-tts-server/phonon/` (default `~/.cache/...`), keyed by pin,
bit width and mlx-audio version, so a pin or mlx-audio change re-converts. A convert
killed mid-run (`kill -9`, power loss) strands a `.<name>.tmp-<pid>-<tid>` sibling
directory; the next start of a quantized alias removes such directories once they are
more than ten minutes old. The server reports the alias you passed as its `model`.

```sh
uv run python -m tts_server serve --backend phonon --model phonon-q8
```

Extra voices are chosen **ahead of time by the operator** with the server env var
`PIPECAT_TTS_PHONON_VOICES` (comma-separated catalog slugs, e.g.
`zoey,juniper`; no CLI flag). Only listed voices are downloaded (one file
each) and advertised; an unknown or unfetchable slug is warned about and skipped,
and a client asking for a skipped voice gets `invalid_config`. A resolved voice file
must be an absolute, existing `.safetensors` path (no `@`) or it is skipped the same
way. For a launchd agent,
export it when running `just tts-install phonon` (it is validated and baked into
the plist). The catalog is 102 voices (en/fr/de/es/pt; the model is English, so
non-English voices log a warning):

```sh
uv run python -m tts_server voices                  # slug, lang, enabled, cached (? = unknown, no huggingface_hub)
uv run python -m tts_server voices --language en
uv run python -m tts_server voices --refresh        # diff live voices.jsonl (added/removed/changed, duplicate/invalid slugs); changes nothing
PIPECAT_TTS_PHONON_VOICES=zoey,juniper just smoke-phonon
```

## Voxtral TTS capabilities (as shipped)

> Capability/latency figures in the per-backend sections below were measured on
> mlx-audio 0.4.4; the pin is now 0.6.1 and an A/B re-run showed no steady-state
> TTFB/RTF change (see the [profiling results](../scripts/profiling/README.md)).

`streaming:true` sub-segment streamer (native `stream`/`streaming_interval`,
locked to 0.3 s — measured TTFB 0.395 s, see the dev-plan Findings). Verified
against mlx-community/Voxtral-4B-TTS-2603-mlx-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | genuine sub-segment streaming; client MAY pass larger text |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en","fr","es","de","it","pt","nl","ar","hi"]` | from the 20 voice presets; language is selected by the voice preset (no `lang_code` kwarg) |
| `voice_count` | `20` | full list via `status` (e.g. `casual_male`, `fr_female`) |
| `extras` | `["temperature","top_k","top_p"]` | Voxtral's effective sampling kwargs (`ref_audio` is absent → no cloning; `streaming_interval` is backend config, not advertised) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

## Pocket TTS capabilities (as shipped)

`streaming:true` sub-segment streamer and **fast** (RTF ≈ 0.05–0.13× on-host).
The voice-cloning channel (`ref_audio`) and undocumented `frames_after_eos` are
**deliberately unwired** (decision #2 — no cloning in v1). Verified against
mlx-community/pocket-tts (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | genuine sub-segment streaming |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en"]` | English verified on-host (Pocket has no `lang_code` kwarg) |
| `voice_count` | `8` | `alba`, `marius`, `javert`, `jean`, `fantine`, `cosette`, `eponine`, `azelma` (via `status`) |
| `extras` | `["temperature"]` | Pocket's only effective sampling kwarg (`ref_audio`/`frames_after_eos` never advertised; `streaming_interval` is backend config) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

## dia capabilities (as shipped)

A multi-speaker **dialogue** backend, `streaming:false` and segment-level
(`split_pattern='\n'`, like Kokoro). Speakers are addressed **purely in-text** via
`[S1]`/`[S2]` tags inside an ordinary `plain` payload — the server forwards the
buffer untouched and never parses the tags. There is **no voice concept**
(`voice_count: 0`): a supplied `voice` is accepted by the server and structurally
ignored by the backend. No voice cloning (`ref_audio`/`ref_text` left unwired,
decision #2). Verified against mlx-community/Dia-1.6B-fp16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **44100** | from `server.hello.audio.rate`, read from `model.sample_rate` (NOT 24000) |
| `streaming` | `false` | no sub-segment streaming; each `\n`-separated turn streams as it completes |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | dialogue `[S1]`/`[S2]` tags ride **inside** plain text (see the [protocol](protocol.md), §6, Option A/B) |
| `languages` | `["en"]` | English verified on-host |
| `voice_count` | `0` | no enumerable voices; speakers are in-text `[S1]`/`[S2]` tags |
| `extras` | `["temperature","top_p"]` | dia's effective sampling kwargs (`ref_audio`/`ref_text` never advertised — no cloning) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

> **A commit is the unit of coherence.** dia is autoregressive *within* a single
> commit (every turn conditions on the others) but **stateless across commits**
> (context resets at the boundary). Committing the whole dialogue at once maximises
> cross-turn coherence; incremental commits lower latency at the cost of a coherence
> reset per commit (both are supported). Never split a single `[S1]…` turn across
> two commits. See the dev plan's *Resolved design decisions* #3.

## dia cancellation caveat

dia (like Kokoro) yields one segment per `\n` boundary and the cancel flag is
only checked at a segment boundary. The **client-visible** cancel is prompt
regardless: a `response.cancel` is acknowledged with `response.cancelled` in
~1 ms and no audio follows it. What runs to the segment boundary is the backend
worker / Metal lock: because dia decodes at **RTF ≈ 2.0** (≈ 2× slower than real
time — a model floor, not server overhead), a **long single-segment** commit
holds the lock until its `generate()` reaches the yield (which can be tens of
seconds for a full turn, bounded by `drain_timeout_seconds`), so the *next*
commit can't start synthesizing until then. To free the lock sooner for
back-to-back commits, **chunk at sentence/newline boundaries** — incremental
commits also shorten the first-segment generate that dominates TTFB. The
server's hard guarantee is "no more audio after `response.cancelled`". (See
the [profiling results](../scripts/profiling/README.md) for measured RTF and per-segment latency.)

## Qwen3-TTS capabilities (as shipped)

A genuine sub-segment streamer (native `stream=True`, ~0.4 s of audio per chunk).
The default model is the **CustomVoice** variant, which REQUIRES a speaker: when
the client sends no `voice`, the backend injects **`ryan`**. The `Base` variant
(`--model mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16`) has no speakers
(`voice_count: 0`); any supplied `voice` is accepted by the server and discarded
by the backend (speaker-unconditioned output, dia-style). No voice cloning or
`instruct` styling (never wired). Verified against
mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, read from `model.sample_rate` |
| `streaming` | `true` | native sub-segment streaming (~5 codec tokens ≈ 0.4 s per chunk; TTFB ~0.13 s) |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | |
| `languages` | dynamic | model-native FULL-WORD codes (`"english"`, `"chinese"`, …, plus `"auto"`) — NOT ISO 639-1; consult `capabilities.languages` before sending `language` |
| `voice_count` | `9` | CustomVoice speakers, all-lowercase (`ryan`, `aiden`, `serena`, …); `0` on Base |
| `extras` | `["temperature","top_k","top_p"]` | cloning/style/control kwargs are actively filtered, never advertised |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | **`800`** | hard server cap — LOWER than the siblings' 2000 (see below) |

> **A whole commit renders as ONE generation** — `generate_custom_voice()` has no
> `\n` splitting, and mlx-audio's `max_tokens=4096` single-generation ceiling
> (≈328 s of audio) truncates SILENTLY when hit. Degenerate/repetitive text can
> pace as badly as ~0.19 s of audio per character, so the 800-char cap keeps the
> worst case at ~2x margin under the ceiling; the backend also counts codec
> tokens per generation segment and, if the ceiling is ever reached, FAILS the
> response (`response.failed` with `BACKEND_ERROR`) rather than completing with
> silently missing audio. Commit shorter chunks for long content.

## fish_tts capabilities (as shipped)

A `streaming:false`, segment-level backend (mirrors the `dia` template —
`generate(stream=True)` raises `NotImplementedError` upstream, so every commit's
batches drain through the same non-streaming bridge). There is **no voice
concept** (`voice_count: 0`): Fish's `generate()` deletes its `voice` parameter
unconditionally, so a supplied `voice` is accepted by the server and structurally
discarded by the backend — even more absolute than `dia`'s discard, since Fish
never even inspects the value. No voice cloning (`ref_audio`/`ref_text` left
unwired, decision #2 — the **"Option A accepted cost"**: the WS protocol has no
reference-audio transport, so this is out of scope, not merely unwired by
convenience). Verified against mlx-community/fish-audio-s2-pro (mlx-audio 0.4.4,
Phase 0 gate):

| Field | Value | Note |
|---|---|---|
| rate | **44100** | from `server.hello.audio.rate`, read from `model.sample_rate` (NOT 24000, matches `dia`) |
| `streaming` | `false` | segment-level; one `GenerationResult` per text batch |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | `<|speaker:N|>` and `[tag]` markup ride **inside** plain text (see the [protocol](protocol.md), §6, Option A/B) |
| `languages` | 38-language static list (`en`, `zh`, `ja`, `ko`, `es`, …) | from the upstream model card (Phase 0 Q6); no `language` kwarg exists in `generate()`'s signature |
| `voice_count` | `0` | no enumerable voices; speakers (if any) are addressed via in-text `<|speaker:N|>` tags |
| `extras` | `["temperature","top_k","top_p","instruct"]` | fish's effective sampling kwargs, plus `instruct` — the first backend to advertise a string-typed style-control extra (`ref_audio`/`ref_text` never advertised — no cloning) |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | **`500`** | hard server cap — well below kokoro/voxtral_tts/pocket_tts/dia's 2000 (qwen3_tts is lower still, at 800); derived from Phase 0's per-batch token-ceiling calibration, not from license class — a truncation tripwire (`FishTruncationError` → `response.failed`/`BACKEND_ERROR`) also guards the real per-batch token ceiling (see the dev plan Findings for the calibration) |

**Multi-speaker tag syntax — `<|speaker:N|>` — is NOT `dia`'s `[S1]`/`[S2]`
syntax.** A caller must pick the right dialect for the backend it targets; the
server cannot disambiguate or reject a wrong-dialect tag (same "Option A
accepted cost" as `dia` — e.g. a fish `<|speaker:1|>` tag sent to Kokoro would be
read aloud literally, not interpreted). Example:

```text
<|speaker:0|>Hello, how are you today?
<|speaker:1|>I'm doing well, thanks for asking!
```

**Mixed-input rejection:** untagged prose preceding the *first* `<|speaker:N|>` tag
would otherwise be silently dropped by the model's own text-splitting logic. The
server rejects it at commit time instead, with `error {code: "invalid_config"}` —
don't mix an untagged lead-in with tagged turns in the same commit; the commit
will fail with a clear error rather than silently losing the lead-in.

**Cross-batch context sharing:** consecutive `<|speaker:N|>`-tagged turns within
one committed utterance share generation context — each batch's prompt includes
the previous batch's audio codes, so a caller composing multi-turn tagged text
should expect that context-sharing, not independent per-turn generation
(Phase 0 gate Q1, confirmed on this machine).

**Inline `[tag]` emotion/expression markup** is free-form bracketed text,
accepted anywhere in the payload without server-side validation. The example
vocabulary below is the same 34 example tags from the installed mlx-audio
package's `fish_qwen3_omni/README.md` ("Fine-Grained Inline Control" section,
regrouped thematically here rather than kept in upstream's original order) — the source
itself frames these as *"Examples include"* free-form textual descriptions for
open-ended expression control, i.e. the mechanism is open-ended and other
bracketed descriptions may also work, untested:

`[pause]` `[short pause]` `[emphasis]` `[laughing]` `[laughing tone]`
`[chuckle]` `[chuckling]` `[tsk]` `[singing]` `[excited]` `[excited tone]`
`[interrupting]` `[volume up]` `[volume down]` `[loud]` `[low volume]`
`[low voice]` `[echo]` `[angry]` `[sigh]` `[whisper]` `[screaming]`
`[shouting]` `[surprised]` `[shocked]` `[delight]` `[sad]` `[moaning]`
`[exhale]` `[inhale]` `[panting]` `[audience laughter]` `[with strong accent]`
`[clearing throat]`

For the authoritative, potentially-more-current reference (Fish Audio may add
more tags upstream), see the
[`mlx-community/fish-audio-s2-pro` model card](https://huggingface.co/mlx-community/fish-audio-s2-pro)
and Fish Audio's own S2 Pro documentation. As with `dia`'s `[S1]`/`[S2]` tags,
these are plain substrings the server never parses (**"Option A accepted
cost"**): a fish-dialect tag sent to a non-fish backend is read aloud literally,
not interpreted.

**`instruct` is a separate style-control surface**, not an in-text tag — it is
a plain string request extra (see the `extras` table row above), validated to
be a non-oversized `str`; an oversized or non-`str` `instruct` is **rejected**,
never silently clamped or truncated (unlike `temperature`/`top_p`/`top_k`,
where any in-range value is still a valid sample knob — a truncated
instruction would silently change what the model is told to do). An
empty-or-whitespace-only `instruct` is **valid**, not rejected — it is
silently coerced to `None` and omitted from the forwarded extras, the same
"unset extra" convention as leaving `instruct` out entirely. **The precedence
between `instruct` and an in-text
`[tag]` when they conflict is undefined and model-determined** — the server
performs no arbitration and forwards both unmodified apart from
whitespace-stripping of `instruct`; this is untested, do not assume one
overrides the other without observing actual model output.

## Kokoro capabilities (as shipped)

Built per-backend (`server.hello.capabilities`). Verified against
mlx-community/Kokoro-82M-bf16 (mlx-audio 0.4.4):

| Field | Value | Note |
|---|---|---|
| rate | **24000** | from `server.hello.audio.rate`, not capabilities |
| `streaming` | `false` | no sub-segment streaming; segments still stream per `\n+` |
| `binary_audio` | `false` | base64-in-JSON for v1 |
| `text_formats` | `["plain"]` | ssml/ipa not supported |
| `languages` | `["en","es","fr","hi","it","pt"]` | from voice prefixes, minus languages needing extra G2P — **`ja`/`zh` are off by default** (opt-in, see below) |
| `voice_count` | `54` | full list via `status` |
| `extras` | `["speed"]` | Kokoro's only effective `generate()` kwarg |
| `ideal_words` | `40` | soft target; client rounds up to a sentence boundary |
| `max_text_chars` | `2000` | hard server cap |

<a id="kokoro-language-support-advertised--synthesizable"></a>

## Kokoro language support (advertised = synthesizable)

The advertised `languages` list reflects what this deployment can actually
synthesize, not just what voices the model ships. The default `kokoro` extra
pins `misaki[en]` only; verified live against mlx-community/Kokoro-82M-bf16:

- **`en`** uses misaki[en]; **`es`/`fr`/`it`/`pt`/`hi`** route through the
  espeak-ng G2P bundled with misaki[en] — all synthesize fine and are advertised.
  (`hi`'s first call loads its G2P lazily and can exceed a 60 s client timeout.)
- **`ja` and `zh` need an extra G2P package** — `misaki[ja]` (`pyopenjtalk`) and
  `misaki[zh]` (`ordered_set`) respectively, which the `kokoro` extra does not
  install. Because synthesis would fail at runtime (`response.failed`,
  `code=backend_error`) without them, **they are not advertised by default** and
  a request for them is rejected up front with `invalid_config` (before a
  synthesis slot is consumed) rather than failing mid-response.

**Enabling `ja` / `zh`** is a two-step, build-time decision:

1. Install the G2P package(s):
   `uv pip install "misaki[ja]" "misaki[zh]"`
2. Opt the language(s) back into the advertised set:
   `export PIPECAT_TTS_KOKORO_EXTRA_LANGS=ja,zh`

The server logs its advertised language set at startup (including a reminder of
any languages left disabled). The opt-in only *re-adds* a language the model
already ships voices for; it cannot advertise one the model lacks. If you set the
env var without installing the package, that language is advertised again and
will fail at synthesis — install first.

See [`tests/smoke/`](../tests/smoke/) for the live end-to-end smoke scripts that
verify this (`just smoke-tone` / `just smoke-kokoro` / `just smoke-multilingual`).

## Kokoro cancellation caveat

Kokoro yields one segment per `\n+` boundary and the cancel flag is only checked
at a segment boundary. The **client-visible** cancel is prompt regardless: a
`response.cancel` is acknowledged with `response.cancelled` in ~1 ms (measured on
Apple Silicon), and no audio follows it. What runs to the segment boundary is the
backend worker / Metal lock: a **long single-segment** commit keeps the lock
until its `generate()` reaches the yield (≈ the full single-segment synthesis
time — a few seconds for a ~1700-char segment, bounded by `drain_timeout_seconds`),
so the *next* commit can't start synthesizing until then. To free the lock sooner
for back-to-back commits, **clients should chunk at sentence/newline boundaries**
for Kokoro. The server's hard guarantee is "no more audio after
`response.cancelled`". (See the dev plan's *Phase 2 measured results* for the full
re-measurement; the earlier "≈ tens of seconds" figure was a bridge-bug artifact.)
