# Synthesis profiling scripts

In-process latency/throughput profilers for the TTS backends. They drive the
`TTSBackend`/`TTSStream` protocol **directly** (no server, no UDS), so they never
collide with a running `tts_server` on the canonical socket.

## GPU isolation (Apple-Silicon MLX backends)

All MLX processes share **one** Metal device, and the server's process-wide
synthesis lock does **not** span processes. For a trustworthy reading, stop every
other MLX process first — the sibling `stt_server`, other `tts_server` instances,
any reconnect-test loop. Both scripts print other tts/stt/mlx processes they
detect; an idle process (0% CPU) contends negligibly, an active one inflates RTF.

## Scripts

### `rtf_benchmark.py` — backend-agnostic realtime-factor
Reports `audio_s / ttfb_s / wall_s / RTF` per phrase. **RTF = wall/audio**:
`< 1` = faster than realtime (live-viable), `> 1` = slower (live-unusable).

```sh
uv run --extra kokoro python scripts/profiling/rtf_benchmark.py --backend kokoro --voice af_heart
uv run --extra qwen3_tts python scripts/profiling/rtf_benchmark.py --backend qwen3_tts
uv run python scripts/profiling/rtf_benchmark.py --backend tone
```

Reusable for **Phase 5**: once `voxtral_tts` / `pocket_tts` land, run the same
command with `--backend voxtral_tts` to benchmark their response times and
compare against Kokoro. (Those are `streaming:true`, so also watch `ttfb_s` —
sub-segment streaming should drop time-to-first-byte well below `wall_s`.)

### `kokoro_generate_split.py` — acoustic vs vocoder split (Kokoro-specific)
Hooks mlx-audio 0.4.4 internals (`kokoro.Model.__call__`,
`istftnet.Decoder.__call__`) to attribute generate() wall time to the **acoustic
model** (ALBERT + ProsodyPredictor + TextEncoder) vs the **istftnet vocoder**.
Tells us whether the ~12x is a fixable inefficiency or the model's floor.
Version-pinned to mlx-audio 0.4.4; hooks no-op with a warning if symbols move.

```sh
uv run --extra kokoro python scripts/profiling/kokoro_generate_split.py --voice af_heart
```

## Findings (M4 Max, mlx-audio 0.4.4, Kokoro-82M-bf16, 2026-06-26)

**Root cause found and fixed: a server-side bridge bug, NOT Kokoro.**

The investigation chain (a good template for the Phase 5 backends):

1. `rtf_benchmark.py` → RTF ≈ **11.8–12.5×, flat** across cold/warm and 1/2/3-seg
   inputs; cost was ~100% generation, not model load. Independently matched by the
   gamealerts client (~11.7×).
2. Ruled out the usual suspects: **not** CPU fallback (`mx.default_device()` =
   `Device(gpu, 0)`), **not** slow bf16 (bf16 matmul == fp16), **not** our vocoder
   length-fix shim (a cheap slice). Resident stt/tts processes were at 0% CPU, so
   **not** GPU contention either.
3. `kokoro_generate_split.py` → the neural forward (acoustic + vocoder) was only
   **~0.1s** for 3.25s of audio (~0.03× RTF). The ~40s was spent **outside** the
   model entirely.
4. Raw `model.generate()` driven directly (no bridge) → **RTF 0.03×** (0.08s).
   So mlx-audio is fast; the ~40s was **100% in our bridge**.
5. Root cause: `_stream_util._audio_to_pcm` passed the raw `mx.array` into the
   stdlib `float_to_pcm16`, which **iterates element-by-element** → a device→host
   sync **per sample** (~78k syncs ≈ 40s; hence the flat, sample-proportional RTF).
   **Fix:** bulk-materialize with `.tolist()` (one transfer) before converting.
   Guarded by `tests/test_stream_util_audio_conversion.py`.

**After the fix:** RTF ≈ **0.03×** (33× faster than realtime), TTFB ~40ms with
per-segment streaming. **Kokoro is viable for live commentary.**

Lesson for Phase 5: any MLX backend that hands audio through the bridge must
return arrays we bulk-materialize — never iterate an `mx.array` in Python. Re-run
`rtf_benchmark.py --backend <name>` on each new backend to confirm RTF < 1.

