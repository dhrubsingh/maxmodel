# How MaxModel picks a model

MaxModel answers one question: *what is the smartest open model this Mac can run well?* It reads the hardware, ranks models on published benchmarks, keeps only those that fit in memory **and** answer at a comfortable pace, then plans how each one should run.

The logic lives in `Sources/HearthCore/Recommendation.swift`, with hardware detection in `Sources/HearthCore/Domain.swift`.

- [Reading the Mac](#reading-the-mac)
- [Ranking by published evidence](#ranking-by-published-evidence)
- [Precision variants](#precision-variants)
- [Goals and near-ties](#goals-and-near-ties)
- [Speed estimates](#speed-estimates)
- [Thinking budgets](#thinking-budgets)
- [Memory planning](#memory-planning)
- [Local checks](#local-checks)
- [What the ranking does and doesn't claim](#what-the-ranking-does-and-doesnt-claim)

## Reading the Mac

- **Memory budget.** Uses Metal's recommended working set without double-counting unified memory, and reserves RAM for macOS (the larger of 3 GB or a quarter of memory).
- **Hardware, not the moment.** The recommendation depends on the hardware only. Memory that other apps happen to hold never downgrades the pick. When free and inactive memory (plus memory released by the current model) falls short of the plan, a separate note says other apps are holding memory, and loading keeps a conservative shorter-context fallback.
- **Conditions shown, not used for ranking.** Memory pressure, thermal state, and Low Power Mode appear in the details.
- **When it rescans.** Off the main thread, on returning to the app, on an explicit refresh, and before loading a model. Changing preferences updates suggestions without disrupting a running conversation.

## Ranking by published evidence

- **Benchmarks and weights.** MMLU-Pro 50%, IFEval 30%, GPQA Diamond 20%. These are disclosed product choices, not an intelligence scale.
- **Head to head on shared benchmarks.** Two models are compared only on benchmarks both have published, with at least two shared dimensions. A missing (often harder) test never inflates either side. The feasible model with the fewest head-to-head losses leads, then the one with the most wins.
- **Coverage.** 49 of the 75 configurations have enough comparable evidence to rank. The rest stay downloadable in the catalog; missing scores are never guessed.
- **Provenance.** The bundled archive links each source page, records a hash of the source document and the review date, and binds every fact to the exact GGUF file it describes.

Reviewed inputs are in `scripts/recommendation-evidence.json`. `python3 scripts/build-recommendation-evidence.py` builds the bundled archive (`Sources/HearthCore/recommendation-evidence.json`) from them; see [CONTRIBUTING.md](../CONTRIBUTING.md#add-benchmark-evidence) for adding scores.

## Precision variants

Published scores describe full-precision weights; MaxModel downloads compressed GGUF files.

- **Q4_K_M and finer rank equally.** Their differences are within benchmark noise, and Q4 reads the fewest bytes per token, so it is also the fastest.
- **Only compression beyond Q4 costs points:** IQ4 0.5, Q3 1.5, IQ3 2, Q2/IQ2 7, IQ1 14. gpt-oss's native MXFP4 costs nothing. These allowances are product policy informed by llama.cpp perplexity and KL-divergence comparisons, not measurements of each file. The details panel still labels each file's precision.
- **Several precisions of the top Qwen3.5 models** (Compact IQ3, standard Q4, High-precision Q6, Near-full-precision Q8) are there for manual choice. Automatic picks prefer the Q4 copy, which ties on rank and runs faster. Another precision is picked only when the Q4 copy is excluded, for example after a failed local check.

## Goals and near-ties

| Goal | Who wins | Speed target | First answer within |
| --- | --- | ---: | ---: |
| **Best answers** (default) | The leader, but models within **2 points** count as tied and the fastest of them wins | 5 tokens/s | 45 s |
| **Balanced** | The least demanding model within 5 points of the leader | 10 tokens/s | 20 s |
| **Light & quick** | The least demanding model within 15 points | 15 tokens/s | 10 s |

The 2-point band exists because gaps that small are within benchmark sampling error and differences in publishers' evaluation setups. It is strict: an IQ3 file, exactly 2 points behind its own Q4 copy, never ties it.

Qwen3.5-122B-A10B was evaluated and not added. Its publisher scores (MMLU-Pro 86.7, GPQA 86.6, IFEval 93.4) give a composite of 88.69: a tie with Qwen3.5-27B (88.65), and within the band of Qwen3.5-35B-A3B (87.1), which reads about a third as many weights per token and would win the tie. Its Q4 build is also sharded across several files.

## Speed estimates

Fitting in memory is necessary but not sufficient. Each generated token reads the model's active weights once, so **speed follows memory bandwidth, not memory size**.

- **Bandwidth.** Apple's rated figure for the chip, from 68 GB/s (M1) to 819 GB/s (M3 Ultra). The 14-core M3 Max and M4 Max use their narrower figures. Unlisted chips get a cautious value for their tier, labelled as an estimate. Intel Macs use CPU memory.
- **Generation speed** ≈ 55% of bandwidth ÷ bytes of active weights. Mixture-of-experts models count only their active parameters. On the development M4 the estimate is within 25% of every recorded measurement (Qwen3.5 4B: 24 estimated, 25.5 measured tokens/s).
- **Prompt reading** uses bandwidth as a proxy for GPU compute.
- **Targets apply before download.** A model whose published results used extended thinking must fit at least 512 thinking tokens within the goal's wait; leftover time buys more thinking.
- **Measurements win.** A matching local test replaces the estimate. Estimates describe the hardware and ignore Low Power Mode, heat, and other apps' load.

Best answers on representative Macs (estimates):

| Mac | Pick | Speed | Thinking budget | First answer, hard question |
| --- | --- | ---: | ---: | ---: |
| M1, 8 GB | Qwen3.5 4B | 14 tokens/s | 512 | ≈ 40 s |
| M4, 16 or 24 GB | Qwen3.5 4B | 24 tokens/s | 768 | ≈ 33 s |
| M4 Pro, 24 GB | Qwen3.5 9B | 26 tokens/s | 768 | ≈ 30 s |
| M3 Pro, 36 GB | Qwen3.5 35B-A3B | 44 tokens/s | 1,536 | ≈ 36 s |
| M4 Pro, 48 GB | Qwen3.5 35B-A3B | 80 tokens/s | 2,816 | ≈ 36 s |
| M2 Max, 64 GB | Qwen3.5 35B-A3B | 117 tokens/s | 4,096 | ≈ 35 s |
| M4 Max, 128 GB | Qwen3.5 35B-A3B | 159 tokens/s | 4,096 | ≈ 26 s |

The dense 27B model fits on many of these Macs but reads about 17 GB per token; where it can afford the minimum thinking at all, it ties the 35B-A3B on published results and runs several times slower. On the 16 GB M4, Qwen3.5 9B misses the 45-second target by about two seconds, so that boundary is close; a local check on that Mac would settle it.

## Thinking budgets

- The planner sizes thinking from the expected speed: 512 to 4,096 tokens for Best answers, up to 2,048 otherwise.
- A measured-speed tuner can adjust the budget within the same range after a local check, then validates it with three new prompts.
- A reasoning budget always reserves room for the final answer.

## Memory planning

- **Estimates** cover the weights, runtime headroom, and conversation memory (the key/value cache), using model-specific layouts where reviewed. See [Memory and performance](memory-and-performance.md).
- **Conversation window.** Everyday mode targets 2K–16K tokens by goal; Longer chats can reach 64K within the model's declared maximum.
- **Fallbacks.** If a configuration fails to load, MaxModel retries with a conservative full-precision, shorter-context plan. Corrupted weights never bypass verification.
- **Image support** adds the encoder's memory and loads only when it fits; see [Images and documents](images-and-documents.md).

## Local checks

**Run local check** and first-use speed checks run synthetic prompts entirely on the Mac:

- Thinking time is adjusted once from measured throughput and time to first answer, then three new prompts validate the profile. This can make a capable model practical without switching to a smaller one; it does not assert unchanged quality at a shorter thinking budget.
- The fuller check adds six deterministic sanity tasks (instructions, arithmetic, supplied facts, uncertainty, ordering, JSON), each shown individually. They are not an intelligence benchmark.
- A matching three-prompt test can exclude a model from automatic recommendations if it misses latency or memory limits or fails most basic checks. Manual choice remains available.
- Tests count only when they match the chip, engine, weights, context, and configuration, and are under 30 days old. Benchmarks never contain user chats.

Preferences, profiles, failures, and measurements persist with the rest of the local state; older data migrates without replacing conversations.

## What the ranking does and doesn't claim

The ranking is an **approximate ordering of heterogeneous published evaluations**. It is not independently verified quality of the compressed weights, a measure of writing quality, or a universal intelligence score. Publishers' thinking budgets and precision can differ substantially from MaxModel's. Speed tests don't measure answer quality, and model strengths in the catalog are editorial descriptions. Broader controlled evaluations of exact quantizations remain necessary.
