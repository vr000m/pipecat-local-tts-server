# dia dialogue smoke fixtures

`[S1]`/`[S2]` speaker-tagged transcripts fed to the `dia` backend by
`tests/smoke/dia_dialogue_smoke.py` (mlx-gated, dia-only, **listen-and-judge** — these
exist so a human can hear whether dia renders two distinct speakers and handles
interruption naturally; there is no automated perceptual assertion).

Per the dia plan's *Resolved design decisions*, speaker control is **purely in-text**:
these files are normal `text_format: plain` payloads the server forwards untouched, and
dia interprets the `[S1]`/`[S2]` tags itself. The server never parses them.

## Files

| File | Scenario | What to listen for |
|------|----------|--------------------|
| `podcast_turntaking.txt` | Two podcasters, clean turn-taking plus an inline one-word S2 backchannel (`Mm-hmm`) inside an S1 turn and a nonverbal (`(laughs)`) | Speaker identity stays consistent across turns; S1 ≠ S2; backchannel and laugh land naturally |
| `interview_interruption_inline.txt` | Interruption + resumption, **layout (a)**: single segment, no newlines, em-dashes mark the cut and resume | Does S1 resume the *same* sentence with continuous prosody after S2 cuts in? |
| `interview_interruption_newline.txt` | Interruption + resumption, **layout (b)**: identical text, but each turn on its own line | Both layouts ride in **one commit**, and Phase 0 verified dia is **autoregressive across `\n`-separated turns within a commit** (the turns are NOT independent) — so does the `\n`-separated layout's resumed line still sound as continuous as the inline one, or does the turn boundary subtly change the prosody? |

## The load-bearing comparison

`interview_interruption_inline.txt` and `interview_interruption_newline.txt` are the
**same dialogue in two layouts**, both committed in **one commit each**. The Phase 0 gate
(2026-06-30, recorded in the dia plan's Findings) **falsified** the earlier "independent
segments" premise: editing an earlier turn changed a later turn's audio, so dia carries
cross-segment state *within* a `generate()` call (it is stateless only *across* commits).
The comparison is therefore **in-context continuity inline vs `\n`-separated** — not
segment independence. Listening to (a) vs (b) back-to-back tells us whether the turn
layout (inline vs newline) affects continuity *within an already-coherent commit*, i.e.
whether a client should prefer one layout for the smoothest resumption. Record the result
in the plan's Findings after the first real dia run.

## Notes

- Nonverbals (`(laughs)`) and backchannels are included because dia is known for them, but
  the live tag/nonverbal vocabulary is **unverified against `mlx-audio==0.4.4`** — confirm
  against the real model before treating any specific token as supported.
- These are pure dialogue payloads (no comments), so they can be piped straight to a client
  without anything extra being read aloud.
