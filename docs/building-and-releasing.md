# Building and releasing

- [Requirements](#requirements)
- [Running from source](#running-from-source)
- [Building the app](#building-the-app)
- [Signing and notarization](#signing-and-notarization)
- [How packaging works](#how-packaging-works)
- [Releases, website, and updates](#releases-website-and-updates)
- [Refreshing the catalog](#refreshing-the-catalog)

## Requirements

- macOS 14 or later. Apple Silicon is recommended for development; it's where everything is runtime-tested.
- Xcode or the Apple command-line tools with **Swift 6.1 or newer**.
- **Python 3** for the engine fetcher, packaging, and catalog maintenance. No third-party Python packages are needed.

## Running from source

```sh
git clone https://github.com/dhrubsingh/maxmodel.git
cd maxmodel
python3 scripts/fetch-engine.py        # downloads and verifies llama.cpp b11146 into vendor/llama/
MAXMODEL_DATA_DIR="$PWD/.test-data/dev" swift run Hearth
```

`MAXMODEL_DATA_DIR` keeps a development copy's chats and models separate from your installed MaxModel. Without it, the development build shares `~/Library/Application Support/MaxModel/` with the installed app. `.test-data/` is ignored by git.

To reuse models you've already downloaded, point it at a folder whose `Models/` contains them, or copy the files and their `.verified` receipts.

Debug builds have no update feed, so Sparkle stays off.

## Building the app

```sh
bash scripts/build-app.sh             # Apple Silicon: dist/MaxModel.app and dist/MaxModel-macOS.zip
bash scripts/verify-package.sh        # extract the ZIP elsewhere and verify it

bash scripts/build-app.sh x86_64      # Intel: dist/Intel/; doesn't replace the Apple Silicon build
bash scripts/verify-package.sh dist/Intel/MaxModel-macOS-Intel.zip --static
```

The build fetches the matching engine (`vendor/llama/` or `vendor/llama-x86_64/`) if it isn't there yet. Each download contains only its own architecture. Intel builds are cross-built and statically verified (architecture, deployment targets, dependencies, notices, signature) but **not runtime-tested on Intel hardware**.

By default, builds are ad-hoc signed for local use, and Gatekeeper blocks them on other Macs.

## Signing and notarization

To produce a build anyone can open, you need a **Developer ID Application** certificate (Apple Developer Program) and a notarytool keychain profile:

```sh
xcrun notarytool store-credentials maxmodel-notary --apple-id YOU@example.com --team-id TEAMID
HEARTH_SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" \
HEARTH_NOTARY_PROFILE=maxmodel-notary bash scripts/build-app.sh
```

What the script does:

1. **Checks credentials first:** the identity must be a Developer ID Application certificate (Apple Development certificates sign but are refused by notarization), and the notary profile must work.
2. **Signs inside-out** with the hardened runtime and a secure timestamp: every engine binary, Sparkle's helpers and framework, then the app.
3. **Notarizes** the ZIP, staples the ticket, re-archives, and runs `spctl --assess`.
4. **On rejection,** prints Apple's notarization log and removes the unnotarized ZIP.

Run it once per architecture.

**Why no extra entitlements are needed:** the engine finds its libraries through `@loader_path`, not `DYLD_*` variables, and loads them under library validation when every binary shares one Team ID. A copy signed this way with an Apple Development certificate loaded a model on Metal and answered. Ad-hoc signing with the hardened runtime fails that check because ad-hoc code has no Team ID; that's expected and not a distribution problem.

## How packaging works

- **Engine.** `fetch-engine.py` pins llama.cpp `b11146` and verifies the release archive against a committed SHA-256. The build bundles and signs the runtime, its libraries, the catalog, and `hearth-engine-guardian` (`scripts/engine-guardian.c`), which keeps the engine's process ID unchanged and stops it if the app disappears.
- **Trimmed.** Packaging follows the runtime's actual dependency graph, removes unused command-line tools, and strips local and debug symbols (`scripts/optimize-package.py`). App builds compile only the app product.
- **Notices as real files.** Every original license notice ships as a real file and verifies byte-for-byte after extraction. Shared symlinks broke license reads when the app ran from an iCloud-synced folder.
- **Clean staging.** Packaging happens in a clean temporary directory so synced Desktop folders can't add Finder metadata before signing, and the ZIP is created without extended attributes. A file provider can still attach metadata to a loose `.app` on a synced Desktop afterwards; `verify-package.sh` checks the extracted archive in a clean location.
- **Sparkle.** Embedded as `Contents/Frameworks/Sparkle.framework`, thinned to the target architecture, with its XPC services and updater signed individually.
- **Verification.** `scripts/verify-bundle.py` checks that every notice and the evidence archive match the source byte-for-byte, that evidence matches the exact downloadable weights, that every binary targets macOS 14 and links only bundled or system libraries, and that Sparkle and its license are present.

## Releases, website, and updates

The download page is `site/`, published to [dhrubsingh.github.io/maxmodel](https://dhrubsingh.github.io/maxmodel/). Two workflows run it:

| Workflow | Trigger | What it does |
| --- | --- | --- |
| `.github/workflows/ci.yml` | Every pull request | Fetches the engine, runs the tests, builds and verifies the package |
| `.github/workflows/release.yml` | Every push to `main` | Releases if the version is new, then redeploys the website |

### Shipping a version (maintainers)

1. In `Resources/Info.plist`, raise **`CFBundleShortVersionString`** (for example `0.9.1`) and **`CFBundleVersion`**, an integer that must increase with every release or installed copies won't update. The workflow fails if it doesn't.
2. Merge to `main`.

The workflow then runs the tests, builds and verifies both apps, signs both ZIPs and both update feeds with the Sparkle key, publishes GitHub release `vX.Y.Z` with the ZIPs, `release.json`, `appcast.xml` (Apple Silicon), and `appcast-intel.xml`, and redeploys the site. Merges that don't change the version only redeploy the site.

The download page reads `release.json` for its version, size, and links, and shows first-launch instructions until a release is notarized. Each architecture follows its own feed, so an Intel Mac is never offered the Apple Silicon build.

### Repository secrets

| Secret | Needed for |
| --- | --- |
| `SPARKLE_PRIVATE_KEY` | **Required.** Signs updates. Its public half is `SUPublicEDKey` in `Info.plist`. |
| `DEVELOPER_ID_P12`, `DEVELOPER_ID_P12_PASSWORD` | Optional. Base64 of an exported Developer ID Application certificate (.p12) and its password. |
| `NOTARY_APPLE_ID`, `NOTARY_TEAM_ID`, `NOTARY_PASSWORD` | Optional, with the certificate. Apple ID, team ID, and an app-specific password. |

With the optional secrets, releases are Developer ID signed, notarized, and marked notarized on the site. Without them they're ad-hoc signed. Installed copies update either way, including from ad-hoc to notarized builds.

### The Sparkle key

**The key is irreplaceable:** installed copies only accept updates signed with it.

- It lives in the maintainer's login keychain under the account `maxmodel`. `generate_keys --account maxmodel -p` prints the public key.
- Keep an offline backup: run `.build/artifacts/sparkle/Sparkle/bin/generate_keys --account maxmodel -x maxmodel-sparkle.key`, store the file in a password manager, then delete it.
- Never commit it or paste it into an issue or log.

### How updates reach users

On second launch MaxModel asks once whether to check automatically. If allowed, it checks the signed feed daily; **MaxModel → Check for Updates…** checks on demand. Sparkle requires a signed feed and verifies the archive before unpacking. An end-to-end check (an installed 0.9.0 test copy updating itself to 0.9.1 from a local signed feed, and refusing a tampered download) passed before the first release.

## Refreshing the catalog

```sh
python3 scripts/update-catalog.py                    # everything
python3 scripts/update-catalog.py --only MODEL_ID    # selected entries
```

- The reviewed inventory is `scripts/catalog-specs.json`.
- Existing weight revisions are preserved; `--refresh-weights` deliberately moves them.
- The script checks original-author licensing against the quantizer's, reads architecture and memory metadata from each pinned GGUF header, finds the matching image encoder, and preserves original notices under `Sources/HearthCore/model-notices/`. Missing or inconsistent licensing blocks publication.
- `--cached` reuses fetched repository metadata.
- Review catalog and license changes before releasing. The app never runs this script or refreshes metadata remotely.

Step-by-step recipes for adding models and evidence are in [CONTRIBUTING.md](../CONTRIBUTING.md).
