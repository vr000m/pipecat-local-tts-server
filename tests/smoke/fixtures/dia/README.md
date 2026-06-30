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
| `interview_interruption_newline.txt` | Interruption + resumption, **layout (b)**: identical text, but each turn on its own line | dia splits on `split_pattern='\n'`, so each turn is an **independent segment** — does S1's resumed line still sound continuous, or does the per-segment boundary make it disjoint? |

## The load-bearing comparison

`interview_interruption_inline.txt` and `interview_interruption_newline.txt` are the
**same dialogue in two layouts**. dia generates each `\n`-separated turn as a separate
segment, so prosodic state is not guaranteed to carry across the interruption in layout
(b). Listening to (a) vs (b) back-to-back is what tells us whether a client should keep a
turn newline-free when it wants dia to render it as one continuous utterance. Record the
result in the plan's Findings after the first real dia run.

## Notes

- Nonverbals (`(laughs)`) and backchannels are included because dia is known for them, but
  the live tag/nonverbal vocabulary is **unverified against `mlx-audio==0.4.4`** — confirm
  against the real model before treating any specific token as supported.
- These are pure dialogue payloads (no comments), so they can be piped straight to a client
  without anything extra being read aloud.
