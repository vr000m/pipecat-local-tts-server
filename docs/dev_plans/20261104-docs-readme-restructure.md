# Task: Restructure the root README into focused user guides

**Status**: Complete
**Component**: tts-server (server, protocol, backends, client)
**Assigned to**: Codex
**Priority**: Medium
**Branch**: docs/shorten-readme
**Created**: 2026-11-04
**Completed**: 2026-11-04
**Review Gates**: none

## Objective

Turn the published root README into a concise project landing page while moving
backend reference material and server-operation detail into focused, linked
guides without losing any user-facing behavior, license, or safety guidance.

## Context

The root README is 752 lines and 6,224 words. Installation, server operations,
and backend-specific reference material account for most of its length, while
the authoritative wire contract already lives in `docs/protocol.md`. The root
README is also the package metadata document selected by `pyproject.toml`, so it
must retain a working quickstart and a useful backend-selection summary.

Existing files under `docs/dev_plans/` remain historic decision records; they
are not destinations for current user instructions. The macOS application and
profiling harness already have dedicated READMEs and should be linked rather
than duplicated.

## Requirements

- Keep the root README useful as a repository and package landing page.
- Preserve a complete quickstart covering install, prefetch, serve, status, and
  the reference client.
- Preserve the backend license matrix and every backend-specific capability,
  voice, language, text-control, limit, and cancellation caveat.
- Preserve operational guidance for endpoints, launchd, authentication,
  keepalive, status, prefetch, voices, and supervised mode.
- Keep `docs/protocol.md` authoritative for the wire contract and replace its
  prose references to moved README sections with direct guide links.
- Add a small `docs/README.md` index that distinguishes user guides from
  development records.
- Use absolute canonical GitHub URLs for guide links in the published root
  README; use repository-relative links inside repository-only documentation.
- Leave historic plans unchanged unless this work materially supersedes one of
  their decisions. When it does, append a dated correction and cross-link this
  plan without rewriting the original record.
- Introduce no dependency or runtime behavior changes.

## Review Focus

- No operator warning or restrictive model-license statement may disappear in
  the move.
- The README must not duplicate the detailed backend and operations guides.
- All links and moved anchors must resolve from their new source files.
- `docs/protocol.md` must remain about wire behavior rather than becoming an
  operations or backend manual.

## Implementation Checklist

### Phase 1: Split and cross-link the user documentation

**Impl files:** `README.md, AGENTS.md, docs/README.md, docs/backends.md, docs/operations.md, docs/protocol.md, docs/images/service-toolbar-panel.png, docs/images/service-toolbar-settings.png, docs/dev_plans/20261104-docs-readme-restructure.md`
**Test files:** none
**Test command:** `uv run pytest`
**Validation cmd:** `git diff --check`
**Goal:** Each fact has one clear canonical home: orientation in README, model-specific behavior in the backend guide, runtime management in operations, and wire semantics in the protocol.

- Inventory every moved heading, operator warning, restrictive-license
  qualifier, inbound link, and public README anchor before pruning the source.
- Create `docs/backends.md` from the backend matrix and backend-specific
  reference sections, adapting relative links and headings.
- Create `docs/operations.md` from server runtime, endpoint, environment,
  health, prefetch, launchd, and supervised-mode guidance.
- Stabilize destination anchors, update `docs/protocol.md` references, and
  verify source-to-destination coverage.
- Rewrite the README around project identity, quickstart, backend selection,
  Pipecat/macOS entry points, documentation navigation, and development checks.
- Retain the compact canonical port table and compatibility anchors in README;
  link each moved public section to its new guide destination.
- Update `AGENTS.md` so future contributors use the new canonical guides.
- Create `docs/README.md` as the user/developer documentation index.
- Audit the repository for stale references to headings removed from README.

## Technical Specifications

### Files to Modify

