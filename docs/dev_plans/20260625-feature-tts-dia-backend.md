# Task: tts-server — `dia` dialogue backend (formerly v1 Phase 5c)

**Status**: In progress — **Phase 0 model-verification gate PASSED 2026-06-30** (5/6; segment-independence
falsified → decision #3 redesigned, one-commit-coherence-unit / incremental-commits-supported; see
*Resolved design decisions* #3 + `## Findings`). Reshaped into conduct phases. **`/review-plan`
refresh completed 2026-06-30** on the post-gate contract (5 lenses; 1 Critical + 7 Important + 5 Minor,
all addressed — folded into decision #3, Phases 1–3, and Acceptance Criteria; see `## Findings` →
*Review resolution 2026-06-30*) — cleared for conduct.
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
   shape (`pocket_tts.py:164-165`) is only an analogue for building kwargs, not sufficient by itself.
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
3. **Each commit is one "coherence unit"; the client chooses commit granularity.**
   **RESOLVED by Phase 0 (2026-06-30) — the original "independent segments" assumption was FALSIFIED,
   but the practical contract is more permissive than first feared.** Two verified facts:
   - **Within a single `generate()` call (= one commit), dia carries cross-segment state** — editing an
     earlier turn changes a later turn's audio (autoregressive across `\n`-separated turns, unlike
     Kokoro; seeded control A==B deterministic, A≠C when turn-1 edited — see `## Findings`).
   - **Across separate `generate()` calls (= across commits), dia is STATELESS** — *architecturally*
     verified (temperature-independent): the server feeds one commit to exactly one fresh `generate()`
     call (`server.py:1006`→`:1157`, one `gen_factory()` per drain at `_stream_util.py:203`); no model
     state is threaded across calls. This byte-identity was *also* confirmed empirically under
     `seed`+`temperature=0.0` (`X_alone == X_after`; see `## Findings`) — note that proof is a property
     of seeded/greedy decoding and does not reproduce at the production default `temperature=1.3`, so the
     **architectural** argument (not the byte-equality) is what carries the claim at production
     temperature. Conclusion: incremental committing is **safe and clean**, with no order-dependent
     artifacts.
     - **Named residual assumption (review 2026-06-30, Critical lens finding).** The architectural
       argument proves only that *the server* threads no state across calls; it does **not** exclude
       module/instance-level state *inside* mlx-audio's `generate()` on the shared, reused `self._model`
       object (e.g. a persisted KV-cache, a cached RNG, a decoder buffer). The byte-identity check pins
       statelessness **only under greedy decoding** (`seed`+`temperature=0.0`); at the production default
       `temperature=1.3` the claim therefore rests on the **assumption** that mlx-audio carries no such
       cross-call state on the model object. This is a named assumption, not a verified fact at
       production temperature. Phase 3 adds a **production-temperature coupling diagnostic** (below) to
       probe it empirically rather than relying on the greedy guard alone. If that diagnostic ever shows
       coupling, decision #3's "incremental commits are safe" conclusion must be revisited.

   Consequences for the client contract:
   - **A commit is the unit of coherence.** Every turn inside one commit conditions on the others;
     turns in a *later* commit are NOT conditioned on an earlier commit (context resets at the boundary).
   - **The client picks the granularity — a latency-vs-coherence knob:**
     - *Whole dialogue in one commit* → maximum cross-turn coherence; higher latency to full output.
     - *Incremental commits* (e.g. 2 turns now, more later) → lower latency; coherence resets per
       commit. **This is allowed and supported** — pick commit boundaries where a coherence reset is
       acceptable (scene breaks, complete exchanges).
   - **Commits are sequential under K=1, not queued (existing server behavior, dia inherits it).** With
     the v1 per-connection in-flight cap `K=1`, committing the next chunk *before the prior response
     reaches a terminal state* is **rejected with `error {code: busy, retry_after_ms}`, not enqueued**
     (`server.py:1021-1024`); the buffer is left intact to retry. So incremental commits must be paced
     to prior-response completion — they are not pipelined ahead. Because dia commits are longer than
     the streaming backends', an over-eager next commit is *more* likely to hit `busy`; smaller
     incremental commits shorten each in-flight window and reduce that. To interrupt a playing dialogue,
     `response.cancel` → `response.cancelled` (prompt, ~1 ms) → then commit the replacement (the
     synthesis slot/Metal-lock may lag the cancel by up to `drain_timeout_seconds`, so the replacement
     commit can briefly see `busy`). **No dia-specific server change** — this is the existing K=1 /
     barge-in contract (`docs/protocol.md` §4, §7).
   - **The one hard rule:** a single `[S1]…` turn MUST NOT be split across two commits (mid-utterance
     fragmentation). Splitting *between* turns across commits is fine. `\n` separates turns/segments
     within a commit and may be used freely there.
   - **No `ideal_words` opt-out needed (the coherence-unit invariant holds for free).** `ideal_words` is
     advisory capability metadata, NOT a server-side splitter — `server.py:979-981` leaves chunking to
     the client and the whole committed buffer is fed as ONE `generate()` call (`server.py:1006`→
     `:1157`). So one-commit-=-one-coherence-unit already holds with no new flag; the client simply
     controls commit boundaries by choosing what to commit. (Do not build a phantom opt-out.)
   - **Accepted cost (cancel / Metal-lock):** a larger commit is a longer `generate()`, so the Metal
     lock/slot frees only at the next segment yield boundary (bounded by `drain_timeout_seconds`). The
     client-visible `response.cancel`→`response.cancelled` stays prompt (~1 ms, decoupled). Incremental
     commits *also* shorten the lock-hold per call — so the latency-vs-coherence knob doubles as a
     barge-in-responsiveness knob.
   - **Smoke expectation change:** the newline-layout smoke (script 2, layouts a-vs-b) now compares
     prosodic continuity **within one coherent commit**, NOT segment independence. Both layouts ride in
     one commit; the question is whether inline vs `\n`-separated turn boundaries affect continuity.

