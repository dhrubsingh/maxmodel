# Architecture

MaxModel is a native SwiftUI app built with Swift Package Manager. It bundles the [llama.cpp](https://github.com/ggml-org/llama.cpp) server as its inference engine and talks to it over a local, authenticated HTTP connection.

> The app was called **Hearth** before 0.9, and the Swift targets still use that name (`Hearth`, `HearthCore`, `HearthSmoke`). The product name, bundle, and data folder are MaxModel.

- [How the pieces fit](#how-the-pieces-fit)
- [Repository layout](#repository-layout)
- [Source guide](#source-guide)
- [Data files](#data-files)
- [Environment variables](#environment-variables)
- [Dependencies](#dependencies)

## How the pieces fit

```text
┌───────────────────── MaxModel.app ─────────────────────┐
│  SwiftUI views  ──▶  AppStore (@Observable, main actor) │
│                        │                                │
│        HearthCore: recommendation, storage, downloads,  │
│        attachments, conversation rendering              │
│                        │  HTTP on 127.0.0.1 + token     │
│  hearth-engine-guardian ──▶ llama-server (Metal/CPU)    │
│  Sparkle (signed updates)                               │
└─────────────────────────────────────────────────────────┘
        │ explicit downloads only                │ update feed
   Hugging Face (pinned GGUF files)        GitHub Pages appcast
```

1. **Hardware** is read from system APIs and Metal (`Hardware` in `Domain.swift`).
2. **The planner** (`RecommendationPlanner`) combines the bundled catalog, benchmark evidence, hardware, goal, and local measurements into a ranked, speed-checked recommendation and a `RuntimeProfile` (context size, cache precision, thinking budget, threads).
3. **Downloads** (`ModelDownload`) fetch pinned files and `LocalStorage` verifies and installs them.
4. **The engine** (`LocalEngine`) starts `llama-server` through a small guardian process with the profile's arguments, then streams chat completions. The guardian keeps the engine's process ID and stops it if the app disappears.
5. **Conversations** are rendered to engine messages by `ConversationRenderer`, which fits attachments and history to the window, then saved through `StateWriter`.

## Repository layout

```text
Sources/Hearth/          SwiftUI app: screens, application state, update checker
Sources/HearthCore/      Catalog, hardware, recommendations, storage, downloads, engine, attachments
Sources/HearthSmoke/     hearth-smoke: real-model integration and measurement tool
Tests/HearthCoreTests/   Deterministic tests for the core library, plus opt-in real-engine tests
Tests/HearthAppTests/    App state, navigation, chat journeys, attachments, responsiveness
Resources/Info.plist     App manifest: version, bundle ID, Sparkle feed and public key
scripts/                 Engine fetch, packaging, verification, catalog and evidence maintenance
site/                    Download page published to GitHub Pages
.github/                 CI, release workflow, issue and pull request templates
docs/                    This documentation
vendor/llama/            Checksum-verified engine build input (not committed)
.test-data/              Local fixtures and measurement records (not committed)
```

## Source guide

### `Sources/HearthCore` (library, no UI)

| File | Responsibility |
| --- | --- |
| `Domain.swift` | Core types: `LocalModel`, `VisionEncoder`, `Hardware` (including the memory bandwidth table), `ChatMessage`, `AppData`, catalog loading and validation |
| `Recommendation.swift` | Goals, evidence, quantization policy, speed estimates, `RecommendationPlanner`, `RuntimeProfile`, performance tuning |
| `ContextOptimization.swift` | Model-specific cache geometry, KV-cache precision, fitting long histories |
| `AdaptiveOptimization.swift` | **Tune for this Mac**: execution candidates, trials, and promotion rules |
| `LocalCalibration.swift` | Local speed checks and the six basic answer checks |
| `GenerationPolicy.swift` | Publisher-recommended sampling settings |
| `Engine.swift` | `LocalEngine`: launching `llama-server`, authentication, streaming, token counting, image payloads |
| `Attachments.swift` | `ChatAttachment`, image and PDF processing, attachment budgets, `ConversationRenderer` |
| `AssistantInstructions.swift` | The system prompt: name, date, capabilities, knowledge cutoff |
| `Storage.swift` | `LocalStorage`: data folder, verification receipts, license notices, migration from Hearth |
| `Downloader.swift` | Resumable, redirect-restricted, hash-verified downloads |
| `StateWriter.swift` | Ordered, atomic background saves |
| `Discovery.swift` | The single home recommendation and recorded example answers |
| `ChatMarkdown.swift` | Markdown parsing into renderable blocks |
| `catalog.json`, `recommendation-evidence.json`, `discovery-examples.json`, `model-notices/` | Generated, bundled data (see [Data files](#data-files)) |

### `Sources/Hearth` (app)

| File | Responsibility |
| --- | --- |
| `HearthApp.swift` | App entry, menus, `UpdateChecker` (Sparkle, enabled only when the bundle has a feed URL) |
| `AppStore.swift` | All application state and actions: hardware, recommendations, downloads, chat, attachments, image support |
| `Views.swift`, `PageHost.swift` | Window layout, sidebar, retained page hosting |
| `DiscoveryView.swift`, `RecommendationView.swift` | Home screen and recommendation details |
| `AssistantsView.swift`, `ComparisonView.swift`, `AnswerComparison.swift` | Catalog, storage library, model comparisons |
| `ChatView.swift`, `StreamingReply.swift`, `ChatScrollObserver.swift`, `MarkdownView.swift` | Chat, composer, live reply, scrolling, Markdown rendering |
| `AttachmentViews.swift` | Attachment chips, thumbnails, drop overlay, image-support notices |
| `ModelDetailsView.swift`, `ModelKnowledgeView.swift`, `DownloadModelSheet.swift`, `FitMeter.swift` | Model details, knowledge cutoff, download confirmation, memory fit |
| `MacView.swift` | This Mac: hardware, storage, download lock |
| `Theme.swift` | Colors, type, buttons, and the app glyph |

### `Sources/HearthSmoke`

`hearth-smoke` drives the real engine with real weights for integration, family, optimization, responsiveness, and example-generation runs. See [Testing](testing.md).

## Data files

| File | Edited by hand? | Built by |
| --- | --- | --- |
| `scripts/catalog-specs.json` | Yes: the reviewed model inventory | — |
| `scripts/catalog-exclusions.json` | Yes: models deliberately withheld, with reasons | — |
| `scripts/model-knowledge.json` | Yes: reviewed knowledge cutoffs | — |
| `scripts/recommendation-evidence.json` | Yes: reviewed benchmark scores with sources | — |
| `scripts/*-research.json` | Yes: research reviews and maintainer decisions | — |
| `Sources/HearthCore/catalog.json` | No | `scripts/update-catalog.py` |
| `Sources/HearthCore/model-notices/` | No | `scripts/update-catalog.py` |
| `Sources/HearthCore/recommendation-evidence.json` | No | `scripts/build-recommendation-evidence.py` |
| `Sources/HearthCore/discovery-examples.json` | No | `hearth-smoke --examples` |

## Environment variables

None of these are user settings; they exist for development and tests.

| Variable | Effect |
| --- | --- |
| `MAXMODEL_DATA_DIR` | Use another data folder (`HEARTH_DATA_DIR` is still accepted) |
| `HEARTH_ENGINE_PATH` | Use another `llama-server` binary |
| `HEARTH_SETUP_FIXTURE` | Path to a test model; enables the real one-click setup test |
| `HEARTH_NAV_REPORT` | Enables the navigation layout probe and writes its report |
| `HEARTH_SNAPSHOT_DIR` | Renders key screens to PNGs in this folder |
| `HEARTH_RECOMMENDATION_REPORT` | Writes the simulated Mac lineup to this file |
| `HEARTH_VISION_FIXTURES` | Folder with a vision model and encoder; enables real image tests |
| `HEARTH_VISION_REPORT` | Writes the image-test measurements to this file |

## Dependencies

All pinned in `Package.swift` and `Package.resolved`, compiled or embedded into the app, with their licenses shipped in the bundle:

- **llama.cpp `b11146`**, downloaded by `scripts/fetch-engine.py` and verified against a pinned SHA-256.
- **Sparkle 2.10.0**, embedded as `Contents/Frameworks/Sparkle.framework` and thinned to the target architecture.
- **Swift Markdown 0.7.3** and swift-cmark.

Nothing is fetched at runtime except model downloads and the update feed.