- `README.md` — compact package landing page and shortest successful path.
- `AGENTS.md` — contributor-facing canonical documentation pointers.
- `docs/protocol.md` — direct links to backend-guide anchors after the move.
- `docs/dev_plans/20261104-docs-readme-restructure.md` — work contract and final
  verification record.

### New Files to Create

- `docs/README.md` — documentation index.
- `docs/backends.md` — backend selection, licenses, capabilities, and caveats.
- `docs/operations.md` — CLI/runtime operation and supervision guide.
- `docs/images/service-toolbar-panel.png` — main menu bar panel screenshot.
- `docs/images/service-toolbar-settings.png` — settings and quit-menu screenshot.

### Architecture Decisions

- Keep one backend guide rather than one file per backend so the comparison and
  shared capability language remain centralized.
- Keep one operations guide rather than separate CLI, launchd, and supervision
  guides because those surfaces share endpoint, environment, and auth rules.
- Retain a compact backend/license table in README so package-index readers can
  make an informed first choice before following the detailed guide.
- Keep the canonical per-backend port table in README. Existing drift tests and
  source comments continue to treat that table as the compact invariant; the
  operations guide links to it instead of defining a second canonical table.
- Use absolute GitHub URLs for root-README links that must work on PyPI. Use
  relative links within `docs/`, `macos/`, `scripts/`, and `tests/` documents.
- Preserve old README fragments with non-duplicating HTML anchors and short
  moved-section links. The new guides hold the detailed content.
- Keep capability-field definitions and wire validation semantics in
  `docs/protocol.md`. Move release-specific model inventories, licenses, limits,
  and examples to `docs/backends.md`.
- Preserve existing model-license wording, qualifiers, warnings, and source
  links as a documentation snapshot. This restructure does not perform legal
  revalidation and must not imply legal advice.
- Modify a historic plan only when this restructure supersedes a recorded
  decision. Append a dated correction and cross-link; preserve original text.

### Dependencies

- `pyproject.toml` identifies version `0.9.0`, Python `>=3.12`, base dependency
  `websockets>=13.0`, backend runtime `mlx-audio==0.6.1`, and example adapter
  `pipecat-ai==1.4.0`; this documentation-only change alters none of them.

### Integration Seams

| Seam | Writer | Reader | Contract |
|---|---|---|---|
| Backend detail | `docs/backends.md` | README and protocol | Stable relative links and headings for licenses, capabilities, and dialects |
| Runtime detail | `docs/operations.md` | README and macOS users | Commands and environment rules match the existing CLI and operator surface |
| Documentation navigation | `docs/README.md` | Repository readers | Separate current user guides from historic plans and generated rich views |
| Published navigation | `README.md` | GitHub and PyPI readers | Absolute GitHub guide URLs plus local compatibility anchors |
| Port-map drift guard | `README.md` | `tests/test_justfile_recipes.py` and operator scripts | Keep `### Per-backend port convention` and its canonical table shape |

### Source-to-Destination Inventory

| Current README material | Canonical destination | README residue |
|---|---|---|
| Project purpose and two server contracts | `README.md` | Retain and tighten |
| Install commands for every extra | `docs/backends.md` | Lean install plus one backend quickstart |
| macOS menu bar application | `macos/README.md` | Short summary and two commands |
| Serve, sockets, environment, auth, keepalive, status, prefetch, launchd, supervision | `docs/operations.md` | Quickstart, canonical port table, compatibility links |
| Wire message and capability-field semantics | `docs/protocol.md` | Brief protocol summary |
| Backend licenses, capabilities, voices, languages, tags, limits, cancellation | `docs/backends.md` | Compact selection/license matrix and compatibility links |
| Reference and Pipecat examples | `README.md` | Retain in shortened form |
| Repository layout | `docs/README.md` | Replace with documentation index |