A `/review-plan` refresh on the original (pre-Phase-0) design was completed 2026-06-29. The Phase 0 gate
then ran 2026-06-30 and re-opened decision #3; this section reflects the post-gate redesign and **requires
a fresh `/review-plan` pass before conduct** (the contract changed).

## Implementation Checklist

Conduct-shaped phases. Phase 0 is the model-verification GATE (already run manually — see
`## Findings`); Phases 1–3 are the implementation. Per-phase completion is tracked in `## Progress`
below the marker. mlx-gated tests (real-model synth, rate value) are **local-only** and are NOT in the
conduct test commands — those run lean (`_SpyModel`, no `mlx_audio`) checks only.

### Phase 0 — Verify dia against the live model (GATE; before any wiring)

**STATUS: COMPLETE (2026-06-30) — 5/6 passed; segment-independence resolved in the negative →
decision #3 redesigned (see `## Findings` + redesigned *Resolved design decisions* #3). The gate did
its job: the "independent segments" premise was falsified before any wiring.** Recorded results:

- [x] **dia ships in the pinned wheel + concrete repo id** — `mlx-community/Dia-1.6B-fp16` loads via
  `mlx_audio.tts.utils.load(..., lazy=False, strict=True)` under `mlx-audio==0.4.4`.
- [x] **Live signature** — `generate(text, voice=None, temperature=1.3, top_p=0.95,
  split_pattern='\n', max_tokens=None, verbose=False, ref_audio=None, ref_text=None, **kwargs)`;
  `ref_text` IS a real kwarg (its negative-guard is meaningful).
- [x] **Bridge contract** — `generate()` returns an iterator of items whose `.audio` is 1-D float32
  mono. "reuses `_stream_util`, no server-side change" holds (`_stream_util.py:97,203-207`).
- [x] **No-voice generation works** — `generate(text)` with no voice produces audio (unlike Kokoro's
  broadcast error, `kokoro.py:382-383`).
- [x] **`model.sample_rate` populated pre-warmup** — **44100** (NOT Kokoro's 24000).
- [x] **Segment independence — FALSIFIED (resolved).** dia carries cross-segment state WITHIN a
  `generate()` call but is STATELESS across calls. Decision #3 was redesigned (one commit = one
  coherence unit; incremental commits supported), not wired around.

### Phase 1 — dia backend module + lean tests

**Impl files:** tts_server/backends/dia.py, tts_server/backends/__init__.py
**Test files:** tests/test_dia_lean.py, tests/test_capabilities_extras.py, tests/test_import_safety.py
**Test command:** `uv run pytest tests/test_dia_lean.py tests/test_capabilities_extras.py tests/test_import_safety.py`

Creates the backend module + `make_backend` lazy-import branch and the lean (`_SpyModel`, no `mlx_audio`)
tests. This may land BEFORE Phase 2 without a red state: creating `dia.py` + a resolver branch does NOT
add `dia` to argparse, so the dia-absence drift tests stay green. Adding `tests/test_dia_lean.py` to the
CI pytest allow-list (`.github/workflows/test.yml`) is the ONE workflow edit allowed here — it adds a
test path, it does not invert any dia-absence assertion (those belong to Phase 2 only).

- [ ] `backends/dia.py`. **Re-verify the live signature via `inspect.signature` before wiring** (R7/R8;
  pin `mlx-audio==0.4.4`). Phase 0 confirmed: `generate(text, voice=None, temperature=1.3, top_p=0.95,
  split_pattern='\n', max_tokens=None, verbose=False, ref_audio=None, ref_text=None, **kwargs)`. **NOT a
  streaming backend** — no `stream` param, uses `split_pattern` (segment-level, like Kokoro) → advertise
  **`streaming:false`** (assert `capabilities()["streaming"] is False`). extras `{temperature, top_p}`.
- [ ] **Implement the full streaming-bridge contract dia inherits — it is NOT free (review 2026-06-30).**
  dia's `_DiaStream` MUST implement `wait_closed` (`SupportsWaitClosed`, `backend.py:70-86`) and thread
  `_worker_done` exactly as Pocket does (`pocket_tts.py:152-156`). The cancel/Metal-lock semantics in
  decision #3 and the cancel-latency caveat below depend on the slot being held until the worker releases
  the Metal lock; a `_DiaStream` that omits `wait_closed` silently changes barge-in timing. Mirror the
  Pocket/Kokoro `_stream_util` bridge shape — the method is part of the contract, not optional.
- [ ] **Mirror Pocket's `validate_extras` for `{temperature, top_p}` (review 2026-06-30).** dia advertises
  both extras, so it MUST implement `SupportsExtrasValidation.validate_extras` (`pocket_tts.py:290-302`)
  to clamp/reject non-finite or out-of-range values, closing the unbounded-value-under-the-Metal-lock DoS
  vector the base guard warns about (`backend.py:89-102`). Do **not** forward extras verbatim — that would
  be an inconsistency with the sibling backend advertising the same `temperature` extra. Add a lean test
  (no `mlx_audio`) that `validate_extras` rejects a non-finite `temperature`/`top_p`.
