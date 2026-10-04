# Privacy and security

MaxModel has no accounts, no analytics, and no cloud processing. Conversations, attachments, and benchmarks never leave the Mac.

To report a vulnerability, see [SECURITY.md](../SECURITY.md).

- [What touches the network](#what-touches-the-network)
- [What's stored, and where](#whats-stored-and-where)
- [The local engine](#the-local-engine)
- [Downloads](#downloads)
- [Displaying replies](#displaying-replies)
- [The app itself](#the-app-itself)
- [The assistant](#the-assistant)

## What touches the network

| Connection | When | What is sent |
| --- | --- | --- |
| Hugging Face and its HTTPS CDN | Only when you explicitly download a model or image support | A request for a pinned, public file |
| GitHub Pages (update feed) | Daily if you allow automatic checks on second launch, or when you choose **MaxModel → Check for Updates…** | A request for the signed `appcast.xml`. No system profile, chat text, or model information. |
| Links you click (sources, licenses) | Only when you click them | Opens your browser |

The app has no remote inference URL or analytics code. The catalog and the inference engine are bundled. If you decline automatic update checks, MaxModel never checks on its own.

## What's stored, and where

Everything lives in `~/Library/Application Support/MaxModel/`. Data from earlier versions, stored in `Hearth/`, moves there on first launch.

```text
~/Library/Application Support/MaxModel/
├── Models/              # .gguf weights and image encoders (.mmproj.gguf), partial downloads,
│                        # integrity receipts, and .notices directories with licenses
├── Attachments/         # downscaled images, thumbnails, and extracted text, named by attachment ID
└── conversations.json   # chats, drafts (including unsent attachments), selected model, benchmarks,
                         # profiles, preferences, download lock, license acceptances
```

- **Owner-only permissions** on the folder (0700) and its files (0600). The folder is excluded from automatic backup.
- **Chats are plaintext** on disk. FileVault and device security still matter; third-party backups and your own exports are outside the app's control.
- **Saves are atomic and run off the main thread.** If saved state can't be read, it's set aside as a recovery copy instead of being overwritten.
- **Attachments keep no originals,** only the downscaled image, thumbnail, and extracted text. Removing a chip, or deleting the last conversation that uses an attachment, deletes its files.
- **Uninstalling doesn't delete this folder.** Remove it yourself to erase everything.
- Developers can point the app at another folder with `MAXMODEL_DATA_DIR`; see [Building and releasing](building-and-releasing.md#running-from-source).

## The local engine

- The bundled llama.cpp server binds to `127.0.0.1` on an ephemeral port and requires a fresh random bearer token. The token is passed through the child process environment, not the command line.
- The engine's web UI and tools are disabled.
- It receives an allowlisted environment, so inherited cloud, proxy, and agent settings can't configure it.
- Follow-up chats can reuse the matching prompt prefix in memory. There's no disk prompt cache, and the auxiliary RAM cache is disabled; unloading the model releases its context.
- Text recognition (Apple Vision) and PDF reading (PDFKit) run on the device.
- MaxModel doesn't claim OS-wide isolation. Instead, the integration suite verifies that chat works offline inside a macOS process sandbox that blocks all non-loopback networking (`scripts/test-offline.sh`).

## Downloads

- Each file comes from a pinned repository revision with a trusted SHA-256, checked on install and again before every load. Bundled license documents are hash-checked when the catalog loads.
- Redirects are followed only to Hugging Face and its HTTPS CDN hosts.
- Downloads never run Python or repository scripts.
- Custom licenses must be accepted before download and are asked again if the terms change. MaxModel preserves each publisher's license and use policy; it never replaces them with a blanket open-source license.
- The **download lock** in This Mac blocks all new downloads.

## Displaying replies

Markdown renders as native views. Remote images aren't fetched, HTML is shown as text, and only an explicit click on an HTTP(S) link opens a browser. No web view or JavaScript is involved.

## The app itself

- **Hardened runtime with library validation:** the app loads only code signed by the same team, meaning the bundled engine, its libraries, and Sparkle.
- **Signed updates:** Sparkle requires a signed feed and verifies each update against the app's built-in EdDSA public key before unpacking it. Nothing installs without passing both checks. The private key never enters the repository.
- **Notarization:** releases are notarized when the maintainer's Developer ID credentials are configured. Until then, macOS asks you to approve the first launch.
- **Engine provenance:** `scripts/fetch-engine.py` downloads llama.cpp's official build `b11146` for the Mac's architecture and refuses any archive that doesn't match its pinned SHA-256. The tag and digest travel with the app in the engine's `version.json`.

## The assistant

The model can't browse, open files on its own, see the screen, or take actions on the Mac. It works only with what you type or attach. Answers can be wrong, and models may not know recent events; see [knowledge cutoffs](models-and-licenses.md#knowledge-cutoffs).
