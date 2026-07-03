# Task: tts-server — `qwen3_tts` streaming backend

**Status**: Not Started
**Component**: tts-server (backends)
**Assigned to**: Varun Singh
**Priority**: Medium
**Branch**: `feature/tts-qwen3-backend` (off `main` @ `093e65f`)
**Created**: 2026-07-03

## Objective

Add a `qwen3_tts` streaming TTS backend (mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16 via the
already-pinned mlx-audio 0.4.4) as a voxtral-derived sub-segment streamer behind its own lazy
extra, with tests, justfile smoke recipes, and a cross-backend profiling entry. **No server-side
changes** — the backend plugs into the existing session loop / re-chunker / `_stream_util` bridge.

## Context

- mlx-audio 0.4.4 (the R8-pinned version this project already installs) ships the `qwen3_tts`
  model family — this backend needs **no pin bump**, unlike every other candidate model family.
- Qwen3-TTS is multilingual (7 named speakers per the family README: 2 English, 5 Chinese incl.
  dialects) with upstream README claims of RTF ~1.67x, TTFB ~85 ms, ~3.9 GB, 24 kHz — **unverified
  on this machine**.
- Its `generate(stream=True, streaming_interval=…)` shape matches the Voxtral backend template,
  so the net-new work is a Phase-0 verification gate (dia precedent: the gate falsified a core
  assumption and forced a re-plan *before* wiring) plus the standard backend-add wiring.
- Out of scope for v1 of this backend: voice cloning (`ref_audio`+`ref_text` — the WS protocol
  cannot carry reference audio), the CustomVoice/VoiceDesign model variants
  (`generate_custom_voice()` / `generate_voice_design()` entry points and their `instruct` knob),
  and the `repetition_penalty`/`speed`/`split_pattern`/`max_tokens`/`streaming_context_size`
  sampling knobs. Out-of-scope kwargs are **actively guarded** (lean negative tests, Phase 1),
  not merely undocumented — `generate()` accepts them all and ICL cloning silently activates
  when `ref_audio`+`ref_text` are present (`qwen3_tts.py:1241-1265`).

## Requirements

- Backend name, extra name, and justfile recipe suffix are all **`qwen3_tts`** (consistent with
  `voxtral_tts` / `pocket_tts`).
- Default model `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16`, exported as `DEFAULT_QWEN3_MODEL`.
- Lean-base invariant holds: `import tts_server` and `make_backend("qwen3_tts", …)` succeed with
  only the lean base installed; `mlx_audio` enters the process only in `start()`. Enforced by a
  dedicated `tests/test_qwen3_lean.py` (every sibling backend has one) wired into the CI lean
  allowlist.
- Streaming backend contract: `capabilities()["streaming"] is True`; sub-segment chunks flow
  through the shared `_stream_util.stream_generate` bridge; `sample_rate` read from
  `model.sample_rate` in `start()` before warmup (never hardcode 24000 — the ModelConfig default
  is a dataclass default, not the repo-confirmed value; the gate records the real one).
- Voice knob maps to named speakers (`generate(voice=<speaker>)`; base models route it as
  `speaker`). `voices()` enumerates dynamically from `model.get_supported_speakers()` (which reads
  `config.talker_config.spk_id`) — do NOT hardcode the speaker list, and record/advertise the
  **exact-case** strings the model returns (`generate()` lowercases its lookup; the server
  validates verbatim against `frozenset(voices())`, `server.py:775`).
- **Language policy**: advertise `capabilities()["languages"]` dynamically from
  `model.get_supported_languages()`; `open_stream(language=…)` maps the client's validated
  `language` to `generate(lang_code=…)`, defaulting to `"auto"` when the client sends none. (The
  server validates client `language` against advertised capabilities and forwards it into
  `open_stream` — `server.py:718-733, 1170` — so "always auto" would contradict what we
  advertise.)
- Sampling extras mirror Voxtral's set (`temperature`, `top_k`, `top_p`) with clamped bounds;
  `streaming_interval` is backend config, never an advertised extra.
- Phase 0 is a **hard gate**: its questions (below) must be answered on this machine before any
  backend code is written. A falsified assumption triggers a re-plan, not a workaround.