## Baseline numbers — Kokoro (for Phase 5 comparison)

Recorded 2026-06-26 on M4 Max (16-core), mlx-audio 0.4.4, `mlx-community/Kokoro-82M-bf16`,
post throughput-fix. **Re-run the same commands against `voxtral_tts` / `pocket_tts`
once Phase 5 lands and compare against this table.**

| Metric | Kokoro (2026-06-26) | How to reproduce |
|---|---|---|
| Cold load + warmup (`start()`) | ~2.4 s | `rtf_benchmark.py --backend kokoro` |
| RTF, 1-sentence (3.25 s audio), warm | **0.03×** | `rtf_benchmark.py` |
| RTF, 2-sentence single-seg (5.58 s), warm | **0.03×** | `rtf_benchmark.py` |
| RTF, 3-seg newlines (6.62 s), warm | **0.03×** | `rtf_benchmark.py` |
| TTFB, 1-sentence (warm) | ~0.08 s | `rtf_benchmark.py` |
| TTFB, 3-seg (sub-segment streaming) | ~0.04 s | `rtf_benchmark.py` |
| Full single-segment synth, ~1700 chars (commit→done) | **~2.9 s** | cancel-latency harness, no-cancel ceiling |
| Client-visible cancel (`response.cancel`→`response.cancelled`) | **~1 ms** | cancel-latency harness; constant across cancels fired 0/0.5/1.0/2.0 s into synth |
| Multiconn 2×5 turns (incl. cold load), ~380 s of audio total | **~15 s wall** (PASS) | `tests/smoke/run_multiconn.sh --backend kokoro` |

Notes for the comparison:
- `voxtral_tts` / `pocket_tts` are `streaming:true`, so **TTFB** is the headline number to
  beat — sub-segment streaming should push it well below `wall_s`.
- Cancellation latency is two separate numbers: **client-visible cancel** (~1 ms here,
  decoupled from the worker) vs **Metal-lock/slot release** (waits for `generate()`'s yield
  boundary, bounded by `drain_timeout_seconds` ≈ the full single-segment synth time). A
  streaming backend that yields more often should cut the lock-release ceiling too.
- The original "≈ 51 s single-segment cancel" figure (dev plan, 2026-06-24) was a bridge-bug
  artifact and is superseded — do not compare against it.

## Phase 5 cross-backend comparison (M4 Max 16-core, 2026-06-27)

Like-for-like run: same prompt for all three, each on an **English female** voice
(`kokoro=af_heart`, `voxtral_tts=casual_female`, `pocket_tts=cosette`). Accent caveat:
only Kokoro's `af_` prefix is *specifically American female*; Voxtral encodes language —
not accent — in its voice preset (`casual_female` → `en`), and Pocket exposes no accent
selector (English-primary presets only). So the comparison is matched on **gender +
language**, the closest the three models allow.

### In-process (`rtf_benchmark.py`, model-only — bypasses server/UDS)

