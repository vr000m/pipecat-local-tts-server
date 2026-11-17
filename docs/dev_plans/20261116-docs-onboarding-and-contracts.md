# Task: Complete onboarding and clarify the shipped TTS contracts

**Status**: Complete
**Component**: tts-server (server, protocol, backends, client)
**Assigned to**: Codex
**Priority**: Medium
**Branch**: docs/onboarding-and-contracts
**Created**: 2026-11-16
**Completed**: 2026-11-16
**Review Gates**: none

## Objective

Apply the seven approved documentation improvements: executable package onboarding,
accurate streaming/cancellation and endpoint contracts, troubleshooting, a client
guide, backend comparison/navigation, separation of current behaviour from design
history, and a task-based documentation index.

## Context

The existing guide split is retained. The package README currently uses a
checkout-only client script without obtaining it. Protocol prose overstates audio
cadence and mixes shipped behaviour with future design. This is documentation-only.

## Requirements

- Preserve README compatibility anchors and the canonical backend port table.
- Keep package-facing README links absolute and guide links relative.
- Preserve backend capabilities, licence qualifiers, operator warnings, and dated
  benchmark context; do not claim fresh upstream or legal verification.
- Explain the distinction between response admission, generated audio, client-visible
  cancellation, and eventual backend worker/lock release.
- Provide a standalone packaged-client WAV example with timeout, errors, clean close,
  and audio rate from the handshake. No checkout imports in this example.
- Label Pipecat pipeline snippets as sketches and state checkout/import requirements.
- Document endpoint and token environment handling accurately for each client surface.
- Keep historical records intact; append a dated correction only where a recorded
  decision or completion claim is materially superseded.
- Change no runtime, dependency, test, image, or release files. Do not commit or publish.

## Review Focus

- Copy/paste onboarding must work outside the repository with only the base package.
- Streaming and cancellation prose must agree with server scheduling and error shapes.
- Navigation improvements must retain existing anchors and all backend caveats.
- Validation must exercise actual documentation snippets and preserve the port map.

## Implementation Checklist

### Phase 1: Update the guides and examples

- Add the packaged-client example and integration guide; link it from the README,
  docs index, macOS guide, and agent documentation.
- Correct protocol wording and server/client endpoint instructions; add recovery steps.
- Add backend comparison and contents, with Kokoro first among detailed sections.
- Link protocol design rationale to existing decision records and append a dated
  correction to the previous README plan's package-quickstart completion claim.

### Phase 2: Verify the documentation

- Run exact WAV examples against an isolated tone server and inspect the resulting WAV.
- Exercise stalled responses, protocol errors, synthesis failure, and premature
  closure in the temporary harness; assert bounded failure and connection cleanup.
- Check a built wheel in an isolated base-only environment outside the repository.
- Validate links/fragments, preserved anchors, port-table bytes, and documentation scope.
- Run existing focused protocol/client/port tests, Ruff format/check, and the full suite.

## Technical Specifications

### Files to Modify

- `README.md`: prerequisites, packaged-client quickstart, and integration link.
- `docs/README.md`: task-based navigation and client-guide entry.
- `docs/operations.md`: endpoint semantics, lifecycle table, and troubleshooting.
- `docs/backends.md`: comparison, contents, and reordered Kokoro sections.
- `docs/protocol.md`: shipped status, accurate audio/cancel/error semantics, and
  links to historical tag-dialect decisions.
- `macos/README.md`: complete TTS import and client-guide link.
- `AGENTS.md`: canonical client-guide pointer.
- `docs/dev_plans/20261104-docs-readme-restructure.md`: dated correction to the
  package quickstart claim, cross-linked to this plan.
- This plan: contract and concise completion evidence.

### New Files to Create

- `docs/clients.md`: complete Python WAV script and Pipecat integration sketch.

### Architecture Decisions

- Documentation only: no independently executing component is changed.
- Keep a short executable WAV example in README and the same canonical example
  in the client guide; verify the two blocks are byte-identical to prevent drift.
- The WAV example accepts a socket path argument, connects explicitly to retain
  the hello rate, reads until completion, fails on errors or premature closure,
  and always closes. A bounded timeout covers the whole request. It uses stdlib
  plus `tts_server.client` only; no hard-coded voice/language or retry machinery.
- Explain persistent-connection retry/cancel/buffer rules separately; the simple
  one-shot example reports busy/errors and closes the connection.
- Keep backend details in one file. Preserve licence text and old public anchors
  while adding a concise selection table; link measured performance separately.
- Replace protocol Option A/B narration with shipped behaviour and a link to the
  existing Fish backend plan, which already records those decisions.

### Verified Codebase Facts and Dependencies

Create-time Explore verified `TTSClient.connect()` returns hello; control methods
send without awaiting replies (`tts_server/client.py:79–225`). Its constructor
requires explicit endpoints. `LocalTTSService` is a checkout example with bounded
busy retries (`examples/pipecat_tts_service.py:119–164`). Packaging selects only
`tts_server` (`pyproject.toml:201–205`). The existing port parser depends on the
literal README heading (`tests/test_justfile_recipes.py:65–81`).

