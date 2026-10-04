# Memory and performance

How MaxModel fits long conversations into memory, tunes execution for a specific Mac, and keeps the interface responsive while a model runs.

- [Conversation memory](#conversation-memory)
- [Research reviewed](#research-reviewed)
- [Tune for this Mac](#tune-for-this-mac)
- [Generation settings](#generation-settings)
- [Prompt reuse](#prompt-reuse)
- [A responsive interface](#a-responsive-interface)

## Conversation memory

### Longer chats

In **Why this one? → Advanced · memory, local checks & tuning**, set **Conversation memory** to **Longer chats**. MaxModel plans up to **65,536 tokens**, bounded by the model's declared context limit and the memory budget. Everyday mode keeps its smaller, goal-based window. Changing the setting updates recommendations; use the assistant again to apply it. Saved messages are untouched.

### Compact conversation cache (Q8)

On compatible Apple Silicon paths, the planner can use the runtime's **Q8_0 key/value cache**. Each 32-value block takes 34 bytes instead of FP16's 64: a **46.875% reduction in attention-cache storage**, not in total model memory.

- Q8 is chosen when reviewed layout estimates show at least 256 MiB of savings, or when it lets a requested window fit.
- Hybrid and sliding-window models without reviewed geometry keep FP16 when it fits. Unknown or unreviewed cache paths, and Intel, keep FP16.
- Compatibility comes from pinned GGUF dimensions and a reviewed architecture list, with representative runtime tests. It doesn't certify every configuration's accuracy.
- Q8 can trade some accuracy. Turning off **Allow compact conversation cache when it helps**, in the same Advanced section, keeps FP16; the section also explains the model's cache layout.

### Model-specific layouts

The planner understands **Qwen3.5's recurrent/full-attention split** and **Gemma 4's shared and sliding-window caches**, from pinned metadata and the matching runtime implementation:

- Recurrent state stays FP32; shared layers aren't counted twice.
- The rolling cache includes the fixed 512-token microbatch and alignment.
- At most **two partial-state checkpoints** are kept (the runtime default is 32), with their memory included in the estimate. This bounds memory but can mean more rereading after large edits to earlier context.
- Weight and runtime headroom and the macOS reserve still apply. Other layouts keep conservative estimates.

In a planner test with a 4.8 GiB budget, Gemma 4 E2B can use a 64K FP16 window, where the old dense-layer estimate allowed a much shorter one.

### When plans change

A planned estimate is not a measurement of exact allocation. A compressed-cache load failure triggers a new FP16 plan within the budget; integrity failures never bypass verification. Configuration identity includes precision and the checkpoint-policy revision, so older speed and long-memory results don't carry over. Old saved profiles decode as FP16 and are replanned when reviewed geometry changes.

### Checking longer memory

**Check longer memory on this Mac** adds a synthetic retrieval test: three facts placed near the beginning, middle, and end of a generated input, sized with the real tokenizer up to 32K input tokens or three quarters of the window. Results show input length, facts recovered, first-answer delay, and the answer itself. It's a limited retrieval check, not proof of long-document comprehension, and it never reads user files or chats. A failure is disclosed and affects that configuration's recommendation.

### Fitting long histories

When a conversation outgrows the window, MaxModel drops only complete old turns, finding the longest fitting suffix with a logarithmic number of exact template/tokenizer requests (at most 12 checks for 1,000 turns in the regression test). A visible notice says how many earlier messages were omitted. An oversized latest message is rejected with an actionable error, never silently truncated.

## Research reviewed

Reviewed October 2, 2026. Maintainer decisions and hashes of the reviewed runtime sources are in `scripts/context-optimization-research.json`. These optimizations improve memory use and execution; they don't add training knowledge to a model.

| Research or technique | How it applies |
| --- | --- |
| [KIVI](https://arxiv.org/abs/2402.02750), [TurboQuant](https://arxiv.org/abs/2504.19874), [UltraQuant (revised September 2026)](https://arxiv.org/abs/2606.20474) | Motivates compressing conversation memory. MaxModel ships the existing GGML Q8_0, a different method, and claims none of their compression ratios or speedups. UltraQuant's AMD serving path isn't a drop-in Mac implementation. |
| [FlashAttention](https://arxiv.org/abs/2205.14135) and [the pinned Metal implementation](https://github.com/ggml-org/llama.cpp/blob/7fe450e19/ggml/src/ggml-metal/ggml-metal-ops.cpp) | Uses the bundled efficient-attention kernels, enabled explicitly where Q8 V-cache needs them. No custom kernel port or new speedup is claimed. |
| [YaRN](https://arxiv.org/abs/2309.00071) | Each model's declared context and positional settings are preserved. Arbitrary extrapolation can degrade answers, so no generic scaling factor is forced. |
| [DFlash](https://arxiv.org/abs/2602.06036), [DSpark](https://arxiv.org/abs/2607.05147), [runtime speculation support](https://github.com/ggml-org/llama.cpp/blob/7fe450e19/docs/speculative.md) | Investigated, not enabled globally. Drafting heads are model-specific, use memory, and need workload-specific validation. No speculative speedup is claimed. |
| [PagedAttention](https://arxiv.org/abs/2309.06180) | Addresses serving many concurrent requests. MaxModel runs one local model slot, so no batching subsystem is included. |

## Tune for this Mac

**Why this one? → Advanced → Tune for this Mac** runs an optional, cancellable comparison for an installed model. It never downloads another model, trains weights, or reads chats.

**What it compares.** With the weights, context, cache precision, and thinking budget held fixed: compatible CPU core and microbatch settings, experimental Metal backend sampling, and verified n-gram drafting. Hybrid, recurrent, and shared-KV paths skip unreviewed drafting. The runtime chooses GPU offload within its device allowance rather than assuming every layer fits on the GPU.

**How a setting earns its place.** Three synthetic workloads (read a longer input and return JSON, write a small function, edit repeated text), with a warm engine, prompt reuse disabled, a monotonic clock, greedy sampling, and exact output hashes and token counts. A candidate must:

- cut total response time by at least 8% and stay within the memory budget;
- avoid any per-workload or first-answer regression over 15% (plus a small scheduling tolerance);
- repeat stably within 15% alongside a repeated baseline, with the gain persisting;
- keep every previously passing basic check passing, with at least four of six passed.

**Where settings apply.** The policy is portable; a measured setting is not. Profiles are tied to the hardware (CPU topology, GPU, memory), macOS version, power mode, exact model, runtime and configuration, and expire after 30 days. Critical memory pressure, serious thermal throttling, a power-mode change, cancellation, or a failed candidate keeps the previous settings. **See what was tried** lists every trial, and **Restore automatic settings** removes a saved tune.

**What it doesn't claim.** Overall intelligence, factual correctness, identical stochastic answers, or speedups on every task. Keeping the defaults is a valid result. A backend may decline experimental sampling and fall back to CPU; MaxModel reports what it requested and measures what actually happened.

**Deliberately out of scope:** target-specific EAGLE3, DFlash, DSpark, or MTP downloads, custom TurboQuant kernels, arbitrary context extrapolation, and retraining. They'd need compatible kernels and weights, license and integrity handling, memory accounting, and quality evidence first. The candidate/measurement/promotion layer is the extension point. Windows, Linux, and phones would need platform ports.

## Generation settings

Sampling follows reviewed publisher recommendations for Qwen3, Qwen3.5, Gemma 4 E2B/E4B/31B, SmolLM3, and the original DeepSeek R1 Qwen distillations; other models use MaxModel's defaults. Chat uses sampling; greedy decoding is limited to controlled synthetic checks. Sources and revision hashes are in `scripts/adaptive-optimization-research.json`; in the app, the Advanced section shows the settings in use with a **Why these generation settings** link to the publisher.

## Prompt reuse

Follow-up messages reuse the active model's matching prompt prefix in memory, so long conversations don't reread everything. In a repeated long-prompt probe with Qwen3 0.6B, time to first text went from 0.92 s with reuse disabled to 0.018 s with it enabled. That is a controlled repeated-input case, not a claim that every answer becomes 50 times faster. There is no disk prompt cache, and the auxiliary RAM cache is disabled; unloading the model releases its context. Benchmarks and comparisons use fresh prompt processing. The implementation uses the [pinned llama.cpp prompt-cache API](https://github.com/ggml-org/llama.cpp/blob/7fe450e19/tools/server/README.md).

## A responsive interface

- **Isolated updates.** Property-level Swift Observation, an isolated live reply, and an isolated composer mean token updates and typing don't refresh unrelated screens. Messages render Markdown once when complete, not on every token.
- **Off the main thread.** State saves, hardware scans, model verification, unloading, attachment reading, and image encoding for requests all run in the background. Cancellation reaches background verification.
- **Cached results.** Recommendations and grouped catalog results are reused until their hardware, storage, installation, or filter inputs change; searchable text is prepared once, and search is debounced while typing stays immediate.
- **Retained screens.** Sidebar navigation keeps each visited screen's view, scroll position, and local state; hidden screens lose keyboard focus. Navigation never loads a model or rescans hardware.
- **Memory pressure.** On macOS warnings, inactive screens and rendered Markdown caches are released; conversations and drafts stay. Idle model memory is released after 15 minutes without interaction, or under memory pressure when nothing is running; the next message reloads it.

Measurements behind these changes are in the [validation history](validation-history.md#responsiveness-measurements).
