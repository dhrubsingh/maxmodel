# Security policy

MaxModel runs AI models locally, downloads large files, and updates itself, so security reports are taken seriously.

## Reporting a vulnerability

**Please don't open a public issue.** Report privately through GitHub:

1. Go to the repository's [**Security** tab](https://github.com/dhrubsingh/maxmodel/security).
2. Click **Report a vulnerability**.
3. Describe the problem, how to reproduce it, the MaxModel and macOS versions, and the impact you expect.

You'll get an acknowledgement within a few days. Once a fix ships, you'll be credited in the release notes unless you'd rather not be.

## Supported versions

Only the latest release receives fixes. MaxModel updates itself, so most users move to a fix quickly.

## What's in scope

Especially welcome:

- Anything that sends conversations, attachments, or other local data off the Mac
- Ways to install a model file, image encoder, or app update that doesn't match its pinned hash or signature
- Reaching the local inference engine from another user or another machine
- Code execution through model files, attachments, Markdown in replies, or downloads
- Weaknesses in how the app is signed, packaged, or updated

Out of scope:

- Wrong, harmful, or misleading model answers. Those are model limitations, but feel free to open a regular issue.
- Vulnerabilities in llama.cpp, Sparkle, or macOS itself. Report those upstream, and tell us if MaxModel needs to update.
- Attacks that require an already-compromised Mac or physical access to an unlocked one.

How MaxModel protects data and verifies downloads is described in [Privacy and security](docs/privacy-and-security.md).
