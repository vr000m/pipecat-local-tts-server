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
