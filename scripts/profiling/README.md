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
