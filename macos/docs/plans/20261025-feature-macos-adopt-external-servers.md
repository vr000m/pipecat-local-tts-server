# Task: Adopt servers that are already running, and start one only when none is

**Status**: Not Started
**Component**: macos
**Assigned to**: Varun / Claude
**Priority**: High
**Branch**: `feature/macos-adopt-external-servers`
**Created**: 2026-10-25
**Review Gates**: full
**Follows**: [phase 2](20261023-feature-stt-service-toolbar.md) (PR #20, merged as d568f69)

## Objective

The Pipecat Service Toolbar reuses a TTS or STT server that is already running
and gives light control over it: show it, copy its URL, test it. It starts its own
server when none answers, and it can own every TTS and STT server. A server it did
not start is never stopped, and its LaunchAgent is never touched. Several apps
(onoats-bot, a Pipecat bot, this app) can then share one server. Other apps find
the app's servers on the well-known catalog ports, or with the `just` recipes that
ship with each server (both the TTS and the STT recipes resolve those same loopback
ports). The intent is that the releases of this app, the TTS server, the STT server
and onoats-bot stay aligned; that is a commitment to make with those repos, not a
fact verified here.

## Context

- Today the app and the `just tts-*` / `just stt-*` LaunchAgents use the same fixed
  loopback ports (drift-tested against the justfile `_resolve` map). A server that
  already holds the port is reported as a failure ("Port N is busy… stop it before
  starting here", `ServiceLifecycle.swift:51-56`). A healthy server on the right port
  is exactly what the app is for.
- Every installed LaunchAgent is on loopback TCP. TTS agents use `--host/--port`
  (label `pipecat.tts-server.<backend>`, already known to `PortProbe` through
  `ServiceInfo.launchdLabel`). The STT agents moved from Unix sockets to TCP in
  pipecat-local-stt-server PR #16 (open, unreleased as 0.5.0): whisper 9565
  (`pipecat.stt-server`), kyutai 9665 (`pipecat.stt-server.kyutai`), parakeet 9765
  (`pipecat.stt-server.parakeet`), nemotron 9865 (`pipecat.stt-server.nemotron`);
  KeepAlive, 10 s throttle. Verified 2026-10-26 from the LaunchAgent plists and
  `just stt-list` on the dev machine; the wire protocol and client are unchanged.
- **Unix sockets are out of scope.** Both servers still support `--socket-path`, but
  no installed agent uses one (a stale `~/Library/Caches/pipecat-tts/tts.sock`
  remains from earlier runs and is ignored). The app discovers and adopts loopback
  TCP endpoints only.
- Both servers speak the same wire protocol v0.1 and can listen on a LAN address (a
  token is then required). A process binds exactly one listener. onoats-bot has no
  TTS client today.
- `server.hello` is the first frame on every connection and carries
  `backend.name`, `backend.model` and `protocol_version` (STT 0.4.0, verified against
  a running nemotron agent; TTS parsed in `TTSClient.swift:40-52`, which drops
  `protocol_version` today). Whisper reports `mlx`; Phonon reports the raw `--model`
  argument (`phonon-q8`), not the repo (`phonon.py:455`). The TTS server answers HTTP
  403 to any handshake that carries an `Origin` header and 401 without a required
  bearer (`tts_server/server.py:616,623`).
- Both clients use `URLSessionWebSocketTask` over TCP (`STTClient.swift:25-35`,
  `TTSClient.swift:106-115`), and so will the probe.
- The app pins `pipecat-local-stt-server==0.3.3` and launches STT through its own
  helper (`EnvironmentManager.swift:180-182`), not the upstream CLI. 0.3.3 already
  sends `backend` in its hello and accepts the `parakeet` and `nemotron` backends;
  0.4.0 adds `python -m stt_server serve --supervised` (JSON `ready`, stdin-EOF
  stop), the backend registry, Kyutai and `status --json`.
- Both servers listen only after the model has loaded (`tts_server/server.py:480-499`),
  so a restarted agent is unreachable for the whole cold start, not only for the
  KeepAlive throttle.

## Requirements

- **Support floor:** STT >= 0.4.0 (the first release with the upstream supervised
  CLI the app launches), TTS >= 0.7.0 (the first release with `serve --supervised`,
  `prefetch` and the supervised contract; released as v0.7.0). The hello check does not enforce the floor
  (a 0.3.3 STT server's hello passes it, and is adopted, as are the 0.5.0 TCP agents);
  the floor states what the app launches and tests. A hello without `backend.name`
  is unsupported.
- **Protocol v0.1 compatibility is non-negotiable.** Client-side probing only; no
  wire change on either server.
- **Ownership invariant:** the app only ever signals, stops or deletes processes it
  started. It never loads, unloads or restarts a LaunchAgent. Quit leaves External
  services running. For a service in `.external`, `s.server` and `s.native` stay nil
  and the reducer issues only allow-listed effects (`.cancelProbe`, `.openTryIt`,
  `.tearDown` for a Try it session, and the state re-read) under any event; it never
  issues `.stopServer`, `.stopNative`, `.discardNative`, `.launch`, `.launchNative`,
  `.startReadyTimer`, `.runInstall`, `.resumeRemoval` or `.removeEnvironment`. The
  allow-list also admits a read-only `.probePortOwner` (the source-line label lookup)
  and, from the new `tryItRequested` event, `.openTryIt`.
  `removeRequested`, `startRequested` (its guard admits `.external` today,
  `ServiceLifecycle.swift:570-572`) and the Get / Install requests on an External
  service are refused by the reducer, not only hidden in the UI. Reset is the app-wide
  `AppEvent.reset`, not a per-service request: it is gated by `blocksReset` (false for
  `.external`), and a reducer row asserts it neither signals nor changes an External
  service. A discovery event is accepted only in `.notInstalled`, `.installed`,
  `.failed`, `.checking` and `.external`; in `.installing`, `.starting`, `.running`,
  `.stopping` and `.removing` it changes nothing, so an `externalFound` can never drop
  `s.server` and leak the owned process. In `.checking` with `startAfterRead` set,
  `externalFound` goes External and clears `startAfterRead`.
- **One decision function.** `entry(for: hello, port) -> Service?` matches
  `backend.name`, then `backend.model` against the entry's `modelArgument ?? modelRepo`
  (a missing model matches only an entry that pins none, such as tone). An unknown
  model for a known backend is a mismatch. A hello whose `protocol_version` is absent
  or not `0.1` is a mismatch. A second server for the same entry on another port is
  ignored.
- **Probe outcomes:** `adopt`, `mismatch`, `needsToken` (HTTP 401/403 on the
  handshake), `silent` (closed without a hello), `timeout` (accepted, no hello before
  the deadline), `unreachable` (refused). `needsToken` rests on `URLSessionWebSocketTask`
  exposing the upgrade response status; Phase 1 verifies that live, and if it does not
  surface, `needsToken` folds into `silent`. On Start, `mismatch` and `needsToken` keep
  a busy failure whose message names what answered; `silent` and `timeout` keep a busy
  failure that says nothing identified itself (or did not answer in time);
  `unreachable` starts the app's own server. On a re-probe the six outcomes map to
  three reasons: `adopt` is `externalFound`; `unreachable` is `externalLost(refused)`
  and `timeout` is `externalLost(timeout)`, each one failed probe; `mismatch`,
  `needsToken` and `silent` are `externalLost(mismatch)`, which moves the service to
  checking at once (something else holds the port) without counting.
- **Endpoints:** loopback `host:port` only, from the catalog. No token in this plan
  (LAN and token storage are out of scope); `needsToken` is a reject outcome. Local
  discovery only: the catalog's loopback ports. No LAN scan, no socket scan.
- **Hello timeout:** a named constant, `ExternalProbe.helloTimeout`, that tests and
  fakes use too; `ExternalProbe` also takes it as an init parameter, so tests that
  wait past it use a short value instead of the production one. Phase 1 measures hello
  latency on a named backend (kokoro or phonon) while a long commit is generating,
  records it in `## Findings`, and sets the default to that figure with margin. A TTS
  event loop can stall during Metal compute (AGENTS.md sizes the pong timeout at 120 s
  for the same reason); tone has no Metal stall, so it cannot size the margin. It must
  stay below the 15 s re-probe period: a discovery pass probes each port once and skips
  a port whose previous probe is still in flight, so a long timeout never queues probes.
  If the measurement needs more than 15 s, the period is raised to match.
- **Re-probe rule:** `ExternalDiscovery` runs one pass at app bootstrap, on panel open
  and every 15 s while the panel is visible (not on Start; Start has its own probe).
  It owns the timer; the panel view only reports visibility through `AppModel`. It
  probes each catalog
  port once and sends each service an epoch-tagged `externalFound` or
  `externalLost(reason:)` (`refused`, `timeout`, `mismatch`). Refused and timeout each
  count as one failed probe: the first failures keep the service External (shown as
  "not responding"); the Nth moves it to the checking phase and re-reads its state. A
  successful probe resets the count, which lives in `LifecycleState`. **Assumption to
  verify in Phase 1:** a KeepAlive restart is outlasted when N x 15 s exceeds
  (cold start to first hello of the heaviest model) + the 10 s throttle. N defaults
  to 3 and is raised if the measured cold start needs it.
- **External controls:** status, Copy URL / Pipecat service / env vars, Test Voice,
  Test Transcription. No Stop, no Delete, no Get / Install / Reset. The source line
  shows the LaunchAgent label when `PortProbe.owner` confirms the port holder is that
  agent: the pid in `launchctl print` equals the pid `lsof` reports for the port.
  Labels exist per family: the TTS backends' default entries (tone included) and the
  four STT families. Variants (Phonon q8/q4, Whisper sizes, Kyutai 2.6B) and Apple
  Speech have none and show `127.0.0.1:<port>`, as does any row where the pid does not
  match.
- **Apple Speech** is an in-process server on 9465 and skips probing and discovery.
- **Start path:** with nothing answering, the app starts its own server. TTS and
  Apple Speech start as today; STT starts through the upstream CLI after Phase 4.
  App-started STT servers bind TCP on the catalog port. A free TCP port launches at
  once, without a hello probe (the existing fast path); a busy port runs one hello
  probe (`.probeExternal`, the only prober on Start), and the service stays in
  `.starting` while it runs. If the launched server then loses the bind race
  (`EADDRINUSE`, `ServiceLifecycle.swift:648-650`), the reducer chains the same single
  `.probeExternal` before it settles on a busy failure, so a KeepAlive restart that
  wins the port is adopted, not reported busy.

## Review Focus

- Protocol v0.1: no frame, field or ordering change on either server.
- Ownership invariant: no code path can signal, stop or delete a process the app did
  not start, including after pid reuse (cf. the reaped-child test in `CoreTests`),
  asserted at the effect level (allow-list) for every event, not only at Quit.
- `ServiceLifecycle` reducer stays total: every (state, event) cell with the new
  External phase, with epoch-tagged discovery events, and with quit under way; the
  discovery epoch survives every non-transition event instead of being cleared with the
  Start-time probe slot.
- Hello-to-entry matching: Whisper variants all report `mlx`; Phonon quantized
  variants report their alias; `protocol_version` is checked.
- TCP probing: refused versus accepted-but-silent versus HTTP 401/403, a listener
  that accepts but never sends `server.hello`, and that the probe sends no `Origin`
  header (the TTS server rejects it with 403; verify against a live tone server).
- A busy TTS server can answer hello slowly; a late hello must not demote a healthy
  External service.
- Adoption trusts `server.hello`; loopback TCP has no peer-uid check, so a local
  process that binds the port first can claim any backend. Test Voice / Test
  Transcription send only the fixed test line and the bundled clip. Try it sends the
  text the user types, so on an External row that text goes to a server the app did
  not start (loopback only, trusted by `server.hello` alone).
- Supervised contract drift: `docs/supervised-contract.json`,
  `tts_server/supervise.py` and the Swift `SupervisedErrorCode` stay one definition.
- Hash-pinned constraints regenerate cleanly after the 0.4.0 bump, in one commit
  with the catalog change and the helper removal.

## Implementation Checklist

Phases 1 to 3 deliver adoption of today's catalog entries; phase 4 moves STT to the
upstream CLI and adds Parakeet and Nemotron (after adoption, so adoption does not
wait on it); phase 5 is conditional and phase 6 is docs and the out-of-process smoke. There is no Phase 0: the Unix-socket spike
was removed on 2026-10-26 when the STT agents moved to TCP (see `## Findings`). Every
phase boundary builds and passes `swift build` and `swift test`. The package's test
target depends on `PipecatToolbarCore` only (`Package.swift:29-35`), so every piece of
logic that needs a test lives in Core; the app target holds only thin shells (timer,
panel-visibility hook, view code).

### Phase 1: Probe, hello timing and the one decision function

**Impl files:** `macos/Sources/PipecatToolbarCore/ExternalProbe.swift, macos/Sources/PipecatToolbarCore/ServerHelloFrame.swift, macos/Sources/PipecatToolbarCore/Service.swift, macos/Sources/PipecatToolbarCore/STTClient.swift, macos/Sources/PipecatToolbarCore/TTSClient.swift, tests/_macos_catalog.py`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ExternalProbeTests.swift, macos/Tests/PipecatServiceToolbarTests/HelloFixtures.swift, macos/Tests/PipecatServiceToolbarTests/EndToEndTests.swift, macos/Tests/PipecatServiceToolbarTests/CoreTests.swift, tests/test_macos_catalog_drift.py`
**Test command:** `uv run pytest tests/test_macos_catalog_drift.py tests/test_supervised_contract.py tests/test_backend_registry.py tests/test_justfile_recipes.py -q && swift test --package-path macos`
**Goal:** One probe and one pure hello-to-entry function, so every caller decides the same way.

- `ExternalProbe`: connect to a loopback port over `URLSessionWebSocketTask`, read `server.hello` under `ExternalProbe.helloTimeout` (an init parameter defaulting to the constant), return one of the six outcomes in Requirements. Error mapping, confirmed by the live probe below: connect refused (`-1004`) is `unreachable`; the deadline passing, or `-1001`, is `timeout`; the socket closing without a hello (`-1005`) is `silent`; a failed upgrade (`-1011`) carrying HTTP 401/403 is `needsToken`. One shared `ServerHelloFrame.decode` in Core parses the hello for `STTClient`, `TTSClient` and `ExternalProbe`, so there is one parser; `protocol_version` is added to `ServerHello` as an optional that defaults to nil, so memberwise callers (`TTSRequestMachineTests.swift:16`) compile unchanged.
- Measure and record in `## Findings`: (a) hello latency on kokoro or phonon mid-commit, which sets `helloTimeout`; (b) cold start to first hello for the heaviest model, against a real KeepAlive restart of an agent, which sets the failure count N; (c) that the probe carries no `Origin` header against a live tone server; (d) how an HTTP 401 surfaces from `URLSessionWebSocketTask` against a tone server started with `--auth-token-file` (if the status is not exposed, `needsToken` folds into `silent`); (e) one real `server.hello` per available backend, recorded into `HelloFixtures.swift`.
- Catalog (`Service.swift`) gains the expected `backend.name` per entry (`mlx` for Whisper), the LaunchAgent label per family (the TTS backends' default entries, tone included, and the four STT families; variants and Apple Speech have none), and the pure `entry(for:port:)`.
- `tests/_macos_catalog.py` (the regex parser of `ServiceInfo(` blocks) learns the new fields. The drift test compares each TTS backend's static `backend_name` and default model with its catalog entry (read from source, which runs in the lean job); a live hello is asserted for tone only.
- Tests: fake servers for every probe outcome with an injectable hello delay (under and over a short `helloTimeout` passed to `init`); Phonon q8/q4, Whisper variants, tone with a model, kokoro with no model, a hello without `protocol_version`, a wrong `protocol_version`. `entry(for:port:)` also runs on the recorded real hellos in `HelloFixtures.swift`, and the existing live E2E tests (`EndToEndTests.swift`) assert that the live hello of the server they start maps back to the service they started.

### Phase 2: Discovery and the External lifecycle

**Impl files:** `macos/Sources/PipecatToolbarCore/ServiceLifecycle.swift, macos/Sources/PipecatToolbarCore/ServiceDriver.swift, macos/Sources/PipecatToolbarCore/PortProbe.swift, macos/Sources/PipecatToolbarCore/ExternalDiscoveryPolicy.swift, macos/Sources/PipecatToolbarCore/ServiceCounts.swift, macos/Sources/PipecatServiceToolbar/State/ExternalDiscovery.swift, macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift, macos/Sources/PipecatServiceToolbar/State/AppModel.swift, macos/Sources/PipecatServiceToolbar/Views/PanelView.swift, macos/Sources/PipecatServiceToolbar/Views/ServiceDetailView.swift, macos/Sources/PipecatServiceToolbar/App/Snapshots.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ServiceLifecycleTests.swift, macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift, macos/Tests/PipecatServiceToolbarTests/ExternalDiscoveryPolicyTests.swift, macos/Tests/PipecatServiceToolbarTests/ServiceCountsTests.swift, macos/Tests/PipecatServiceToolbarTests/CoreTests.swift`
**Test command:** `swift test --package-path macos`
**Goal:** The reducer stays total and an External service can never be signalled, stopped or deleted; the package builds and passes at this phase boundary.

- New `external(port, ExternalInfo)` phase in the pure reducer. `ExternalInfo` is its own struct (backend name, model, rate, protocol version; no pid), so `ServiceRunningInfo.pid` stays non-optional. There is no separate owner slot for discovery: the `externalEpoch` below is the only discovery state that gates events (the existing probe slot is still cleared whenever the phase is not `.starting`, which is why discovery events do not use it).
- Event tags: discovery events carry an `externalEpoch`, a counter in `LifecycleState` that the reducer bumps on every transition into or out of `.external`, and on Delete, Stop and shutdown. `ExternalDiscovery` reads the epoch from the service snapshot when it starts a probe and the outcome carries that epoch back (the policy never re-reads it afterwards); `isCurrent` compares it with `externalEpoch` only and drops an event that is behind, so a Delete, Stop or quit during a probe, or a late result, cannot resurrect a service. `externalFound(epoch:info:)` and `externalLost(epoch:reason:)` are classified in `Kind.owner`, `isNonOwning` and `isCurrent` (`everyKindIsClassified` enforces this): `externalFound` and the Nth `externalLost` (which change the phase) are owning; a below-threshold `externalLost` (count only) is non-owning. The Start-path probe result is a separate event, `startProbeResult(tag:outcome:)`, owned by the `.probe` slot. The failure count lives in `LifecycleState`.
- Discovery policy lives in Core: `ExternalDiscoveryPolicy` is a pure function of (catalog, per-port probe outcomes with their epoch, each service's phase) returning the events to send; it skips any service in an owned phase (the ownership guard in Requirements), skips Apple Speech, and applies "second server ignored". A thin `HelloProber` protocol (default: `ExternalProbe`) lets tests inject outcomes. `ExternalDiscovery` (app target) is only the shell: it owns the 15 s timer, runs one pass at bootstrap (`AppModel` calls it once at launch, before the panel is ever opened), runs the policy, calls the `ServiceDriver` entry points below, and takes panel visibility from `AppModel` (the panel view's `.onAppear` / `.onDisappear` report it). It does not probe on Start.
- `ServiceDriver` gains `externalFound`, `externalLost`, `startProbeResult` and `tryItRequested` entry points that call `send(_:)` and execute the returned effects, refusing when `quitting`, like the existing intents. The `.probeExternal` effect runs through a new `ServiceHost.probeExternal(port:) async -> ExternalProbe.Outcome` seam (`ServiceDriver.swift:45`; `FakeHost` implements it), tracked in `probes[tag]` so `.cancelProbe`, Stop, Delete and quit cancel it like the existing port probe, and its outcome returns as `startProbeResult`.
- Start path (reducer): a free TCP port launches at once (no probe); a busy port emits one `.probeExternal`, and the service stays in `.starting`. One row per outcome, in `.starting` and with a stale tag: `adopt` goes External; `mismatch` chains `.probePortOwner` before the busy failure; `needsToken`, `silent` and `timeout` fail busy with their message; `unreachable` launches. `EADDRINUSE` after a launch (`ServiceLifecycle.swift:648-650`) chains the same single `.probeExternal`: `adopt` goes External, anything else stays the busy failure.
- Derived predicates in `ServiceLifecycle.swift:326-375` (`hasLiveWork` at :326, `blocksReset` at :338): `hasLiveWork` true, `blocksReset` false, `isActive` true, `isBusy` false, `isInstalled` follows the app's environment. `refreshed` does not overwrite `.external`. The counting that decides `AppModel`'s `active`, `startable`, `canReset`, `summary` and `menuBarBadge` (`AppModel.swift:77-120`, `232-234`), `ServiceModel.isRunning` (`ServiceModel.swift:66`) and `quitTitle` (`PanelView.swift:694`, "Stop All & Quit") moves into a pure `ServiceCounts` in Core: External counts as running, and `quitTitle` counts owned services only. The Try it views' `isRunning` gates (`ServiceDetailView.swift:29,32`) allow External. The reducer refuses `removeRequested` and the install/reset requests for `.external`.
- Try it sessions open on demand from an External row (not at adoption). A new `tryItRequested` event (owner none) returns `[.openTryIt(port)]` in `.external`; the existing `becameReady` path is unchanged for owned services. The failed-probe threshold tears the session down (`.tearDown`). This makes four new events (`externalFound`, `externalLost`, `startProbeResult`, `tryItRequested`), so `LifecycleEvent.Kind.allCases` goes from 28 to 32 and the hard-coded count at `ServiceLifecycleTests.swift:285` moves with it.
- `.portBusy(port, owner?)` gains `found` (what answered), so `Snapshots.swift:142` and the views change in this phase. The two views that switch on the phase get their minimal `.external` cases here; Phase 3 finishes the UI. `PortProbe.owner` changes: it parses `pid =` from `launchctl print` and sets `launchdLabel` only when that pid equals the lsof pid for the port (today it sets the label whenever `launchctl print` exits 0, `PortProbe.swift:60-68`).
- Panel visibility: `MenuBarExtra(.window)` has no open/close signal (`ToolbarApp.swift:33-39`). The panel view's `.onAppear` / `.onDisappear` call `AppModel` to start and stop the timer. Verify at the start of this phase (a short spike, before the policy is wired to it) that both fire on every open and close, or fall back to an `NSWindow` visibility observer; Phase 3 re-checks it by hand.
- Tests: add `.external` to the hand-maintained `phases` array in `ServiceLifecycleTests`, add `externalFound` / `externalLost` rows (gone, timeout x1, intermediate failures stay External, the Nth moves to checking, found resets the count, `mismatch` moves to checking at once, and one row each for the `silent` and `needsToken` re-probe outcomes), rows for `externalFound` / `externalLost` in every owned phase (changes nothing) and in `.checking` with `startAfterRead`, `startRequested`, `removeRequested` and Reset on an External service (refused or unchanged), `tryItRequested` rows, rows asserting the epoch survives every non-transition event, the Start-path outcome rows above, a `LifecycleEvent.Kind.allCases` exhaustiveness guard (cf. `AppLifecycleTests.swift:100`), stale-tag x every phase and `shuttingDown` rows, an allow-list effect assertion plus `s.server == nil && s.native == nil` for every event x stale x `shuttingDown`, and quit with an External service next to an owned one. `FakeHost` in `ServiceDriverTests` compiles against the changed host protocol, and a driver test adopts the live tone server (the same gate as the existing live tone test) and asserts Quit leaves it running. `CoreTests` covers `PortProbe.owner` (pid match sets the label, a mismatching pid does not). Policy fixtures: silent listener, hello mismatch, needs-token, second server ignored, owned service skipped, Apple Speech never probed (9465), a slow hello that stays External, and `externalLost` then `externalFound` after a LaunchAgent restart. `ServiceCountsTests` covers the predicates and `quitTitle`.

### Phase 3: External services in the menu

**Impl files:** `macos/Sources/PipecatServiceToolbar/Views/PanelView.swift, macos/Sources/PipecatServiceToolbar/Views/ServiceDetailView.swift, macos/Sources/PipecatServiceToolbar/State/ServiceModel.swift, macos/Sources/PipecatServiceToolbar/App/Snapshots.swift, macos/Sources/PipecatServiceToolbar/App/ToolbarApp.swift, macos/Sources/PipecatToolbarCore/ServiceLifecycle.swift, macos/Sources/PipecatToolbarCore/ServiceDriver.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ServiceLifecycleTests.swift, macos/Tests/PipecatServiceToolbarTests/ServiceDriverTests.swift, macos/Tests/PipecatServiceToolbarTests/CoreTests.swift`
**Test command:** `swift test --package-path macos`
**Validation cmd:** `just app-smoke`
**Goal:** A person can tell at a glance which servers the app owns, and Quit never touches the ones it does not.

- "External" badge and source line (the LaunchAgent label when `PortProbe.owner` confirms the holder's pid matches the entry's `launchdLabel` agent, otherwise `127.0.0.1:<port>`; variants and Apple Speech have no label; "not responding" during the re-probe window). Stop, Delete, Get, Install and Reset hidden; Copy URL, Pipecat service, env vars, Test Voice, Test Transcription present. Copy actions use the existing host/port forms; a TCP endpoint is all there is.
- The Try it chain stays port-typed (the host is always 127.0.0.1), so `TryItSession`, `STTTryItSession`, `TTSRequestDriver`, `STTClient(port:)` (including its `#if DEBUG` caller in `DebugTools.swift:81`) and the `init(host:port:)` convenience are unchanged.
- Verify the panel `.onAppear` / `.onDisappear` timer hook from Phase 2 fires on every open and close (manual, in the validation step).
- `AppLifecycle` stays unchanged: it has no service knowledge, and `shutdownServers` already stops only `s.server` / `s.native`. The quit invariant is tested at the service level (Phase 2 tests).
- Debug snapshots render an External row.

### Phase 4: STT through the upstream CLI, plus Parakeet and Nemotron

**Impl files:** `macos/Sources/PipecatToolbarCore/Service.swift, macos/Sources/PipecatToolbarCore/EnvironmentManager.swift, macos/Sources/PipecatToolbarCore/ServiceDriver.swift, macos/Sources/PipecatToolbarCore/ToolLocator.swift, macos/Sources/PipecatToolbarCore/PrefetchEvent.swift, macos/Helper/pipecat_app_helper.py, macos/scripts/build_app.sh, macos/constraints/stt-whisper.txt, macos/constraints/stt-kyutai.txt, macos/constraints/stt-parakeet.txt, macos/constraints/stt-nemotron.txt, macos/scripts/compile_stt_constraints.py, docs/supervised-contract.json, tests/_macos_catalog.py, .github/workflows/test.yml`
**Test files:** `tests/test_macos_catalog_drift.py, tests/test_supervised_contract.py, tests/test_app_helper_cancel.py, tests/fixtures/stt_supervised_lines.jsonl, macos/Tests/PipecatServiceToolbarTests/CoreTests.swift, macos/Tests/PipecatServiceToolbarTests/EndToEndTests.swift`
**Test command:** `uv run pytest tests/test_macos_catalog_drift.py tests/test_supervised_contract.py tests/test_app_helper_cancel.py -q && swift test --package-path macos`
**Validation cmd:** `PIPECAT_TOOLBAR_E2E=1 swift test --package-path macos --filter EndToEnd`
**Goal:** The app launches STT through the same upstream CLI a LaunchAgent runs, so adoption and ownership use one entry point.

- Order inside the phase: (a) decide which helper behaviour upstream 0.4.0 already covers (Kyutai backend and its leading/trailing silence, mlx-whisper, `prefetch`); record why in `## Findings`. (b) Generalise `tests/_macos_catalog.py` and the helper-coupled tests only in ways that stay green on 0.3.3 (nothing removed yet). (c) One commit, in this order: change the catalog (Parakeet and Nemotron entries) and `tests/_macos_catalog.py` first, because `compile_stt_constraints.py` reads the engines through that parser; then bump `sttServerRequirement` to the exact 0.4.0 release and regenerate all four hash-pinned constraints files, asserting that four files were written; then remove the helper pieces upstream covers and everything that referenced the helper (`macos/scripts/build_app.sh:53` copies it under `set -euo pipefail`, `ToolLocator.swift:12-24,104-126`, `EnvironmentManager.swift:161-163,180-182` and `:528`, `ServiceDriver.swift:446-448`, and the `Tools.helper` field with its constructors in `CoreTests`), or state in `## Findings` which helper subcommands survive and why; switch the launch in `EnvironmentManager` / `ServiceDriver`; add `ModelInvalidError` to `docs/supervised-contract.json` and `SupervisedErrorCode`, with the contract's `error_codes` split per emitter (TTS and STT) so `tts_server/supervise.py` is not edited and never carries a code TTS does not emit; rewrite the helper-coupled drift tests (`serve_events`, the engine-set and `# requirement:` checks, `MODEL_REVISIONS`, and a per-emitter code check in `tests/test_supervised_contract.py`), and, if step (a) removes the cancel path, delete `tests/test_app_helper_cancel.py`, drop it from the lean allow-list at `.github/workflows/test.yml:76` and from this phase's test command. A partial commit fails CI.
- The upstream ready/error lines are contract-tested in the lean job from a recorded fixture (`tests/fixtures/stt_supervised_lines.jsonl`: a real 0.4.0 `ready` and `error` line, checked against `docs/supervised-contract.json`); the opt-in E2E asserts the live line matches it.
- Launch `python -m stt_server serve --supervised --backend <b> --model <m> --host 127.0.0.1 --port <p>` (TCP); read the JSON `ready` line; stdin EOF stops it. The `commands` launch-argument test (`CoreTests.swift:118-126`) is rewritten to assert exactly this argv, so the launch is unit-tested in CI, not only by the opt-in E2E.
- Catalog: Parakeet on 9765 and Nemotron on 9865, the ports the STT repo's LaunchAgents already use (PR #16; the +100 pattern continues the app's series). This is agreement with that repo, not a registry check, and it is confirmed live as of 2026-10-26. Each gets its own environment and constraints file, the hello `backend.name` (`parakeet`, `nemotron`), its `modelRepo` (the LaunchAgents' `mlx-community/parakeet-tdt-0.6b-v3` and `mlx-community/nemotron-3.5-asr-streaming-0.6b`) and its label (`pipecat.stt-server.parakeet` / `.nemotron`); Whisper and Kyutai carry `pipecat.stt-server` and `pipecat.stt-server.kyutai`. The catalog drift test is extended to the STT entries' `modelRepo`.
- E2E (opt-in, not CI): Parakeet and Nemotron install and serve; the Nemotron try-it flow is also run against the TCP LaunchAgent on 9865.

### Phase 5: Discovery file (conditional on onoats-bot)

**Impl files:** `macos/Sources/PipecatToolbarCore/ServicesFile.swift, macos/Sources/PipecatServiceToolbar/State/AppModel.swift`
**Test files:** `macos/Tests/PipecatServiceToolbarTests/ServicesFileTests.swift`
**Test command:** `swift test --package-path macos --filter ServicesFile`
**Goal:** Publish what the app owns for other apps without becoming a dependency of them.

- Default: not built. Whether onoats-bot probes the well-known catalog ports (the STT agents listen on them too) or uses the servers' `just` recipes is unconfirmed and is settled with that repo; it has no probing of its own today. Build the file only if onoats-bot asks for one.
- If built: the app writes `~/Library/Application Support/Pipecat Service Toolbar/services.json` (engine, endpoint, pid, started_at; owned services only), atomically, mode 0600, removed on Quit. It is advisory; consumers must still verify `server.hello`.

### Phase 6: Docs and an out-of-process smoke

**Impl files:** `macos/README.md, macos/docs/architecture.md, AGENTS.md, CHANGELOG.md, macos/scripts/ui_smoke.sh`
**Test files:** `tests/test_justfile_recipes.py`
**Test command:** `uv run pytest tests/test_justfile_recipes.py -q`
**Validation cmd:** `just app-smoke`

- `ui_smoke.sh` starts a server out of process (TCP) on a catalog port that is free, launches the bundle, asserts External from the bootstrap log line written by the one discovery pass `AppModel` runs at launch (Phase 2; the script never opens the panel and cannot read panel text; its phase-line regex at `ui_smoke.sh:137` gains `external`), and asserts the out-of-process pid is alive after Quit. It skips with a clear message when the canonical port is already held by a real agent. It runs through `just app-smoke`, which is manual (the pytest above checks recipe and README drift only).
- README and architecture: the adopt-first rule, the ownership invariant, the support floor, running beside `just tts-install` and `just stt-*`, that the app can own every server while other apps probe the well-known ports, and that Unix sockets are not discovered.
- CHANGELOG entry; extend the "Known follow-ups" list in `macos/docs/architecture.md` (that is where the heading lives; the earlier plans point there) with Unix-socket discovery, LAN endpoints and token storage.

## Technical Specifications

### Files to Modify
- `macos/Sources/PipecatToolbarCore/{STTClient,TTSClient}.swift` - keep `protocol_version` from the hello.
- `macos/Sources/PipecatToolbarCore/{ServiceLifecycle,ServiceDriver,PortProbe}.swift` - External phase and discovery epoch, discovery, Start-probe and `tryItRequested` events, the `ServiceHost.probeExternal` seam, predicates, busy failure that names what answered, pid-checked `PortProbe.owner`.
- `macos/Sources/PipecatToolbarCore/{Service,EnvironmentManager,ToolLocator,PrefetchEvent}.swift` - expected backend names, LaunchAgent labels, hello-to-entry function, STT launch command, helper removal, `SupervisedErrorCode`, Parakeet and Nemotron.
- `macos/Sources/PipecatServiceToolbar/{State/ServiceModel,State/AppModel,Views/PanelView,Views/ServiceDetailView,App/Snapshots,App/ToolbarApp}.swift` - External rows, menu items, derived properties, timer hook, bootstrap discovery pass.
- `macos/Helper/pipecat_app_helper.py`, `macos/scripts/build_app.sh`, `macos/constraints/*`, `macos/scripts/compile_stt_constraints.py`, `docs/supervised-contract.json` (error codes per emitter).
- `tests/_macos_catalog.py`, `tests/test_macos_catalog_drift.py`, `tests/test_supervised_contract.py`; `.github/workflows/test.yml` (Phase 4, the lean allow-list).

### New Files to Create
- `macos/Sources/PipecatToolbarCore/{ExternalProbe,ServerHelloFrame,ExternalDiscoveryPolicy,ServiceCounts}.swift`; test fixture `macos/Tests/PipecatServiceToolbarTests/HelloFixtures.swift`.
- `macos/Sources/PipecatServiceToolbar/State/ExternalDiscovery.swift` (thin shell).
- `macos/Sources/PipecatToolbarCore/ServicesFile.swift` (phase 5, conditional).
- `macos/constraints/stt-parakeet.txt`, `stt-nemotron.txt`; `tests/fixtures/stt_supervised_lines.jsonl`.
- Matching test files under `macos/Tests/PipecatServiceToolbarTests/`.

### Architecture Decisions
- **Adopt first, own second.** A busy port is probed before the app starts anything; a free port launches at once. The canonical loopback port is the discovery contract, and several apps can share one server.
- **The app can own every server.** App-started servers bind the catalog TCP ports, which are well known; other apps probe them or use the `just` recipes.
- **The app never touches a LaunchAgent.** KeepAlive restarts anything the app stops within 10 s, and a second owner for one process invites races. It only reads the label (through `PortProbe.owner`, which requires the `launchctl` pid to equal the pid holding the port) to show where a server came from.
- **Support floor, not version sniffing.** Neither hello carries a package version.
- **Strict hello matching** (name, model alias, protocol 0.1), one pure function.
- **External controls are observe, copy and test.** Stop would be undone by KeepAlive.
- **Local discovery only; no token in this plan.** LAN endpoints and token storage are a follow-up.
- **TCP only; Unix sockets deferred.** Every installed agent uses loopback TCP, so the app neither scans nor probes sockets. Protocol untouched.
- **One prober per path.** `ExternalDiscovery` (one bootstrap pass, panel open and a 15 s timer it owns) feeds the per-service reducers found/lost events; the reducer's `.probeExternal` is the Start path and the `EADDRINUSE` path only. The reducer owns every state change; the driver and discovery only run effects and report results. Testable policy lives in Core; the app target holds only shells.

### Dependencies
- `pipecat-local-stt-server` 0.3.3 to 0.4.0 (hash-pinned constraints regenerate in the same commit as the catalog and the helper removal). The 0.5.0 TCP agents (PR #16, unreleased) are adopted by hello alone and need no pin change.
- No new Swift packages.

### Integration Seams

| Seam | Writer (task) | Caller (task) | Contract |
|------|---------------|---------------|----------|
| `ExternalProbe` | Phase 1 | Phase 2 policy, Start path | Six outcomes; `helloTimeout` constant shared with fakes |
| `entry(for:port:)` | Phase 1 | `ExternalDiscoveryPolicy`, Start-path probe | Pure; strict name + model alias + protocol 0.1; nobody re-implements it |
| `ExternalDiscoveryPolicy` and driver entry points | Phase 2 | `ExternalDiscovery` shell, `AppModel` | Pure policy in Core; driver runs effects, refuses when `quitting` |
| Discovery events and External phase | Phase 2 reducer | Phase 3 views, `AppModel` | Epoch-tagged; a service in External is never signalled, stopped or deleted; stale results ignored; owned phases ignore them |
| `ServiceCounts` | Phase 2 | `AppModel`, `PanelView`, `ServiceModel` | Pure; External counts as running, `quitTitle` counts owned only |
| Expected backend names and labels | Phase 1 catalog (TTS and existing STT) / Phase 4 (Parakeet, Nemotron) | `ExternalDiscoveryPolicy`, drift tests | Every entry carries `backend.name`; each family carries a LaunchAgent label (variants and Apple Speech none) |
| Supervised contract | Phase 4 | JSON (codes per emitter), `SupervisedErrorCode`, drift tests, STT fixture | `supervise.py` stays the TTS emitter and is not edited; two definitions plus one recorded upstream fixture, one commit |

## Architecture & Call Flow

Component graph (which component triggers which):

```mermaid
graph LR
    APP["Toolbar app (reducers + drivers)"] -->|"Start path: one probe, only when port busy"| TTS["TTS server (TCP port)"]
    APP -->|"Start path: one probe, only when port busy"| STT["STT server (TCP port)"]
    TIMER["Re-probe timer (owned by ExternalDiscovery; panel visibility via AppModel; one pass at launch)"] -->|"run"| DISC["ExternalDiscovery shell"]
    DISC -->|"policy over probe outcomes"| POL["ExternalDiscoveryPolicy (Core)"]
    DISC -->|"server.hello, once per port"| TTS
    DISC -->|"server.hello, once per port"| STT
    DISC -->|"externalFound / externalLost(reason)"| APP
    APP -->|"owns: serve --supervised"| OWN["App-started server (TCP)"]
    APP -->|"lsof owner lookup on mismatch and for the label"| PORT["Port holder"]
    TRY["Try it sessions"] -->|"port"| TTS
    TRY -->|"port"| STT
    LA["LaunchAgent (KeepAlive)"] -->|"owns"| STT
    LA -->|"owns"| TTS
    BOT["onoats-bot / Pipecat apps"] -->|"WebSocket, well-known port"| STT
    BOT -->|"WebSocket, well-known port"| OWN
```

Trigger order:

```mermaid
sequenceDiagram
    participant U as User
    participant A as Toolbar app
    participant D as ExternalDiscovery
    participant E as Catalog port
    U->>A: open panel
    A->>D: run policy
    D->>E: connect, read server.hello (once per port)
    D-->>A: externalFound or externalLost(reason)
    A-->>U: External row (not stopped on Quit)
    U->>A: press Start
    alt TCP port is free
        A->>A: launch own server at once
        A->>E: wait for ready line
        A-->>U: Running (owned)
    else port busy
        A->>E: one hello probe (.probeExternal)
        A-->>U: External, or busy failure naming what answered
    end
    loop every 15 s while the panel is open
        D->>E: re-probe External
        Note over A: failures below the threshold keep External, the Nth re-reads state
    end
    U->>A: Quit
    A->>A: stop owned only, leave External running
```

Context lifecycle:

| Step | Trigger | Enters context | Cleared/persisted | Turn boundary |
|------|---------|----------------|-------------------|---------------|
| 1 | Panel opens | catalog entries, expected `backend.name` and model | persists in the service model | after the policy returns |
| 2 | `server.hello` read | `backend.name`, `backend.model`, `protocol_version`, rate | persists as External info | probe connection closed |
| 3 | Adopted | port, epoch | persists until the Nth failed probe | none |
| 4 | Probe fails (refused or timeout) | reason | counted in `LifecycleState`; reset by a success; the Nth failure re-reads state | next probe |
| 5 | App starts its own server | `ready` line (pid, port, model) | persists until Stop or Quit | after the `ready` line |
| 6 | Quit | owned set only | owned stopped, External untouched | after the drain |

## Testing Notes

### Test Approach
- [ ] Reducer table tests cover every (state, event) cell with the External phase: `.external` in the `phases` array, discovery events with reasons, an `allCases` guard, stale tags, quit under way, `removeRequested` and install/reset refused, discovery events in owned phases change nothing, one row per Start-path probe outcome, and the `EADDRINUSE` chain.
- [ ] Effect-level ownership invariant: an allow-list of effects for `.external`, and `s.server == nil && s.native == nil`, for every event x stale x `shuttingDown`.
- [ ] Probe tests against fake servers with an injectable hello delay: matching hello, wrong backend, wrong model, no or wrong `protocol_version`, silent, timeout, token required, closed port.
- [ ] Hello-to-entry tests: Whisper variants, Phonon q8/q4, tone with and without a model, kokoro with none; drift of each TTS backend's static `backend_name` against the catalog (lean), live hello for tone only.
- [ ] `ExternalDiscoveryPolicy` and `ServiceCounts` tests in Core (policy fixtures and counting predicates, `quitTitle`).
- [ ] Live tests: tone server over TCP (adopt, then Quit leaves it running; a `ServiceDriverTests` test behind the existing live-tone gate); hello latency on a real backend mid-commit; cold start to first hello and a real agent restart (sets N).
- [ ] Recorded upstream `ready`/`error` fixture checked in the lean job; opt-in E2E (`PIPECAT_TOOLBAR_E2E=1`): Parakeet and Nemotron install and serve.
- [ ] Out-of-process smoke in `ui_smoke.sh` (Phase 6).
- [ ] Manual: run beside `just tts-install tone` and an STT LaunchAgent; the app shows both as External and Quit leaves them; the panel `.onAppear` / `.onDisappear` hook fires on every open and close.

### Test Results
- [ ] All existing tests pass
- [ ] New tests added and passing
- [ ] Manual verification complete

### Edge Cases Tested
- [ ] A LaunchAgent restarts the server while the app shows it External (the count absorbs the refused connections and the row recovers; N measured in Phase 1).
- [ ] A KeepAlive restart wins the port right after the app launched (`EADDRINUSE`): adopted, not a busy failure.
- [ ] A server on the port answers with the wrong backend or model.
- [ ] Two servers for one engine on different ports (the second is ignored).
- [ ] A re-probe that finds a different backend (`mismatch`), a silent listener or a token-protected server moves the row to checking at once.
- [ ] A busy server misses one hello window and stays External.
- [ ] Discovery never changes a service the app owns.
- [ ] Apple Speech never probes.

## Acceptance Criteria

- With `just tts-install tone` running, the app shows Tone as External, never reports "port busy", and Quit leaves it running.
- With nothing running, Start launches an owned server (TTS and Apple Speech as today; STT through the upstream CLI after Phase 4).
- After Phase 4, with an STT LaunchAgent on `127.0.0.1:9865` (Nemotron), the app shows Nemotron as External with its LaunchAgent label and Test Transcription works.
- No path signals, stops or deletes a process the app did not start; an effect-level allow-list test asserts it.
- STT starts through `python -m stt_server` (the launch argv is unit-tested in CI); Parakeet and Nemotron install and run (verified by the opt-in E2E tests, which are not in CI).
- `swift build` and `swift test` pass at every phase boundary.
- No change to wire protocol v0.1 on either server.
- Code reviewed and approved; tests passing; docs updated.

<!-- reviewed: 2026-10-26 @ 834c5b88b57a0078d9ae42794019ec07224a57d3 -->

<!-- /review-plan writes the review marker above this line. Everything below is the workspace: edits here do NOT invalidate the marker. -->

## Progress

- [x] Phase 1: Probe, hello timing and the one decision function (code and tests; the live measurements in the Phase 1 findings entry are still open)
- [x] Phase 2: Discovery and the External lifecycle (code and tests; the panel `.onAppear`/`.onDisappear` hook is UNVERIFIED and needs a manual check)
- [ ] Phase 3: External services in the menu
- [ ] Phase 4: STT through the upstream CLI, plus Parakeet and Nemotron
- [ ] Phase 5: Discovery file (conditional on onoats-bot)
- [ ] Phase 6: Docs and an out-of-process smoke

## Findings

- **2026-10-26, supersedes the socket facts below (user decision after the third `/review-plan`):** the plan is TCP-only. Evidence: the four `pipecat.stt-server*` LaunchAgent plists on the dev machine pass `--host 127.0.0.1 --port 9565|9665|9765|9865` and no `--socket-path`; the one installed TTS agent (`pocket_tts`) is on `127.0.0.1:8965`; `~/Library/Caches/pipecat-stt` is empty and `pipecat-tts` holds only a stale `tts.sock`; `just stt-list` shows every agent on TCP. Source: pipecat-local-stt-server PR #16 (`feat/stt-recipes-tcp-endpoints`, open, unreleased as 0.5.0; peer `pipecat-local-stt-server-78`). Removed: Phase 0 (Unix spike), `Endpoint`, `WebSocketTransport`, `SocketScan`, the socket criteria, the `unix:` copy actions and the `.lock` handling.
- 2026-10-26, decisions from the third `/review-plan` (user): contradiction 24 resolved as "label when launchd holds the port" (`PortProbe.owner` resolves to the entry's `launchdLabel`, else `127.0.0.1:<port>`); contradictions 5 and 7 dissolved by TCP-only; contradiction 6 resolved to the second grill's decision (`.probeExternal` is the Start and `EADDRINUSE` path only; discovery runs on panel open and the timer). All other findings applied as recommended: discovery policy and counting moved into Core (the test target sees only `PipecatToolbarCore`), epoch-tagged discovery events plus a separate `startProbeResult`, `ExternalInfo` without a pid, owned-phase guard, driver entry points, `EADDRINUSE` chain, `hasLiveWork`/`blocksReset` citations corrected, `test.yml` and `test_app_helper_cancel.py` handled in Phase 4 step (c), hello timeout measured on a named backend, the restart-window assumption measured in Phase 1.
- 2026-10-26, decisions from the fourth `/review-plan` (user said "address all"; all grilled items accepted as recommended; the edits were applied directly to the plan, not through `/dev-plan update`):
  - Decision (grilled): the source-line label needs the `launchctl print` pid to equal the lsof pid; labels exist per family (TTS default entries including tone, four STT families), variants and Apple Speech show `127.0.0.1:<port>`; `.probePortOwner` (read-only) joins the External allow-list.
  - Decision (grilled): Review Focus is reworded; Test Voice / Test Transcription send fixed content, Try it sends typed text to an External server.
  - Decision (grilled): `AppModel` runs one discovery pass at bootstrap, so the Phase 6 smoke can assert External from the bootstrap log without opening the panel.
  - Decision (grilled): discovery events are gated by `externalEpoch` only (no discovery owner slot), captured at probe start and carried on the outcome; below-threshold `externalLost` is non-owning.
  - Decision (grilled): new `tryItRequested` event opens Try it on an External row; `Kind.allCases` goes 28 to 32.
  - Applied as recommended: re-probe outcome mapping (`mismatch`/`needsToken`/`silent` move to checking at once), `startRequested` refusal and Reset gating, accepted phases named, `helloTimeout` init parameter and ceiling below the 15 s period, URLSession error mapping and the 401 live check, shared `ServerHelloFrame.decode`, recorded hello fixtures, `ServiceHost.probeExternal` seam, timer ownership, panel-hook spike at the start of Phase 2, Phase 4 helper-removal completeness and ordering, per-emitter contract codes (`supervise.py` not edited), STT `modelRepo` drift check, argv unit test, Phase 1 test command includes `test_justfile_recipes.py`, "stale `tts.sock`" edge case dropped, onoats-bot probing marked unconfirmed.
- 2026-10-26, Phase 1 live measurements (run by the conductor against throwaway servers on 18665/18666 plus read-only probes of the real agents; the real agents were not restarted or loaded beyond one pocket_tts commit): (a) hello latency, `ExternalProbe` against the real agents idle: 1-3 ms (pocket_tts 8965, Whisper 9565, Kyutai 9665, Parakeet 9765, Nemotron 9865). Against a throwaway kokoro (Metal) with 1 and then 3 concurrent long commits: 40 and 60 probes, median 2 ms, worst 112 ms (the tail was 13, 16, 74 and 112 ms). Phonon and the heavier TTS backends were not measured. The provisional 5.0 s is about 45x the worst seen; a lower value is the user's call and is not applied. (b) OPEN: cold start to first hello against a real KeepAlive restart was not measured (it needs a restart of a real agent); it sets N. (c) CONFIRMED: a tone server answers 403 to an upgrade that carries an `Origin` header and 101 to one that does not; `ExternalProbe` sends none and adopted/mismatched every server it was pointed at. (d) CONFIRMED: against a tone server started with `--auth-token-file`, `URLSessionWebSocketTask` fails with NSURLErrorDomain -1011 and `task.response` is an `HTTPURLResponse` with statusCode 401, so `ExternalProbe` returns `.needsToken`, as the fake-server tests assume. Side finding: an unrelated web app on 9520 (`koda-pipecat`) answers 403 to the upgrade and also maps to `.needsToken`; discovery only probes catalog ports, so this only matters if a catalog port is ever taken by a non-Pipecat HTTP server (the Phase 3 menu text for `.needsToken` should not claim the server is Pipecat). (e) real hellos recorded for pocket_tts, kokoro, Whisper (turbo), Kyutai (1b), Parakeet and Nemotron: `protocol_version` 0.1, keys `audio, backend, capabilities, event_id, protocol_version, type`, and `backend.name`/`backend.model`/rate all equal the `HelloFixtures.synthesized` rows for pocket_tts, kokoro, Whisper turbo and Kyutai 1b. Parakeet reports `parakeet` / `mlx-community/parakeet-tdt-0.6b-v3` and Nemotron `nemotron` / `mlx-community/nemotron-3.5-asr-streaming-0.6b` (both 16 kHz); they have no catalog entry until Phase 4, so today they probe as `.mismatch`. Not recorded live: phonon, qwen3, voxtral, dia, fish, the Whisper variants, Kyutai 2B and Apple Speech, which stay marked synthesized.
- 2026-10-26, Phase 1 conduct (code and tests committed; live measurements OPEN, they need real servers and the user): (a) hello latency on kokoro or phonon mid-commit, which replaces the provisional `ExternalProbe.helloTimeout = 5.0`; (b) cold start to first hello of the heaviest model against a real KeepAlive restart, which sets N; (c) no `Origin` header against a live tone server (the live tone test asserts this); (d) how an HTTP 401 surfaces from `URLSessionWebSocketTask` against a tone server with `--auth-token-file` (only the fake server's 401/403 is tested so far); (e) real hellos per backend (only tone is recorded; the rest are marked synthesized in `HelloFixtures.swift`). Advisory reviewer findings: Important, the new STT `launchdLabel` values reach the unchanged `PortProbe.owner` (no pid check until Phase 2), so the busy-port message can name an STT agent that does not hold the port; Minor, a cancelled probe returns `.silent`/`.timeout` so Phase 2 callers must discard cancelled results by tag/epoch; the free `entry(for:port:)` forwarder duplicates `ServiceInfo.entry(for:port:)`; stale `PortProbe.Owner.launchdLabel` doc comment; `HelloFixtures.liveHello` has no receive deadline; `ExternalProbe.outcome(for:httpStatus:)` has no direct table test.
- 2026-10-26, Phase 2 conduct (sequential spawn: the four new events and the new `ExternalInfo`, `ServiceCounts` and policy types had payloads the plan did not fix, so tests in parallel would have targeted guessed signatures; 259 Swift tests pass, 0 fix-loop iterations). Not done and owed to a person: the panel-visibility spike. `PanelView` calls `AppModel.setPanelVisible` from `.onAppear`/`.onDisappear`, but nobody has confirmed both fire on every open and close of the `MenuBarExtra(.window)` panel (a GUI cannot be driven here); if `.onAppear` fires only once the 15 s timer never restarts, and if `.onDisappear` never fires it probes forever. Fallback is an `NSWindow` visibility observer. Phase 3's manual check must cover it. Implementer deviations: new file `HelloProber.swift` (not in the Impl list) and `Service.swift` edited to remove the free `entry(for:port:)` forwarder; `Snapshots.swift` not edited (`.portBusy(found:)` has a default, the External snapshot row is Phase 3). Plan wording to fix: the plan says an External service never gets `.discardNative`, but `reduce`'s first guard answers a stale `nativeBound` with it in every phase; the driver treats it as a no-op and a native id only names an app-launched Apple Speech server, so the allow-list wording should exempt it. Advisory reviewer (opus, one pass; no Critical): Important, the panel-hook spike above. Minor: (1) `startRequested` does not advance `externalEpoch`, so a discovery probe that began before Start and adopts after the Start probe settled into `.failed(.portBusy(.server))` is still current and adopts a server the Start probe judged a mismatch (fix: add `.startRequested` to `changesExternalEpoch`, or bump on settle); (2) `PortProbe.owner`'s `launchctlPid(...) == pid` condition is not tested end to end, only `launchctlPid` parsing is (extract a pure `label(lsofPid:launchctlLines:label:)` and table-test it); (3) `canDeleteModel` ignores `.external`, so an External row still offers a Delete Model dialog the reducer refuses (add `!phase.isExternal`, `ServiceModel.swift:78`); (4) the bootstrap discovery pass is awaited by shutdown and `discovery.stop()` cannot cancel it, so a Quit during launch can wait up to `helloTimeout`, and an already-running timer pass makes the bootstrap pass return early so the phase log lines the Phase 6 smoke reads can precede the External results; (5) after the panel closes mid-pass `passing` stays true until the cancelled probes unwind, so an immediate reopen skips the open-time pass (track the pass Task instead of a boolean); (6) `ServiceCounts.owned` counts `.running` only, so an app-owned server in `.starting`/`.stopping` shows plain "Quit" (count `server != nil || native != nil`); (7) only `ExternalDiscoveryPolicy.probes` keeps Apple Speech out of discovery, the `externalFound` reducer guard does not check `runtime` (add `s.runtime != .appleSpeech`). Reviewer-confirmed: the ownership invariant holds (`.external` cannot produce a stop/launch/install/remove effect and keeps `server == nil && native == nil`), epoch capture and gating are sound, every Start-path outcome row matches, cancelled probes are dropped by tag and by `Task.isCancelled`, and `launchctlPid` parses the real STT plist shape. The `PortProbe.owner` pid check (the Phase 1 Important finding) is in. Phase 1's "cancelled probe returns `.silent`/`.timeout`" Minor is handled for both consumers.
- Pending: pipecat-local-stt-server-78 asked this branch to confirm 9765/9865 (done, they match Phase 4) and when this branch ships (not stated by the user yet). Until it ships, an app-started server and an agent on one port contend and the app reports `failed(.portBusy)`.
- (superseded socket facts, kept for history) 2026-10-25, STT peer (`pipecat-local-stt-server-78`, v0.4.0, main 4484373), facts from its code:
  - `server.hello` and `server.status` carry `backend: {name, model}`. `name` is one of echo, mlx, parakeet, nemotron, kyutai (`mlx` is Whisper). Hello is the first frame on every connection.
  - `--socket-path PATH` replaces the TCP flags (no TCP listener is bound); one listener per process. Socket 0600 under umask 077, directory owned by the user and 0700, `<sock>.lock` (flock) left on disk. Peer uid must equal the server's euid (else 403); a bearer token is optional on top, and is the only auth on TCP.
  - `python -m stt_server status [--socket-path|--host/--port|--uri] [--json]` is the health probe; `serve --supervised` prints one JSON `ready` line or one `error` line (codes: EADDRINUSE, EACCES, ModuleNotFoundError, ModelDownloadError, ModelInvalidError, ConfigError, BackendStartError); stdin EOF stops it.
- 2026-10-25, codebase facts: both Swift clients are TCP only; `NWProtocolWebSocket` is used server-side in `STTWebSocketServer.swift`; the app pins 0.3.3 and launches STT through its own helper, which also defines Kyutai.
- 2026-10-25, onoats-bot (relayed by the user): STT is a WebSocket. A raw (non-WebSocket) connect fails the handshake ("did not receive a valid HTTP request"), so every probe must speak WebSocket. Its default was the Unix socket (`stt.sock`) with TCP via `STT_WS_URI` / `STT_WS_HOST` / `STT_WS_PORT`; with the STT agents on TCP it must use the port (not yet confirmed with onoats-bot).
- 2026-10-25, decision (user): LAN endpoints are out of scope for this plan; local discovery only. Revisit as a follow-up.
- 2026-10-25, decisions from the first `/review-plan` grill (user):
  1. App-started STT binds TCP on the catalog port (accepted). Phase 4's goal says "same upstream CLI".
  2. Re-probe: failures keep External until the threshold, then checking plus re-read; a timeout means retry later (accepted; refined below).
  3. No token in the endpoint; `needsToken` is a reject outcome (accepted).
  4. Strict hello-to-entry match: name, `modelArgument ?? modelRepo`, protocol 0.1 (accepted).
  5. Phase 4 stays in this branch as the last phase (accepted). The user added: the menu bar app can own all STT and TTS servers; onoats-bot can probe them with the servers' `just` recipes or a well-known port; releases are aligned across onoats-bot and this repo. Phase 5 (`services.json`) therefore defaults to not built.
- 2026-10-26, decisions from the second `/review-plan` grill (user, all accepted as recommended):
  1. A refused connection counts as one failed probe, the same as a timeout (so a KeepAlive restart recovers without the row disappearing).
  2. `ExternalDiscovery` owns re-probing; reducers only consume found/lost events; `.probeExternal` is Start-path only.
  3. (superseded: the Phase 0 no-go fallback) The branch is now TCP-only by decision, not by a failed spike.
- 2026-10-26, applied without a grill (obvious from the second review): added a `timeout` probe outcome distinct from `silent`; moved `Snapshots.swift` into Phase 2; Phase 4 steps (b)/(c) split so only (c) removes the helper; the real-hello drift test compares static backend names (live hello for tone only); a recorded upstream `ready`/`error` fixture for the lean job; adoption of Parakeet and Nemotron arrives in Phase 4; the Known follow-ups heading lives in `macos/docs/architecture.md`.
- 2026-10-26, user: onoats-bot needs STT only, no TTS. TTS adoption is for other Pipecat apps and the `just tts-*` agents; onoats-bot's only touchpoint is STT.
- Pending: onoats-bot-39 has not answered about LaunchAgent self-heal when the app holds a port (it does no port probing today), nor confirmed it follows the STT agents to TCP.
- Not yet verified: whether the app's STT try-it flow fits the nemotron backend's transcript semantics (Phase 4 E2E checks it); the restart window N and `helloTimeout` (Phase 1 measures them).

## Issues & Solutions

(none yet)

## Final Results
