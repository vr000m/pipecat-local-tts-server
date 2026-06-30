# Task: tts-server — `dia` dialogue backend (formerly v1 Phase 5c)

**Status**: Planned — **design resolved 2026-06-29** (dialogue voice/text-semantics: tags-in-`plain`,
`voice_count:0`; see *Resolved design decisions*). Conduct-ready pending a `/review-plan` refresh.
Split out of the v1 plan (`20260624-feature-tts-server-v1.md`, where it was Phase 5c) on 2026-06-25
because, unlike the streaming backends `voxtral_tts`/`pocket_tts`, `dia` carried an unsolved design
that touches the single-voice `open_stream(voice=…)` contract — a backend-*contract* change, not just
a backend addition.
**Component**: tts-server (backends)
**Assigned to**: Varun Singh
**Priority**: Medium (after v1 Phase 5a/5b land)
**Branch**: `feature/tts-dia-backend` (off `main`; Phase 5a/5b/6 already merged in 0.2.0)
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

## Resolved design decisions (2026-06-29)

**How does a client address speakers in a `dia` dialogue?** — RESOLVED.

1. **Speaker control is purely in-text via `[S1]`/`[S2]` tags.** The client emits the tagged text;
   the server does not parse or interpret it. `voice` does **not** select a speaker. dia advertises
   **`voice_count: 0`** (no enumerable `voices()`), so `_validate_voice` (`server.py:724`) is skipped
   and `voice` is omitted from `generate()` (the `voice=None`-OMIT rule, copying
   `pocket_tts.py:161-165` — the existing analogue).
2. **Dialogue text rides inside `text_format: plain` (Option A — no server-side changes).** `[S1]`/
   `[S2]` are literal characters in a normal `plain` payload; the server forwards the committed buffer
   untouched (verified `server.py:1006` — text is handed whole to the backend, never re-split server
   side; the only split is `split_pattern='\n'` *inside* mlx-audio's `generate()`).
   `SUPPORTED_TEXT_FORMATS` stays `("plain",)` — **no protocol/server change**.
   - **Accepted cost:** the format is undocumented on the wire. The server cannot tell dialogue text
     from plain text, so it cannot reject `[S1]` tags aimed at a non-dialogue backend (e.g. Kokoro
     would read them aloud literally as "bracket S one"). The dialogue contract lives only in client
     convention. If a fail-loud guarantee is later wanted, a per-backend `text_formats` capability
     (Option B, making `server.py:~904` validation capability-driven) is the upgrade path — deferred.
3. **Chunking stays the client's job; turns must not split mid-tag.** `ideal_words` chunking is
   already client-side (`server.py:980`); dia keeps `split_pattern='\n'`. The client MUST NOT break a
   `[S1]…` turn across two commits, and MUST NOT place a `\n` inside a turn it wants dia to render as
   one segment. **Open model-quality unknown:** dia generates each `\n`-separated turn as an
   independent segment, so prosodic continuity across an interruption is *not* guaranteed — the
   two-layout dialogue smoke (below) is what tells us whether it holds.

A `/review-plan` refresh on this resolved design is still recommended before conduct.

## Implementation Checklist (after the design question is settled)

### Backend
- [ ] `backends/dia.py`. **Re-verify the live signature via `inspect.signature` before wiring**
  (R7/R8; pin `mlx-audio==0.4.4`). As surveyed 2026-06-24 (source read, line numbers approximate):
  `generate(text, voice=None, temperature=1.3, top_p=0.95, split_pattern='\n', max_tokens=None,
  verbose=False, ref_audio=None, ref_text=None, **kwargs)`. **NOT a streaming backend** — no `stream`
  param, uses `split_pattern` (segment-level, like Kokoro) → advertise **`streaming:false`** (assert
  `capabilities()["streaming"] is False`). extras `{temperature, top_p}`.
- [ ] Apply the `voice=None`-OMIT rule by **copying `pocket_tts.py:161-165`** (the existing analogue —
  conditionally omit `voice` from the `generate()` call when `None`; NOT Kokoro's `speed`-omit, and
  Kokoro never omits `voice`). Per *Resolved design decision* #1, dia advertises `voice_count: 0`, so
  `voice` is always omitted and speaker control is purely in-text.
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
- [ ] **Dialogue-mapping tests** (net-new, the reason this is its own plan): per *Resolved design
  decisions* #1/#2 — assert `[S1]`/`[S2]` text passes through to `generate()` intact (boundary test,
  as in 5b), `text_format` stays `plain`, `capabilities()` advertises `voice_count: 0`, and `voice`
  is omitted from the `generate()` call.