- Tests mirror the sibling-backend two-layer pattern: `tests/test_qwen3_backend.py` (mlx-gated)
  + `tests/test_qwen3_lean.py` (lean, CI-runnable).
- justfile gains `smoke-qwen3_tts` and `smoke-multiconn-qwen3_tts` recipes; the smoke shell
  scripts' hardcoded backend allowlists MUST be extended in the same commit (they `exit 2` on
  unknown backends — this is a required edit, not a conditional).
- **Backend-set drift invariant** (enforced by `tests/test_justfile_recipes.py`): argparse
  `--backend` choices == README port-convention table == `render_tts_plist._BACKEND_RE` ==
  justfile `_resolve` map. Adding `qwen3_tts` to any one without all others breaks existing
  tests. Canonical port assignment: **9165** (next in the +100 sequence 8665…9065).
- Profiling: `rtf_benchmark.py --backend qwen3_tts` run added to the comparison table in
  `scripts/profiling/README.md` (TTFB/RTF; **peak memory is measured in the Phase-0 direct-MLX
  gate**, not by the profiler — the bridge discards `GenerationResult.peak_memory_usage`).
- Docs updated alongside code: README backend + port tables, AGENTS.md if it lists backends,
  `tests/smoke/README.md` weights/license note. The license is **unknown until verified** — the
  Phase-0 gate records the actual HF license file contents into `## Findings`, and the smoke
  README note quotes it verbatim (Qwen models ship under Apache-2.0 *or* Qwen-specific licenses;
  do not pre-assume).

## Review Focus

- **Phase-0 gate completeness**: does the gate actually falsify the assumptions the later phases
  depend on (incremental yield, cross-segment state, `voice=None` behavior, speaker list casing,
  languages, sample rate, license)?
- **Voice/None semantics**: qwen3's base path has **no default speaker** — when `speaker` is
  None/unknown, `speaker_embed` stays None and output is speaker-*unconditioned*
  (`qwen3_tts.py:381-389`; no else-default branch). The backend decision is inject-a-discovered-
  default-speaker vs omit-and-accept-unconditioned-output, decided by gate Q4. Do not reuse
  Voxtral's "the model's own default stands" framing — it is a false analogy here.
- **Chunk cadence math**: qwen3's chunk quantum is `max(1, int(streaming_interval * 12.5))` codec
  tokens (12.5 tokens/s) — the provisional `_STREAMING_INTERVAL = 0.4` (5 tokens ≈ 0.4 s audio)
  differs from Voxtral's 0.3 semantics; TTFB math in review should use tokens, not seconds.
- **Lean-base invariant**: no module-load import of `mlx_audio`/`numpy` in the new module.
- **Out-of-scope kwarg guard**: cloning/style/control kwargs must be provably unable to reach
  `generate()` (lean spy-model tests), since `ref_audio`+`ref_text` silently activate cloning.
- **Drift invariant**: argparse == README port table == `_BACKEND_RE` == justfile `_resolve`.

## Implementation Checklist

### Phase 0: Model verification gate (dia precedent)

**Impl files:** `tests/smoke/qwen3_phase0_gate.py`
**Test files:** `tests/smoke/qwen3_phase0_gate.py`
**Test command:** `uv run --extra dia python tests/smoke/qwen3_phase0_gate.py`

Standalone script (mlx-audio direct, no server) that downloads the model once and answers, with
printed PASS/FAIL per question. The `--extra dia` supplies mlx-audio 0.4.4 (the `qwen3_tts` extra
does not exist until Phase 2; a bare `uv run` re-syncs to lean base and strips mlx-audio — any
existing mlx extra works).

- **Q1 — incremental streaming**: does `generate(stream=True, streaming_interval=0.4)` yield ≥2
  chunks for a single-sentence utterance, with wall-clock gaps between yields (i.e. genuinely
  incremental, not batched-at-end)? Record chunk count and each yield's `is_streaming_chunk` /
  `is_final_chunk` values as present (streaming yields set `is_streaming_chunk=True`; only the
  terminal yield sets `is_final_chunk` — `qwen3_tts.py:1445-1524`). Note: incremental-*timing* is
  a gate-only assertion; the Phase-1 unit test only counts chunks (Voxtral precedent).