The manifest specifies Python `>=3.12`, base `websockets>=13.0`, model runtime
`mlx-audio==0.6.1`, and examples `pipecat-ai==1.4.0`. No dependencies change.
No git refs were named in the request. These verified facts are part of the
reviewed contract; later factual corrections require review-marker refresh.

### Integration Seams

The README and client guide share the WAV snippet. The protocol owns event
semantics; operations owns runtime settings; backend details retain the existing
anchors. Root links must also work when rendered as package metadata.

## Testing Notes

Use temporary files and isolated endpoints; do not touch installed launchd agents,
the canonical socket, user model weights, or application settings. No new tests are
needed for these documentation edits. Verify exact snippets using a temporary harness.

## Acceptance Criteria

- All seven approved improvements are represented in the guides.
- A base-only installed wheel can execute the documented WAV example outside the repo.
- Existing links/anchors and the canonical port table remain intact.
- Documentation examples, relevant tests, formatting, and full-suite outcomes are recorded.
- Only the documentation allowlist is changed; unresolved verification limits are explicit.

<!-- reviewed: 2026-11-17 @ ab6a39b84ebf319ee456d2c6a8c6e4df67042817 -->

## Progress

- [x] Phase 1: Update the guides and examples.
- [x] Phase 2: Verify the documentation.

## Findings

Plan review: five completed lenses, one Important testing-gap finding, no Critical
or Minor findings, and no contradictions. Reconciliation: raw 1, merged 0, unique 1,
related 0, dropped 0. The temporary harness now covers failure paths as well as
successful tone synthesis. This is within the user's approved implementation scope.
Local evidence: `.review-plan/latest-codex.json`. The runtime has no close-agent
tool; all review workers returned terminal reports and are no longer running.

Final documentation audit checked the uncommitted worktree explicitly: the
committed `main...HEAD` range is empty. All ten changed files match the allowlist.
Sibling-plan search matched the previous documentation plan plus six feature/fix
records; only the previous quickstart completion claim needed correction. Other
records retain valid historical decisions and links. No release, changelog, or
PR update is needed for this uncommitted documentation-only change.

Implementation verification found that neither `TTSClient` nor `LocalTTSService`
automatically reads client environment variables, despite a stale adapter source
comment. The guides and agent reference now show explicit arguments or resolver
calls. Runtime source was left unchanged.

## Issues & Solutions

The sandbox blocked socket binding and uv cache access. Authorized native runs
completed the runtime checks and all full-suite assertions. Python then exited
with SIGBUS (138) during SentencePiece's `absl::Flag<bool>` destructor. The host
has an earlier report with the same stack. This is a native shutdown failure,
not a failing test assertion; it prevents claiming a clean full-suite process exit.
No dependency/runtime changes were made for this documentation task.
The temporary harness initially
assumed shutdown removed the socket pathname; it now verifies process exit and
lets its temporary directory remove the stale socket, matching existing behaviour.

## Final Results

All seven approved improvements are implemented. README and `docs/clients.md`
share an identical standalone WAV example; operations and protocol describe the
shipped endpoint, scheduling, and cancellation behaviour. Backend comparison,
contents, task navigation, and troubleshooting retain the original reference detail.

- Installed-wheel test outside the repository, with only the base package and
  `websockets`: 7,200 frames at 24 kHz, mono PCM16; health probe and server teardown passed.
- Exact snippet failure cases: busy, backend error, cancellation, premature close,
  and timeout all fail cleanly, close the connection, and produce no WAV.
- Pipecat sketch imports and constructs a pipeline with supplied processors.
- Navigation: 145 local/same-repository links across 12 documents passed; original
  anchors in seven guides retained. Canonical README port section is byte-identical.
- README licence table and backend licence section remain unchanged. The rebuilt
  wheel includes the new README metadata and still excludes checkout examples.
- Focused tests: 340 passed, exit 0. Two full-suite runs each reported 1,104
  passed, 5 skipped (18 warnings), then exited 138 during native shutdown.
- `uv run --no-sync ruff format .`: 98 files unchanged; Ruff check and diff whitespace passed.

Verification logs: `/private/tmp/tts-docs-focused.log` and
`/private/tmp/tts-docs-full.log`. Temporary runtime and navigation harnesses:
`/private/tmp/verify-tts-docs.py` and `/private/tmp/audit-tts-docs.py`.
First full-run log: `/private/tmp/tts-docs-full-first.log`; minimal shutdown
evidence: `/private/tmp/tts-docs-teardown-evidence.json`.
Model speech synthesis and external licence terms were not revalidated; the
runtime example uses the synthetic tone backend. Implementation was initially
delivered without a commit, push, or PR.

### Commit authorization — 2026-11-16

The user subsequently requested meaningful commits, superseding the original
no-commit restriction. Group the changes into protocol/operations corrections,
client onboarding, and backend navigation with the completion record. This
authorization does not include a push or PR.
