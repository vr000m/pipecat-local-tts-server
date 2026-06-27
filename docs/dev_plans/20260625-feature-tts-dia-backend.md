# Task: tts-server — `dia` dialogue backend (formerly v1 Phase 5c)

**Status**: Planned — design pending. **Blocked on a dialogue voice/text-semantics design** (the
`[S1]`/`[S2]` speaker-tag mapping) before it is conduct-ready. Split out of the v1 plan
(`20260624-feature-tts-server-v1.md`, where it was Phase 5c) on 2026-06-25 because, unlike the
streaming backends `voxtral_tts`/`pocket_tts`, `dia` carries an unsolved design that changes the
single-voice `open_stream(voice=…)` contract — it is a backend-*contract* change, not just a backend
addition.
**Component**: tts-server (backends)
**Assigned to**: Varun Singh
**Priority**: Medium (after v1 Phase 5a/5b land)
**Branch**: TBD (own feature branch off `main`, after Phase 5a/5b merge)
**Created**: 2026-06-25

## Objective

Add the `dia` multi-speaker **dialogue** TTS backend (mlx-audio) to the tts-server, behind its own
lazy-imported extra, advertising `streaming:false`. `dia` is segment-level (`split_pattern`, like
Kokoro), so it reuses the existing backend-agnostic session loop, 20 ms re-chunker, scheduler, and
`_stream_util` bridge — **no server-side changes**. The net-new work is the dialogue voice/text
semantics design plus the standard backend-add wiring.

## Why this is its own plan (not a v1 Phase 5 sub-phase)

Two independent `/review-plan` lenses (architecture, spec-and-testing) flagged 5c on 2026-06-24/25:
- **Architecture:** dia's `voice` interacts with `[S1]`/`[S2]` dialogue tags; its `voice`/text
  semantics differ from the single-voice backends 5a/5b share. That mapping is an *unsolved design*,
  not deferred packaging — a backend-contract change.
- **Spec-and-testing:** the deferred `[S1]`/`[S2]` mapping had **no test coverage** specified inside
  the v1 plan — a silent scope gap. A dedicated plan gives it its own design + review + test
  lifecycle.

## Open design question (must resolve before conduct)

**How does a client address speakers in a `dia` dialogue?** dia's `generate(text, voice=None, …)`
uses inline `[S1]`/`[S2]` tags in the *text* to switch speakers, which does not map cleanly onto the
wire protocol's single `voice` field (`session.update`/`input_text.commit`). Decide:
- Does `voice` select a speaker preset, or is speaker control purely in-text via `[S1]`/`[S2]`?
- Does the server pass dialogue-tagged text through untouched (`text_format: plain`), or add an
  `ssml`-like tagged format?
