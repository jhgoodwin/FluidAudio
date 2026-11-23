# Speed patches from FluidInference

Tracks the review of performance changes in
[FluidInference/FluidAudio](https://github.com/FluidInference/FluidAudio) that are missing from this fork's
parent, [altic-dev/FluidAudio](https://github.com/altic-dev/FluidAudio). The goal: make the FluidVoice setup faster
without changing its transcripts.

## Context

- **Fork chain:** `jhgoodwin/FluidAudio` → `altic-dev/FluidAudio` → `FluidInference/FluidAudio`. altic split from
  FluidInference on 2026-03-28. No FluidInference fix since then has been copied into altic.
- **Why stay on altic:** FluidVoice needs altic-only features: the Fluid Parakeet Mini/Pico/Pro models,
  `loadLocalOnly`, pronunciation learning and Granite. FluidInference has none of them.
- **Porting:** FluidInference reorganised the code after the split, so patches must be ported by hand. They don't
  cherry-pick.
- **Target setup:** FluidVoice with the Fluid Speech Pro model (`fluidParakeetPro`, int8 encoder),
  `AsrManager(config: ASRConfig.default)`, preprocessor on `.cpuAndGPU`. The final dictation call is
  `manager.transcribe(samples, source: .microphone)`. Judge patches against every feature that may be turned on
  later, not only current settings: custom-dictionary vocabulary boosting (CTC110m), pronunciation profiles and
  FluidMeet. FluidMeet transcribes with the selected speech model and uses Nemotron's Sortformer only for speaker
  labels, plus Parakeet EOU for live captions.
- **Benchmark machine:** Apple M1 Pro, 16 GiB RAM, macOS 27.2.1.

## Branches

All local and not pushed. FluidVoice still pins `3857a6d`.

| Branch | Commits |
|---|---|
| `fix/preprocessor-compute-units` | `3857a6d` preprocessor compute-unit option (FluidVoice uses it) |
| `perf/parallel-chunks` (ships) | `06d14c2` `parallelChunkConcurrency` (#507 port) |
| | `afa757e`, `3447859` benchmark harness, without the GPU pass |
| | `f744861` skip CTC inference without candidates (#993 port), harness boosting mode |
| | `56c3ff4` zero the CTC spotter's audio padding (#1003 fix) |
| `devin/encoder-compute-units` (archive) | `64e5366`, `1d75db1` encoder compute-unit option (#659 port), the original #507 commits and harness |

`perf/parallel-chunks` is built on `3857a6d` without the encoder option. Cherry-picking #507 conflicted only in
`AsrModelsTests.swift`: the GPU-encoder test was dropped because it needs the `encoderComputeUnits` parameter.

## Status

| PR | Change | Status | Evidence |
|---|---|---|---|
| [#507](https://github.com/FluidInference/FluidAudio/pull/507) | Parallel long-form chunk transcription | **Done** (opt-in; FluidVoice to use 2) | Benchmarked |
| [#659](https://github.com/FluidInference/FluidAudio/pull/659) | Encoder on GPU instead of Neural Engine | **Rejected** | Benchmarked |
| [#1168](https://github.com/FluidInference/FluidAudio/pull/1168) | Back the joint's top-K outputs | Rejected: doesn't apply | Code: Pro/v3/Mini/Pico joints have no top-K outputs |
| [#941](https://github.com/FluidInference/FluidAudio/pull/941) | Bulk-fill MLMultiArray resets and copies | Rejected: already covered | Code: altic has its own version |
| [#1165](https://github.com/FluidInference/FluidAudio/pull/1165) | Reuse AVAudioConverter across calls | Rejected: not on live path | Code: FluidVoice's live audio skips it; saves microseconds |
| [#804](https://github.com/FluidInference/FluidAudio/pull/804) | General speedups | Rejected: doesn't apply | Code: targets Paraformer/SenseVoiceSmall |
| [#993](https://github.com/FluidInference/FluidAudio/pull/993) | Skip unnecessary CTC vocabulary inference | **Done** | Benchmarked with boosting on |
| [#1034](https://github.com/FluidInference/FluidAudio/pull/1034) | Less CTC keyword-scoring memory and CPU | Rejected: doesn't apply | Code: optimises upstream's blank-expanded DP; altic has the older token DP |
| [#1039](https://github.com/FluidInference/FluidAudio/pull/1039) | Remove boxed scalar reads in CTC probabilities | Rejected: already covered | Code: altic's `copyFloatValues` already bulk-reads logits |
| [#1173](https://github.com/FluidInference/FluidAudio/pull/1173) | Bulk-copy CTC spotter audio | Rejected: already covered | Code: altic's `prepareAudioArray` already bulk-copies |
| [#1003](https://github.com/FluidInference/FluidAudio/pull/1003) | Zero CTC spotter audio padding (bug fix) | **Done** | Found while reviewing #1173; real-model test |

The CTC patches only matter when custom-vocabulary boosting runs: FluidVoice's "vocabulary boosting" toggle in the
custom dictionary view (off by default), which loads CTC110m for the final dictation manager. They were first
rejected because the toggle is off on the benchmark Mac, then reopened because it may be turned on later.

Altic's bulk audio copy assumed `MLMultiArray(shape:dataType:)` zero-fills. It doesn't, and the CTC mel model reads
the whole fixed window, so the tail after a short clip could hold garbage. Upstream traced run-to-run CTC
differences on short clips to this (#991). The fix zeroes the buffer before copying.

## Results

All runs use the 120 FluidVoice dictation recordings (5,647 s of audio; 98 clips longer than 15 s) and alternate
settings twice. Raw output is in `Benchmarks/parakeet-bench/results/` (gitignored, local only).

### #507 parallel chunks: done

| Chunks in parallel | Total | Speed | Median / p90 per clip | Peak memory |
|---|---|---|---|---|
| 1 (current) | 42.4–45.0 s | 126–133× | 248–261 / 633–646 ms | ~456 MB |
| 2 | 27.6–27.9 s | 202–205× | 167–174 / 365–387 ms | ~641–651 MB |
| 4 | 26.3–26.7 s | 212–215× | 167–175 / 341–347 ms | ~750 MB |

- Transcripts matched exactly for 1, 2 and 4 chunks on all 120 clips.
- Memory re-run: one pass per process under `/usr/bin/time -l`, order 1, 2, 4, 1, 2, 4. Peak memory footprint was
  457–464 MB for 1, 641–651 MB for 2 and 768–775 MB for 4. Times were 41.3–47.3 s, 26.9–27.4 s and 25.5–25.7 s.
  Transcripts again matched serial on all 120 clips. Output is in `results/mem-run{1,2}-{ane,p2,p4}/`.
- Recommendation: 2. It gives ~95% of the 4-chunk speedup for ~60% of the extra memory (+~185 MB vs +~310 MB over
  serial).
- Clips of 15 s or less are a single chunk, so they're unchanged at ~93 ms. Clips over 15 s went from ~312 ms to
  ~190 ms median.
- API: `ASRConfig(parallelChunkConcurrency:)`, default 1, clamped to at least 1. Workers come from
  `AsrManager.makeChunkWorker()` and share the loaded models. Results are merged in chunk order through the existing
  merge.
- The parallel path is skipped while pronunciation customization is active. That combination wasn't benchmarked.
- Tests: `testParallelChunkConcurrencyDefaultsToSerialAndClampsToOne` and the real-model
  `testFluidParakeetParallelChunksMatchSerialTranscript` in `AsrModelsTests`, plus the 48 existing
  `ChunkProcessor` tests, all pass. The real-model test needs `FLUIDAUDIO_PRO_MODEL_DIR` and
  `FLUIDAUDIO_PARAKEET_TEST_AUDIO` (a recording longer than one model window).

### #659 GPU encoder: rejected

| Encoder | Total | Speed | Median per clip |
|---|---|---|---|
| Neural Engine (default) | 47.8–48.0 s | 118× | 270–288 ms |
| GPU | 90.6–92.4 s | 61–62× | 547–556 ms |

- 7 of 120 transcripts changed on the GPU. Two Neural Engine runs matched each other exactly.
- Upstream reported +8% for Parakeet v3, but it doesn't hold for Pro on an M1 Pro. The fastest placement depends on
  the model/chip pair, so re-test after changing either one. The cause wasn't profiled.
- The port adds `encoderComputeUnits` to model loading and `--encoder-compute-units <ane|gpu|cpu|all>` to the CLI.
  It isn't shipped, to avoid maintaining setup options for a rejected speedup. It stays on
  `devin/encoder-compute-units` for re-testing on other chips.

### Related finding: altic's existing frontend pipelining

altic can already overlap preprocessor, encoder and decoder work across chunks. It turns this on automatically
only with ≥ 24 GiB physical and ≥ 8 GiB available memory, so it's off on the 16 GiB benchmark Mac. Forcing it with
`FLUIDAUDIO_FRONTEND_PIPELINE_MODE=pipeline` vs `serial` gave 31.9 s vs 39.0–39.3 s (~1.23×), with identical
transcripts. This was measured before the #507 port. When `parallelChunkConcurrency > 1`, the parallel path runs
instead of pipelining.

Head to head, with pipelining forced on, one pass per process in the order pipeline, 2, pipeline, 2:

| Mode | Total | Speed | Median / p90 per clip | Peak memory |
|---|---|---|---|---|
| Pipeline, 1 chunk | 36.6–37.5 s | 151–154× | 224–231 / 500–518 ms | ~483 MB |
| 2 chunks in parallel | 29.1–30.0 s | 188–194× | 178–182 / 402–410 ms | ~635–640 MB |

- Transcripts matched serial on all 120 clips in both modes.
- 2 chunks is ~1.25× faster than pipelining, so setting it is also a win on ≥ 24 GiB Macs, where pipelining would
  otherwise turn on by itself. Output is in `results/pipe-run{1,2}-{ane,p2}/`.

### #993 CTC candidate preflight: done

`VocabularyRescorer.hasCTCRescoringCandidates` runs the rescorer's own candidate discovery and text guards
without log-probabilities and stops at the first candidate that would be scored. `AsrManager` and
`SlidingWindowAsrManager` skip CTC inference when it returns false. Upstream only added the API, with no internal
caller, and returns true for small vocabularies because of its "spotter rescue". Altic has no spotter rescue, so
here the check is exact.

Boosting on, CTC110m, one pass per process, order unported, ported, unported, ported. Vocabularies:
`vocab/tech-20.json` (20 terms from the recordings and projects) and FluidVoice's
`parakeet_custom_vocabulary.json` (1 term, `FluidVoice`). Without boosting the same set takes 41–47 s.

| Vocabulary | Unported | Ported | Median per clip, unported → ported |
|---|---|---|---|
| 20 terms | 50.0–55.9 s | 47.9–48.1 s | 299–328 → 277 ms |
| 1 term | 54.1–54.5 s | 45.0–49.5 s | 316–318 → 261–286 ms |

- Transcripts and applied terms matched on all 120 clips. Boosting changed 11 clips with 20 terms (mostly "Xcode")
  and 1 clip with 1 term, identically before and after.
- Test: `VocabularyCandidateDiscoveryTests` (real CTC110m and recording). Expected discovery for 12 cases, and every
  "no candidate" case is checked to leave `ctcTokenRescore` unchanged with real log-probabilities.
- Only the default term-centric path is exercised. The BK-tree path is gated by a compile-time constant, which is off.

### Pronunciation customization and #507: no benchmark needed

FluidVoice turns pronunciation customization on for the final pass only when matching profiles exist
(`FluidAudioProvider`, `setPronunciationCustomizationEnabled(!profiles.isEmpty)`). With profiles, clips over
240,000 samples (15 s) go through `ParakeetIncrementalSession` in 15 s blocks, so they never reach the chunked
path. Clips of 15 s or less are a single chunk. Either way, #507 can't speed up a dictation that has profiles, so
there's nothing to benchmark. This Mac has no `pronunciation-dictionary-v1.json`, so its dictation takes the
parallel path.

### FluidMeet candidates: deferred

Upstream commits since the split that touch Sortformer, EOU streaming or the offline diarizer:

| PR | Change | Kind |
|---|---|---|
| #680 | Opt-in fused EOU decoder+joint (+7–9% RTFx upstream) | Speed; live captions |
| #728 | Rebuilt Sortformer v3 models, precision/compute-unit control | Crash fix + speed option; new model files |
| #807 | Sortformer streaming mel emitted phantom frames; timestamps drift late | Correctness |
| #1091 | Sortformer predicts every frame of complete audio | Correctness |
| #480, #789 | Offline diarizer embedding skip, cacheable segmentation | Speed; `SpeakerDiarizationService` |

None was ported. There are no meeting recordings to benchmark against (`FluidVoice/Meetings` is empty), and the
adoption rule needs real-recording parity. #807 and #1091 look more important than the speedups.

## Open items

- Fast-forward `main` to `perf/parallel-chunks`, then repoint FluidVoice's pin and set
  `parallelChunkConcurrency: 2`.
- FluidMeet candidates, once there are meeting recordings to benchmark.

## How to benchmark a patch

The harness is `Benchmarks/parakeet-bench`. It depends on the repository root (`../..`), so it builds whatever is
checked out.

```bash
cd Benchmarks/parakeet-bench
swift build -c release
.build/release/parakeet-bench \
  "$HOME/Library/Application Support/FluidAudio/Models/fluid-parakeet-pro-coreml" \
  "$HOME/Library/Application Support/FluidVoice/DictationAudioHistory" \
  results/<run-name> ane,p4,ane,p4
./compare.py results/<run-name>/pass0-ane.json results/<run-name>/pass*.json
```

- **Passes:** `ane` = default placement, serial chunks. `pN` = N parallel chunks.
- **Vocabulary boosting:** set `PARAKEET_BENCH_VOCAB` to a FluidVoice-format vocabulary JSON (for example
  `vocab/tech-20.json`). It downloads CTC110m on first use, and each clip records `ctcAppliedTerms`.
- **A/B across code changes:** copy `.build/release/parakeet-bench` aside before the change, then alternate the two
  binaries.
- **New options:** to test one, add a pass name in `Sources/parakeet-bench/main.swift`.
- **Output:** each pass writes per-clip timings and transcripts as JSON.
- **compare.py:** prints total time, speed, transcript differences against the first file, and median/p90
  latency split at 15 s.
- **Timing:** one pass over all 120 clips takes about 30–90 s.
- **Adoption rule:** zero transcript differences against `ane`, plus a consistent speedup across alternating runs.
