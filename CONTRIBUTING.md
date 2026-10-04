# Contributing to MaxModel

Thanks for helping make the smartest free AI easy to run on any Mac. Contributions of every size are welcome, from a typo fix to a new model family, and many don't need any code.

- [Ways to help](#ways-to-help)
- [Where help is most wanted](#where-help-is-most-wanted)
- [What MaxModel stands for](#what-maxmodel-stands-for)
- [Getting set up](#getting-set-up)
- [Making a change](#making-a-change)
- [Recipes for common changes](#recipes-for-common-changes)
- [Pull request checklist](#pull-request-checklist)
- [Releases](#releases)
- [License and conduct](#license-and-conduct)

## Ways to help

**No code needed**

- **Report a bug.** [Open a bug report](https://github.com/dhrubsingh/maxmodel/issues/new?template=bug_report.yml) with your Mac model, memory, macOS version, and MaxModel version. These are on the **This Mac** screen.
- **Share how it runs on your Mac.** Run **Why this one? → Advanced → Run local check** and post the results in an issue, especially from Macs we haven't tested: Intel, M1/M2/M3 variants, Pro/Max/Ultra chips, and 8 GB or 64 GB+ machines.
- **Request a model.** [Suggest one](https://github.com/dhrubsingh/maxmodel/issues/new?template=model_request.yml) with a link to its publisher's release and published benchmark scores.
- **Improve the docs.** Anything unclear in this repository is a bug. Small fixes can go straight to a pull request.
- **Suggest a feature.** [Describe the problem](https://github.com/dhrubsingh/maxmodel/issues/new?template=feature_request.yml) you want solved. For anything large, please open an issue before writing code.

**Code**

Look for issues labelled [`good first issue`](https://github.com/dhrubsingh/maxmodel/labels/good%20first%20issue) or [`help wanted`](https://github.com/dhrubsingh/maxmodel/labels/help%20wanted), or pick something from the list below. Comment on an issue to claim it, so work isn't duplicated.

## Where help is most wanted

| Area | What's needed | Start with |
| --- | --- | --- |
| **Intel Macs** | Builds are packaged and statically verified but have never run on Intel hardware. Download, chat, and image support all need a real test. | [Testing](docs/testing.md) |
| **Image support for more models** | Only Qwen3.5 4B's image encoder is runtime-tested. Gemma 3, Gemma 4, Ministral 3, and Mistral Small 3.2 encoders are pinned but untested. | [Images and documents](docs/images-and-documents.md) |
| **Benchmark evidence** | 26 of 75 configurations lack enough published scores to be ranked. Each new sourced score helps. | [Add benchmark evidence](#add-benchmark-evidence) |
| **Knowledge cutoffs** | 53 configurations say "Not documented." Publisher-stated cutoffs only. | [Add a knowledge cutoff](#add-a-knowledge-cutoff) |
| **Speed reports** | Speed estimates are calibrated on one M4. Measurements from other chips make them better. | [Speed estimates](docs/recommendations.md#speed-estimates) |
| **Accessibility and localization** | VoiceOver labels, keyboard navigation, and translations. | [Architecture](docs/architecture.md#sourceshearth-app) |

## What MaxModel stands for

These principles guide every review. A change that conflicts with one needs a strong reason.

1. **Simple first.** One clear recommendation and one button to start. Depth belongs behind a disclosure, not in the way.
2. **Private by design.** No telemetry, accounts, or cloud inference. Nothing leaves the Mac except explicit model downloads and the update check.
3. **Honest numbers.** Every claim has a source or a measurement, and estimates are labelled as estimates. Missing data stays missing rather than being guessed.
4. **Respect model licenses.** Original licenses and notices ship with the weights; custom terms need explicit acceptance.
5. **Verified downloads.** Every file has a pinned revision and a SHA-256. No model repository code ever runs.
6. **A responsive interface.** Heavy work (file reading, hashing, saving, hardware scans) stays off the main thread.
7. **Native and small.** SwiftUI, no web views, and few dependencies. New dependencies need discussion first.

Out of scope for now: actions on the Mac (agents and tools), web search, cloud models, and Windows or Linux builds. The [docs](docs/models-and-licenses.md#what-maxmodel-doesnt-do) list the rest.

## Getting set up

You need macOS 14 or later, Swift 6.1 or newer (Xcode or the command-line tools), and Python 3. An Apple Silicon Mac is best, since that's where everything is runtime-tested.

```sh
git clone https://github.com/dhrubsingh/maxmodel.git
cd maxmodel
python3 scripts/fetch-engine.py                     # pinned, checksum-verified llama.cpp engine
bash scripts/test.sh                                # unit and app tests (no downloads)
MAXMODEL_DATA_DIR="$PWD/.test-data/dev" swift run Hearth
```

`MAXMODEL_DATA_DIR` keeps development chats and models separate from your installed copy. You can also open `Package.swift` in Xcode.

> The Swift targets are still named `Hearth`, the app's former name. The product is MaxModel.

New to the code? [Architecture](docs/architecture.md) explains how the pieces fit and what each source file does.

## Making a change

1. **Fork** the repository and create a branch from `main` (for example `fix/download-resume` or `model/olmo3`).
2. **Keep it focused.** One pull request per fix or feature is easier to review and to revert.
3. **Match the surrounding code.** Follow the existing style, naming, and comment density. Comments explain constraints the code can't show, not what the next line does.
4. **Add or update tests** for behavior changes. See [Testing](docs/testing.md).
5. **Run `bash scripts/test.sh`** before pushing. Engine-backed tests need a normal terminal, not a restricted sandbox.
6. **Update docs** when you change behavior users or contributors can see.
7. **Open a pull request** and fill in the template. CI runs the tests and builds and verifies the package on every pull request.

Write commit messages in the imperative ("Add Granite 4 to the catalog"), with a short body explaining *why* when it isn't obvious.

## Recipes for common changes

### Add or update a model

Models come from a reviewed inventory, `scripts/catalog-specs.json`. The catalog builder fetches everything else (pinned file, hash, size, architecture, licenses, image encoder) from Hugging Face.

1. **Check that it qualifies:**
   - The original publisher states a license on its release. Apache-2.0 and MIT need no acceptance; reviewed custom licenses (Llama, Gemma, Falcon, and others in `LICENSE_NAMES` in `scripts/update-catalog.py`) require it. A new license type needs maintainer review.
   - The GGUF distributor's license matches the publisher's.
   - The model is a single GGUF file, not sharded.
   - Its architecture is supported by the bundled llama.cpp build (the builder checks).
2. **Add an entry** to `scripts/catalog-specs.json`:

   ```json
   {
     "id": "qwen35-4",
     "source": "Qwen/Qwen3.5-4B",
     "distributor": "unsloth/Qwen3.5-4B-GGUF",
     "family": "Qwen",
     "series": "Qwen3.5",
     "parameters": 4.0,
     "category": "Everyday",
     "reasoning": false
   }
   ```

   | Field | Meaning |
   | --- | --- |
   | `id` | Stable, unique ID. Never reuse or rename one; saved state refers to it. |
   | `source` | The original publisher's Hugging Face repository (for licenses and the model card) |
   | `distributor` | The repository with the GGUF file |
   | `family`, `series`, `parameters` | Grouping and display. Entries with the same series share a card. |
   | `category` | `Everyday`, `Coding`, or `Reasoning` |
   | `reasoning` | `true` for models that think before answering |
   | `quantization` | Optional. Defaults to `Q4_K_M` (`MXFP4` for gpt-oss). Set it for extra precisions, such as `Q6_K`. |
   | `name`, `tagline`, `strengths`, `limitations`, `preference` | Optional display text and ordering |
   | `baseSource` | Optional. The base model whose notices must also ship, for fine-tunes |

3. **Build it:** `python3 scripts/update-catalog.py --only YOUR_ID`. This writes the entry to `Sources/HearthCore/catalog.json` and the license documents to `Sources/HearthCore/model-notices/YOUR_ID/`. If the release ships `mmproj-F16.gguf`, image support is added automatically.
4. **Add its benchmark evidence and knowledge cutoff** if published (next two recipes). Without evidence, the model stays downloadable but isn't recommended automatically.
5. **Try it:** download it in a development copy, chat with it, and attach an image if it can see. If it works end to end, you may add its ID to `TESTED` in `update-catalog.py` and rebuild, which marks it **Tested locally**.
6. **Run the tests.** Catalog validation checks hashes, URLs, notices, and encoder pins.
7. **In the pull request,** include the publisher link, the license, and what you tested.

To deliberately move an existing model to a newer upload, use `--refresh-weights`. Otherwise pinned revisions never change.

### Add benchmark evidence

Recommendations use MMLU-Pro, IFEval, and GPQA Diamond. A model needs at least two of them to be ranked.

1. **Find a publisher or paper result** for the same model version (not a different size or a fine-tune). Pin the page if possible, for example a Hugging Face `resolve/<commit>/README.md` URL or an arXiv version.
2. **Hash the exact document** you read:

   ```sh
   curl -sL "SOURCE_URL" | shasum -a 256
   ```

3. **Add the scores** under the model's ID in `metricsByModel` in `scripts/recommendation-evidence.json`:

   ```json
   "qwen3-4b": [
     {
       "name": "MMLU-Pro",
       "value": 58,
       "sourceURL": "https://huggingface.co/Qwen/Qwen3-4B-Instruct-2507",
       "sourceSHA256": "8e3dd0c3…",
       "setting": "Published direct-answer evaluation; upstream weights, not this GGUF.",
       "thinking": false
     }
   ]
   ```

   `setting` describes how the score was measured. `thinking` is `true` if the result used extended thinking, which makes MaxModel budget thinking time for that model.
4. **Rebuild the archive:** `python3 scripts/build-recommendation-evidence.py`. It needs cached GGUF headers for every catalog model; on a fresh clone, run `python3 scripts/update-catalog.py` once first (pinned revisions are preserved; check `git diff` for unintended catalog changes).
5. **Run the tests**, and mention in the pull request whether the recommendation changed for any Mac (`HEARTH_RECOMMENDATION_REPORT=/tmp/matrix.json bash scripts/test.sh` writes the simulated lineup).

Never estimate a score from parameter count or a related model. Leave it missing.

### Add a knowledge cutoff

1. Find the cutoff **as stated by the publisher** (model card, paper, or official docs). Release dates and a model's own claims in chat don't count.
2. Add or update the model's entry in `scripts/model-knowledge.json`:

   ```json
   "phi4-mini": {
     "cutoff": "June 2024",
     "sourceURL": "https://huggingface.co/microsoft/Phi-4-mini-instruct/resolve/cfbefacb99257ffa30c83adab238a50856ac3083/README.md",
     "checkedAt": "2026-10-02",
     "note": "Microsoft reports this cutoff for publicly available training data; the model also uses synthetic and post-training data."
   }
   ```

   Write the cutoff as the source does ("Mid-2024", "June 2024 or earlier"); approximate stays approximate. Use `"cutoff": null` with a note when a reviewed source doesn't state one.
3. Run `python3 scripts/update-catalog.py --only MODEL_ID` to carry it into the catalog.

### Change recommendation logic

The planner is in `Sources/HearthCore/Recommendation.swift`, and its tests in `Tests/HearthCoreTests/RecommendationTests.swift` cover goals, near-ties, precision variants, speed estimates, and the simulated Mac lineup.

- Explain the reasoning and any evidence in the pull request. Policy values (benchmark weights, tie bands, speed targets) are product decisions and are documented in [How MaxModel picks a model](docs/recommendations.md).
- Include before and after recommendations for the simulated lineup.
- Update the docs if the behavior users see changes.

### Add a chip's memory bandwidth

`Hardware.memoryBandwidth` in `Sources/HearthCore/Domain.swift` maps chip names to Apple's rated bandwidth. Add new chips with a link to Apple's published specification in the pull request. Unknown chips fall back to a cautious estimate for their tier.

### Change the interface

- Views are in `Sources/Hearth`, with state and actions in `AppStore.swift`.
- Keep heavy work off the main thread, and keep the first screen simple.
- Render screenshots with `HEARTH_SNAPSHOT_DIR=/tmp/shots bash scripts/test.sh`, or try it with `MAXMODEL_DATA_DIR="$PWD/.test-data/ui" swift run Hearth`.
- Include before and after screenshots in the pull request.

### Update the engine

The engine is llama.cpp's official macOS build, pinned to `b11146`.

1. Update `TAG` and both `HASHES` (arm64 and x64) in `scripts/fetch-engine.py`, and `ARCH_URL` in `scripts/update-catalog.py`.
2. Search for remaining `b11146` references (`rg b11146 Sources scripts`) and update them. Measured profiles are tied to the engine version, so older measurements stop applying, as intended.
3. Run the full test suite plus the real-model integration suites in [Testing](docs/testing.md), and build and verify both packages.

### Update the website

The download page is a single file, `site/index.html`, with images in `site/assets/`. It reads `release.json` from the latest release for its version and download links. Merging to `main` redeploys it. Preview locally with `python3 -m http.server -d site`. Without `release.json`, the buttons link straight to the latest release's files instead of showing version details.

## Pull request checklist

- [ ] `bash scripts/test.sh` passes.
- [ ] New behavior has tests; real-model behavior was tried with a real model.
- [ ] Interface changes include screenshots.
- [ ] Docs are updated where behavior changed.
- [ ] No personal data, chats, models, or generated `.test-data/` files are committed.
- [ ] Model or evidence changes link their sources.
- [ ] `Resources/Info.plist` version numbers are unchanged (maintainers bump them when releasing).

## Releases

Maintainers release by raising the version in `Resources/Info.plist` and merging to `main`; a workflow builds, signs, publishes, and updates the website. See [Building and releasing](docs/building-and-releasing.md#releases-website-and-updates).

## License and conduct

MaxModel is [MIT licensed](LICENSE). By contributing, you agree that your contributions are licensed under the same terms. Models keep their own licenses.

Everyone taking part is expected to follow the [Code of Conduct](CODE_OF_CONDUCT.md). Report security issues privately as described in [SECURITY.md](SECURITY.md), not in public issues.