- How do `ideal_words` / sentence-chunking (decision #6) interact with not splitting across a
  speaker-tag boundary mid-turn?

Resolve these (a short design pass + `/review-plan` refresh) before implementing.

## Implementation Checklist (after the design question is settled)

### Backend
- [ ] `backends/dia.py`. **Re-verify the live signature via `inspect.signature` before wiring**
  (R7/R8; pin `mlx-audio==0.4.4`). As surveyed 2026-06-24 (source read, line numbers approximate):
  `generate(text, voice=None, temperature=1.3, top_p=0.95, split_pattern='\n', max_tokens=None,
  verbose=False, ref_audio=None, ref_text=None, **kwargs)`. **NOT a streaming backend** — no `stream`
  param, uses `split_pattern` (segment-level, like Kokoro) → advertise **`streaming:false`** (assert
  `capabilities()["streaming"] is False`). extras `{temperature, top_p}`.
- [ ] Apply the `voice=None` omit-in-backend rule (replicate Kokoro's `speed`-omit pattern, applied
  to `voice`; there is no existing `voice`-omit to copy) — **subject to the dialogue-tag design
  decision above** (the `[S1]`/`[S2]` interaction may change what `voice=None` means here).
- [ ] **Leave BOTH `ref_audio` AND `ref_text` unwired** (locked decision #2). Negative-guard test
  must cover `ref_text` too — assert at **both** layers (capabilities exclusion **and** absence at the
  `generate()` call boundary, as in v1 Phase 5b) for `{ref_audio, ref_text}`.
- [ ] **Cancel latency caveat (inherited from Kokoro):** dia is segment-level, so a long single
  segment's backend `generate()` runs to its yield boundary before the Metal lock frees for the next
  commit. Per Kokoro's re-measurement (v1 plan Findings → *Phase 2 measured results*, 2026-06-26):
  the **client-visible cancel** (`response.cancel` → `response.cancelled`) is prompt (**~1 ms**,
  decoupled from the worker); only the **lock/slot release** waits for `generate()`'s yield boundary
  (bounded by `drain_timeout_seconds`). Carry Kokoro's resolution: hard guarantee is "no more deltas
  after `response.cancelled`"; chunking at sentence/newline boundaries still helps free the Metal lock
  faster for the NEXT commit (no longer needed for prompt client-visible barge-in).
- [ ] **Dialogue-mapping tests** (net-new, the reason this is its own plan): cover whatever the design
  question resolves to — e.g. `[S1]`/`[S2]` text passes through to `generate()` intact, speaker
  switching produces the expected multi-voice output, and chunking does not split mid-turn.

### Standard backend-add wiring (follow the v1 Phase 5a/5b pattern)
- [ ] Wire `dia` into **both** call sites in the same commit: the `make_backend` resolver
  (`tts_server/backends/__init__.py`, lazy-import branch, `mlx_audio` only in `start()`) **and** the
  argparse `--backend` choices tuple (`tts_server/__main__.py`). A passing `make_backend` unit test
  will NOT catch a missing `--backend` choice. Add a lean construction/lazy-import test.
- [ ] Per-backend `sample_rate` discovery (R1/R3): expose `sample_rate` after `start()`/load so
  `server.hello.audio.rate` advertises the true model rate; mlx-gated test reads `model.sample_rate`
  (the config property), **not** a backend literal. dia's rate is per-model and unverified — do not
  assume it matches Kokoro's 24000.
- [ ] Packaging/CI: add the `pyproject.toml` `dia` extra (`mlx-audio==0.4.4`); the macOS smoke job
  already syncs `--all-extras` once v1 Phase 5a lands, so a new extra is install-smoked automatically.
  Backend synth tests stay local/mlx-gated only.
- [ ] If a new lean test file is added, extend the lean allow-list (`.github/workflows/test.yml`) in
  the same commit; prefer folding the negative-guard assertion into the already-allow-listed
  `tests/test_capabilities_extras.py`.
- [ ] Update the README/`docs/protocol.md` capabilities & extras table for `dia` (including its
  `streaming:false` flag).
- [ ] If Phase 6 (launchd ops, v1 plan) has landed, add dia's `(label, port)` row
  (`pipecat.tts-server.dia` → 9065) to the justfile `_resolve` map + README port table +
  `render_tts_plist.py` defaults in the same commit, so the drift test
  (`tests/test_justfile_recipes.py`) stays green.

## Acceptance Criteria
- `python -m tts_server serve --backend dia` serves; `status` prints `backend=dia` + the model rate.
- `capabilities()["streaming"] is False`; `capabilities()["extras"]` == `{temperature, top_p}` and
  excludes `ref_audio`/`ref_text`.
- The dialogue voice/text mapping resolved in the design question is implemented and tested.
- Lean CI unaffected; `mlx_audio` absent at import time (lazy).

## References
- Parent / pattern source: `docs/dev_plans/20260624-feature-tts-server-v1.md` — Phase 5a/5b are the
  backend-add template; *Locked design decisions* #2 (no `ref_audio`/cloning), R7 (per-backend
  extras), R1/R3 (rate contract), and the *Per sub-phase* checklist all apply here.

<!-- review-marker-placeholder: run /review-plan after the dialogue-mapping design is settled -->