Pure model throughput. **RTF = wall/audio** (`<1` faster than realtime / live-viable).
Numbers below are a **pristine run** — all sibling MLX processes (operator kokoro
`tts_server`, nemotron `stt_server`) were stopped first (`launchctl bootout` + kill), so
the profiler reported `isolation: clean run`. A prior contended run showed Voxtral RTF
1.12→1.50 and a 22 s `start()`; isolating proved that was **contention on the tail**, not
the floor — pristine Voxtral still sits at RTF ~1.1–1.3 (so RTF > 1 is the model floor, a
real gap), while its load dropped to ~5 s (the 22 s was a cold/contended outlier).
Kokoro and Pocket were unchanged (idle siblings didn't affect them).

| Metric (in-process, pristine) | kokoro | voxtral_tts | pocket_tts |
|---|---|---|---|
| Cold load + warmup (`start()`) | 2.8 s | 4.9 s | **1.9 s** |
| TTFB, warm (1-sentence) | 0.08 s | 0.42 s | **0.02 s** |
| RTF, 1-sentence (warm) | **0.03** | 1.09–1.11 | 0.05 |
| RTF, 2-sentence (warm) | **0.02** | 1.10–1.17 | 0.05 |
| RTF, 3-seg (warm) | **0.03** | 1.20–1.29 | 0.05 |

Pocket's very first synth after load costs ~0.5 s wall / 0.31 s TTFB once, then settles to
0.02 s TTFB / RTF 0.05 — worth one warmup call at startup if first-utterance latency matters.

### Output loudness / onset (RMS over the synthesized WAV)

| | kokoro | voxtral_tts | pocket_tts |
|---|---|---|---|
| Full-clip RMS | 1182 | **947** | 1386 |
| Peak | −10.9 dBFS | −8.6 dBFS | −7.9 dBFS |
| First 0.25 s window (RMS / dB) | 1448 / −27 dB | **295 / −41 dB** | 998 / −30 dB |

Voxtral is ~2–3 dB quieter overall **and** ramps in from a soft onset (first 0.25 s at
−41 dB vs −27/−30 dB for the others). The onset window is ~295 RMS (not zero) → a model
**prosody ramp, not a dropped frame**. Net effect: a leading word (e.g. a self-ID prefix)
can be hard to hear. See gaps below.

### Gaps to optimize (ranked)

1. **Voxtral RTF > 1 (≈1.1–1.3, pristine).** The headline perf gap — sustained throughput is
   *slower than realtime* even with zero GPU contention (confirmed pristine in-process AND on
   the wire at 1.55), so long-form playback can underrun/stutter. This is the **model floor**,
   not interference. It streams, so first audio is prompt (0.42 s TTFB) and short utterances are
   fine; sustained live narration is the risk. Levers: a smaller/more-quantized Voxtral
   checkpoint, or scope it to short turns.
2. **Voxtral output level** (~2–3 dB low + soft −41 dB onset) — a per-backend peak/RMS
   normalization step would even the three out for like-for-like A/B and stop quiet leading words.
3. **Wire vs in-process TTFB overhead:** Kokoro 0.13 s wire vs 0.08 s in-process (~50 ms
   server+UDS+base64); Pocket 0.025 vs 0.02 (negligible). Overhead is small and not a priority.

### Daily-driver recommendation

For a live/streaming default, **pocket_tts** and **kokoro** are both strong; Voxtral is the
odd one out (RTF > 1).

- **pocket_tts** — best fit for *streaming* use: 1.9 s load, 0.02 s TTFB, RTF 0.05, and it
  genuinely streams (`streaming:true`, deltas dribble). 8 English-primary voices. CC-BY-4.0
  (commercial OK). One-time first-utterance warmup (~0.5 s) is the only wrinkle.
- **kokoro** — best *raw throughput* (RTF 0.02–0.03 ≈ 37× realtime) and the widest voice set
  (54, true `af_` American-female presets) + multilingual, but `streaming:false`: it
  buffer-then-flushes, so for very long single commits time-to-first-audio is gated by full
  synthesis (still ~0.13 s here; grows with length). Apache-2.0 (commercial-safe; the
  repo's default backend).
- Pick **pocket** if low, *incremental* first-audio latency under streaming is the priority;
  pick **kokoro** if voice variety / languages / non-streaming batch throughput matter more.
  Both clear the realtime bar with large margin; Voxtral does not.

## dia vs siblings — normalized single-paragraph comparison (M4 Max 16-core, 2026-07-01)

Added when `dia` landed. Unlike the 2026-06-27 per-sentence tables above, this run feeds **one
identical ~485-char paragraph** (single utterance, no newlines) to all four backends, so audio
lengths land in the same ballpark (~26–30 s) and absolute TTFB/wall become directly comparable —
not just RTF (which is already length-normalized as `wall/audio`). `dia` gets a leading `[S1]` tag
(its only input difference); the others get the bare text. `--warm 2` (3 runs/phrase), warm-stable
values shown. **Caveat:** this was a *contended-but-idle* run — a pocket `tts_server`, a nemotron
`stt_server`, and a second `dia` server were resident at 0% CPU; memory pressure inflated dia's
`start()` to 9–27 s (vs ~9 s isolated). Treat as directional, not pristine.

| Metric (in-process, same 485-char text) | kokoro | pocket_tts | voxtral_tts | dia |
|---|---|---|---|---|
| rate | 24 kHz | 24 kHz | 24 kHz | **44.1 kHz** |
| Cold load + warmup (`start()`) | 2.7 s | **2.1 s** | 4.8 s | 9–27 s |
| audio produced (same text) | 27.9 s | 26.1 s | 26.6 s | 29.7 s |
| TTFB (commit → first audio) | 0.64 s | **0.02 s** | 0.44 s | **~55 s** |
| wall to full render | **0.65 s** | 1.31 s | ~30 s | ~55 s |
| RTF (wall / audio) | **0.02** | 0.05 | 1.07–1.21 | 1.82–1.89 |

To render ~28 s of speech: kokoro **0.65 s**, pocket **1.3 s**, voxtral **~30 s**, dia **~55 s**
(dia ≈85× slower than kokoro, ≈42× slower than pocket). First-audio latency is sub-second for the
three siblings and **~55 s for dia** (non-streaming single segment → you wait for the whole
render). kokoro's TTFB reads 0.64 s here — not the ~0.08 s of the short-sentence table — because
`streaming:false` + a longer single segment means it renders the full ~28 s clip before flushing,
so TTFB ≈ wall on long single commits; the two only split for the streaming backends.

### dia per-phrase (short prompts, `[S1]`-tagged, 2026-07-01)

| Phrase | audio_s | TTFB | wall_s | RTF |
|---|---|---|---|---|
| 1-sentence (~50 chars) | 29.98 | ~52 s | ~53 s | 1.74–1.80 |
| 2-sentence, 1 seg (~90 chars) | 28.81 | ~52 s | ~53 s | 1.81–1.88 |
| 3-seg, newlines (~140 chars) | 95.22 | ~71 s | ~190 s | 1.97–2.04 |

**~30 s single-segment output ceiling (the load-bearing dia finding).** Every single-segment
`generate()` produced ~30 s of audio *regardless of input length* — a 50-char one-liner and a
485-char paragraph both landed at ~30 s. This is the ~3072-token `max_tokens` default
(≈30 s @ 44.1 kHz): short text is padded toward it, and text longer than ~485 chars in one segment
is truncated at it. Splitting on `\n` resets the budget per segment — hence the 3-newline row makes
~95 s (3 × ~30 s) and its TTFB (~71 s) sits below its total (~190 s, confirming per-segment
streaming). A client that needs the full text spoken must chunk into `\n` segments under ~30 s each.

**Recommendation:** dia is a *dialogue-rendering* backend (multi-speaker, offline), not a
low-latency single-voice engine. For short, single-voice, latency-sensitive output (e.g. game
alerts), **kokoro or pocket_tts** win by ≈40–85× on throughput and ≈100× on first-audio latency;
dia's ~55 s TTFB and 30 s-per-segment ceiling make it unsuitable there.

Reproduce: siblings via `rtf_benchmark.py --backend <name>`. dia needs `[S1]`-tagged input (the
committed `PHRASES` are untagged), so both dia tables used a one-off wrapper feeding tagged text
through the same `_synth_once` harness.

## qwen3_tts per-phrase profile (M4 Max 16-core, 2026-07-03)

Added when `qwen3_tts` landed. Standard `rtf_benchmark.py` phrase set against
`mlx-community/Qwen3-TTS-12Hz-0.6B-CustomVoice-bf16` (24 kHz, default voice `ryan`,
`streaming:true` at the backend's `streaming_interval=0.4`). Pristine run, `--warm 2`
(warm1st + 3 warm repeats); values were flat across all warm runs.
Cold load + warmup (`start()`): **3.4 s**.

| Phrase | audio_s | TTFB | wall_s | RTF |
|---|---|---|---|---|
| 1-sentence (~50 chars) | 5.04 | 0.12 s | 1.39–1.40 s | 0.28 |
| 2-sentence, 1 seg (~90 chars) | 7.52 | 0.12 s | 2.06–2.07 s | 0.27–0.28 |
| 3-seg, newlines (~140 chars) | 8.08 | 0.12 s | 2.22 s | 0.27 |

Reading the table:
- **RTF ≈ 0.27 (~3.7× realtime), TTFB 0.12 s, both flat with input length** — comfortably
  live-viable. Slots between pocket (0.05) and voxtral (>1) on throughput; TTFB sits at the
  streaming-interval floor, well below `wall_s` (genuinely incremental).
- **Whole commit = one generation on CustomVoice.** `generate_custom_voice()` has no
  `split_pattern`, so `\n` does **not** split segments — visible above: the 3-seg phrase
  behaves exactly like the single-segment rows (same TTFB, same RTF), unlike dia's
  per-`\n`-segment budget.
- **Peak memory is gate-sourced, not profiler-sourced.** The bridge strips mlx-audio's
  `GenerationResult`, so `rtf_benchmark.py` cannot see peak memory. From the Phase-0 gate
  (`tests/smoke/qwen3_phase0_gate.py`, 2026-07-03): **3.08–3.10 GB** at
  `streaming_interval=0.4` (the backend's operating point); 4.08–4.32 GB at interval 2.0
  (larger decode chunks cost more).
- **Concurrency caveat:** `supports_tts_batch(stream=True) == False` — mlx-audio's batching
  path does not apply when streaming, so multi-connection behavior is serialized
  per-generation like the other streaming backends; do not extrapolate from upstream batch
  throughput claims.
- **Upstream discrepancy:** the upstream README claims RTF 1.67x, TTFB ~85 ms, ~3.9 GB. Our
  end-to-end numbers are RTF **0.27** and TTFB **0.12 s** at the 0.4 s streaming interval —
  the upstream TTFB is tokens-level (first token, not first audio) and its RTF/memory were
  measured under different conditions; compare against this table, not the model card.

Reproduce: `uv run --extra qwen3_tts python scripts/profiling/rtf_benchmark.py --backend qwen3_tts`.

### Same-day cross-backend re-run (2026-07-03, identical phrase set)

To make the qwen3 comparison strictly like-for-like (the sections above cite 2026-06-27
numbers), all five backends were re-benchmarked back-to-back on 2026-07-03 with the unchanged
`PHRASES` set (`rtf_benchmark.py` untouched since 2026-06-26, commit `1999c2a`). Warm-run
values (`warm1`; ranges span warm1–warm3):

| backend | load+warmup | TTFB warm (1-sent) | RTF 1-sent | RTF 2-sent | RTF 3-seg |
|---|---|---|---|---|---|
| kokoro | 2.3 s | 0.08 s | 0.02 | 0.02 | 0.03 |
| voxtral_tts | 5.4 s | 0.37–0.38 s | 1.09 | 1.08–1.13 | 1.16–1.17 |
| pocket_tts | 1.6 s | 0.02 s | 0.05 | 0.05 | 0.05 |
| dia | — | (segment-level; see dia plan) | — | — | 2.16–2.40 |
| **qwen3_tts** | 2.5 s | **0.12 s** | **0.27** | **0.28** | **0.28** |

Every historical number reproduced within noise (kokoro 0.02–0.03 vs 0.03; voxtral 1.08–1.17
vs 1.09–1.29; pocket 0.05 vs 0.05; dia RTF ~2.2–2.4 vs ~2.0 — dia renders the untagged 3-seg
phrase as a 65 s dialogue, its known behavior on untagged text, so its row is not
phrase-comparable and lives in the dia plan's Findings). The 2026-06-27 sections above remain
valid as-is. Standings unchanged: kokoro fastest raw throughput, pocket fastest TTFB,
**qwen3_tts is the fastest *quality-voice* streamer** (RTF 0.27 ≈ 3.7× realtime, TTFB 0.12 s)
and the only streaming backend with voxtral-class voices at sub-realtime RTF.

Raw output: session scratchpad `rtf-cross-backend-20260703.txt` (regenerate with the loop
below):

```sh
for b in kokoro voxtral_tts pocket_tts dia qwen3_tts; do
  uv run --extra "$b" python scripts/profiling/rtf_benchmark.py --backend "$b"
done
```

## Phase 5 wire-level smoke + concurrency (M4 Max 16-core, 2026-06-27)

Measured over the **wire path** — a real `tts_server` on a Unix socket, driven by
`tests/smoke/latency_smoke.py` (TTFB/RTF/cadence), `examples/reference_client.py`
(WAV round-trip), and `tests/smoke/multiconn_smoke.py` (concurrency). These numbers
therefore **include** server scheduling + UDS + base64 framing overhead, so they read
slightly higher than the in-process `rtf_benchmark.py` baselines above (e.g. Kokoro
wire TTFB 0.13 s vs in-process ~0.08 s). Compare wire-to-wire, not against the
in-process table. Same prompt for all three (~5.2–6.1 s of audio):
*"The quick brown fox jumps over the lazy dog. Pack my box with five dozen liquor jugs."*

| Metric (wire path) | kokoro | voxtral_tts | pocket_tts |
|---|---|---|---|
| `streaming` capability | `False` | `True` | `True` |
| Model load → listening | 2.6 s | 3.6 s | 2.1 s |
| TTFB (commit → first delta) | 0.129 s | 0.543 s | **0.025 s** |
| RTF (wall / audio) | **0.027** | 1.547 | 0.061 |
| Delta cadence | buffer-then-flush (span 22 ms) | steady dribble (span 7.5 s) | streamed (span 0.29 s) |
| Voice count | 54 | 20 | 8 |
| Concurrency 2×2–3 turns | PASS | PASS | PASS |
| Per-connection in-flight cap (BUSY/429, `retry_after_ms=250`) | PASS | PASS | PASS |

Reading the table:
- **kokoro** is `streaming:false` — it synthesizes the whole utterance, then flushes all
  deltas in one ~22 ms burst. `latency_smoke.py` reports this as a cadence FAIL; that is the
  **expected non-streaming signature, not a regression**. Raw throughput is still the best of
  the three (RTF 0.027 ≈ 37× realtime) and TTFB stays low because the clip finishes before
  first delivery.
- **pocket_tts** is the best fit for live/streaming use: 25 ms TTFB at 16× realtime while still
  genuinely streaming (deltas spread over 0.29 s, not a single flush).
- **voxtral_tts** RTF 1.55 on this longer phrase is prefill-dominated (matches the dev-plan
  Phase 5a finding); it streams genuinely (span 7.5 s) with a prompt 0.54 s first byte.

### Concurrency stress (escalating matrix, single server per backend)

| Cell (conns × turns) | tone | pocket_tts |
|---|---|---|
| 2×2 … 6×3 (sentences ≤ ~1000 chars) | PASS | **PASS** |
| 4×5, 8×5, 12×5 | **PASS** | — |
| 6×5 (sentences grow to 1701+ chars) | — | **conns closed** (`ConnectionClosedError`) |

- **tone** (non-streaming, backend-agnostic scheduler) scaled cleanly to **12 conns × 5 turns** —
  the concurrency/backpressure machinery itself is healthy.
- **pocket_tts** held clean through **6 conns × 3 turns**, then at **6 × 5** (where the driver
  grows each sentence to 1701+ chars) the server began closing connections. Server-side log
  showed **no errors or tracebacks** → this is the **R4 send-queue high-water close**: a fast
  *streaming* backend floods deltas faster than the smoke driver drains them, so the server
  sheds the connection by design. Documented in dev-plan Phase 5b as a smoke-driver limitation,
  not a backend bug; confirmed here and bounded (threshold sits between 6×3 and 6×5 / ~1000–1700
  chars per commit under this driver's send pattern). A real client that reads continuously
  while sending does not hit this.

Reproduce: `tests/smoke/run_smoke.sh --backend <name> --play`, then
`tests/smoke/run_multiconn.sh --backend <name> --connections N --turns M`.

## fish_tts per-phrase profile (M4 Max 16-core, 2026-08-06)

Added when `fish_tts` landed. Standard `rtf_benchmark.py` phrase set against
`mlx-community/fish-audio-s2-pro` (44.1 kHz, `streaming:false` — segment-level,
`dia`'s direct structural comparator: both non-streaming, one `GenerationResult`
per commit, TTFB == wall-time). **Contended-but-idle run** (a nemotron
`stt_server` and a `pocket_tts` `tts_server` were resident, matching the caveat
on dia's cross-backend table above) — treat as directional, not pristine.
Cold load + warmup (`start()`): **3.3 s**.

| Phrase | audio_s | TTFB (=wall_s) | RTF |
|---|---|---|---|
| 1-sentence (~50 chars) | 3.39 | 6.88–7.54 s | 2.03–2.23 |
| 2-sentence, 1 seg (~90 chars) | 5.99 | 12.42–12.55 s | 2.07–2.10 |
| 3-seg, newlines (~140 chars) | 6.46 | 12.88–13.56 s | 2.00–2.10 |

(warm1st excluded as a compile/cache outlier per convention; warm1–warm3 shown,
flat within noise.)

Reading the table:
- **`streaming:false`, TTFB == wall_s** — same non-streaming signature as dia:
  no audio until the whole segment finishes.
- **RTF ≈ 2.0–2.2 (slower than realtime)** — in the same family as dia's
  RTF≈2.0, both well above 1, both `streaming:false` non-streaming latency
  outliers relative to the sub-1 streaming backends (kokoro/pocket/qwen3) and
  even relative to voxtral (~1.1–1.3).
- **`\n`-segmentation does not obviously multiply cost the way dia's does**:
  the 3-seg phrase's wall_s (~13 s) tracks its audio_s (6.46 s) at the same
  RTF as the 1- and 2-sentence rows, unlike dia where each `\n` segment resets
  a ~30 s output-ceiling budget. This profiler run used the committed,
  untagged `PHRASES` set (no `<|speaker:N|>` tags), so it never exercises
  fish's multi-batch/cross-batch-coupling path (Phase-0 gate Q1) — this table
  is single-batch-per-phrase throughout.
- **Peak memory is gate-sourced, not profiler-sourced** (bridge strips
  mlx-audio's `GenerationResult`, same qwen3/dia precedent). From the Phase-0
  gate (`tests/smoke/fish_phase0_gate.py`, 2026-08-06): **14.27 GB** (short
  utterance, 1 batch) / **18.28 GB** (~15s-equivalent long utterance, 1
  batch) — notably higher than qwen3's 3.08–4.32 GB, worth calling out in
  README capacity/hardware guidance.
- **Concurrency caveat**: `streaming:false`, one `GenerationResult` per
  commit — no sub-segment streaming, so multi-connection behavior serializes
  per-generation like dia, not like the `streaming:true` backends.

**Discrepancy vs. the Phase-0 gate (Q2) — flagged, not resolved:**
Gate: short utterance TTFB=5.35 s/RTF=1.62 (3.30 s audio, 1 batch); long
utterance TTFB=29.49 s/RTF=1.72 (17.14 s audio, 1 batch). Profiler: RTF
2.0–2.2 across all three phrases — noticeably higher (worse) than the gate's
1.6–1.7, on much shorter audio (3.4–6.5 s vs. the gate's 3.3/17.1 s), so this
is not simply "expected variance from different phrase sets": the direction
(profiler slower) and magnitude (~25–35% higher RTF) line up with a
documented, load-bearing asymmetry between the two harnesses rather than
noise. Two candidate causes, not distinguished by this run:
1. **Compile-mode divergence (the more likely primary cause)**: the Phase-0
   gate calls `generate()` directly with `mx.compile` active by default;
   production `FishBackend.start()` (which the profiler drives, since it
   exercises the real backend) calls `mx.disable_compile()` per Phase 1's
   proactive `CompilerCache`-segfault mitigation. This eager-vs-compiled
   asymmetry is exactly the divergence flagged in the plan's Context
   ("Gate/production measurement divergence" bullet) as untested — this is
   the first measurement that surfaces a concrete, consistent delta
   attributable to it, though it was not isolated (no gate-with-
   `mx.disable_compile()` A/B run exists yet to confirm the attribution).
2. **GPU contention**: this profiler run had a resident idle `stt_server` +
   `pocket_tts` `tts_server` (see caveat above); the gate run's process state
   at measurement time is not recorded in the plan's Findings, so a
   contention-based explanation cannot be ruled out either.

Both numbers agree fish is well outside the live-viable RTF<1 band regardless
of which is closer to fish's true floor — this does not change the
backend's non-streaming, batch-synthesis usage profile.

**Upstream model-card comparison: not available.** Phase 0 Q6 (the plan's
sole designated source for upstream `fishaudio/s2-pro` performance/scale
claims) fetched and recorded license text and the 38-language list from both
`mlx-community/fish-audio-s2-pro` and `fishaudio/s2-pro`, but captured no
training-hours, RTF, or latency figures from the model card — the plan's
Findings explicitly note "No training-hours figure was visible in the first
40 lines fetched." There is nothing to compare the measured numbers above
against upstream on performance, unlike qwen3 (which had an upstream RTF/TTFB
claim to contrast against).

Reproduce: `uv run --extra fish_tts python scripts/profiling/rtf_benchmark.py --backend fish_tts`.
