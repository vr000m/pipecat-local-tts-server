# Task: Menubar app — offer the last-used model of the other category in the Running panel

**Status**: Not Started
**Component**: macos
**Assigned to**: Varun Singh / Claude
**Priority**: Medium
**Branch**: `feature/menubar-suggest-other-category` (off `main` @ `0fef323`)
**Created**: 2026-10-30
**Completed**: (fill when done)
**Review Gates**: none

## Objective

When one category (Text to Speech or Speech to Text) has a running service and the other has none, the Running panel shows only the running service. Starting the other half of a voice pipeline then means opening Add Models and finding the right tab. Add one row for the idle category: the model the user last started there, with a Start button.

## Context

- Nothing running: the Running panel already lists every installed model of both categories with Start (`RunningView`, `PanelView.swift:59-72`). That stays.
- Something running: only active services are listed (`PanelView.swift:59-61`); everything else is behind Add Models, split across a TTS and an STT tab.
- Operator feedback (2026-10-30, after verifying restore on launch and the Quit guard): with Nemotron running, starting a TTS model needs Add Models, and the right tab is not always the one that opens.
- `restore.wanted` cannot supply "last used": a service leaves the set when it is stopped (`WantedTransition`), so a stopped pipeline half is forgotten. A new per-category value is needed.
- Sibling plan for the persistence and test patterns reused here: `20261028-feature-macos-restore-and-quit-guard.md`.

## Requirements