- **Q2 — latency + memory**: measure TTFB (first chunk wall time) and full-utterance RTF for a
  short and a ~15 s utterance, at `streaming_interval` 0.4 and the 2.0 default. Record **peak
  memory here** (via `GenerationResult.peak_memory_usage` / `mx.get_peak_memory()`) — the Phase-3
  profiler cannot see it (the bridge strips everything but PCM).
- **Q3 — speakers + languages + rate**: print `model.get_supported_speakers()` **verbatim**
  (exact casing — the family README is inconsistent, `ryan` vs `Ryan`, and server-side voice
  validation is case-exact while `generate()` lowercases) and `model.get_supported_languages()`;
  confirm English speakers exist in THIS model's `spk_id` (family README claims are not
  model-config facts). Record `model.sample_rate` actually reported.
- **Q4 — `voice=None`**: verify the no-speaker path — base models generate speaker-unconditioned
  output (no default, no error, per `qwen3_tts.py:381-389`). Listen to it. Decide: inject a
  discovered default speaker (and which one) vs omit and accept unconditioned output.
- **Q5 — cross-segment state**: with a seeded two-line (`\n`-separated) input, is segment 2's
  audio affected by editing segment 1 (dia-style autoregressive coupling)? And are two separate
  `generate()` calls independent? Use the dia gate's A/B/C seeded-comparison method.
- **Q6 — license**: fetch/read the HF repo's license file for
  `mlx-community/Qwen3-TTS-12Hz-0.6B-Base-bf16` (and the upstream Qwen3-TTS license it mirrors);
  record the exact license into `## Findings` for the Phase-2 smoke-README note.
- Also record: audio sanity (no NaN, not clipped, audible speech written to WAV for perceptual
  check of both English speakers).

**GATE**: Q1 false → re-shape as segment-level `streaming:false` backend (kokoro-like) — re-plan.
Q5 shows cross-call state → dia-precedent re-plan. Q3/Q4 surprises → update Phase 1 defaults
before proceeding. Findings land in `## Findings` below the marker.

### Phase 1: Backend module + unit tests (mlx-gated + lean)

**Impl files:** `tts_server/backends/qwen3_tts.py`
**Test files:** `tests/test_qwen3_backend.py, tests/test_qwen3_lean.py`
**Test command:** `uv run pytest tests/test_qwen3_backend.py tests/test_qwen3_lean.py -v`

- New `Qwen3Backend` derived from the Voxtral template (`voxtral_tts.py`): lazy `load()` in
  `start()`, `sample_rate` from `model.sample_rate` pre-warmup (never hardcoded), warmup synth,
  `open_stream()` returning a stream whose `events()` drains `generate(text, stream=True,
  streaming_interval=_STREAMING_INTERVAL, **kwargs)` through `stream_generate` with
  `maxsize=_BRIDGE_MAXSIZE`.
- `_STREAMING_INTERVAL` module constant, value set from Phase 0 Q2 findings (provisional 0.4).
- Voice handling per Phase 0 Q4 (inject-default vs unconditioned — NOT Voxtral's omit-rule
  framing); `voices()` dynamic via `get_supported_speakers()` with exact-case strings. NOTE:
  `_discover_voices` here is **net-new code**, not a Voxtral copy (Voxtral walks
  `_voice_embedding_files`; qwen3 reads model API) — define the empty-`spk_id` fallback
  (`config.py` default is `None` → `[]`) with a static fallback mirroring Voxtral's `_STATIC_*`
  pattern, populated from gate Q3.
- Language mapping: `open_stream(language=…)` → `generate(lang_code=…)`, `None` → `"auto"`;
  `capabilities()["languages"]` from `get_supported_languages()` (gate-informed static fallback).
- Extras: exactly `temperature`, `top_k`, `top_p` with validation/clamping mirroring Voxtral's
  `validate_extras()`. **Negative guard**: out-of-scope kwargs (`ref_audio`, `ref_text`,
  `instruct`, `speed`, `split_pattern`, `max_tokens`, `streaming_context_size`,
  `repetition_penalty`) must never reach `generate()` even if injected via `open_stream` extras.
