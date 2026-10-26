# Loopback listeners without a token

Status: **decided, not done** (2026-10-24). Every service the app runs listens
on `127.0.0.1` with no bearer token. This note records what a token would take,
so turning one on stays an explicit decision rather than a review finding that
keeps coming back.

## What is exposed today

- TTS (`tts_server serve --supervised --host 127.0.0.1 --port P`), STT
  (`python -m stt_server serve --supervised`, started without an auth token) and
  Apple Speech (`STTWebSocketServer`, in-process) all accept any local connection.
- Requests carrying a browser `Origin` are refused, so a web page cannot reach
  them; any local process running as any user can. `stt_server` logs a
  warning about this on every start ("TCP listener is running without
  --auth-token").
- Exposure: a local process can synthesize or transcribe on the user's GPU and
  read what it sends back. There is no file or credential access through the
  wire protocol.

## What a token would take

The servers already support one: `tts_server` reads `PIPECAT_TTS_AUTH_TOKEN` /
`--auth-token-file`, `stt_server.server.serve(auth_token=...)` checks
`Authorization: Bearer`, and both Python clients (`TTSClient`,
`stt_server.client`, and the Pipecat adapters `LocalTTSService` /
`LocalWebSocketSTTService`) accept `auth_token=` or `TTS_WS_TOKEN`. The work is
everywhere else:

1. **Mint and store a token.** One per app install (or per service), written
   `0600` under `~/Library/Application Support/Pipecat Service Toolbar/`, or in
   the Keychain. It must survive app updates and be rotatable.
2. **Pass it to every server.** `serveArguments` gains `--auth-token-file` for
   TTS; the `stt_server serve` arguments gain that CLI's bearer-token option;
   `STTWebSocketServer` gains a header check (it has none).
3. **Send it from the app's own clients.** Try it (`TTSClient`, `STTClient`)
   adds the `Authorization` header.
4. **Every Pipecat consumer changes — the breaking part.** The detail page's
   copy-paste snippets (`ServiceInfo.environment`, `pipecatService`) gain the
   token, and every existing bot configured with only `host`/`port` (or
   `TTS_WS_HOST`/`TTS_WS_PORT`, `STT_WS_HOST`/`STT_WS_PORT`) starts failing the
   handshake with 401 until its owner adds the token. There is no way to
   accept old clients and still have the token mean anything.
5. **Docs and tests.** README/architecture, the end-to-end tests, the live tone
   test, and a migration note.

## Decision

Not now: the app is a single-user developer tool bound to loopback, and step 4
breaks every existing consumer for a threat (another local process) that
already has the user's files. Revisit if the app ever binds a non-loopback
interface, runs services for other users, or ships to non-developers; then do
all five steps in one release with a migration note, and consider an opt-in
"require a token" setting first so consumers can migrate before it becomes
the default.
