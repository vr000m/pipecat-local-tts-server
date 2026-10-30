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
- With at least one active service in category A and none in category B, show one extra row for B: its suggested model, with Start. "Active" is `LifecycleState.isActive` (starting, running, stopping, external, failed at runtime), the same notion as `AppModel.active(_:)`. A model that is starting or has failed at runtime therefore already occupies its category, and the row is gone the moment the user presses Start.
- A category is also occupied while any of its models is `installing` or `removing` (a Get, a packages refresh that a Start triggered first, or a removal). No row is shown for it until that ends. Without this, a Start on a model with an outdated environment (`ServiceLifecycle.swift:783-789` begins a packages install, then starts) would swap the row to the fallback model for the duration of the refresh.
- No row is shown until bootstrap has finished and the restore on launch has run, so a restored service never flashes as a suggestion first.
- With an active service in both categories, no suggestion row appears. The user goes to Add Models, as before.
- Only models that are downloaded and ready are suggested: phase exactly `.installed`. `needsModel` (environment present, weights not cached), `installing`, `notInstalled`, `unavailable`, `checking`, `removing` and `failed` are never suggested. (`LifecycleState.isInstalled` is not the right test: it is also true for `needsModel`.)
- Suggested model, in order: (1) the category's last-used model if it is still `.installed`; (2) the category's default model (`isDefault`) if `.installed`; (3) the first `.installed` model of the category in catalog order; (4) none, and no row. `tone` (a test signal) is never suggested at any step.
- "Last used" is the model most recently started by the user in that category, remembered after it is stopped, restarted, removed or the app quits. A last-used model that is no longer `.installed` is skipped (falls through to 2-4); the stored value is left alone so it applies again if the model comes back.
- Persist one value per category in `UserDefaults`, in the same domain as `restore.wanted` (`PreferencesDomain.defaults()`, so `PIPECAT_TOOLBAR_DEFAULTS_SUITE` redirects it and the smoke script and tests never touch the operator's real value).
- Only a user-initiated Start writes last-used. Restore on launch, External adoption and any other automatic start do not. Starting `tone` is not recorded either, so testing with it never displaces a real last-used model.
- The row reuses `CatalogRow` unchanged (name, Default badge, "Ready · size", Start) under the idle category's section header.
- Pure logic lives in `PipecatToolbarCore` with unit tests. The views stay logic-free.

## Review Focus

- The suggestion predicate: `.installed` only, never `isInstalled` or `isStartable` (both admit `needsModel` / `installing`). Read `LifecycleState.isInstalled` (`ServiceLifecycle.swift:529-538`) and `ServiceCounts.isStartable` (`ServiceCounts.swift:55`).
- Where last-used is written: it must be only the user Start path, and only when the driver accepts the start. `AppModel.restoreWantedServices()` calls the same `ServiceModel.start()` (`AppModel.swift:234`).
- That the row cannot flicker or double-render: Start makes the category occupied in the same state change that removes the row, including the packages-refresh path (`installing` before `starting`) and the restore loop at launch (`AppModel.restoreWantedServices()` starts models in a synchronous loop; confirm `start()` updates state synchronously, else the restore gate is what prevents a flash).
- Reset (`AppModel.send` → `.clearWantedServices`, `AppModel.swift:164`) and the suite-scoping doc in `PreferencesDomain.swift:7-12`.
- That `tone` is excluded in both places: never suggested, never recorded.

## Implementation Checklist

Phase task descriptions are plain bullets; completion lives in `## Progress` below the marker.

### Phase 1: Core — last-used store and suggestion policy (pure)

**Impl files:** `macos/Sources/PipecatToolbarCore/LastUsedStore.swift, macos/Sources/PipecatToolbarCore/SuggestionPolicy.swift, macos/Sources/PipecatToolbarCore/PreferencesDomain.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/LastUsedStoreTests.swift, macos/Tests/PipecatServiceToolbarTests/SuggestionPolicyTests.swift, macos/Tests/PipecatServiceToolbarTests/MemoryLastUsedStore.swift`
**Test command:** `swift test --package-path macos --filter "LastUsedStoreTests|SuggestionPolicyTests"`
**Goal:** The suggestion is a pure function of per-service lifecycle state and the stored last-used value, and can never name a model that is not ready to start.

- `LastUsedStore` protocol: `lastUsed(_ kind: ServiceKind) -> Service?`, `setLastUsed(_ service: Service)`, `removeAll()`. `NoopLastUsedStore`, and `UserDefaultsLastUsedStore` (keys `lastUsed.tts` and `lastUsed.stt`, value is the `Service` raw value; an unknown or wrong-kind raw value reads as nil). Same shape as `WantedServiceStore` (`WantedServiceStore.swift:8-33`); `init(defaults:)` has no default.
- `SuggestionPolicy.suggestion(for:states:lastUsed:) -> Service?` implementing the Requirements rules (`tone` filtered out of every candidate set; a category with any `isActive`, `installing` or `removing` model is occupied); `SuggestionPolicy.suggestions(states:lastUsed:) -> [ServiceKind: Service]` for the panel.
- `PreferencesDomain` doc comment names the new keys as suite-scoped.
- Tests: the `ServiceKind × category-occupancy` table (none / A only / B only / both), every `ServicePhase` twice, as the candidate (only `.installed` is suggested) and as a sibling in the idle category (`isActive`, `installing` and `removing` occupy it; the rest do not), written as a test over `ServicePhase` cases so a new phase fails to compile or fails the table; a runtime failure occupies the category, an install or download failure does not; the four fallback steps, a deleted last-used, a wrong-kind or unknown stored value, `tone` never suggested (as last-used, default-less fallback, or only-installed model), store round-trip on a throwaway suite `"last-used-tests-\(UUID())"`.

### Phase 2: App wiring — record on user Start, expose, render, Reset

**Impl files:** `macos/Sources/PipecatToolbarCore/ServiceDriver.swift, macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift, macos/Sources/PipecatServiceToolbar/State/AppModel.swift, macos/Sources/PipecatServiceToolbar/Views/PanelView.swift, macos/Sources/PipecatServiceToolbar/App/Snapshots.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift, macos/Tests/PipecatServiceToolbarTests/MemoryLastUsedStore.swift`
**Test command:** `swift test --package-path macos --filter "ServiceDriverTests|SuggestionPolicyTests|LastUsedStoreTests"`
**Goal:** Last-used changes only on an accepted user Start; the panel shows the row exactly when `SuggestionPolicy` says so.

- `ServiceDriver` takes a `lastUsed` store (default `NoopLastUsedStore`) and `start(userInitiated: Bool = true)`. Record the service when the driver accepts a user-initiated start, except `tone`. Confirm in the code what "accepts" means (the phase guards around `.startRequested`, `ServiceDriver.swift:237-243`) and record on the same condition; do not record a refused start.
- `AppModel.restoreWantedServices()` starts with `userInitiated: false`. External adoption never calls `start()`.
- `AppModel` builds the `UserDefaultsLastUsedStore` from the same `preferences` it passes to the wanted store and injects it into each `ServiceModel`/driver. It exposes the models to list per kind for the active-panel branch: the active ones plus the suggestion.
- `AppModel` shows suggestions only when bootstrap has finished and `restoredThisProcess` is true (make that flag observed, since `AppModel` is `@Observable` and views read the panel models through it). Verify while implementing whether `ServiceModel.start()` updates state synchronously; the gate makes the answer irrelevant, but record it in Findings.
- `RunningView`: in the `app.anyActive` branch, list `active(kind)` plus the suggestion for the idle kind, rendering `RunningRow` for active models and `CatalogRow` for the suggestion (one small row view that picks by state). The nothing-running branch is untouched.
- Reset also clears last-used: extend the existing `.clearWantedServices` handling in `AppModel.send` (no change to the `AppLifecycle` reducer or its effects).
- Snapshot scenes `running-suggest-stt` and `running-suggest-tts` (one category running, an installed model in the other), via `ServiceModel.setPreviewState`.
- `ServiceDriverTests`: user start records; restore-style start (`userInitiated: false`) does not; a refused start does not; starting `tone` does not; recording survives Stop and a driver rebuild over the same store.

### Phase 3: Docs

**Impl files:** `macos/README.md, macos/docs/architecture.md, AGENTS.md, CHANGELOG.md`
**Test files:** `tests/test_justfile_recipes.py`
**Test command:** `uv run pytest tests/test_justfile_recipes.py -q`

- `macos/README.md` Menu bar "Running" bullet (about lines 144-150): the suggestion row and when it appears. Reset bullet (about line 77) and the Restore and Quit section if it lists what Reset clears.
- `macos/docs/architecture.md` (about lines 545-552 and 335): the Running panel rule, the last-used store, Reset.
- `AGENTS.md`: the `PIPECAT_TOOLBAR_DEFAULTS_SUITE` row names the keys it scopes; add the last-used keys. Update the `macos/` layout bullet only if the file list there names Core types.
- `CHANGELOG.md`: one Added bullet in the existing `[0.9.0]` section (0.9.0 is unreleased: no `v0.9.*` tag locally or on `origin`; sentences of 20 words or fewer). Set the section's date to the release day when releasing (it reads 2026-10-29 today). No version bump; the compare links stay as they are.
- Operator checks (not CI): the Running panel with each category running and the other idle, a stopped-and-relaunched app, and a deleted last-used model.

## Technical Specifications

### Files to Modify
- `macos/Sources/PipecatToolbarCore/ServiceDriver.swift` — optional `lastUsed` store; `start(userInitiated:)`.
- `macos/Sources/PipecatToolbarCore/PreferencesDomain.swift` — doc comment: the new keys are suite-scoped.
- `macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift` — pass the store and the `userInitiated` flag through `start()` (`ServiceModel.swift:149-152`).
- `macos/Sources/PipecatServiceToolbar/State/AppModel.swift` — build the store, expose the panel models, pass `userInitiated: false` from `restoreWantedServices()` (`:226-241`), clear on Reset (`:164`).
- `macos/Sources/PipecatServiceToolbar/Views/PanelView.swift` — `RunningView` active branch (`:59-61`), `serviceList` row builder (`:86-103`).
- `macos/Sources/PipecatServiceToolbar/App/Snapshots.swift` — two scenes.
- `macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift` — user vs restore start.
- `macos/README.md`, `macos/docs/architecture.md`, `AGENTS.md`, `CHANGELOG.md`.

### New Files to Create
- `macos/Sources/PipecatToolbarCore/LastUsedStore.swift` — protocol, no-op and `UserDefaults` implementations.
- `macos/Sources/PipecatToolbarCore/SuggestionPolicy.swift` — the pure rule.
- `macos/Tests/PipecatServiceToolbarTests/{LastUsedStoreTests,SuggestionPolicyTests,MemoryLastUsedStore}.swift`.

### Architecture Decisions
- Separate `LastUsedStore`, not an extra method on `WantedServiceStore`: the wanted set is cleared per service on Stop and by Reset's own rules; last-used has the opposite lifetime. Two protocols keep each store's meaning single.
- Record in `ServiceDriver`, not in the view or `ServiceModel`: Core is the only target the tests link (`Package.swift:29-35`), and the driver already owns the start path and the wanted-flag write (`ServiceDriver.reduce`, `:158-166`).
- The suggestion predicate is exactly `.installed`. The empty-state list keeps `isStartable`, which also shows `needsModel` and `installing` rows; this plan does not change it (see Decisions, 4).
- The row hides because the category becomes active, not because of any new suggestion state. No "pending" or "failed" row variant exists.
- `tone` is a test signal: it is never suggested and never recorded as last-used.
- Last-used is stored by `Service` raw value (a variant such as `phononQ8` is its own `Service`, not the family).

### Decisions (operator, 2026-10-30)
1. `tone` is only for testing: never suggested (not as last-used, default or fallback) and never recorded as last-used.
2. Reset clears everything, including last-used (via the existing `.clearWantedServices` handling in `AppModel.send`; the `AppLifecycle` reducer is unchanged).
3. Apple Speech is not special: it counts as a started and last-used STT model like any other.
4. The empty-state list stays as today, including its `needsModel` and `installing` rows; only the new row requires `.installed`.
5. No separate release: this ships in the unreleased 0.9.0. The changelog bullet goes in `[0.9.0]` and its date is set at release.

### Dependencies
- None new. Swift tools 6.0, macOS 15, no external packages (`Package.swift:1,9`).

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| last-used value | `ServiceDriver` start path (Phase 2) | `AppModel` panel models → `SuggestionPolicy` (Phase 2) | Written only on an accepted user Start; read-only for the policy; survives Stop |
| restore start | `AppModel.restoreWantedServices()` | `ServiceModel.start(userInitiated:)` | Passes `false`; never records |
| suite scoping | `PreferencesDomain.defaults()` | `UserDefaultsLastUsedStore` | Same `UserDefaults` as `restore.wanted`; tests and `ui_smoke.sh` use a throwaway suite |
| Reset | `AppModel.send(.clearWantedServices)` | `LastUsedStore.removeAll()` | Cleared alongside the wanted set; the `AppLifecycle` reducer is unchanged |
| row visibility | `SuggestionPolicy` | `RunningView` | Row shown iff the policy returns a model for the idle category; Start makes the category active, which removes it |

## Testing Notes

### Test Approach
- [ ] Unit: `SuggestionPolicy` (occupancy table, every phase, fallback order, deleted last-used, `tone` exclusion).
- [ ] Unit: `UserDefaultsLastUsedStore` on a throwaway suite (round trip, unknown value, `removeAll`).
- [ ] Unit: `ServiceDriver` (user start records, restore start and refused start do not, survives Stop).
- [ ] Snapshot: `running-suggest-stt` and `running-suggest-tts` render (non-empty PNGs via `ui_smoke.sh --snapshot`; judged by eye).
- [ ] Manual (operator): Nemotron running → the TTS row appears with the last-used model; start it → the row becomes a running row; stop it → the row returns; both running → no row; relaunch → last-used survives; Reset → falls back to the default (last-used cleared).

### Test Results
- [ ] All existing tests pass (`swift test --package-path macos`; the install/cancel/pipe-drain suites flake under load, re-run alone)
- [ ] New tests added and passing
- [ ] `swift build --package-path macos` has no warnings
- [ ] `uv run ruff format --check .` and `uv run ruff check .` clean
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] Last-used model removed or its weights deleted
- [ ] Last-used model is a variant (`phononQ8`) whose family sibling is running
- [ ] Only `needsModel` or `installing` models in the idle category: no row
- [ ] Idle category has only `tone` installed and no history: no row
- [ ] `tone` is the user's most recent start: not recorded, a real last-used model still suggested
- [ ] The only running model is External (adopted): the idle category still gets its row
- [ ] Failed-at-runtime service occupies its category
- [ ] Start on a model with an outdated environment (phase `installing`, then `starting`): the row disappears and never shows a fallback in between
- [ ] A Get or removal running in the idle category: no row until it ends
- [ ] App launch with services restored: no suggestion row before or during the restore
- [ ] A start that fails at runtime and is dismissed: the same model is suggested again (accepted: it is what the user last tried)

## Acceptance Criteria

- With one category running and an installed model in the other, the Running panel shows that other category's last-used model (else default, else first installed) with a working Start button.
- The row never shows a model that is not downloaded, is installing, is running, or is `tone`.
- No row when both categories have an active service, when the idle category has nothing installed, while the idle category is installing or removing a model, or before the restore on launch has run.
- Last-used changes only on a user-initiated Start (never for `tone`), survives Stop and relaunch, and is cleared by Reset.
- The nothing-running list is unchanged.
- Tests, `swift build` and ruff clean; documentation updated.

<!-- reviewed: YYYY-MM-DD @ <hash> -->
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
- Unverified, settle in Phase 2: what "accepted start" means in `ServiceDriver.start()` (`:237-243`); the remaining scenes in `Snapshots.swift` after line 140; how `ExternalDiscovery` reaches the driver (it does not call `start()`).

## Issues & Solutions

(none yet)

## Final Results

(fill when complete)
