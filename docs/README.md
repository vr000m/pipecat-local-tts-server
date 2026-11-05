# Documentation

Start with the root [README](../README.md) for installation and a complete local
quickstart. The guides below are the canonical homes for detailed behavior.

## User guides

- [Backends](backends.md) — model selection, licenses, capabilities, voices,
  languages, text controls, limits, and cancellation caveats.
- [Server operations](operations.md) — endpoints, environment variables,
  authentication, launchd, health checks, prefetch, and supervised mode.
- [WebSocket protocol](protocol.md) — wire messages, lifecycle, capabilities,
  backpressure, errors, and client requirements.
- [Pipecat Service Toolbar](../macos/README.md) — native macOS menu bar app.

## Validation and performance

- [Live smoke tests](../tests/smoke/README.md) — backend, reconnect,
  multi-connection, language, and supervised-path checks.
- [Profiling](../scripts/profiling/README.md) — measured TTFB, RTF, memory, and
  cross-backend comparisons.
- [`supervised-contract.json`](supervised-contract.json) — machine-readable
  event and error-code contract shared with the macOS app.

## Development records

- [`dev_plans/`](dev_plans/) — historic plans and decision records. These explain
  why behavior exists; current usage belongs in the guides above.
- [`upstream/`](upstream/) — focused reports for upstream mlx-audio issues.
- [`rich/`](rich/) — generated HTML plan views and fragments.