- With nothing active in either category, the panel is unchanged: every startable model of both categories, as today.
- Terms. A model is *active* when `LifecycleState.isActive` (starting, running, stopping, external, failed at runtime), the same notion as `AppModel.active(_:)`. A category is *occupied* when any of its models is active, `installing`, `removing` or `checking` (a Get, a packages refresh that a Start triggered first, a removal, or the cache read that follows a Stop during a busy-port probe, a lost External server or a finished removal: the model stays `.checking` until the read lands, `ServiceLifecycle.swift:836-845, 936-945, 984-988`). A model is *ready to start* when `LifecycleState.isReadyToStart` (below).
- With at least one active service in category A and category B not occupied, show one extra row for B: its suggested model, with Start. The row is gone the moment the user presses Start, because `start()` changes the phase before it returns (`ServiceDriver.swift:142-146`, `ServiceLifecycle.swift:787-793, 851-857`). While B is occupied by an install, a removal or a `.checking` read no row is shown; without this, a Start on a model with an outdated environment (`ServiceLifecycle.swift:783-789` begins a packages install, then starts) would swap the row to the fallback model for the duration of the refresh.
- No row is shown until bootstrap has finished and the restore on launch has run, so a restored service never flashes as a suggestion first. After a failed bootstrap the restore does not run, so no row is shown until a retry succeeds (Decision (grilled): the row stays hidden; Apple Speech can still be started in that state).
- With an active service in both categories, no suggestion row appears. The user goes to Add Models, as before.
- Only models that are downloaded and ready are suggested: `LifecycleState.isReadyToStart`, a new Core predicate that is true for phase `.installed` unless the cache check refuses it, exactly the test `RestorePolicy` already applies (`RestorePolicy.swift:44-45`, which refuses `.installed` with `cache?.cached == false`). `RestorePolicy` and `SuggestionPolicy` both call it, so the two cannot disagree. `needsModel` (environment present, weights not cached), `installing`, `notInstalled`, `unavailable`, `checking`, `removing` and `failed` are never ready. (`LifecycleState.isInstalled` is not the right test: it is also true for `needsModel`.)
- Suggested model, in order: (1) the category's last-used model if it is ready to start; (2) the category's default model (`isDefault`) if it is ready to start; (3) the first ready-to-start model of the category in catalog order; (4) none, and no row. `tone` (a test signal, marked by a new `ServiceInfo.isTestSignal` attribute) is never suggested at any step.
- "Last used" is the model most recently started by the user in that category, remembered after it is stopped, restarted, removed or the app quits. A last-used model that is not ready to start (no longer `.installed`, or refused by the cache check) is skipped (falls through to 2-4); the stored value is left alone so it applies again if the model comes back.
- Persist one value per category in `UserDefaults`, in the same domain as `restore.wanted` (`PreferencesDomain.defaults()`, so `PIPECAT_TOOLBAR_DEFAULTS_SUITE` redirects it and the smoke script and tests never touch the operator's real value).
- Only a user-initiated Start writes last-used. Restore on launch, discovery-driven External adoption and any other automatic start, including the driver's own re-entry after a packages refresh, do not. A user Start is recorded when the driver accepts it, whatever its outcome (for example a Start on a busy port that ends in adopting the server that answers). Starting a test-signal model (`tone`) is not recorded either, so testing with it never displaces a real last-used model.
- The row reuses `CatalogRow` unchanged (name, Default badge, "Ready · size", Start) under the idle category's section header.
- Pure logic lives in `PipecatToolbarCore` with unit tests. The views stay logic-free: Core tags each listing entry as active or suggested (`PanelEntry`) and the view only switches on the tag (Decision (grilled)).

## Review Focus

- The suggestion predicate: `isReadyToStart` only (phase `.installed` and not refused by the cache check), never `isInstalled` or `isStartable` (both admit `needsModel` / `installing`). Read `LifecycleState.isInstalled` (`ServiceLifecycle.swift:529-538`) and `ServiceCounts.isStartable` (`ServiceCounts.swift:55`).
- Where last-used is written: only the user Start path, only when the driver accepts the start, once. `AppModel.restoreWantedServices()` calls the same `ServiceModel.start()` (`AppModel.swift:234`), and the reducer's `.start` effect re-enters `ServiceDriver.start()` after a packages refresh (`ServiceLifecycle.swift:718`, `ServiceDriver.swift:364`); neither may record.
- That the row cannot flicker or double-render: Start makes the category occupied in the same dispatch that removes the row, including the packages-refresh path (`installing` before `starting`), the free-port, busy-port and outdated-environment paths, and the restore loop at launch.
- Reset (`AppModel.send` → `.clearWantedServices`, `AppModel.swift:164`) and the suite-scoping doc in `PreferencesDomain.swift:7-12`.
- That `tone` is excluded in both places: never suggested, never recorded.

## Implementation Checklist

Phase task descriptions are plain bullets; completion lives in `## Progress` below the marker.

### Phase 1: Core — last-used store and suggestion policy (pure)

**Impl files:** `macos/Sources/PipecatToolbarCore/LastUsedStore.swift, macos/Sources/PipecatToolbarCore/SuggestionPolicy.swift, macos/Sources/PipecatToolbarCore/PreferencesDomain.swift, macos/Sources/PipecatToolbarCore/ServiceLifecycle.swift, macos/Sources/PipecatToolbarCore/RestorePolicy.swift, macos/Sources/PipecatToolbarCore/Service.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/LastUsedStoreTests.swift, macos/Tests/PipecatServiceToolbarTests/SuggestionPolicyTests.swift, macos/Tests/PipecatServiceToolbarTests/MemoryLastUsedStore.swift, macos/Tests/PipecatServiceToolbarTests/ServiceLifecycleTests.swift, macos/Tests/PipecatServiceToolbarTests/RestorePolicyTests.swift`
**Test command:** `swift test --package-path macos --filter "LastUsedStoreTests|SuggestionPolicyTests|ServiceLifecycleTests|RestorePolicyTests"` and `uv run pytest tests/test_backend_registry.py tests/test_justfile_recipes.py -q` (Phase 1 edits `Service.swift`, whose `ServiceInfo` blocks `tests/_macos_catalog.py:79-94` parses)
**Goal:** The suggestion is a pure function of per-service lifecycle state and the stored last-used value, and can never name a model that is not ready to start.

- `LastUsedStore` protocol: `lastUsed(_ kind: ServiceKind) -> Service?`, `setLastUsed(_ service: Service)`, `removeAll()`. `NoopLastUsedStore`, and `UserDefaultsLastUsedStore` (keys `lastUsed.tts` and `lastUsed.stt`, value is the `Service` raw value; an unknown or wrong-kind raw value reads as nil). Same shape as `WantedServiceStore` (`WantedServiceStore.swift:8-33`); `init(defaults:)` has no default.
- `ServiceInfo.isTestSignal` (true for `tone` only), read by the policy and by the recorder.
- `LifecycleState.isReadyToStart` in `ServiceLifecycle.swift`, and `RestorePolicy`'s `.installed` arm rewritten to call it (behaviour unchanged; `RestorePolicyTests` pin it).
- `ServiceLifecycle.acceptsStart(...)`: the pure guard now inline at `ServiceLifecycle.swift:783-786` (`appAvailable`, no server, native, install or removal, phase not `.removing`, not external). The `.startRequested` reducer arm calls it, and so will the driver in Phase 2, so the reducer and the recorder cannot disagree. Behaviour unchanged.
- `SuggestionPolicy.suggestion(for:states:lastUsed:) -> Service?` (`lastUsed` is a `[ServiceKind: Service]` snapshot that `AppModel` reads once from the store, as `restoreWantedServices()` does with `wantedStore.read()` at `AppModel.swift:229`; the policy never touches `UserDefaults`) implementing the Requirements rules (test-signal models filtered out of every candidate set; a category is occupied per the Requirements definition). `SuggestionPolicy.suggestions(states:lastUsed:ready:) -> [ServiceKind: Service]` returns nothing when `ready` is false (bootstrap not finished or restore not yet run). A pure `SuggestionPolicy.panelListing(states:lastUsed:ready:) -> [ServiceKind: [PanelEntry]]` returns, per kind, the active services as `.active(Service)` plus the suggestion as `.suggested(Service)`, in catalog order; `ready: false` keeps the `.active` entries and drops only the suggestion (an adopted External server renders during the launch pass while the gate is still false); the view only switches on the tag; `AppModel` maps entries to models. `PanelEntry` lives in `SuggestionPolicy.swift`.
- `PreferencesDomain` doc comment names the new keys as suite-scoped.
- Tests: the `ServiceKind × category-occupancy` table (none / A only / B only / both), every `ServicePhase` twice, as the candidate (only a ready `.installed` is suggested) and as a sibling in the idle category (`isActive`, `installing`, `removing` and `checking` occupy it; the rest do not). `ServicePhase` has associated values, so the table is driven by an exhaustive `switch` with no `default` (a new phase then fails to compile) over `SuggestionPolicyTests.allPhases`, a local fixture with one `.failed` per kind (`.crashed(status:)`, `.startup(code:)`, `.portBusy(_, found:)` occupy; `.install`, `.download` do not; the bare names used elsewhere in this plan are shorthand for those cases). Do not extend the shared `ServiceLifecycleTests.phases`: `RestorePolicyTests.swift:34` and `ServiceCountsTests.swift:105` assert `table.count == phases.count`, and `ServiceCountsTests.swift:42`, `WantedTransitionTests.swift:32-33` and `ExternalPresentationTests.swift:69` iterate it, none of them in this phase's filter (Decision (grilled)); `isReadyToStart` for `.installed` with and without a cache refusal; `acceptsStart` for each guard; `panelListing` for ready=false with an active service (the `.active` entries remain, no suggestion) and with none (empty), both categories idle, A active + B suggested, both active, A running + A installed + B installed (A lists only the running model); a variant case: STT active, `phononQ8` `.installed` and last-used, `phonon` `.installing(.converting)` → no row, then `phonon` `.installed` → row names `phononQ8`; the four fallback steps, a deleted last-used, a last-used model refused by the cache check with a ready default (the default is suggested), a wrong-kind or unknown stored value, a test-signal model never suggested (as last-used, default-less fallback, or only-installed model), store round-trip on a throwaway suite `"last-used-tests-\(UUID())"` removed with `removePersistentDomain(forName:)`, as `WantedServiceStoreTests.swift:12,22` do.

### Phase 2: App wiring — record on user Start, expose, render, Reset

**Impl files:** `macos/Sources/PipecatToolbarCore/ServiceDriver.swift, macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift, macos/Sources/PipecatServiceToolbar/State/AppModel.swift, macos/Sources/PipecatServiceToolbar/Views/PanelView.swift, macos/Sources/PipecatServiceToolbar/App/Snapshots.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift, macos/Tests/PipecatServiceToolbarTests/MemoryLastUsedStore.swift`
**Test command:** `swift test --package-path macos --filter "ServiceDriverTests|SuggestionPolicyTests|LastUsedStoreTests"`
**Goal:** Last-used changes only on an accepted user Start, once; the panel shows the row exactly when `SuggestionPolicy.panelListing` says so.

- `lastUsed` rides on `ServiceDependencies` beside `wanted` (`ServiceDriver.swift:85`, default `NoopLastUsedStore`), so `ServiceDriver(info:dependencies:)` stays source-compatible. The public `start(origin: StartOrigin)` (`StartOrigin` is `user`, `restore` or `effect`, with no default in production code; the six call sites `PanelView.swift:259/:586/:599`, `ServiceDetailView.swift:91/:323` and `AppModel.swift:234` pass it explicitly, and tests use a helper that passes `.user`) evaluates `ServiceLifecycle.acceptsStart` on the pre-dispatch state, dispatches, and records the service once when the start was accepted, has origin `.user` and is not a test-signal model. The reducer's `.start` effect (`ServiceDriver.swift:364`, the continuation after a packages refresh) starts with origin `.effect`, which never records. Recording is decided at acceptance, not outcome. The `reduce()` doc comment (`ServiceDriver.swift:152-166`) names last-used as the one exception to "persisted per-service state follows the event inside `reduce()`" (as `WantedTransition` does), because the recorder keys on the call's origin, which is not in the event stream (Decision (grilled)).
- `AppModel.restoreWantedServices()` starts with origin `.restore`. Discovery-driven External adoption never calls `start()`; a user Start that ends in adoption is recorded (see Requirements).
- `AppModel` builds the `UserDefaultsLastUsedStore` from the same `preferences` it passes to the wanted store and injects it into each `ServiceModel`/driver. It reads the last-used store once into the `lastUsed` snapshot and exposes the entries to list per kind for the active-panel branch (`PanelEntry`: the active ones plus the suggestion).
- Decision (grilled): one fact, one flag. `restoredThisProcess` (`AppModel.swift:74, 228`) drops `@ObservationIgnored` and becomes the observed gate (`suggestionsEnabled` is a computed alias of it, not a second stored flag). It is set in `restoreWantedServices()` after the restore loop's synchronous `start(origin: .restore)` calls, in the same main-actor turn, so the first render with the gate true already sees the restored services occupying; the write site is named in the code and in a manual check. It stays false after a failed bootstrap (`AppModel.swift:200-204` returns before `:220`), so a retry still runs the restore and no row shows meanwhile. `finishPreviewBootstrap()` (`AppModel.swift:328`) also sets it, so `--snapshot` renders can show the row. `AppModel` passes `ready: suggestionsEnabled` to `SuggestionPolicy.panelListing`.
- `RunningView`: in the `app.anyActive` branch, list the `PanelEntry` values for each kind and switch on the tag: `.active` renders `RunningRow`, `.suggested` renders `CatalogRow` (no state test in the view). The nothing-running branch is untouched.
- Reset also clears last-used: extend the existing `.clearWantedServices` handling in `AppModel.send` (no change to the `AppLifecycle` reducer or its effects).
- Snapshot scenes `running-suggest-stt` and `running-suggest-tts` (one category running, an installed model in the other), via `ServiceModel.setPreviewState`. `Snapshots.renderIfRequested` builds its `AppModel` over a throwaway `UserDefaults` suite seeded with a fixed last-used value, so a render never reads the operator's `lastUsed.*` and is the same on every machine. The suite is removed with `removePersistentDomain(forName:)` once the render finishes (as `ui_smoke.sh:126-127` deletes its suite), so no plist is left in `~/Library/Preferences`.
- `ServiceDriverTests`: a user start records once; a restore-style start (origin `.restore`) does not; an `.effect`-origin start never records; a restore start on an `.outdated` environment does not record after the refresh and the `.start` re-entry (`ScriptedEnvironment(.outdated(...))`, pattern at `ServiceDriverTests.swift:607-635`); a user start on an `.outdated` environment records exactly once; a refused start does not; a user start on a busy port that adopts the answering server records (extend `startOnABusyPortAdoptsTheServerThatAnswers`, `ServiceDriverTests.swift:802`); starting a test-signal model does not; occupancy (`isActive` or `isInstalling`) holds right after `start()` on the free-port, busy-port and outdated-environment paths; recording survives Stop and a driver rebuild over the same store; occupancy also holds on the Apple Speech native path (a stub `makeNativeServer`: `launchNative` dispatches `.nativeLaunched` inline, `ServiceDriver.swift:484-503`; a nil server ends `.failed(.startup)` and is still recorded); a user start on a busy port followed by `stop()` before the probe answers keeps the category occupied (`.checking`) until the read lands.

### Phase 3: Docs

**Impl files:** `macos/README.md, macos/docs/architecture.md, AGENTS.md, CHANGELOG.md`
**Test files:** `tests/test_justfile_recipes.py`
**Test command:** `uv run pytest tests/test_justfile_recipes.py -q` (a regression guard: it reads `PreferencesDomain` and `WantedServiceStore.swift`, and `test_no_helper_era_mentions` fails if the edited docs (`macos/README.md`, `AGENTS.md`, root `README.md`, `macos/docs/*.md`) contain helper-era strings; it asserts nothing else about the new text)

- `macos/README.md` Menu bar "Running" bullet (about lines 144-150): the suggestion row and when it appears. Reset bullet (about line 77) and the Restore and Quit section if it lists what Reset clears.
- `macos/docs/architecture.md` (about lines 545-552 and 335): the Running panel rule, the last-used store, Reset.
- `AGENTS.md`: the `PIPECAT_TOOLBAR_DEFAULTS_SUITE` row names the keys it scopes; add the last-used keys. Update the `macos/` layout bullet only if the file list there names Core types.
- `CHANGELOG.md`: one Added bullet in the existing `[0.9.0]` section (0.9.0 is unreleased: no `v0.9.*` tag locally or on `origin`; sentences of 20 words or fewer). Set the section's date to the release day when releasing (it reads 2026-10-29 today). No version bump; the compare links stay as they are.
- Operator checks (not CI): the Running panel with each category running and the other idle, a stopped-and-relaunched app, and a deleted last-used model.

## Technical Specifications

### Files to Modify
- `macos/Sources/PipecatToolbarCore/ServiceDriver.swift` — `lastUsed` on `ServiceDependencies`; `StartOrigin` (`user`, `restore`, `effect`) and `start(origin:)` recording on acceptance for `.user` only; the `reduce()` doc comment names the exception.
- `macos/Sources/PipecatToolbarCore/ServiceLifecycle.swift` — `LifecycleState.isReadyToStart`, `ServiceLifecycle.acceptsStart(...)` (extracted from the `.startRequested` guard).
- `macos/Sources/PipecatToolbarCore/RestorePolicy.swift` — `.installed` arm calls `isReadyToStart`.
- `macos/Sources/PipecatToolbarCore/Service.swift` — `ServiceInfo.isTestSignal`.
- `macos/Sources/PipecatToolbarCore/PreferencesDomain.swift` — doc comment: the new keys are suite-scoped.
- `macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift` — pass the store and the `StartOrigin` through `start()` (`ServiceModel.swift:149-152`).
- `macos/Sources/PipecatServiceToolbar/State/AppModel.swift` — build the store, observed gate (`restoredThisProcess` without `@ObservationIgnored`, also set by `finishPreviewBootstrap()`, `:328`), read `lastUsed` once into a snapshot, map `panelListing` to models, pass `.restore` from `restoreWantedServices()` (`:226-241`), clear on Reset (`:164`).
- `macos/Sources/PipecatServiceToolbar/Views/PanelView.swift` — `RunningView` active branch (`:59-61`), `serviceList` row builder (`:86-103`).
- `macos/Sources/PipecatServiceToolbar/App/Snapshots.swift` — two scenes over a throwaway defaults suite.
- `macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift` — user vs restore start, re-entry, adoption, occupancy.
- `macos/Tests/PipecatServiceToolbarTests/ServiceLifecycleTests.swift`, `RestorePolicyTests.swift` — `acceptsStart`, `isReadyToStart`, unchanged restore decisions.
- `macos/README.md`, `macos/docs/architecture.md`, `AGENTS.md`, `CHANGELOG.md`.

### New Files to Create
- `macos/Sources/PipecatToolbarCore/LastUsedStore.swift` — protocol, no-op and `UserDefaults` implementations.
- `macos/Sources/PipecatToolbarCore/SuggestionPolicy.swift` — the pure rule and the `PanelEntry` tag.
- `macos/Tests/PipecatServiceToolbarTests/{LastUsedStoreTests,SuggestionPolicyTests,MemoryLastUsedStore}.swift`.

### Architecture Decisions
- Separate `LastUsedStore`, not an extra method on `WantedServiceStore`: the wanted set is cleared per service on Stop and by Reset's own rules; last-used has the opposite lifetime. Two protocols keep each store's meaning single.
- Record in `ServiceDriver`, not in the view or `ServiceModel`: Core is the only target the tests link (`Package.swift:29-35`), and the driver owns the start path.
- Acceptance rule (decided 2026-10-30): one pure guard, `ServiceLifecycle.acceptsStart`, shared by the `.startRequested` reducer arm and the driver's recorder. Rejected: keying on a non-empty effect list (couples recording to an effect-list shape), comparing `state.phase` before and after (it couples recording to how far the effects have run inside the dispatch: a free-port start passes through `.installed` until `.launched` lands, so the comparison depends on effect timing even though the phase has moved by the time `start()` returns), carrying the origin on `.startRequested` and `LifecycleState` (a larger reducer change for the same result).
- Re-entry (decided 2026-10-30): the public `start(origin:)` records only for `.user`; the `.start` effect passes `.effect` (supersedes the earlier private-entry design: an explicit `StartOrigin` with no production default means a new call site cannot record by omission, round 2, 2026-10-30). This keeps a restore on an outdated environment out of last-used and records a user start on that path exactly once, at the user's call.
- Ready predicate (decided 2026-10-30): one `LifecycleState.isReadyToStart`, shared by `RestorePolicy` and `SuggestionPolicy`. The empty-state list keeps `isStartable`, which also shows `needsModel` and `installing` rows; this plan does not change it (see Decisions, 4).
- Gate and listing live in Core (decided 2026-10-30): `panelListing(states:lastUsed:ready:)` is pure and table-tested; `AppModel` forwards the observed gate (`restoredThisProcess`) and maps tagged entries to models. Reset's clear stays a manual check.
- The row hides because the category becomes occupied, not because of any new suggestion state. No "pending" or "failed" row variant exists.
- `ServiceInfo.isTestSignal` marks `tone`; the policy and the recorder test the attribute, not the `Service` case.
- Last-used is stored by `Service` raw value (a variant such as `phononQ8` is its own `Service`, not the family).
- Decision (grilled, 2026-10-30): the Running panel is driven by tagged `PanelEntry` values from Core, so the view holds no state test.
- Decision (grilled, 2026-10-30): the gate is the single observed `restoredThisProcess`; after a failed bootstrap it stays false and the row stays hidden.
- Decision (grilled, 2026-10-30): the suggestion's fallback steps all use `isReadyToStart`, not bare `.installed`.
- Observation invariant: the last-used value is a `UserDefaults` read that `@Observable` does not track. The row refreshes only because every write coincides with an observed change (the phase move on an accepted Start; `AppModel.phase` to `.resetting` on Reset). A new writer needs its own observed change.

### Decisions (operator, 2026-10-30)
1. `tone` is only for testing: never suggested (not as last-used, default or fallback) and never recorded as last-used.
2. Reset clears everything, including last-used (via the existing `.clearWantedServices` handling in `AppModel.send`; the `AppLifecycle` reducer is unchanged).
3. Apple Speech is not special: it counts as a started and last-used STT model like any other.
4. The empty-state list stays as today, including its `needsModel` and `installing` rows; only the new row requires `isReadyToStart`.
5. No separate release: this ships in the unreleased 0.9.0. The changelog bullet goes in `[0.9.0]` and its date is set at release.
6. Last-used recording uses a pure `acceptsStart` guard plus a non-recording path for the `.start` effect (operator, 2026-10-30, `/review-plan`); round 2 realises that path as `StartOrigin.effect` (Decision 10).
7. `RestorePolicy` and the suggestion share one `isReadyToStart` predicate (operator, 2026-10-30).
8. The gate and the combined listing move into Core with table tests; snapshot scenes use a throwaway suite (operator, 2026-10-30).
9. `tone` is marked by `ServiceInfo.isTestSignal`; the remaining review fixes are applied as recommended (operator, 2026-10-30).
10. Round 2 (`/review-plan`, operator, 2026-10-30): all reported findings are fixed. `.checking` occupies a category; `start(origin: StartOrigin)` replaces the `userInitiated` flag; `lastUsed` is a snapshot dictionary; `panelListing` returns tagged `PanelEntry` values and keeps actives when `ready` is false; Phase 1 uses a local `allPhases` fixture and also runs the Python drift tests; throwaway suites are removed after use.
11. Round 2 contradictions (operator, 2026-10-30): the row stays hidden after a failed bootstrap and the gate is the single observed `restoredThisProcess`; the view only switches on `PanelEntry` tags; fallback steps use `isReadyToStart`; the rationale for rejecting a before/after phase comparison is reworded.

### Dependencies
- None new. Swift tools 6.0, macOS 15, no external packages (`Package.swift:1,9`).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| last-used value | `ServiceDriver.start(origin:)` (Phase 2) | `AppModel` → `SuggestionPolicy.panelListing` (Phase 2) | Written once, on an accepted user Start, via `acceptsStart`; never from the `.start` re-entry; read-only for the policy; survives Stop |
| restore start | `AppModel.restoreWantedServices()` | `ServiceModel.start(origin:)` | Passes `.restore`; never records, including after a packages refresh |
| ready predicate | `LifecycleState.isReadyToStart` (Phase 1) | `RestorePolicy`, `SuggestionPolicy` | One definition; restore decisions unchanged |
| suite scoping | `PreferencesDomain.defaults()` | `UserDefaultsLastUsedStore` | Same `UserDefaults` as `restore.wanted`; tests and `ui_smoke.sh` use a throwaway suite |
| Reset | `AppModel.send(.clearWantedServices)` | `LastUsedStore.removeAll()` | Cleared alongside the wanted set; the `AppLifecycle` reducer is unchanged |
| row visibility | `SuggestionPolicy.panelListing` | `RunningView` via `AppModel`'s observed gate (`restoredThisProcess`) | Row shown iff the listing includes a suggestion for the idle category; `ready` is false until bootstrap and restore have run; Start makes the category occupied in the same dispatch, which removes it. The last-used read is untracked by `@Observable`; the row refreshes only because each write coincides with an observed change (see the observation invariant under Architecture Decisions) |

## Testing Notes

### Test Approach
- [ ] Unit: `SuggestionPolicy` (occupancy table, every phase, fallback order, deleted last-used, `tone` exclusion).
- [ ] Unit: `UserDefaultsLastUsedStore` on a throwaway suite (round trip, unknown value, `removeAll`).
- [ ] Unit: `ServiceDriver` (user start records once; restore start, restore after a packages refresh and refused start do not; busy-port adoption records; synchronous occupancy on three start paths; survives Stop).
- [ ] Unit: `acceptsStart`, `isReadyToStart`, `panelListing` (Core, table tests).
- [ ] Snapshot: `running-suggest-stt` and `running-suggest-tts` render with the row present (`ui_smoke.sh --snapshot` only checks the PNGs are non-empty, so the row is checked by eye).
- [ ] Manual (operator): launch with a service in `restore.wanted`: no row before or during the restore (the gate flips after the restore loop in `restoreWantedServices()`).
- [ ] Manual (operator): Nemotron running → the TTS row appears with the last-used model; start it → the row becomes a running row; stop it → the row returns; both running → no row; relaunch → last-used survives; Reset → falls back to the default (last-used cleared).

### Test Results
- [ ] All existing tests pass (`swift test --package-path macos`; the install/cancel/pipe-drain suites flake under load, re-run alone)
- [ ] New tests added and passing
- [ ] `swift build --package-path macos` has no warnings
- [ ] `uv run ruff format --check .` and `uv run ruff check .` clean
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] Last-used model removed or its weights deleted
- [ ] Last-used model is a variant (`phononQ8`) whose family sibling is installing, then ready (`SuggestionPolicyTests`)
- [ ] A user Start on a busy port that adopts the answering server records last-used
- [ ] A restore of an outdated-environment model never records, before or after the refresh
- [ ] Only `needsModel` or `installing` models in the idle category: no row
- [ ] Idle category has only `tone` installed and no history: no row
- [ ] `tone` is the user's most recent start: not recorded, a real last-used model still suggested
- [ ] The only running model is External (adopted): the idle category still gets its row
- [ ] Failed-at-runtime service occupies its category
- [ ] Start on a model with an outdated environment (phase `installing`, then `starting`): the row disappears and never shows a fallback in between
- [ ] A Get or removal running in the idle category: no row until it ends
- [ ] App launch with services restored: no suggestion row before or during the restore
- [ ] Failed bootstrap with Apple Speech started: no row until a retry succeeds
- [ ] Stop during a busy-port probe of the only occupying model: the category stays occupied until the read lands (no fallback flip)
- [ ] Last-used model installed but refused by the cache check: the ready default is suggested
- [ ] A start that fails at runtime and is dismissed: the same model is suggested again (accepted: it is what the user last tried)