- `capabilities()`: `streaming: True`, `voice_count` from discovered list, `languages` dynamic,
  `ideal_words`/`max_text_chars` gate-informed; `streaming_interval` NOT in `extras`.
- `tests/test_qwen3_backend.py` (mlx-gated) mirrors `test_voxtral_backend.py`: module-scoped
  `started_backend`, `pytest.importorskip("mlx_audio")`, ≥2-chunk streaming test, NaN/clip test,
  hello-rate test via `tests/_helpers.py`. It imports `Qwen3Backend` **directly** (not via
  `make_backend`), so the Phase-1 commit stays green before the Phase-2 registry branch exists.
- `tests/test_qwen3_lean.py` (no mlx) mirrors `test_voxtral_lean.py`: subprocess lean-import
  check (module import pulls no mlx), `make_backend("qwen3_tts")` constructs without mlx
  (this test lands green only after Phase 2 wires the registry — mark xfail/skip until then or
  fold into Phase 2's run), locked-value assertion `_STREAMING_INTERVAL == <final>` plus
  `max(1, int(_STREAMING_INTERVAL * 12.5)) == <expected tokens>`, `streaming: True` caps shape,
  `"streaming_interval" not in caps["extras"]` and `caps["extras"] == ["temperature", "top_k",
  "top_p"]`, spy-model tests for the Q4 voice-None decision, the language→lang_code mapping,
  and the forbidden-kwargs negative guard.
- Cancel-mid-stream/bridge-teardown and `wait_closed` (SupportsWaitClosed slot-accounting,
  protocol.md §7) are covered by the backend-agnostic `tests/test_streaming_and_cancel.py`
  suite — cite in test docstrings rather than duplicating.

### Phase 2: Wiring — registry, CLI, extra, justfile, smoke scripts, renderer, docs

**Impl files:** `tts_server/backends/__init__.py, tts_server/__main__.py, pyproject.toml, uv.lock, justfile, scripts/render_tts_plist.py, tests/smoke/run_smoke.sh, tests/smoke/run_multiconn.sh, .github/workflows/test.yml, tests/test_import_safety.py, README.md, AGENTS.md, tests/smoke/README.md`
**Test files:** `tests/test_qwen3_lean.py`
**Test command:** `uv run pytest tests/ -q`
**Validation cmd:** `just smoke-qwen3_tts`

All of the following are **one atomic unit** — the smoke scripts auto-run
`uv sync --extra "$BACKEND"`, so the extra, the allowlists, the recipes, and the registry must
land in the same commit or `just smoke-qwen3_tts` is red at every intermediate point:

- `make_backend` branch for `"qwen3_tts"` (lazy import, `model or DEFAULT_QWEN3_MODEL`, same
  comment discipline as siblings).
- `tts_server/__main__.py`: add `qwen3_tts` to the argparse `--backend` choices (lines ~359-360)
  and to the backend→default-model resolution map (lines ~45-61).
- `pyproject.toml` extra: `qwen3_tts = ["websockets>=13.0", "mlx-audio==0.4.4"]` (transformers is
  transitive through mlx-audio — no bespoke dep; verify with `uv sync --extra qwen3_tts`); sync
  `uv.lock`.
- justfile: `smoke-qwen3_tts` + `smoke-multiconn-qwen3_tts` recipes AND the `_resolve` map entry
  (`pipecat.tts-server.qwen3_tts` / `127.0.0.1` / `9165`, plus the error-message "valid:" list).
- `tests/smoke/run_smoke.sh`: add `qwen3_tts` to the backend allowlist (:52-53), the `IS_MLX`
  list (:58), and a `qwen3_tts` verify branch mirroring voxtral's streaming latency check
  (:166-187). `tests/smoke/run_multiconn.sh`: extend the allowlist/extra-install list (:44-45).
- `scripts/render_tts_plist.py`: extend `_BACKEND_RE` (:57) and the human-readable backend list
  (:201-202).
- CI: add `tests/test_qwen3_lean.py` to the lean allowlist in `.github/workflows/test.yml`
  (:37-65) and extend `tests/test_import_safety.py`.
- Docs: README backend table row + **port-convention table row (9165)**, AGENTS.md backend list
  if present, smoke README license note quoting the gate-verified license verbatim.
- Drift-invariant check: `uv run pytest tests/test_justfile_recipes.py -q` green (argparse ==
  README table == `_BACKEND_RE` == `_resolve`).

### Phase 3: Profiling + comparison table

**Impl files:** `scripts/profiling/README.md`
**Test files:** (none — measurement phase)
**Test command:** `uv run python scripts/profiling/rtf_benchmark.py --backend qwen3_tts`

- Run the standard rtf_benchmark phrase set against `qwen3_tts`; capture TTFB/RTF (the profiler
  reports `audio_s`/`ttfb_s`/`wall_s`/`RTF` only — peak memory comes from the Phase-0 gate).
- Add the row to the cross-backend comparison in `scripts/profiling/README.md`, with the
  `supports_tts_batch(stream=True) == False` caveat noted for the concurrency story, and the
  gate-measured peak memory cited as such.
- Compare against Phase 0 Q2 numbers and the upstream README claims; discrepancies → Findings.

## Technical Specifications

### Files to Modify
- `tts_server/backends/__init__.py` — new `qwen3_tts` branch in `make_backend` (chain at lines 29–65).
- `tts_server/__main__.py` — argparse `--backend` choices (~359-360) + default-model map (~45-61).
- `pyproject.toml` — new `qwen3_tts` extra (pattern at lines 51/71/87/103: all pin `mlx-audio==0.4.4`); `uv.lock` sync.
- `justfile` — two smoke recipes (pattern at lines 374–398) + `_resolve` map entry (port 9165).
- `scripts/render_tts_plist.py` — `_BACKEND_RE` (:57) + human-readable list (:201-202).
- `tests/smoke/run_smoke.sh` — allowlist (:52-53), IS_MLX (:58), verify branch (:166-187).
- `tests/smoke/run_multiconn.sh` — allowlist/extra-install list (:44-45).
- `.github/workflows/test.yml` — lean-test allowlist (:37-65); `tests/test_import_safety.py`.
- `README.md` (backend table + port-convention table), `AGENTS.md`, `tests/smoke/README.md`,
  `scripts/profiling/README.md` — doc rows/notes.

### New Files to Create
- `tts_server/backends/qwen3_tts.py` — the backend (voxtral-derived; `_discover_voices` net-new).
- `tests/test_qwen3_backend.py` — mlx-gated unit tests (voxtral-test-derived).
- `tests/test_qwen3_lean.py` — lean unit tests (voxtral-lean-derived).
- `tests/smoke/qwen3_phase0_gate.py` — Phase-0 gate script (kept: doubles as a regression probe).

### Architecture Decisions
- **Voxtral template, not Pocket**: qwen3 streams via `stream=True` + `streaming_interval` exactly
  like Voxtral (`voxtral_tts.py:264–303`). `_discover_voices` is the one net-new piece (model-API
  driven, not embedding-file walk).
- **`voice` kwarg passthrough with exact-case discovery**: qwen3's `generate()` routes `voice` →
  `speaker` for base models (`qwen3_tts.py:1294-1295`) via a **lowercased** lookup, while the
  server validates the client's voice case-exactly against `voices()`. Advertising the model's
  verbatim `spk_id` keys keeps both sides consistent. None-handling decided by Phase 0 Q4
  (inject-default vs unconditioned — there is no model-side default speaker).
- **Language → `lang_code` mapping**: advertise `get_supported_languages()`; forward the
  server-validated client `language` as `lang_code`, defaulting `"auto"`. Voxtral's ignore-
  language approach does not fit qwen3 (language is a real generate() knob here, not a voice-
  preset property).
- **Chunk cadence is token-quantized**: `streaming_chunk_size = max(1, int(streaming_interval *
  12.5))` (`qwen3_tts.py:1318–1319`); provisional `_STREAMING_INTERVAL = 0.4` → 5 tokens ≈ 0.4 s
  audio/chunk. Finalized from Phase 0 Q2 TTFB measurements and locked by a lean test.
- **No manual speech-tokenizer plumbing**: `mlx_audio.tts.utils.load()` calls `post_load_hook`
  automatically (loads AutoTokenizer + speech_tokenizer + generation_config) — the backend treats
  `load()` as returning a ready model, same as Voxtral.
- **Peak memory is a gate measurement, not a profiler output**: the bridge strips
  `GenerationResult` down to PCM, so `peak_memory_usage` is only observable in the direct-MLX
  Phase-0 gate; `rtf_benchmark.py` stays unchanged.
- **No server changes**: capabilities/voice validation/re-chunker all existing; `is_final_chunk`
  metadata on qwen3 results is ignored by the bridge (it drains `GenerationResult.audio` only).

### Dependencies
- `mlx-audio==0.4.4` (existing pin; ships `qwen3_tts` family). `transformers 5.12.1` transitive.
  No new top-level deps.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `make_backend("qwen3_tts")` | Phase 2 registry branch | CLI / rtf_benchmark / smoke scripts | Lazy import; ValueError on unknown; `model or DEFAULT_QWEN3_MODEL` |
| argparse choices / `_BACKEND_RE` / README port table / `_resolve` | Phase 2 | `test_justfile_recipes.py` drift tests | all four sets identical; port 9165 |
| `open_stream(voice=…)` | Phase 1 backend | server session loop | voice pre-validated by server against exact-case `voices()`; None per Q4 decision |
| `open_stream(language=…)` | Phase 1 backend | server session loop | server-validated language → `lang_code`; None → `"auto"` |
| `stream_generate` bridge | Phase 1 `_gen_factory` | `_stream_util.py` | generator yields `GenerationResult` with `.audio` float32 mx.array; backend sets `maxsize` |
| `sample_rate` attr | Phase 1 `start()` | server `hello.audio.rate` | set before first `open_stream`; from model, never hardcoded (gate-verified value) |
| justfile recipes + smoke allowlists | Phase 2 (atomic) | user / CI | `run_smoke.sh --backend qwen3_tts` accepted; `uv sync --extra qwen3_tts` resolvable |

## Architecture & Call Flow

Component graph — which component triggers which:

```mermaid
graph LR
    C[WS client] -->|text.append / input.commit| S[tts-server session loop]
    S -->|open_stream/feed/end| B[Qwen3Backend]
    B -->|gen_factory: generate stream=True| M[mlx-audio qwen3_tts model]
    M -->|GenerationResult chunks| U[_stream_util.stream_generate bridge]
    U -->|float32 chunks| S
    S -->|20 ms int16 frames| C
```

Trigger order — one committed utterance:

```mermaid
sequenceDiagram
    participant C as WS client
    participant S as server loop
    participant B as Qwen3Backend
    participant M as mlx model (thread)
    C->>S: text.append + input.commit
    S->>B: open_stream(voice, language) → feed(text) → end()
    B->>M: generate(text, voice, lang_code, stream=True, streaming_interval)
    loop every ~5 codec tokens (~0.4 s audio)
        M-->>B: GenerationResult(.audio)
        B-->>S: chunk via bridge queue (maxsize backpressure)
        S-->>C: audio.delta frames (20 ms re-chunked)
    end
    S-->>C: response.done
```

Context lifecycle:

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| 1 | server start | model weights + tokenizers via `load()` (once) | persists for process life | `start()` returns after warmup |
| 2 | `input.commit` | committed text snapshot → one `gen_factory()` call | generator state local to the call; freed at drain end | `response.done`/`cancelled` |
| 3 | chunk yield | one `GenerationResult` in bridge queue | consumed by session loop; queue bounded (`maxsize`) | per chunk |
| 4 | next commit | fresh `generate()` call | no cross-call model state (Phase 0 Q5 verifies) | per commit |

## Testing Notes

### Test Approach
- Phase 0 gate script (perceptual WAVs + printed PASS/FAIL) — machine-verified assumptions,
  incl. peak memory and license record.
- Two-layer unit tests: `test_qwen3_backend.py` (mlx-gated) + `test_qwen3_lean.py` (lean,
  CI-allowlisted), mirroring the voxtral pair.
- End-to-end: `just smoke-qwen3_tts` (WAV round-trip + TTFB/cadence) and
  `just smoke-multiconn-qwen3_tts` (fairness/busy under 2 clients).
- Drift invariant: `tests/test_justfile_recipes.py` (existing, must stay green).
- Profiling: `rtf_benchmark.py` standard phrase set (TTFB/RTF only).

### Test Results
- (fill during implementation)

### Edge Cases Tested
- `voice=None` (per Q4, lean spy test), unknown voice name (server-side rejection),
  language→lang_code mapping incl. None→auto (lean spy test), forbidden kwargs never reach
  `generate()` (lean spy test), extras out of bounds (clamped/rejected), multi-`\n` commit,
  cancel mid-stream / `wait_closed` (covered by backend-agnostic `test_streaming_and_cancel.py`).

## Acceptance Criteria

- Phase 0 gate ran on this machine; all six questions answered in `## Findings` (incl. exact-case
  speakers, languages, sample rate, peak memory, license); any falsified assumption triggered a
  recorded re-plan decision before Phase 1 code.
- `uv sync --extra qwen3_tts` on a clean env installs only `mlx-audio==0.4.4`(+transitive) beyond base.
- Lean-base: `tests/test_qwen3_lean.py` green in the lean CI job (module import pulls no mlx;
  `make_backend("qwen3_tts")` constructs without importing mlx_audio).
- `uv run pytest tests/ -q` green, including the new suites AND the existing
  `tests/test_justfile_recipes.py` drift tests (argparse == README port table == `_BACKEND_RE`
  == justfile `_resolve`, port 9165).
- `just smoke-qwen3_tts` passes: audible WAV, hello advertises the gate-verified model rate,
  ≥2 streaming chunks. `just smoke-multiconn-qwen3_tts` passes.
- Profiling row present in `scripts/profiling/README.md` with measured TTFB/RTF and the
  gate-measured peak memory cited as gate-sourced.
- Docs updated (README backend + port tables, AGENTS.md, smoke README license note quoting the
  verified license) in the same PR.
- `ruff format` + `ruff check` clean.

<!-- reviewed: 2026-07-03 @ 19fadeaded582e9450585610433a9e0c2ee3e0aa -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [ ] Phase 0: Model verification gate
- [ ] Phase 1: Backend module + unit tests (mlx-gated + lean)
- [ ] Phase 2: Wiring — registry, CLI, extra, justfile, smoke scripts, renderer, docs
- [ ] Phase 3: Profiling + comparison table

## Findings

### Review resolution 2026-07-03

Reviewed by 5 fresh-context lenses (architecture, sequencing, spec-and-testing, assumptions,
codebase-claims) + an independent Codex CLI review. 24 raw findings → 22 reconciled
(2 Critical, 11 Important, 9 Minor); codebase-claims verified 18/18 references clean. All
findings folded into the contract above:

- **Critical (both wiring completeness)**: Phase 2 now explicitly covers `tts_server/__main__.py`
  (argparse choices + default-model map), `scripts/render_tts_plist.py` (`_BACKEND_RE`), the
  README port-convention table (port 9165), the justfile `_resolve` map, and the smoke-script
  allowlists — all as one atomic commit; drift tests (`test_justfile_recipes.py`) added to
  acceptance.
- **Important**: lean test layer (`test_qwen3_lean.py` + CI allowlist + import-safety) added;
  voice=None reframed (no model-side default speaker — inject vs unconditioned, gate Q4);
  language policy decided (advertise dynamic languages, map to `lang_code`, None→auto);
  forbidden-kwargs negative guard added (cloning silently activates on ref_audio+ref_text);
  peak-memory moved from Phase-3 profiler (can't see it) to Phase-0 gate; license de-asserted
  (unknown until gate Q6 reads the HF license file); locked `_STREAMING_INTERVAL` +
  token-quantum assertions added; sample_rate never hardcoded.
- **Minor**: Phase-0 gate command pinned to `uv run --extra dia` (bare `uv run` strips mlx-audio);
  exact-case speaker recording (server validates verbatim, generate() lowercases); gate Q1
  reworded to `is_streaming_chunk`/`is_final_chunk` semantics; `_discover_voices` marked net-new
  with empty-`spk_id` fallback; edge-case list made traceable (cites
  `test_streaming_and_cancel.py`); atomic-commit unit named; incremental-timing noted gate-only.

## Issues & Solutions

- (none yet)

## Final Results

(fill when complete)
