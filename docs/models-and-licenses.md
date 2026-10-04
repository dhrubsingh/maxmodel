# Models and licenses

MaxModel ships a reviewed catalog of open models. It doesn't bundle any model; each is downloaded from its publisher's Hugging Face release when you choose it.

- [The catalog](#the-catalog)
- [Verification labels](#verification-labels)
- [Downloads and integrity](#downloads-and-integrity)
- [Licenses](#licenses)
- [Knowledge cutoffs](#knowledge-cutoffs)
- [What MaxModel doesn't do](#what-maxmodel-doesnt-do)
- [Upstream components](#upstream-components)

To add or update a model, see [CONTRIBUTING.md](../CONTRIBUTING.md#add-or-update-a-model).

## The catalog

- **75 pinned configurations in 28 model groups across 12 families:** Qwen, SmolLM, Phi, Mistral, Llama, Gemma, Granite, OLMo, DeepSeek, Liquid, Falcon, and gpt-oss. Related sizes and precisions share one card.
- **Downloads range from 105 MB to 63.4 GB** (decimal units; the app shows binary GB/MB). Setup downloads a model; it never trains one.
- **Browsing.** Filter by hardware fit, family, use (everyday, coding, reasoning), or license, and sort by suggested order, download size, or name. "Fits this Mac" checks memory estimates and free disk space; an installed model doesn't need its download space again.
- **22 configurations can see images** with an optional encoder; see [Images and documents](images-and-documents.md).
- **Not every upload on the internet.** The catalog is a maintained collection of popular families. GLM-4.7-Flash is withheld because a complete original model license notice couldn't be verified; the code repository's different license is not substituted (see `scripts/catalog-exclusions.json`).

The catalog lives in `Sources/HearthCore/catalog.json`, built from the reviewed inventory in `scripts/catalog-specs.json` by `scripts/update-catalog.py`. The app never runs that script or refreshes metadata remotely.

## Verification labels

- **Metadata verified:** pinned file size and hash, GGUF architecture (checked against the bundled engine), and original license notices were all checked.
- **Tested locally (12 configurations):** that exact weight file completed real inference tests. It doesn't assert answer quality. Larger models and custom-license entries aren't all runtime-tested on the 16 GB development Mac.

## Downloads and integrity

- Every file comes from a **pinned repository revision** with a **trusted SHA-256**, and is checked at installation and again before each load.
- Downloads show progress and an ETA, pause and resume across restarts, and check free disk space first.
- Downloads follow redirects only to Hugging Face and its HTTPS CDN hosts. No Python or repository scripts are ever run.
- The **download lock** in This Mac prevents any new download; installed models keep working.
- Removing a model frees its disk space (including image support) and keeps your chats.

## Licenses

- Cards label Apache/MIT models clearly and mark **custom terms** (19 configurations, such as Llama, Gemma, and Falcon licenses).
- Custom terms must be **explicitly accepted** before download. Acceptance is saved against the bundled terms' digest, so changed terms ask again.
- Original licenses, use policies, model cards, required attribution ("Built with Llama"), and provenance are kept with the installed weights, and existing installations receive them too. Bundled license documents are hash-checked when the catalog loads and ship byte-for-byte.
- Installed notices are rewritten only when their bytes change; missing or damaged documents, and their permissions, are repaired.
- A model's own license and incorporated policies still govern its use. MaxModel preserves them and requires acknowledgement; it never replaces a publisher's terms with a blanket open-source license.

The notices live in `Sources/HearthCore/model-notices/<model id>/`.

## Knowledge cutoffs

**About this model** shows the **knowledge cutoff** with the publisher source, review date, and a freshness explanation; the chat footer and comparisons keep a quiet reminder.

- The reviewed sources establish dates for 22 configurations; the other 53 say **Not documented**. Approximate dates stay approximate.
- A cutoff isn't a release date or proof of factual accuracy, and dates a model claims in chat are not treated as evidence.
- Details are bundled for offline use; opening a source link is an explicit browser action.
- Assistant instructions include the current local date, the model's actual capabilities and name, and its documented cutoff (or say it's unknown). That doesn't supply newer knowledge.

Maintainers review `scripts/model-knowledge.json`; the catalog builder carries it forward without inferring dates from model names or related models.

## What MaxModel doesn't do

No fine-tuning, arbitrary model import, automatic multi-model routing, web search, document indexing across files, tool execution or actions on the Mac, phone app, or Windows/Linux build. Recommendations are not a claim that the smartest model has been independently established.

## Upstream components

- [llama.cpp](https://github.com/ggml-org/llama.cpp) (MIT), the bundled inference engine, pinned to build `b11146`. Its license ships in the engine directory.
- [Sparkle](https://sparkle-project.org) (MIT), for signed app updates.
- [Swift Markdown](https://github.com/swiftlang/swift-markdown) (Apache-2.0 with the Swift runtime exception) and [swift-cmark](https://github.com/swiftlang/swift-cmark), for rendering replies.
- Models from their original publishers, including [Qwen](https://huggingface.co/Qwen) (Apache-2.0 for the selected entries), [SmolLM3](https://huggingface.co/HuggingFaceTB/SmolLM3-3B) and [Ministral 3](https://huggingface.co/mistralai/Ministral-3-3B-Instruct-2512) (Apache-2.0), and [Phi-4 mini](https://huggingface.co/microsoft/Phi-4-mini-instruct) (MIT). Each catalog entry links its publisher and exact license.
- Compressed GGUF files distributed by the publishers, [ggml-org](https://huggingface.co/ggml-org), [Unsloth](https://huggingface.co/unsloth), and [bartowski](https://huggingface.co/bartowski). Immutable revisions and digests are in `Sources/HearthCore/catalog.json`.

All third-party notices are included in the app. MaxModel is independent of these projects and not affiliated with their authors.
