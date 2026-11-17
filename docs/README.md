# Documentation

Start with the root [README](../README.md) for installation and a complete local
quickstart. The guides below are the canonical homes for detailed behaviour.

## Find your task

| I want to… | Start here |
|---|---|
| Generate my first WAV | [Quickstart](../README.md#quickstart) |
| Connect a Python application | [Packaged Python client](clients.md#write-a-wav-with-the-python-client) |
| Connect a Pipecat bot | [Reference adapter](clients.md#use-the-pipecat-adapter) |
| Choose a model and voice | [Backend comparison](backends.md#choose-a-backend) |
| Manage speech services from the menu bar | [Pipecat Service Toolbar](https://github.com/pipecat-ai/pipecat-service-toolbar/blob/main/README.md#quickstart) |
| Run a server at login | [Launchd lifecycle](operations.md#running-multiple-backends-with-launchd) |
| Diagnose a failed or slow request | [Troubleshooting](operations.md#troubleshooting) |
| Implement another client | [WebSocket protocol](protocol.md) |

## User guides

- [Client integration](clients.md) — Python WAV example, Pipecat setup,
  capabilities, authentication, retries, and cancellation.
- [Backends](backends.md) — model selection, licenses, capabilities, voices,
  languages, text controls, limits, and cancellation caveats.
- [Server operations](operations.md) — endpoints, environment variables,
  authentication, launchd, health checks, prefetch, and supervised mode.
- [WebSocket protocol](protocol.md) — wire messages, lifecycle, capabilities,
  backpressure, errors, and client requirements.
- [Pipecat Service Toolbar](https://github.com/pipecat-ai/pipecat-service-toolbar/blob/main/README.md) — native macOS menu bar app.

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
