# Validation history

What was tested for each release, newest first. Measurements come from the development Mac (M4, 16 GB) with other apps running unless stated otherwise.

Machine-readable summaries with artifact hashes are in [`validation-records.json`](validation-records.json). Paths under `.test-data/` refer to raw records on the machine that produced them; that folder isn't committed.

- [0.9: Images and documents](#09-images-and-documents)
- [0.9: Speed-aware recommendations](#09-speed-aware-recommendations)
- [0.8: Everyday chat experience](#08-everyday-chat-experience)
- [0.7: Adaptive execution](#07-adaptive-execution)
- [0.6: Longer conversation memory](#06-longer-conversation-memory)
- [0.5: Evidence-based recommendations](#05-evidence-based-recommendations)
- [0.4: Discovery redesign and footprint](#04-discovery-redesign-and-footprint)
- [Responsiveness measurements](#responsiveness-measurements)

## 0.9: Images and documents

**97 tests passed, none skipped**, including real-model image tests (Qwen3.5 4B with its encoder, Qwen3 4B reading recognized text) and the full app path with thinking on. Records: `validation-records.json` under `imageAttachments`.

| Measurement | Result |
| --- | ---: |
| First answer about an image (invoice with a colored shape) | 4.6–8.9 s, depending on load |
| Follow-up about the same image | 0.5–0.8 s |
| Real Retina screenshot of the app | about 6–10 s |
| PDF question | 1.0–2.1 s |
| Text-only model reading recognized text | 1.1–1.8 s |
| Loading with image support | about 9.5 s; process memory 3.84 GB |
| Reading a Retina screenshot | 0.41 s (0.92 s first after launch) |
| Reading a 24-megapixel photo | 1.68 s |
| Longest main-thread pause while reading | 40 ms |

**Image token cap.** The same image and question on a busy system (load average about 5.5): 1,024 tokens took 10.7–14.8 s, 768 took 11.0–12.9 s, and 512 took 6.8–7.7 s. Image tokens were read at about 73 tokens/s against 272 for text. The cap was set to 512, with up to 3,000 characters of recognized text added to carry fine print.

**Fixes found in testing.** The assistant instructions now name the running model and treat shared content as real; before, Qwen3.5 4B called a real screenshot of itself a "mockup." The instructions also still said "Hearth."

**Rendered states:** chat with attachments, a text-only model, image support downloading, and the drop overlay.

**Limits.** Only Qwen3.5 4B's encoder was runtime-tested; the other encoders are pinned and hash-checked. Intel was statically verified only.

## 0.9: Speed-aware recommendations

**79 tests passed, none skipped**, with the setup, navigation, recommendation-matrix, and snapshot probes enabled. The setup probe loads the real engine and generates a reply.

New checks covered chip bandwidth lookup, speed estimates against M4 measurements, the minimum-thinking and wait rules, near-ties going to the faster model, precision variants not shifting the tie window, and a one-entry-per-model shortlist. The home screen and recommendation details were rendered offscreen for this M4 (`.test-data/speed-aware/snapshots/`), and the simulated Mac lineup (`.test-data/speed-aware/hardware-matrix.json`) produced the table in [How MaxModel picks a model](recommendations.md#speed-estimates).

Both architecture packages were rebuilt and passed signature, catalog, notice, and dependency verification; the Apple Silicon engine started from the extracted ZIP. Records: `speedAwareRecommendations`.

## 0.8: Everyday chat experience

**71 tests passed, none skipped**, including real local inference for setup, retry, continuation, and switching conversations during generation. The offline smoke test passed with external networking denied.

Native UI checks covered draft restoration, archived answers, edit preservation, starter input, assistant discovery, and expandable performance details. Both archives passed signature, runtime dependency, catalog, and license-notice checks. Records: `mvpUX`.

## 0.7: Adaptive execution

**64 tests passed, none skipped**, including real local setup, cancellation that unloads the experimental engine, migration, hardware/model/runtime invalidation, memory and quality gates, and native navigation. The packaged engine passed inference, persistence, switching, deletion, benchmarking, and crash-cleanup checks, with external networking denied for the offline regression. Both ZIPs passed signature, dependency, architecture, and notice validation.

Optimizer probes covered Qwen3 1.7B (Metal), Qwen3.5 0.8B (hybrid), DeepSeek R1 1.5B with 512 thinking tokens, and Qwen3 0.6B with GPU offload disabled. The native UI completed an isolated Qwen3 0.6B run, saved the result, displayed the trial details, and created no chats. **None of these established a repeatable additional speedup on this M4 under the conditions at the time, so defaults were kept.** The user's conversation and selected model were preserved. Records: `.test-data/adaptive-optimization/VALIDATION.json`.

Bundles: 27,774,271 bytes (Apple Silicon) and 27,375,764 bytes (Intel); ZIPs 12,166,586 and 12,413,145 bytes. No runtime dependency or draft-model download was added.

## 0.6: Longer conversation memory

**56 tests passed, none skipped**, including real offline setup, native navigation, old-state decoding, model-specific memory accounting, precision fallback, preference persistence, measurement invalidation, strict retrieval grading, and complete-turn trimming. The Apple Silicon package passed the offline regression and crash-cleanup checks; both packages passed static verification.

**Exploratory cache comparison.** A 16K window, about 12K input tokens, thinking off, process resident memory. This preceded the final two-checkpoint cap; values and outputs varied between runs:

| Model | FP16 memory | Q8 memory | Basic checks, FP16 / Q8 | Facts retrieved, FP16 / Q8 |
| --- | ---: | ---: | ---: | ---: |
| Qwen3 4B | 4.60 GiB | 3.58 GiB | 5/6 / 4/6 | 0/3 / 0/3 |
| Qwen3.5 4B | 3.18 GiB | 3.01 GiB | 5/6 / 5/6 | 3/3 / 3/3 |
| Gemma 4 E2B | 3.20 GiB | 3.07 GiB | 5/6 / 5/6 | 3/3 / 3/3 |
| SmolLM3 3B | 3.00 GiB | 2.52 GiB | 4/6 / 4/6 | 3/3 / 3/3 |

A smaller cache didn't consistently speed up generation; Gemma slowed. Qwen3's retrieval failure in both formats shows why allocated capacity isn't evidence of reliable recall.

**With the final checkpoint policy:** Qwen3.5 4B with a 32,768-token Q8 window passed six basic checks and recovered three facts from 24,560 input tokens. The native UI loaded and tuned Gemma 4 E2B with a 49,152-token FP16 window, passed all six checks, and recovered all three facts from 32,763 input tokens. Its short-prompt benchmark was about 55 tokens/s and 5.6 s to first answer; the long retrieval input took 86.9 s to first answer. The 64K setting is covered by planner tests.

Records: `.test-data/context-optimization/` (`comparison-summary.json`, `cache-probe-32768-compact.json`, `ui-long-context-result.json`, and logs). The UI preview used separate data.

## 0.5: Evidence-based recommendations

**46 tests passed, none skipped**, including the real offline setup flow and the native navigation probe. The packaged engine passed offline multi-turn inference, authentication, context limits, cancellation, switching, deletion, benchmarking, persistence, unloading, and parent-crash cleanup. Both archives passed signature, dependency, catalog, evidence, and notice checks.

Real calibration at a 16K window:

| Model | Tuned thinking | Generation speed | First answer | Basic checks |
| --- | ---: | ---: | ---: | ---: |
| Qwen3.5 4B | 768 tokens | 25.5 tokens/s | 26.3 s | 6/6 |
| Gemma 4 E2B | 1,792 tokens | 49.8 tokens/s | 5.3 s | 6/6 |

These are synthetic-prompt measurements, not quality comparisons. Qwen3.5 9B was evaluated by the planner from published evidence and memory estimates, not downloaded.

The native UI was exercised in an isolated preview: preferences, source disclosures, configuration details, model switching, automatic calibration and tuning, and a post-switch reply with bullets and code. The user's app reopened with its conversation, eight messages, and selected model preserved.

Package: 27,482,833-byte app, 12,048,791-byte ZIP (Intel ZIP 12,288,232 bytes). Navigation layout: 1.50 ms median, 2.74 ms maximum across 15 repeat switches. Records: `.test-data/recommendation/`.

## 0.4: Discovery redesign and footprint

**32 checks** with both opt-in probes enabled:

```sh
HEARTH_SETUP_FIXTURE="$PWD/.test-data/smoke/Models/smollm2-135m.gguf" HEARTH_NAV_REPORT=/tmp/hearth-navigation.json bash scripts/test.sh
```

The release UI was reviewed in an isolated preview and the user's app. Records: `.test-data/discovery-redesign/`.

**Footprint.** The Apple Silicon bundle went from 37,738,566 bytes (36.0 MiB) to **27,094,856 bytes (25.8 MiB), 28.2% smaller**; the ZIP to 11,901,304 bytes (11.4 MiB), 13.9% smaller. All 240 original notices were preserved, with 129 duplicates sharing bytes. These figures exclude model weights, which remain the main storage and memory cost.

**Derived-state caching.** 2,000 repeated catalog and recommendation reads took 3,630.9 ms before result reuse and 4.4 ms after, with identical results. This measures repeated derived-state work, not generation speed or click latency.

The stripped runtime passed offline authentication, multi-turn chat, trimming, cancellation, switching, deletion, benchmarking, persistence, unloading, and crash cleanup. The production app reopened with the user's data, and its saved-state hash was unchanged. Records: `.test-data/optimization/`.

## Responsiveness measurements

**Navigation (0.3.1).** With a synthetic 16-message Markdown and code conversation and the full model browser in a 1220 × 820 native host, across 15 repeat switches: median layout time fell from 48.0 ms to 1.6 ms, and maximum from 113.0 ms to 5.4 ms. First visits still build their screen. This is an offscreen debug-build layout measurement including a 1 ms run-loop interval, not click-to-display latency. Reproduce with `HEARTH_NAV_REPORT=/tmp/hearth-navigation.json bash scripts/test.sh`.

**Model unloading.** A three-cycle Qwen3 0.6B unload/load probe measured a maximum main-actor delay of 140.8 ms before nonblocking shutdown and 5.2 ms after. This covers that lifecycle path, not all clicks or generation speed. Records: `.test-data/performance/baseline-responsiveness.json` and `updated-responsiveness.json`.

**Prompt reuse.** A repeated long prompt with Qwen3 0.6B reached first text in 0.92–0.93 s with prefix reuse disabled and 0.018 s with it enabled, a controlled repeated-input case. Reproduce with `.build/release/hearth-smoke --prompt-cache`.

None of these changes claim a tokens-per-second speedup for the model itself; the engine is the same C++/Metal runtime.
