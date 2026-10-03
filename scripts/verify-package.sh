#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
STAGING="$(mktemp -d /private/tmp/hearth-verify.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
ARCHIVE="${1:-dist/MaxModel-macOS.zip}"
ditto -x -k "$ARCHIVE" "$STAGING"
codesign --verify --deep --strict "$STAGING/MaxModel.app"
cmp Sources/HearthCore/catalog.json "$STAGING/MaxModel.app/Contents/Resources/Hearth_HearthCore.bundle/catalog.json"
python3 scripts/verify-bundle.py "$STAGING/MaxModel.app"
if [[ "${2:-}" != "--static" ]]; then
    "$STAGING/MaxModel.app/Contents/Resources/engine/llama-server" --version
fi
echo "PASS: portable ZIP signature, exact catalog, all original notices, and runtime dependency closure"
