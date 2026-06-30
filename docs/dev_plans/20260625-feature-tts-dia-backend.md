# Task: tts-server — `dia` dialogue backend (formerly v1 Phase 5c)

**Status**: Planned — **design resolved + `/review-plan` refreshed 2026-06-29** (tags-in-`plain`,
`voice_count:0`; see *Resolved design decisions*). Conduct-ready; **the Phase 0 model-verification
gate must pass first** (it can fail and re-open the design).
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
   **`voice_count: 0`** (no enumerable `voices()`), so `_validate_voice` (`server.py:724-768`) treats
   the backend as having no voice concept and accepts a supplied `voice` instead of rejecting or
   stripping it. Therefore the dia backend itself must ignore `voice` and omit the `voice` kwarg from
   `generate()` even if `open_stream(voice=...)` receives one; Pocket's conditional `voice=None` omit
   shape (`pocket_tts.py:160-166`) is only an analogue for building kwargs, not sufficient by itself.
2. **Dialogue text rides inside `text_format: plain` (Option A — no server-side changes).** `[S1]`/
   `[S2]` are literal characters in a normal `plain` payload; the server forwards the committed buffer
   untouched (verified `server.py:904-925` validates/appends `plain` text without parsing,
   `server.py:1006` snapshots the buffer, and `server.py:1157` feeds that whole string to the backend;
   the only split is `split_pattern='\n'` *inside* mlx-audio's `generate()`).
   `SUPPORTED_TEXT_FORMATS` stays `("plain",)` — **no protocol/server change**.
   - **Accepted cost:** the format is undocumented on the wire. The server cannot tell dialogue text
     from plain text, so it cannot reject `[S1]` tags aimed at a non-dialogue backend (e.g. Kokoro
     would read them aloud literally as "bracket S one"). The dialogue contract lives only in client
     convention. If a fail-loud guarantee is later wanted, a per-backend `text_formats` capability
     (Option B, making `server.py:904-905` validation capability-driven) is the upgrade path — deferred,
     but keep the Option B note prominent in `docs/protocol.md` (not just here): the moment a second
     dialogue-aware consumer or a mixed-backend deployment appears, the `plain`-overload becomes a
     silent-misrender vector and Option B is no longer optional.
3. **Chunking stays the client's job; turns must not split mid-tag.** `ideal_words` chunking is
   already client-side (`server.py:979-981`); dia keeps `split_pattern='\n'`. The client MUST NOT break a
   `[S1]…` turn across two commits, and MUST NOT place a `\n` inside a turn it wants dia to render as
   one segment. **Open model-quality unknown:** dia is *assumed* (by analogy to Kokoro — **verify in
   Phase 0**) to generate each `\n`-separated turn as an independent segment, so prosodic continuity
   across an interruption is *not* guaranteed — the two-layout dialogue smoke (below) is what tells us
   whether it holds. If Phase 0 shows dia carries cross-segment state, this decision re-opens.

A `/review-plan` refresh on this resolved design was completed 2026-06-29; its findings are folded into
the Phase 0 gate and the checklist below.

## Implementation Checklist (after the design question is settled)

### Phase 0 — Verify dia against the live model (GATE; before any wiring)

`dia`/`mlx-audio` is **not installed** in the repo, so the behavioral claims this plan relies on are
**assumptions until checked against the real model**. Run this gate first (mlx-gated, local) and do
**not** proceed to Backend/wiring until every item passes; if one fails, **re-plan** rather than wire
around it. (`/review-plan` 2026-06-29 flagged each item below as a fact stated without verification.)

- [ ] **dia ships in the pinned wheel + concrete repo id.** Confirm `mlx-audio==0.4.4` actually
  contains a loadable dia family and pin a concrete repo id (as Kokoro/Pocket each do):
  `python -c "from mlx_audio.tts.models import dia"` plus a `load(<repo-id>)` smoke. If dia only landed
  in a later release or on `main`, the pin is wrong — stop.
- [ ] **Live signature.** `inspect.signature(model.generate)` — confirm the surveyed shape and in
  particular that `ref_text` is a **real** `generate()` kwarg (else its negative-guard guards nothing).
- [ ] **Bridge contract.** The shared `_stream_util` bridge HARD-REQUIRES `generate()` return a Python
  iterator whose items expose `.audio` materializing to a **1-D float32 mono** sequence
  (`_stream_util.py:97,203-207`). Assert iterator-ness and item-0 `.audio` shape/dtype. If dia returns
  a single result / ndarray / stereo / non-float32, the "reuses the bridge, no server-side changes"
  claim fails — stop and re-plan.
- [ ] **No-voice generation works.** Kokoro documents `voice=None` trips a broadcast-shape error in
  mlx-audio 0.4.4 (`kokoro.py:382-383`). Call `generate(text)` with no voice and confirm it produces
  audio rather than raising — dia must tolerate no-voice (tag-conditioned) generation.
- [ ] **`model.sample_rate` populated pre-warmup.** Confirm `getattr(model, "sample_rate", None)` is
  truthy immediately after `load()` (Kokoro/Pocket treat a missing rate as fatal). Record the value;
  do not assume Kokoro's 24000.
- [ ] **Segment independence (decision #3's premise).** Generate a 2-turn input, alter turn 1's text,
  re-generate; confirm turn 2's audio is unchanged — i.e. dia segments on `split_pattern='\n'` with no
  cross-segment decoder state. If dia DOES carry state across segments, decision #3 and the
  newline-layout smoke expectation change — re-open the design.

### Backend
- [ ] `backends/dia.py`. **Re-verify the live signature via `inspect.signature` before wiring**
  (R7/R8; pin `mlx-audio==0.4.4`). As surveyed 2026-06-24 (source read, line numbers approximate):
  `generate(text, voice=None, temperature=1.3, top_p=0.95, split_pattern='\n', max_tokens=None,
  verbose=False, ref_audio=None, ref_text=None, **kwargs)`. **NOT a streaming backend** — no `stream`
  param, uses `split_pattern` (segment-level, like Kokoro) → advertise **`streaming:false`** (assert
  `capabilities()["streaming"] is False`). extras `{temperature, top_p}`.
- [ ] Apply dia's **voice-ignore/OMIT rule** at the backend boundary — a **third** kwarg shape neither
  existing backend has. Pocket (`pocket_tts.py:163-166`) conditionally omits `voice` *when None*; Kokoro
  (`kokoro.py:312`) *always* passes `voice=self._voice`. dia must do neither: its `_gen_factory` MUST
  **never build a `voice` kwarg under any branch** (ignore `self._voice` entirely), and
  `open_stream(voice=...)` accepts-and-discards. This is the single enforcement point, because the
  server accepts a non-`None` client voice when `voice_count` is falsy (`server.py:752-768`) and carries
  it into `open_stream` (`server.py:1152`) — do **not** copy Pocket's conditional-omit, which would
  forward a non-None voice (the exact bug).
- [ ] **`voice_count:0` invariant — name both halves.** For `_validate_voice`'s accept branch to be
  reached deterministically, dia MUST (a) **not define a `voices()` method** (so
  `isinstance(backend, SupportsVoices)` is False at `server.py:1429-1441` / `backend.py:130` and
  `_voice_set` stays empty) **and** (b) advertise `voice_count: 0`. `_validate_voice` checks
  `_voice_set` *first* (`server.py:756-768`) and would *reject* a non-member voice if dia ever exposed a
  voice list. Lean test: a supplied `voice` on a `voice_count:0` dia backend does **not** error at the
  server boundary (complements the backend-layer "voice never reaches generate()" assertion).
- [ ] **Leave BOTH `ref_audio` AND `ref_text` unwired** (locked decision #2). Negative-guard test
  must cover `ref_text` too — assert at **both** layers (capabilities exclusion **and** absence at the
  `generate()` call boundary, as in v1 Phase 5b) for `{ref_audio, ref_text}`. **Phase 0 confirms
  `ref_text` is a real `generate()` kwarg** — if it is not, the boundary guard for `ref_text` is
  vacuous (the server already drops unadvertised keys; see `test_pocket_lean.py:142-150`).
- [ ] **Cancel latency caveat (inherited from Kokoro):** dia is segment-level, so a long single
  segment's backend `generate()` runs to its yield boundary before the Metal lock frees for the next
  commit. Per Kokoro's re-measurement (v1 plan Findings → *Phase 2 measured results*, 2026-06-26):
  the **client-visible cancel** (`response.cancel` → `response.cancelled`) is prompt (**~1 ms**,
  decoupled from the worker); only the **lock/slot release** waits for `generate()`'s yield boundary
  (bounded by `drain_timeout_seconds`). Carry Kokoro's resolution: hard guarantee is "no more deltas
  after `response.cancelled`"; chunking at sentence/newline boundaries still helps free the Metal lock
  faster for the NEXT commit (no longer needed for prompt client-visible barge-in).
- [ ] **Dialogue-mapping tests** (net-new, the reason this is its own plan) — these are **LEAN
  `_SpyModel` assertions, NOT the listen-and-judge smoke** (mirror `tests/test_pocket_lean.py:82-113`:
  a spy model records `generate()` kwargs, `open_stream` is called directly bypassing the server
  pre-filter). Assert, deterministically: `call["text"]` contains the `[S1]`/`[S2]` markers verbatim
  (pass-through intact), `text_format` stays `plain`, `capabilities()` advertises `voice_count: 0`, and
  `"voice" not in call` **even when `open_stream(voice="...")` was supplied** (decisions #1/#2). Only
  the *perceptual* speaker-switch effect is left to the smoke; pass-through is asserted here.
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
  3. **Short backchannel** — covered inside `podcast_turntaking.txt` as a one-word S2 interjection
     ("Mm-hmm") inside an S1 turn.
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
  1. backend module + `make_backend` resolver (`tts_server/backends/dia.py`,
     `tts_server/backends/__init__.py`, lazy-import branch, `mlx_audio` only in `start()`);
  2. CLI backend surface (`tts_server/__main__.py`): `_resolve_model` default branch
     (`__main__.py:34-56`) plus argparse `--backend` choices tuple (`__main__.py:306-310`) — a
     passing `make_backend` unit test will NOT catch a missing `--backend` choice;
  3. packaging/CI surface: `pyproject.toml` `dia` extra; `.github/workflows/test.yml` macOS
     `--all-extras` import-smoke block (`test.yml:115-136`) must import the dia backend module; the CI
     pytest allow-list (`test.yml:37-63`) must include any new dia lean test file; **and add
     `"tts_server.backends.dia"` to `_TTS_MODULES` in `tests/test_import_safety.py:27-37`** so the
     no-`mlx_audio`-at-module-load invariant is asserted for `dia.py` — a **separate list** from the CI
     allow-list (do not conflate); missing it is a silent gap (a dia.py importing `mlx_audio` at module
     top would pass CI), not a red state;
  4. renderer/launchd validation surface: renderer `_BACKEND_RE` and backend hint string
     (`scripts/render_tts_plist.py:56-58`, `scripts/render_tts_plist.py:186-191`) plus
     `scripts/install_tts_agent.sh:16` backend comment;
  5. docs/operator surfaces that name the shipped backend set: README install snippets, port table,
     backend/license/capabilities tables (`README.md:35-44`, `README.md:98-115`, `README.md:217-264`);
     `docs/protocol.md` shipped-backends/extras table (`docs/protocol.md:136-162`); `AGENTS.md`
     quick CLI/install/CI references (`AGENTS.md:21-24`, `AGENTS.md:33`, `AGENTS.md:59-63`);
     `CHANGELOG.md` reserved-dia note if the release notes are updated in the same branch;
  6. justfile backend-name surfaces: `_resolve` `(label, port)` row
     (`pipecat.tts-server.dia` → 9065 — the v1-reserved port), unknown-backend message, and
     `tts-status` backend-name case (`justfile:41-56`, `justfile:169-201`);
  7. generic/manual smoke surfaces that name or branch on the backend set: `tests/smoke/run_smoke.sh`
     backend validation / mlx-extra sync / synthesis case (`run_smoke.sh:52-59`, `run_smoke.sh:163-181`),
     `tests/smoke/run_multiconn.sh` mlx-extra sync list (`run_multiconn.sh:43-52`), and
     `tests/smoke/reconnect_smoke.py` `DEFAULT_VOICE` / argparse choices
     (`reconnect_smoke.py:51-58`, `reconnect_smoke.py:234-237`) if dia is expected to run those
     generic smokes rather than only `dia_dialogue_smoke.py`;
  8. **invert ALL the dia-absence assertions** in `tests/test_justfile_recipes.py` —
     `test_dia_is_absent_from_readme_and_renderer` (`:118-122`), `test_resolve_dia_exits_nonzero`
     (`:148-150`), the inline `_BACKEND_RE.match("dia")` guard (`:105`), **and the module docstring**
     (`:12-13`, the easy-to-miss one) — into positive presence assertions, matching the other backends.
     A partial inversion leaves a test asserting dia both present and reserved.
  Add a lean construction/lazy-import test for dia in the same commit. **Sequencing guard:** the
  Backend-section `dia.py` + its dialogue-mapping/voice lean tests MAY land in an earlier commit
  (creating `dia.py` + a `make_backend` branch does not add `dia` to argparse, so the drift tests stay
  green), but the **item-8 assertion inversions MUST belong to this atomic commit only** — inverting
  `test_dia_is_absent_*` before argparse includes `dia` asserts dia present in a set that still lacks it
  and goes red immediately. Phase 6 (launchd ops) has **already merged** (v1 plan, PR #7), so the
  launchd/operator surfaces are unconditional — not gated on "if Phase 6 has landed."
- [ ] Per-backend `sample_rate` discovery (R1/R3): expose `sample_rate` after `start()`/load so
  `server.hello.audio.rate` advertises the true model rate; mlx-gated test reads `model.sample_rate`
  (the config property), **not** a backend literal, and asserts it is **non-None/non-zero pre-warmup**
  (Phase 0 confirms the property exists and populates). dia's rate is per-model and unverified — do not
  assume it matches Kokoro's 24000.
- [ ] Packaging/CI: add the `pyproject.toml` `dia` extra (`mlx-audio==0.4.4`); the macOS smoke job
  already syncs `--all-extras` once v1 Phase 5a lands, so a new extra is install-smoked automatically;
  also add the dia backend module to the macOS import-smoke block so lazy module import is exercised.
  Backend synth tests stay local/mlx-gated only.
- [ ] If a new lean test file is added, extend the **CI pytest allow-list**
  (`.github/workflows/test.yml:37-63` — distinct from `_TTS_MODULES` in atomic item 3) in the same
  commit, or `pytest -x` skips it silently; prefer folding the negative-guard assertion into the
  already-allow-listed `tests/test_capabilities_extras.py` to avoid adding a new file at all. (The
  README/`docs/protocol.md` capabilities & extras table — including dia's `streaming:false` flag — and
  the justfile/port/renderer/drift-test surfaces are all covered by the single atomic dia-enablement
  commit above.)

## Acceptance Criteria
- `python -m tts_server serve --backend dia` serves; the `status` **reply dict** carries `backend=dia`
  + the model rate (lean dict-level assertion, as in `tests/test_status.py:27-45`; the CLI-print path
  stays a manual/mlx-gated check, not a lean test).
- `capabilities()["streaming"] is False`; `capabilities()["extras"] == ["temperature", "top_p"]`
  (ordered list, matching `docs/protocol.md` + `tests/test_capabilities_extras.py`) and excludes
  `ref_audio`/`ref_text`.
- `capabilities()` advertises `voice_count: 0` and `text_formats: ["plain"]`; `voice` is omitted from
  `generate()` even when supplied by a client, and `[S1]`/`[S2]` tags pass through to `generate()`
  intact (decisions #1/#2).
- `tests/smoke/dia_dialogue_smoke.py` runs against a live dia server and writes one WAV per script
  (both interruption layouts); the (a)-vs-(b) prosodic-continuity result is recorded in Findings.
- Lean CI unaffected; `mlx_audio` absent at import time (lazy).

## References
- Parent / pattern source: `docs/dev_plans/20260624-feature-tts-server-v1.md` — Phase 5a/5b are the
  backend-add template; *Locked design decisions* #2 (no `ref_audio`/cloning), R7 (per-backend
  extras), R1/R3 (rate contract), and the *Per sub-phase* checklist all apply here.

<!-- reviewed: 2026-06-29 @ fe4fae4eacd3f64227cb5488d95faca05002b957 -->
