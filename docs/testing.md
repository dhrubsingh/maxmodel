# Testing

MaxModel's tests use **real weights and the real Metal engine** wherever behavior depends on a model. Fast deterministic tests run on every pull request; heavier real-model suites are opt-in.

- [Quick reference](#quick-reference)
- [Unit and app tests](#unit-and-app-tests)
- [Opt-in probes](#opt-in-probes)
- [Real-model integration](#real-model-integration)
- [Packaging checks](#packaging-checks)
- [Testing the interface by hand](#testing-the-interface-by-hand)
- [Where results go](#where-results-go)

## Quick reference

| Command | What it covers | Downloads |
| --- | --- | --- |
| `bash scripts/test.sh` | Unit and app tests (what CI runs) | None |
| `bash scripts/test.sh --integration` | Plus real inference end to end | About 1.5 GB of fixtures on first run |
| `bash scripts/test-offline.sh` | Integration flows with external networking denied by macOS | Uses existing fixtures |
| `bash scripts/verify-package.sh` | Extracts and verifies the built ZIP | None |

Run `python3 scripts/fetch-engine.py` once first. Engine-backed tests need loopback networking and Metal, so run them in a normal terminal rather than a restricted command sandbox.

## Unit and app tests

`bash scripts/test.sh` runs both test targets:

- **`Tests/HearthCoreTests`**: recommendations and speed estimates, context and cache planning, adaptive optimization rules, attachments and conversation rendering, Markdown, knowledge metadata, storage, downloads, persistence, and catalog and license integrity.
- **`Tests/HearthAppTests`**: application state, chat journeys (drafts, retry, edit, continue), attachments in the app, assistant discovery, navigation, and responsiveness.

The suite also covers isolated typing and streaming observation, ordered background saves, partial-answer recovery, debounced search, recommendation fit, example provenance, comparison license gates, nested Markdown lists, code-block whitespace, unfinished streaming fences, tables, inert HTML, images and unsafe links, variant aggregation, storage budgets, and bundled license integrity.

The current suite has 97 tests. Some tests skip unless you opt in with the variables below; a full run has none skipped.

## Opt-in probes

Set any of these when running `bash scripts/test.sh`:

| Variable | Enables |
| --- | --- |
| `HEARTH_SETUP_FIXTURE=$PWD/.test-data/smoke/Models/smollm2-135m.gguf` | Real one-click setup: copies the fixture into an isolated partial download, runs verification and installation, loads the engine, generates a reply, and checks saved state. Never contacts a model host. |
| `HEARTH_NAV_REPORT=/tmp/navigation.json` | The native navigation layout probe (median and maximum layout time across repeat switches) |
| `HEARTH_SNAPSHOT_DIR=/tmp/shots` | Renders the home screen, recommendation details, and chat states (attachments, text-only model, image-support download, drop overlay) to PNGs |
| `HEARTH_RECOMMENDATION_REPORT=/tmp/matrix.json` | Writes the recommendation for a simulated lineup of Macs |
| `HEARTH_VISION_FIXTURES=$PWD/.test-data/vision` | Real image tests: Qwen3.5 4B looking at an image and reading a PDF, Qwen3 4B reading recognized text, cached follow-ups, and the full app path with thinking on |
| `HEARTH_VISION_REPORT=/tmp/vision.json` | Writes image-test timings and answers |

**Getting the image fixtures.** `hearth-smoke` doesn't download image encoders. Run a development copy with `MAXMODEL_DATA_DIR="$PWD/.test-data/vision" swift run Hearth`, download **Qwen3.5 4B** (let image support finish) and **Qwen3 4B**, then quit and pass that folder as `HEARTH_VISION_FIXTURES`.

**Getting the setup fixture.** `bash scripts/test.sh --integration` downloads SmolLM2 135M into `.test-data/smoke/Models/`.

## Real-model integration

`hearth-smoke` is a command-line tool that drives the real engine. Build it with `swift build`, then:

```sh
bash scripts/test.sh --integration                    # verified download, pause/resume, auth, chat, trimming,
                                                      # cancellation, switching, deletion, benchmarks, persistence
.build/debug/hearth-smoke --families --download       # Qwen3 0.6B, SmolLM3 3B, Phi-4 mini, Ministral 3 3B (~6.6 GB more)
.build/debug/hearth-smoke --models qwen35-08,smollm2-135m,granite33-2b,deepseek-r1-15b,gemma4-e2b,olmo2-7b --download
python3 scripts/test-process-cleanup.py               # the packaged engine exits after its parent crashes
.build/debug/hearth-smoke --responsiveness --report .test-data/performance/updated-responsiveness.json
.build/release/hearth-smoke --prompt-cache            # prompt reuse timing
.build/release/hearth-smoke --examples                # regenerate recorded example answers from installed fixtures
```

Execution tuning probes:

```sh
HEARTH_ENGINE_PATH="$PWD/vendor/llama/llama-server" .build/debug/hearth-smoke --optimize qwen3-17b,qwen35-08 --direct
HEARTH_ENGINE_PATH="$PWD/vendor/llama/llama-server" .build/debug/hearth-smoke --optimize qwen3-06b --direct --cpu
```

Reports go to `.test-data/adaptive-optimization/`. Omitting `--direct` keeps the planned thinking budget. These probes use isolated fixture storage and never create conversations.

What the suites cover:

- **Integration** (`.test-data/smoke/`): verified download, pause and resume, authentication, single and multi-turn inference, oversized conversations, cancellation and recovery, two-model switching, deletion, benchmarks, persistence, and unloading. The benchmark report is `.test-data/smoke/benchmark-report.json`.
- **Families**: verified downloads, chat templates, multi-turn recall, cross-family switching, and three-prompt speed benchmarks, saved to `family-report.json`. Phi missed an ambiguous recall question and then recalled the fact when the question referenced the previous message; this is recorded as a quality limitation. These are compatibility checks, not answer-quality evaluations.
- **Additional architectures**: runtime compatibility and answer-quality observations, recorded separately in `catalog-report.json`. Never accepts a custom license automatically.

## Packaging checks

```sh
bash scripts/build-app.sh && bash scripts/verify-package.sh
bash scripts/build-app.sh x86_64 && bash scripts/verify-package.sh dist/Intel/MaxModel-macOS-Intel.zip --static
```

`verify-package.sh` extracts the ZIP outside the project and checks the signature, the exact catalog, every original notice, the evidence archive, Sparkle, and the runtime dependency closure, then runs the extracted engine to confirm it launches. `--static` skips that last step, so the Intel package can be checked without running Intel code.

## Testing the interface by hand

Use a separate data folder so test chats never mix with your own:

```sh
MAXMODEL_DATA_DIR="$PWD/.test-data/ui" swift run Hearth
```

Worth covering for interface changes:

- First launch: recommendation, download, first message.
- Chat: streaming, thinking, scrolling away and back with **Latest**, retry, edit, continue, drafts surviving a restart.
- Attachments: drag, paste, and paperclip; a model that sees and one that doesn't; a long PDF.
- Catalog: filters, custom-license acceptance (without accepting real terms), the download lock.
- Memory release and switching models while a reply is running.

Models make mistakes. The small 0.6B model made factual errors during testing, which is why answer quality is judged separately from speed.

## Where results go

`.test-data/` holds fixtures and measurement records. It's ignored by git, so records referenced in the [validation history](validation-history.md) exist only on the machine that produced them. Summaries with artifact hashes are kept in [`validation-records.json`](validation-records.json).
