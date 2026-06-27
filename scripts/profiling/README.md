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
