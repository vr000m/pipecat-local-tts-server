# Task: tts-server — extended `pocket_tts` voice catalog (beyond mlx-audio's 8)

**Status**: Backlog — note only, not started. Low urgency; gated upstream (see Options).
**Component**: tts-server (backends)
**Assigned to**: Varun Singh
**Priority**: Low (consumer has a working interim voice — see Consumer note)
**Branch**: TBD (own feature branch off `main` if/when picked up)
**Created**: 2026-06-28

## Objective

`pocket_tts` currently advertises only the **8 voices** that mlx-audio 0.4.4 wires into its
`PREDEFINED_VOICES` map. Kyutai's hosted Pocket TTS demo offers a much larger catalog (~24 voices,
including `Anna` and multilingual voices like Estelle/Giovanni/Lola). This plan records *why* our set
is smaller and what it would take to expose more, so the gap doesn't surprise consumers (e.g.
gamealerts) later.

This is a **note + future-feature** plan, not conduct-ready work. No prep ritual run yet.

## Findings (authoritative, 2026-06-28)

- Our backend serves exactly what mlx-audio exposes — it does **not** filter. Introspected
  `mlx_audio.tts.models.pocket_tts.utils.PREDEFINED_VOICES` directly:
  `count=8` → `['alba', 'azelma', 'cosette', 'eponine', 'fantine', 'javert', 'jean', 'marius']`.
  **`anna` is absent.** The running agent logs "serving 8 voices" with no fallback warning, so 8 is
  the package's real set (not our `_STATIC_VOICES` safety net in `tts_server/backends/pocket_tts.py`).
- The demo's extra voices exist as **voice-embedding safetensors** in the
  `kyutai/pocket-tts-without-voice-cloning` HF repo, but (per the backend docstring) that repo "holds
  only the voice-embedding safetensors, not a loadable config." mlx-audio only wired 8 of them into
  the selectable `PREDEFINED_VOICES` API we consume. The rest are files on disk, not selectable voices.
- Not a bug in our backend — a capability boundary of the `mlx-community/pocket-tts` port.

## Options (if/when more voices are needed)

1. **Upstream (cleanest):** mlx-audio expands `PREDEFINED_VOICES`. We'd pick it up for free on a
   version bump — `_discover_voices()` already reads the map dynamically with a static fallback.
2. **Load embeddings ourselves:** pull the extra embedding safetensors from
   `kyutai/pocket-tts-without-voice-cloning` and feed the chosen embedding into `generate()`.
   Mechanically this is close to the **`ref_audio` voice-embedding channel deliberately left unwired**
   (v1 decision #2 — no cloning), so it's a scoped backend-feature decision (config surface, voice
   discovery, validation), not a quick toggle.

## Consumer note

- **gamealerts** wanted `anna` (Kyutai demo voice). Since `pocket_tts` doesn't expose it, gamealerts
  uses **`azelma`** as the interim voice. No change required on either side; revisit only if the fuller
  catalog lands via Option 1 or 2.
- For the widest selectable voice set today, **kokoro** offers 54 voices.

## Out of scope

- Voice cloning from arbitrary reference audio (`ref_audio`) — still unwired per v1 decision #2; that
  is a separate decision from exposing the model's *predefined* embeddings.