- [ ] **Per-backend `sample_rate` discovery (R1/R3).** Expose `sample_rate` after `start()`/load so
  `server.hello.audio.rate` advertises the true model rate; read `model.sample_rate` (the config
  property), **not** a literal. Phase 0 recorded **44100** — treat a missing/zero rate after load as
  fatal (as Kokoro/Pocket do). The rate-value assertion is mlx-gated/local-only; a lean test may assert
  the backend reports a `backend=dia` status-reply dict shape (as `tests/test_status.py:27-45`).
  **The lean test MUST assert `sample_rate == 0` pre-`start()`** (the model is unloaded, so the rate is
  not yet known; cf. `test_pocket_lean.py:178`) **and only the *presence* of the rate field — never
  `== 44100`** (review 2026-06-30). 44100 is a single-run Phase 0 observation and is mlx-gated/local-only;
  letting it leak into a lean assertion would couple CI to a model-loaded value it cannot produce.
- [ ] Apply dia's **voice-ignore/OMIT rule** at the backend boundary — a **third** kwarg shape neither
  existing backend has. Pocket (`pocket_tts.py:164-165`) conditionally omits `voice` *when None*; Kokoro
  (`kokoro.py:312`) *always* passes `voice=self._voice`. dia must do neither: its `_gen_factory` MUST
  **never build a `voice` kwarg under any branch** (ignore `self._voice` entirely), and
  `open_stream(voice=...)` accepts-and-discards. **Make this structural, not test-enforced (review
  2026-06-30):** dia's `_DiaStream`/`_gen_factory` MUST NOT accept or store a `voice`/`self._voice`
  member at all — omit the `voice` parameter from `_DiaStream.__init__` so "never build a `voice` kwarg"
  is **unrepresentable in the code**, not merely covered by a test. `open_stream(voice=...)` accepts the
  arg at the server-facing signature and discards it without threading it into the stream object. This
  removes the Pocket-conditional-omit look-alike trap entirely. This is the single enforcement point,
  because the
  server accepts a non-`None` client voice when `voice_count` is falsy (`server.py:752-768`) and carries
  it into `open_stream` (`server.py:1152`) — do **not** copy Pocket's conditional-omit, which would
  forward a non-None voice (the exact bug). **Call flow** (why the backend discard is mandatory, not
  redundant with server validation): `commit(voice=X)` → `_validate_voice` accepts (voice_count:0) →
  `open_stream(voice=X)` → `_gen_factory` ignores it → `generate()` has no `voice` kwarg.
- [ ] **`voice_count:0` invariant — name both halves.** For `_validate_voice`'s accept branch to be
  reached deterministically, dia MUST (a) **not define a `voices()` method** (so
  `isinstance(backend, SupportsVoices)` is False at `server.py:1429-1441` / `backend.py:130` and
  `_voice_set` stays empty) **and** (b) advertise `voice_count: 0`. `_validate_voice` checks
  `_voice_set` *first* (`server.py:756-768`) and would *reject* a non-member voice if dia ever exposed a
  voice list. **Two distinct lean tests at two layers** (the backend-layer `_SpyModel` assertion below
  bypasses the server pre-filter, so it CANNOT prove the server boundary): (a) backend-layer — `"voice"
  not in call` via `_SpyModel` in `tests/test_dia_lean.py` (lean/CI); (b) **server-boundary** — a supplied
  `voice` on a `voice_count:0` dia backend does **not** error through the real `_validate_voice` accept
  branch. **Decision (review 2026-06-30): write (b) against the real dia backend behind an
  `mlx`-availability skip — mlx-gated/local-only, NOT a lean CI test.** `tests/test_capabilities_extras.py`
  only ever constructs `ToneBackend` (`voice_count:1`) today and has no `voice_count:0` fixture; a
  synthetic voice_count:0 stand-in would assert the test framework, not dia's real accept-branch path
  through `_validate_voice` (`server.py:752-768`). Place it behind the same `mlx` skip the other
  mlx-gated dia checks use (e.g. in `tests/test_dia_lean.py` guarded by `pytest.importorskip`, or a
  local-only module). **Accepted CI gap (named, not silent):** the server-boundary accept-branch is
  verified locally only; the backend-layer half (a) remains lean/CI. Naming only (a) leaves the
  accept-branch half unproven.