- [ ] **`tests/smoke/dia_dialogue_smoke.py`** (net-new, mlx-gated, dia-only, **listen-and-judge** —
  NOT a CI assertion; mirrors `tests/smoke/latency_smoke.py` + `examples/reference_client.py`).
  Connects a real client to a real dia server, sends crafted dialogue scripts, writes one WAV per
  script, prints their paths for a human to judge. Only structural assert is non-empty audio per
  script (perceptual "two distinct speakers" / "natural resumption" cannot be cheaply auto-verified).
  Scripts:
  1. **Turn-taking** — `[S1]…[S2]…[S1]…`; does speaker identity stay consistent across turns?
  2. **Interruption + resumption, BOTH layouts** (the load-bearing test for decision #3): (a) inline
     tags, single segment (no `\n`) — in-segment continuity; (b) newline-separated turns — does
     continuity survive dia's per-segment `split_pattern='\n'`? S1 starts a sentence, S2 cuts in, S1
     finishes the *same* sentence; listen for whether S1 resumes naturally vs disjointly.
  3. **Short backchannel** — a one-word S2 interjection ("mm-hmm") inside an S1 turn.
  This is scripted (in-text) interruption — distinct from protocol `response.cancel` barge-in, which
  is terminal (no resume). Record the (a)-vs-(b) prosodic-continuity result in Findings after the
  first dia run; it tells the client whether to keep turns newline-free. (Smoke drivers live in
  `tests/smoke/` and run manually — no lean allow-list change.) Transcript fixtures are committed
  ahead of the driver at `tests/smoke/fixtures/dia/` (`podcast_turntaking.txt` for turn-taking;
  `interview_interruption_inline.txt` vs `interview_interruption_newline.txt` are the same dialogue in
  layouts (a)/(b) for the continuity comparison — see that dir's `README.md`).

### Standard backend-add wiring (follow the v1 Phase 5a/5b pattern)
- [ ] **ONE atomic "dia-enablement" commit (mandatory — avoids a red intermediate state).** Several
  existing drift tests *assert `dia` is absent* and flip to red the instant `dia` becomes a known
  backend, so every surface that names the backend set MUST change together. In a single commit:
  1. `make_backend` resolver (`tts_server/backends/__init__.py`, lazy-import branch, `mlx_audio` only
     in `start()`);
  2. argparse `--backend` choices tuple (`tts_server/__main__.py`) — a passing `make_backend` unit
     test will NOT catch a missing `--backend` choice;
  3. renderer `_BACKEND_RE` (`scripts/render_tts_plist.py`) + `render_tts_plist.py` defaults;
  4. README port table + the `docs/protocol.md`/README capabilities & extras table;
  5. justfile `_resolve` `(label, port)` row (`pipecat.tts-server.dia` → 9065 — the v1-reserved port);
  6. **invert the dia-absence assertions** in `tests/test_justfile_recipes.py`
     (`test_dia_is_absent_from_readme_and_renderer`, `test_resolve_dia_exits_nonzero`, and the inline
     `_BACKEND_RE.match("dia")` guard) into positive presence assertions, matching the other backends.
  Add a lean construction/lazy-import test for dia in the same commit. Phase 6 (launchd ops) has
  **already merged** (v1 plan, PR #7), so all of 3–6 are unconditional — not gated on "if Phase 6 has
  landed."
- [ ] Per-backend `sample_rate` discovery (R1/R3): expose `sample_rate` after `start()`/load so
  `server.hello.audio.rate` advertises the true model rate; mlx-gated test reads `model.sample_rate`
  (the config property), **not** a backend literal. dia's rate is per-model and unverified — do not
  assume it matches Kokoro's 24000.
- [ ] Packaging/CI: add the `pyproject.toml` `dia` extra (`mlx-audio==0.4.4`); the macOS smoke job
  already syncs `--all-extras` once v1 Phase 5a lands, so a new extra is install-smoked automatically.
  Backend synth tests stay local/mlx-gated only.
- [ ] If a new lean test file is added, extend the lean allow-list (`.github/workflows/test.yml`) in
  the same commit; prefer folding the negative-guard assertion into the already-allow-listed
  `tests/test_capabilities_extras.py`. (The README/`docs/protocol.md` capabilities & extras table —
  including dia's `streaming:false` flag — and the justfile/port/renderer/drift-test surfaces are all
  covered by the single atomic dia-enablement commit above.)

## Acceptance Criteria
- `python -m tts_server serve --backend dia` serves; `status` prints `backend=dia` + the model rate.
- `capabilities()["streaming"] is False`; `capabilities()["extras"] == ["temperature", "top_p"]`
  (ordered list, matching `docs/protocol.md` + `tests/test_capabilities_extras.py`) and excludes
  `ref_audio`/`ref_text`.
- `capabilities()` advertises `voice_count: 0` and `text_formats: ["plain"]`; `voice` is omitted from
  `generate()` and `[S1]`/`[S2]` tags pass through to `generate()` intact (decisions #1/#2).
- `tests/smoke/dia_dialogue_smoke.py` runs against a live dia server and writes one WAV per script
  (both interruption layouts); the (a)-vs-(b) prosodic-continuity result is recorded in Findings.
- Lean CI unaffected; `mlx_audio` absent at import time (lazy).

## References
- Parent / pattern source: `docs/dev_plans/20260624-feature-tts-server-v1.md` — Phase 5a/5b are the
  backend-add template; *Locked design decisions* #2 (no `ref_audio`/cloning), R7 (per-backend
  extras), R1/R3 (rate contract), and the *Per sub-phase* checklist all apply here.

<!-- reviewed: 2026-06-29 @ be904cc9fc19e122c94c473512b6a84139104092 -->