The must-retain audit covers restrictive model licenses; card-tag-only and
missing-LICENSE qualifiers; launchd environment and token-file rules;
non-loopback cleartext warnings; keepalive timeout and idle-peer behavior;
backend voice/language/tag dialects; model text ceilings, truncation guards,
coherence rules, and cancellation/lock caveats.

Explore-verified paths and observed patterns in this section are part of the
plan contract. Correcting a path, manifest fact, or documented pattern above
the review marker requires re-running plan review.

## Testing Notes

### Test Approach

- [x] Run the full test suite, including the README port-table drift guard.
- [x] Run an inline Python Markdown checker across changed and non-historic
  current docs; resolve relative targets and GitHub-style heading fragments.
- [x] Search for stale references to removed README headings and confirm each
  old public fragment has a compatibility anchor or an explicit retained heading.
- [x] Compare the source-to-destination inventory and must-retain list against
  the final diff; each detailed topic has exactly one canonical guide.
- [x] Confirm the protocol diff removes release-specific duplication while
  preserving capability-field definitions and wire validation semantics.
- [x] Run `git diff --check` and inspect the final documentation diff.

### Test Results

- [x] Full tests pass.
- [x] Link and anchor audit passes.
- [x] No stale moved-section references remain.
- [x] Topic ownership and preservation audits pass.

### Edge Cases Tested

- [x] Absolute root-README guide links target canonical GitHub `main` URLs;
  relative links resolve correctly inside repository-only docs.
- [x] Restrictive licenses and backend-specific truncation/cancellation warnings
  remain discoverable.
- [x] The quickstart remains usable without reading the reference guides first.

## Acceptance Criteria

- The root README is no more than 2,000 words and contains install, prefetch,
  serve, status, and reference-client quickstart steps.
- `docs/backends.md`, `docs/operations.md`, and `docs/README.md` provide clear,
  non-overlapping destinations for the moved material.
- No substantive user-facing guidance is lost.
- Protocol references point directly to the new backend guide.
- Root README links use package-index-safe absolute guide URLs; repository-only
  relative links and Markdown anchors resolve.
- Full tests and documentation validation pass.
- Review finds no unresolved correctness, security, or documentation issues.

<!-- reviewed: 2026-11-04 @ 2fdf3f498714ba03c3ded16bc7885d7ef9d73a94 -->

## Progress

- [x] Phase 1: Split and cross-link the user documentation

## Findings

- The initial fact-gathering pass verified the root README, protocol, macOS,
  profiling, and smoke-test documents; the three requested user guides did not
  yet exist at planning time.
- Existing docs used repository-relative Markdown links. The protocol referred
  to Qwen3, Fish, and Phonon sections by README heading rather than direct links.
- Review findings were all accepted. The canonical port table remains in README,
  protocol/model ownership is explicit, and package-facing links are absolute.
- The user supplied two toolbar screenshots after plan review; both were copied
  into `docs/images/` with descriptive names and accessible README alt text.

## Issues & Solutions

- The marker writer rejected the draft's nonstandard `reviewed: pending`
  placeholder. Replacing it with the bundled template's exact divider allowed
  the official marker writer to compute the hash.
- The first full suite run had two macOS quit-harness timing failures after
  1,100 passes. Both exact cases passed on rerun; a second full suite passed.

## Final Results

### Summary

Reduced the published README from 6,224 to 1,040 words, moved model and runtime
reference material into canonical guides, added a documentation index and menu
bar screenshots, and retained compatibility anchors and the tested port map.

### Outcomes

- `docs/backends.md` owns model selection, licenses, capabilities, controls,
  limits, and cancellation caveats.
- `docs/operations.md` owns runtime configuration, security, health, prefetch,
  launchd, and supervision.
- `docs/protocol.md` retains wire semantics and links to release-specific facts.
- Markdown validation checked 54 local targets and fragments across nine files.
- Ruff passed; the final full suite passed with 1,102 tests and 5 skips.

### Follow-up Work

- None required for this local documentation change.