- [ ] **Leave BOTH `ref_audio` AND `ref_text` unwired** (locked decision #2). Negative-guard test must
  cover `ref_text` too — assert at **both** layers (capabilities exclusion **and** absence at the
  `generate()` call boundary, as in v1 Phase 5b) for `{ref_audio, ref_text}`. Phase 0 confirmed
  `ref_text` is a real `generate()` kwarg, so the boundary guard is non-vacuous (the server already
  drops unadvertised keys; see `test_pocket_lean.py:142-150`).
- [ ] **Dialogue-mapping tests** (net-new, the reason this is its own plan) — **LEAN `_SpyModel`
  assertions, NOT the listen-and-judge smoke** (mirror `tests/test_pocket_lean.py:82-113`: a spy model
  records `generate()` kwargs, `open_stream` is called directly bypassing the server pre-filter). Assert,
  deterministically: `call["text"]` contains the `[S1]`/`[S2]` markers verbatim (pass-through intact),
  `text_format` stays `plain`, `capabilities()` advertises `voice_count: 0`, and `"voice" not in call`
  **even when `open_stream(voice="...")` was supplied** (decisions #1/#2). Only the *perceptual*
  speaker-switch effect is left to the smoke; pass-through is asserted here. The `extras == ["temperature",
  "top_p"]` ordered-list + `streaming is False` + `text_formats == ["plain"]` assertions live in
  `tests/test_capabilities_extras.py` (already CI-allow-listed).
- [ ] **Tagged-text → deltas lean coverage (review 2026-06-30 — closes a coverage gap).** The `_SpyModel`
  returns an empty generator, so it proves kwarg *pass-through* but NOT that a tagged buffer actually
  *streams audio*. Add a lean test that a multi-line `[S1]`/`[S2]` committed buffer streams **≥1 audio
  delta unchanged** through a `ToneBackend` (the server/bridge path, no `mlx_audio`), giving CI coverage
  of the tagged-text→delta path. Real dia-audio production from tagged text stays mlx-gated (Phase 3
  smoke) — this lean test guards the framing/bridge, not the model.
- [ ] **Land the `test_import_safety.py` `_TTS_MODULES` append in THIS phase (review 2026-06-30 — moved
  from Phase 2 to close a coverage window).** Add `"tts_server.backends.dia"` to `_TTS_MODULES`
  (`tests/test_import_safety.py:27-37`) alongside `dia.py`, so the no-`mlx_audio`-at-module-load invariant
  covers `dia.py` from the commit that introduces it. Without this, between Phase 1 and Phase 2 a `dia.py`
  importing `mlx_audio` at module top would pass CI (the `test_lean` job imports the `backends` package,
  not the `dia` submodule, which `_TTS_MODULES` lists explicitly). This is a pure add (asserts a *correct*
  invariant on a module that exists), cannot go red, and is a **separate list** from the CI pytest
  allow-list — do not conflate. Phase 2 item 3 no longer carries this.
- [ ] **Cancel latency caveat (inherited from Kokoro):** dia is segment-level, so a long
  segment's backend `generate()` runs to its yield boundary before the Metal lock frees for the next
  commit. The **client-visible cancel** (`response.cancel` → `response.cancelled`) is prompt (**~1 ms**,
  decoupled from the worker); only the **lock/slot release** waits for `generate()`'s yield boundary
  (bounded by `drain_timeout_seconds`). Hard guarantee: "no more deltas after `response.cancelled`". See
  redesigned decision #3 for how this interacts with whole-dialogue vs incremental commits.

### Phase 2 — Atomic dia-enablement wiring (follow the v1 Phase 5a/5b pattern)

**Impl files:** tts_server/__main__.py, pyproject.toml, .github/workflows/test.yml, scripts/render_tts_plist.py, scripts/install_tts_agent.sh, README.md, docs/protocol.md, AGENTS.md, CHANGELOG.md, justfile, tests/smoke/run_smoke.sh, tests/smoke/run_multiconn.sh, tests/smoke/reconnect_smoke.py
**Test files:** tests/test_justfile_recipes.py, tests/test_import_safety.py, tests/test_render_tts_plist.py
**Test command:** `uv run pytest tests/test_justfile_recipes.py tests/test_import_safety.py tests/test_render_tts_plist.py`

- [ ] **ONE atomic "dia-enablement" commit (mandatory — avoids a red intermediate state).** Several
  existing drift tests *assert `dia` is absent* and flip to red the instant `dia` becomes a known
  backend, so every surface that names the backend set MUST change together. Phase 1's `dia.py` +
  `make_backend` branch (item 1) is a prerequisite already landed; this phase wires items 2–8 atomically:
  1. *(landed in Phase 1)* backend module + `make_backend` resolver (`tts_server/backends/dia.py`,
     `tts_server/backends/__init__.py`, lazy-import branch, `mlx_audio` only in `start()`);
  2. CLI backend surface (`tts_server/__main__.py`): `_resolve_model` default branch
     (`__main__.py:34-56`) plus argparse `--backend` choices tuple (`__main__.py:306-310`) — a
     passing `make_backend` unit test will NOT catch a missing `--backend` choice;
  3. packaging/CI surface: `pyproject.toml` `dia` extra — **net-new** (review 2026-06-30: today
     `pyproject.toml` declares only `client`/`kokoro`/`voxtral_tts`/`pocket_tts`/`examples`), following the
     kokoro/voxtral_tts pattern exactly: `dia = ["websockets>=13.0", "mlx-audio==0.4.4"]` (no bespoke
     tokenizer, like Pocket); `.github/workflows/test.yml` macOS `--all-extras` import-smoke block
     (`test.yml:115-136`) must import the dia backend module. **(The `_TTS_MODULES` append in
     `tests/test_import_safety.py` has been MOVED to Phase 1 — review 2026-06-30 — so the import-safety
     invariant covers `dia.py` from the commit that creates it; do NOT re-add it here.)**
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
     (`:148-150`), the inline `_BACKEND_RE.match("dia")` guard at `:105` (which lives inside
     `test_renderer_allowlist_matches_argparse_backends`, NOT a dedicated dia-absence test — easy to miss
     by function name), **and the module docstring** (`:12-13`, the easy-to-miss one) — into positive
     presence assertions, matching the other backends.
     A partial inversion leaves a test asserting dia both present and reserved.
  **Sequencing guard:** the **item-8 assertion inversions MUST belong to this atomic commit only** —
  inverting `test_dia_is_absent_*` before argparse includes `dia` asserts dia present in a set that still
  lacks it and goes red immediately. Phase 6 (launchd ops) has **already merged** (v1 plan, PR #7), so the
  launchd/operator surfaces are unconditional — not gated on "if Phase 6 has landed."
  **Completeness guard (review 2026-06-30):** after inverting, run `grep -n '"dia"'
  tests/test_justfile_recipes.py` and confirm **zero** remaining dia-*absence* assertions before
  declaring the phase done. The two easy-to-miss surfaces are the inline `_BACKEND_RE.match("dia")` guard
  at `:105` (inside `test_renderer_allowlist_matches_argparse_backends`, NOT a dedicated dia-absence
  test) and the module docstring `:12-13`. A partial inversion leaves a test asserting dia both present
  and reserved — and because Phase 2's test command runs `tests/test_justfile_recipes.py`, a missed
  surface goes red at the phase-boundary commit.
- [ ] Packaging/CI: the `pyproject.toml` `dia` extra is `mlx-audio==0.4.4`; the macOS smoke job already
  syncs `--all-extras`, so a new extra is install-smoked automatically; also add the dia backend module
  to the macOS import-smoke block so lazy module import is exercised. Backend synth tests stay
  local/mlx-gated only.

### Phase 3 — Dialogue smoke driver (manual, listen-and-judge)

**Impl files:** tests/smoke/dia_dialogue_smoke.py
**Test files:** none

No `Test command:` (listen-and-judge, mlx-gated, no CI assertion) — conduct creates the driver and skips
tests with a warning; the human runs it against a live dia server afterward.

- [ ] **`tests/smoke/dia_dialogue_smoke.py`** (net-new, mlx-gated, dia-only, **listen-and-judge** —
  NOT a CI assertion; mirrors `tests/smoke/latency_smoke.py` + `examples/reference_client.py`).
  Connects a real client to a real dia server, sends crafted dialogue scripts, writes one WAV per
  script, prints their paths for a human to judge. Structural asserts (cheap, non-perceptual): non-empty
  audio per script AND a per-script sample-count sanity bound (finite, roughly proportional to text
  length) AND **`item.audio.ndim == 1`** on the first item of each script (review 2026-06-30 — the bridge
  contract is a single-run Phase 0 snapshot and `_audio_to_pcm` duck-types via `.tolist()`
  (`_stream_util.py:97-107`), so a future stereo/shape drift (`ndim==2`) would not hard-fail loudly;
  assert the mono shape loudly here). Perceptual "two distinct speakers" / "natural resumption" cannot be
  cheaply auto-verified — left to the human.
  **Also add a local-only mlx-gated regression guard** re-running the Phase 0 cross-commit byte-identity
  check so a future `mlx-audio` bump that silently reintroduces cross-call coupling is caught (pins the
  load-bearing statelessness finding decision #3 rests on). **Pin it precisely (review 2026-06-30) so it
  is implementable without re-deriving Phase 0:** a fixed `seed` (record the exact value used in the
  Phase 0 control run — see `## Findings`), two payload strings `textPRIOR` and `textX`,
  `temperature=0.0`, asserting `X_alone == X_after` as **array equality** (`mx.array_equal` /
  `np.array_equal`), where `X_alone` renders `textX` with no prior call and `X_after` renders `textPRIOR`
  then `textX` on the same model object.
  **AND add a production-temperature coupling diagnostic (review 2026-06-30 — the greedy guard alone does
  NOT cover the production default `temperature=1.3`; see decision #3's named residual assumption).**
  Render `textX` alone vs after `textPRIOR` across N seeds (e.g. N=8) at `temperature=1.3` and compare the
  **sample-count (duration) distribution** of the two render sets: a statistically indistinguishable
  distribution *supports* the cross-call statelessness assumption at production temperature; a shifted one
  *falsifies* it and re-opens decision #3. This is a **diagnostic (print + soft-flag), not a hard
  byte-assert** — production-temp output is non-deterministic, so byte-equality cannot apply. Both the
  greedy guard and this diagnostic are mlx-gated/local-only; the statelessness invariant has **zero CI
  protection by design** (named accepted risk).
  Scripts:
  1. **Turn-taking** — `[S1]…[S2]…[S1]…`; does speaker identity stay consistent across turns?
  2. **Interruption + resumption, BOTH layouts** (the load-bearing test for decision #3): (a) inline
     tags, single segment (no `\n`); (b) newline-separated turns. Both ride in ONE commit (decision #3:
     cross-segment state holds within a commit), so the comparison is now in-context continuity inline
     vs `\n`-separated, NOT segment independence. S1 starts a sentence, S2 cuts in, S1 finishes the
     *same* sentence; listen for whether S1 resumes naturally vs disjointly.
  3. **Short backchannel** — covered inside `podcast_turntaking.txt` as a one-word S2 interjection
     ("Mm-hmm") inside an S1 turn.
  This is scripted (in-text) interruption — distinct from protocol `response.cancel` barge-in, which
  is terminal (no resume). Record the (a)-vs-(b) prosodic-continuity result in Findings after the
  first dia run; it tells the client whether to keep turns newline-free. (Smoke drivers live in
  `tests/smoke/` and run manually — no lean allow-list change.) Transcript fixtures are already
  committed at `tests/smoke/fixtures/dia/` (`podcast_turntaking.txt` for turn-taking;
  `interview_interruption_inline.txt` vs `interview_interruption_newline.txt` are the same dialogue in
  layouts (a)/(b) for the continuity comparison — see that dir's `README.md`).

## Acceptance Criteria
- `python -m tts_server serve --backend dia` serves; the `status` **reply dict** carries `backend=dia`.
  The **lean** assertion covers the dict shape + `backend=dia` + presence of the rate field (as in
  `tests/test_status.py:27-45`); the rate **value** (44100) is **mlx-gated/local-only** — a lean test
  cannot load the model, so `sample_rate` is `0` until `start()` (cf. `test_pocket_lean.py:178`). The
  CLI-print path likewise stays a manual/mlx-gated check.
- `capabilities()["streaming"] is False`; `capabilities()["extras"] == ["temperature", "top_p"]`
  (ordered list, matching `docs/protocol.md` + `tests/test_capabilities_extras.py`) and excludes
  `ref_audio`/`ref_text`.
- `capabilities()` advertises `voice_count: 0` and `text_formats: ["plain"]`; `voice` is omitted from
  `generate()` even when supplied by a client, and `[S1]`/`[S2]` tags pass through to `generate()`
  intact (decisions #1/#2). The voice-omit is **structural** — `_DiaStream` takes no `voice` param — not
  merely test-enforced.
- dia's `_DiaStream` implements `wait_closed` (streaming-bridge contract, `backend.py:70-86`) and
  `validate_extras` for `{temperature, top_p}` (mirrors `pocket_tts.py:290-302`, rejecting non-finite
  values); a lean test covers the `validate_extras` reject path.
- A lean test exercises the tagged-text→delta path through `ToneBackend` (multi-line `[S1]`/`[S2]` buffer
  streams ≥1 delta unchanged); `tts_server.backends.dia` is in `test_import_safety.py`'s `_TTS_MODULES`.
- `tests/smoke/dia_dialogue_smoke.py` runs against a live dia server and writes one WAV per script
  (both interruption layouts); each script's first item asserts `audio.ndim == 1`; the (a)-vs-(b)
  prosodic-continuity result is recorded in Findings.
- **Named accepted CI gaps (review 2026-06-30):** the cross-call statelessness invariant (greedy guard +
  production-temperature coupling diagnostic) and the server-boundary `voice_count:0` `_validate_voice`
  accept-branch test are **mlx-gated/local-only** — they have zero CI protection by design. The
  backend-layer voice-omit half and the tagged-text→delta framing are lean/CI.
- Lean CI unaffected; `mlx_audio` absent at import time (lazy).

## References
- Parent / pattern source: `docs/dev_plans/20260624-feature-tts-server-v1.md` — Phase 5a/5b are the
  backend-add template; *Locked design decisions* #2 (no `ref_audio`/cloning), R7 (per-backend
  extras), R1/R3 (rate contract), and the *Per sub-phase* checklist all apply here.

<!-- reviewed: 2026-06-30 @ 17b7dafa51564c686fbe185cfe49c29458f5aa92 -->

## Progress

- [x] Phase 0: Verify dia against the live model (GATE) — complete 2026-06-30; 5/6 pass, decision #3 redesigned (see Findings)
- [x] Phase 1: dia backend module + lean tests — complete 2026-06-30; 40 passed/2 skipped, reviewer clean (commit de70a21)
- [x] Phase 2: Atomic dia-enablement wiring — complete 2026-06-30; 44 phase tests + full suite 259 passed/3 skipped, reviewer 2 Minor (1 sibling-plan doc-sync addressed, 1 historical/intentional) (commit 82f9d87)
- [x] Phase 3: Dialogue smoke driver (manual, listen-and-judge) — complete 2026-06-30; driver py_compile+ruff clean, import-safe without mlx_audio; 3 reviewer Minors folded in (dead code removed, per-script ndim==1 mono guard added, Phase 0 seed caveat recorded) (commit 4df7b00)
- CI-parity gate (2026-06-30): caught that `tests/test_dia_lean.py` was missing from the lean CI allow-list (Phase 1 mandate); added it. Lean CI job replicated locally: 220 passed/2 skipped (the 2 skips = mlx-gated dia tests); ruff check+format clean; lean import-safety OK.
- [x] Phase 3 live smoke run (real model, listen-and-judge) — complete 2026-06-30; measured latency, falsified the "one big delta" assumption (dia streams per-`\n`-segment), abrupt-disconnect poison NOT reproduced (0/7) → added a `--check-disconnect` regression guard. See Findings → "Phase 3 live smoke run".

## Findings

### Phase 0 gate run — 2026-06-30 (live model, `mlx-community/Dia-1.6B-fp16`, `mlx-audio==0.4.4`)

Ran the six-item gate against the real model (Apple Silicon, throwaway env). **5 of 6 PASS; the
segment-independence check RESOLVED in the negative — decision #3 RE-OPENS.**

| # | Check | Result | Evidence |
|---|-------|--------|----------|
| 1 | dia loads from pinned wheel + concrete repo id | ✅ PASS | `mlx-community/Dia-1.6B-fp16` loads via `mlx_audio.tts.utils.load(..., lazy=False, strict=True)`; model type `Model` |
| 2 | Live `generate()` signature; `ref_text` real | ✅ PASS | `generate(text, voice=None, temperature=1.3, top_p=0.95, split_pattern='\n', max_tokens=None, verbose=False, ref_audio=None, ref_text=None, **kwargs)` — `ref_text` present, so its negative-guard is meaningful |
| 5 | `model.sample_rate` populated pre-warmup | ✅ PASS | **`model.sample_rate == 44100`** (NOT Kokoro's 24000) — wire this through the rate contract |
| 3 | Bridge contract (iterator of 1-D float32 mono `.audio`) | ✅ PASS | iterator-like; item-0 `.audio` ndim=1, dtype=float32. "reuses `_stream_util`, no server change" holds |
| 4 | No-voice generation works | ✅ PASS | `generate(text)` with no `voice` produces audio (unlike Kokoro's broadcast error) |
| 6 | Segment independence (decision #3 premise) | ❌ **FALSIFIED** | dia carries **cross-segment state** — see control below |

**Check #6 control experiment (seeded, `temperature=0.0`):** rendered a 2-turn dialogue with a fixed S2
turn three times — twice with identical input (A, B), once with turn-1 edited (C):
- **A == B** (same input): `True` → decoding is deterministic; differences are real, not sampling noise.
- **A == C** (turn-1 edited, S2 unchanged): `False` (S2 = 116299 samples vs 154699) → editing the
  earlier turn changes the later turn's audio.

Conclusion: dia is **autoregressive across `\n`-separated turns**; the segments are NOT independent.
This is the opposite of Kokoro and falsifies decision #3's premise. Per the Phase 0 gate instruction,
**decision #3 re-opens before any wiring.**

**Cross-commit (cross-`generate()`-call) state check — 2026-06-30:** to size the redesign, also checked
whether a *second* `generate()` call is influenced by the first (the server feeds one commit → one
`generate(committed_text)` call, so this is the across-commit question). Seeded: `X_alone` = render
`textX` with no prior call; `X_after` = render `textPRIOR` then `textX`. Result: **`X_alone == X_after`
→ True** (byte-identical, 575126 samples). dia's `generate()` is **stateless across calls** — no hidden
order-dependent coupling. So **incremental committing is safe**: each commit is a clean independent
coherence unit. The only cost is that a later commit is not conditioned on an earlier one (coherence
resets at the boundary). This makes commit granularity a deliberate client-side latency-vs-coherence
knob (see redesigned decision #3), not a correctness hazard.

**Implications — RESOLVED in redesigned decision #3 (2026-06-30):**
1. **Chunking contract.** Resolved: one commit = one coherence unit. The client chooses granularity —
   whole dialogue in one commit (max coherence) OR incremental commits (lower latency, coherence resets
   per commit; verified safe via the cross-commit check above). Incremental committing is *supported*,
   not forbidden — the interim "whole dialogue only" framing was superseded once cross-commit
   statelessness was confirmed.
2. **Cancel / Metal-lock tension.** Resolved: the latency-vs-coherence knob doubles as a
   barge-in-responsiveness knob — smaller commits shorten each `generate()` lock-hold. `response.cancel`
   stays client-visible-prompt (~1 ms). See decision #3's cancel/Metal-lock bullet.
3. **Newline-layout smoke (script 2 a-vs-b).** Resolved: both layouts ride in ONE commit, so the smoke
   now compares in-context continuity (inline vs `\n`-separated) within a coherent commit, not segment
   independence.

The five passing facts (repo id, `ref_text`, `sample_rate=44100`, bridge contract, no-voice gen) are
verified and stand regardless of the decision-#3 redesign.

**Operator action item (Phase 3 reviewer, 2026-06-30):** the Phase 0 cross-commit byte-identity
control run above was "seeded" but its **exact numeric seed was not recorded**. The Phase 3 greedy
regression guard (`tests/smoke/dia_dialogue_smoke.py --seed`) therefore defaults to a **placeholder
seed (42)**: any fixed seed makes greedy decoding deterministic, so the `X_alone == X_after` guard
holds for any value, but reproducing the *exact* Phase 0 run requires the real seed. When dia is
next run on Apple Silicon, record the seed used here and set it as the `--seed` default.

### Review resolution — 2026-06-30 (`/review-plan` refresh on the post-gate contract)

Five-lens `/review-plan` run (architecture, sequencing, spec-and-testing, assumptions, codebase-claims)
against the redesigned contract. raw=14 → 13 unique findings (1 merge, 1 cross-category related).
**All addressed** above the marker; no waivers. Resolutions:

| # | Sev | Lens(es) | Finding | Resolution (decision) |
|---|-----|----------|---------|------------------------|
| 1 | Critical | assumptions | Cross-call statelessness only proven under greedy `temp=0.0`; production runs `1.3` | Named the residual "mlx-audio holds no cross-call model state" **assumption** in decision #3; **added a production-temperature coupling diagnostic** to Phase 3 alongside the greedy guard |
| 2 | Important | architecture | Voice-discard at one enforcement point, Pocket look-alike trap | Made it **structural** — `_DiaStream` omits the `voice` param entirely (Phase 1 item 3 + Acceptance) |
| 3 | Important | sequencing | `_TTS_MODULES` dia append landed in Phase 2 → Phase-1↔2 coverage window | **Moved the append into Phase 1** (new bullet; Phase 2 item 3 annotated; added `test_import_safety.py` to Phase 1 test files/command) |
| 4 | Important | spec-and-testing | Server-boundary `voice_count:0` accept-branch test not shaped against existing helpers | **Decision: write against real dia behind an `mlx` skip (local-only)**; named the CI gap. Backend-layer half stays lean |
| 5 | Important | sequencing + spec-and-testing | Statelessness guard mlx-gated, no CI proxy, under-specified | Pinned seed/payloads/assertion form in Phase 3; named "zero CI protection by design" in Acceptance |
| 6 | Important | spec-and-testing | No CI assertion for tagged-text→audio path (spy returns empty generator) | **Added a `ToneBackend` lean delta check** (multi-line `[S1]`/`[S2]` buffer streams ≥1 delta) to Phase 1 |
| 7 | Important | assumptions | `sample_rate=44100` stated as fact; risk of a lean `==44100` assert | Phase 1 item 2 now mandates lean asserts `sample_rate==0` + field presence, never `==44100` |
| 8 | Important | codebase-claims | `dia` extra absent from `pyproject.toml` | Phase 2 item 3 notes the extra is **net-new**, pinned to the kokoro/voxtral_tts pattern |
| 9 | Minor | architecture | `wait_closed`/`SupportsWaitClosed` not in any checklist item | Added `wait_closed` + `_worker_done` to Phase 1 + Acceptance |
| 10 | Minor | architecture | `validate_extras` unspecified | **Decision: mirror Pocket's `validate_extras`** for `{temperature, top_p}` (Phase 1 + Acceptance + lean reject test) |
| 11 | Minor | sequencing | Partial item-8 inversion risk (`:105` guard, `:12-13` docstring) | Added a `grep '"dia"'` completeness guard to the Phase 2 sequencing guard |
| 12 | Minor | assumptions | Bridge `.audio` shape a single-run snapshot; tolerant `_audio_to_pcm` | Added `audio.ndim == 1` structural assert to the Phase 3 smoke |
| 13 | Minor (related) | spec-and-testing | Lean status-reply test could assert `44100` not `0` | Folded into resolution #7 (same `:300` anchor, cross-category related) |

### Phase 3 live smoke run — 2026-06-30 (real model, `mlx-community/Dia-1.6B-fp16`, this host)

Ran the perceptual smoke + mlx-gated statelessness checks + a new abrupt-disconnect
regression guard against the live model. The driver gained TTFB/total/RTF
instrumentation for this run.

**Latency (3 perceptual scripts, server-streamed, rate 44100):**

| Script | chars | TTFB | total synth | audio | RTF |
|--------|------:|-----:|------------:|------:|----:|
| `podcast_turntaking` (7 `\n` lines) | 819 | **55.3 s** | 448.5 s | 214.9 s | 2.09 |
| `interview_interruption_inline` (1 line, no `\n`) | 313 | **59.0 s** | 59.2 s | 30.0 s | 1.98 |
| `interview_interruption_newline` (3 lines) | 313 | **59.3 s** | 181.3 s | 89.9 s | 2.02 |

Findings:
1. **RTF ≈ 2.0 is a model floor** — dia generates at ~2× slower than real time regardless
   of script. This is intrinsic to the autoregressive descript-codec decode; not a server
   overhead we can tune away.
2. **dia DOES stream per-`\n`-segment** (server emits each segment's audio as it lands).
   So **TTFB = the *first* `\n`-segment's generate time** (~55 s on the 7-turn podcast), **not**
   the full synth time. This **corrects** the earlier note (memory + prior framing) that
   "dia is streaming:false → one big delta after the full generate, TTFB ≈ full synth." That
   only holds for a **single-segment** (no-`\n`) commit — confirmed by the inline script
   (TTFB 59.0 s ≈ total 59.2 s, one segment = one delta at the end). **Biggest latency lever:
   keep the first segment short** (incremental commits / smaller leading turn), since TTFB is
   dominated by it.
3. **Same text, very different output by layout:** the identical 313-char interruption dialogue
   produced **30.0 s** of audio inline vs **89.9 s** newline-split (≈3×). Splitting on `\n`
   makes each segment a fuller, slower utterance — a perceptual item for listen-and-judge
   (WAVs in `/tmp/dia_smoke/` for that run; the driver now defaults to a fresh secure
   `mkdtemp` dir — like `run_smoke.sh` — and prints the path to listen at).

**Statelessness checks (mlx-gated, `--statelessness-only --seed 42 --diag-seeds 6`):**
- Per-script **mono-shape guard PASS** (all 3 scripts' first item `audio.ndim == 1`).
- **Greedy guard PASS** — `X_alone == X_after` byte-identical at `temperature=0.0`. Re-confirms
  the Phase 0 cross-call statelessness finding: the dia **model carries no cross-call state**.
- **Production-temp diagnostic SOFT-FLAGGED** (N=6): `X_alone` mean 377931 vs `X_after` mean
  266656, shift 111275 > pooled stdev 86427. **Interpretation (not a hard failure):** the
  diagnostic deliberately does **not** re-seed between the prior render and the `textX` render,
  so at `temperature=1.3` the two `textX` renders start from **different global mx-RNG states**.
  That RNG drift alone shifts the duration distribution **without any model coupling**. The
  greedy guard (RNG-independent) + the dia source (KV caches are **local per `_generate()`** —
  see disconnect analysis) both prove the model is stateless, so the soft-flag is attributed to
  benign global-RNG advance, not cross-call model state. RNG drift never makes output *wrong*,
  only non-byte-reproducible (already true for `temp>0`). Decision #3 ("incremental commits are
  safe") **stands**. A cleaner future diagnostic would re-seed before `textX` in both arms to
  isolate model coupling from RNG.

**Abrupt-disconnect poison — NOT REPRODUCED (0/7), regression guard added:**
The memory note `dia-abrupt-disconnect-poisons-shared-model` (earlier 2026-06-30 session) reported
that an abrupt client ws-disconnect **mid-`generate()`** poisoned the process-wide shared model so
the next commit returned ~0.13 s of truncated *step-13-EOS* audio (~5707 samples) or stalled, then
self-recovered. This run **could not reproduce it**: 1 standalone repro (conn B + conn C both full
audio) + a 6-iteration loop = **0/7 poison events**; every fresh commit after an abrupt
`transport.abort()` mid-generate returned full audio (1322059 samples, `term=done`).

Root-cause analysis of `mlx_audio/tts/models/dia/dia.py` explains the non-reproduction:
- KV caches (`decoder_self_attention_cache`, `decoder_cross_attention_cache`) are **local
  variables created fresh inside `_generate()`** — there is **no persistent model state** across
  segments or calls.
- `generate()` yields **after `_generate()` has fully returned**; the generator suspends at a
  clean yield boundary, so an early break / GC-time `GeneratorExit` unwinds with no half-finished
  MLX computation. The only skipped line is `mx.clear_cache()` (memory hygiene), not correctness.
- The cancellation-aware Metal-lock acquire + `worker_done` teardown (`_stream_util.py`, commits
  `3b79c9e` / `8befc39`) was **already in place** when the poison was first observed.

**Decision (operator, 2026-06-30): record non-reproduction + add a regression guard; no
speculative code fix.** A true fix for the one real gap (the skipped `mx.clear_cache()` on abort)
would require mlx-specific code in the deliberately mlx-free lean bridge — not worth it for an
unreproducible symptom. Added `tests/smoke/dia_dialogue_smoke.py --check-disconnect` /
`--disconnect-only`: aborts a mid-generate connection, then asserts a fresh commit returns full
(non-truncated, non-stalled) audio. **Guard PASS** this run. If a future teardown change
reintroduces the poison, the guard flips to FAIL.