## Acceptance Criteria

- With one category running and an installed model in the other, the Running panel shows that other category's last-used model (else default, else first installed) with a working Start button.
- The row never shows a model that is not downloaded, is installing, is running, or is `tone`.
- No row when both categories have an active service, when the idle category has nothing installed, while the idle category is installing or removing a model, or before the restore on launch has run.
- Last-used changes only on a user-initiated Start (never for `tone`), survives Stop and relaunch, and is cleared by Reset.
- The nothing-running list is unchanged.
- Tests, `swift build` and ruff clean; documentation updated.

<!-- reviewed: 2026-10-31 @ f2d27ec27f6796c77d10c8333604048182a768b9 -->

<!-- /review-plan writes the marker line above. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

Per-phase completion tracked here so ticking a box during a run does not bust the review marker. Format: `- [ ] Phase <label>: <title>`.

- [ ] Phase 1: Core — last-used store and suggestion policy (pure)
- [ ] Phase 2: App wiring — record on user Start, expose, render, Reset
- [ ] Phase 3: Docs

## Findings

- Explore facts (2026-10-30, `main` @ `0fef323`): `RunningView.body` branches on `anyActive` / `anyStartable` / `bootstrapping` (`PanelView.swift:46-83`); `AppModel.active(_:)` `:103`, `startable(_:)` `:118`, `installed(_:)` `:124`; `ServiceKind` is `tts` / `stt` (`Service.swift:4-5`); defaults are `kokoro` (`Service.swift:290`) and `appleSpeech` (`:337`); user Start and restore Start both reach `ServiceModel.start()` (`ServiceModel.swift:149-152`, `AppModel.swift:234`); there are no view or `AppModel` tests, and the test target links Core only (`Package.swift:29-35`).
- Verified (2026-10-30): `LifecycleState.isInstalled` is true for `needsModel` (`ServiceLifecycle.swift:529-538`), and `.ready` with uncached weights maps to `.needsModel` (`:603`); `isStartable` also admits `installing` (`ServiceCounts.swift:55`). Neither can be the suggestion predicate.
- Walkthrough (2026-10-30): a Start accepted by the driver can begin as `installing` (packages refresh, `ServiceLifecycle.swift:787-789`), so "active" alone is not enough to hide the row; the Retry button on a runtime failure also calls `start()` (`PanelView.swift:594-599`), so it records last-used. Decisions: installing or removing occupies the category (operator, 2026-10-30); a failed start stays recorded.
- `/review-plan` round 1 (2026-10-30): 27 findings (12 Important, 15 Minor, 0 Critical), 5 of them contradictions; the operator's decisions are Decisions 6-9 above. Verified in that round: `ServiceDriver.start()` (`ServiceDriver.swift:237-243`) only builds the event, the acceptance guard is `ServiceLifecycle.swift:783-786` (refusal returns `[]` with no state change); `dispatch` runs effects inline (`ServiceDriver.swift:142-146`), so every accepted start has moved the phase before `start()` returns (`.installing` `ServiceLifecycle.swift:1046`, busy port `.starting` `ServiceLifecycle.swift:792`, free port `.launched` `ServiceDriver.swift:539`); the reducer's `.start` effect re-enters `start()` (`ServiceLifecycle.swift:718`, `ServiceDriver.swift:364`); `RestorePolicy` also refuses `.installed` with an uncached model (`RestorePolicy.swift:44-45`); `finishPreviewBootstrap()` sets only `phase = .ready` (`AppModel.swift:328`), and `restoredThisProcess` is `@ObservationIgnored` (`:74`); `ExternalDiscovery` reaches the driver through `discovered(_:)` (`macos/Sources/PipecatServiceToolbar/State/ExternalDiscovery.swift:71`), never `start()`.
- Unverified, settle in Phase 2: the remaining scenes in `Snapshots.swift` after line 140.

## Issues & Solutions

(none yet)

## Final Results

(fill when complete)
