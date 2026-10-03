#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
TARGET_ARCH="${1:-$(uname -m)}"
case "$TARGET_ARCH" in
    arm64) ENGINE_ARCH=arm64; RUNTIME=vendor/llama; SCRATCH=.build; OUTPUT=dist; ARCHIVE=MaxModel-macOS.zip ;;
    x86_64) ENGINE_ARCH=x64; RUNTIME=vendor/llama-x86_64; SCRATCH=.build/intel; OUTPUT=dist/Intel; ARCHIVE=MaxModel-macOS-Intel.zip ;;
    *) echo "Usage: bash scripts/build-app.sh [arm64|x86_64]" >&2; exit 1 ;;
esac
# Check distribution credentials before building, not after.
if [[ -n "${HEARTH_SIGN_IDENTITY:-}" ]]; then
    if ! security find-identity -v -p codesigning | grep -F -- "$HEARTH_SIGN_IDENTITY" | grep -q "Developer ID Application"; then
        echo "HEARTH_SIGN_IDENTITY must match a valid \"Developer ID Application\" certificate in your keychain. Apple Development certificates sign, but Apple will not notarize them. Available identities:" >&2
        security find-identity -v -p codesigning >&2
        exit 1
    fi
fi
if [[ -n "${HEARTH_NOTARY_PROFILE:-}" ]]; then
    if [[ -z "${HEARTH_SIGN_IDENTITY:-}" ]]; then echo "HEARTH_NOTARY_PROFILE requires HEARTH_SIGN_IDENTITY" >&2; exit 1; fi
    if ! xcrun notarytool history --keychain-profile "$HEARTH_NOTARY_PROFILE" > /dev/null; then
        echo "Notary profile \"$HEARTH_NOTARY_PROFILE\" is not usable. Create it with: xcrun notarytool store-credentials $HEARTH_NOTARY_PROFILE --apple-id YOU@example.com --team-id TEAMID" >&2
        exit 1
    fi
fi
export CLANG_MODULE_CACHE_PATH="$PWD/$SCRATCH/module-cache"
export SWIFTPM_MODULECACHE_OVERRIDE="$PWD/$SCRATCH/module-cache"
if [[ ! -x "$RUNTIME/llama-server" ]]; then
    python3 scripts/fetch-engine.py --arch "$ENGINE_ARCH" --dest "$RUNTIME"
fi
lipo "$RUNTIME/llama-server" -verify_arch "$TARGET_ARCH"
BUILD_FLAGS=(-c release --product Hearth --scratch-path "$SCRATCH" --cache-path .build/cache --disable-sandbox)
if [[ "$TARGET_ARCH" != "$(uname -m)" ]]; then BUILD_FLAGS+=(--triple "$TARGET_ARCH-apple-macosx14.0"); fi
swift build "${BUILD_FLAGS[@]}"
BIN_PATH="$(swift build "${BUILD_FLAGS[@]}" --show-bin-path)"
STAGING="$(mktemp -d /private/tmp/hearth-package.XXXXXX)"
trap 'rm -rf "$STAGING"' EXIT
APP="$STAGING/MaxModel.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/engine"
cp "$BIN_PATH/Hearth" "$APP/Contents/MacOS/MaxModel"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Each architecture follows its own update feed, so it can only be offered its own download.
if [[ "$TARGET_ARCH" == "x86_64" ]]; then
    FEED="$(/usr/libexec/PlistBuddy -c "Print :SUFeedURL" "$APP/Contents/Info.plist")"
    /usr/libexec/PlistBuddy -c "Set :SUFeedURL ${FEED%.xml}-intel.xml" "$APP/Contents/Info.plist"
fi
# Sparkle installs signed updates. Like the engine, ship only this architecture.
mkdir -p "$APP/Contents/Frameworks"
ditto "$BIN_PATH/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
while IFS= read -r -d '' item; do
    if file -b "$item" | grep -q "Mach-O universal"; then lipo "$item" -thin "$TARGET_ARCH" -output "$item"; fi
done < <(find "$APP/Contents/Frameworks/Sparkle.framework" -type f -print0)
cp -R "$RUNTIME/." "$APP/Contents/Resources/engine/"
clang -target "$TARGET_ARCH-apple-macos14.0" -O2 -Wall -Wextra scripts/engine-guardian.c -o "$APP/Contents/Resources/engine/hearth-engine-guardian"
# SwiftPM resource accessor searches next to the executable bundle and its resource directory.
cp -R "$BIN_PATH/Hearth_HearthCore.bundle" "$APP/Contents/Resources/"
mkdir -p "$APP/Contents/Resources/ThirdPartyNotices"
cp "$SCRATCH/checkouts/swift-markdown/LICENSE.txt" "$APP/Contents/Resources/ThirdPartyNotices/SwiftMarkdown-LICENSE.txt"
cp "$SCRATCH/checkouts/swift-markdown/NOTICE.txt" "$APP/Contents/Resources/ThirdPartyNotices/SwiftMarkdown-NOTICE.txt"
cp "$SCRATCH/checkouts/swift-cmark/COPYING" "$APP/Contents/Resources/ThirdPartyNotices/SwiftCmark-COPYING.txt"
cp "$SCRATCH/artifacts/sparkle/Sparkle/LICENSE" "$APP/Contents/Resources/ThirdPartyNotices/Sparkle-LICENSE.txt"
chmod u+w "$APP/Contents/Resources/ThirdPartyNotices/"*
swift scripts/make-icon.swift "$PWD/.build/MaxModel.iconset"
iconutil -c icns .build/MaxModel.iconset -o "$APP/Contents/Resources/MaxModel.icns"
python3 scripts/optimize-package.py "$APP"
# Build artifacts in Desktop folders can acquire Finder metadata that codesign rejects.
# Only clear metadata on our newly generated bundle, never on installed user applications.
xattr -cr "$APP"
# Distribution builds: HEARTH_SIGN_IDENTITY="Developer ID Application: Name (TEAMID)" and, to
# notarize, HEARTH_NOTARY_PROFILE=<profile saved with `xcrun notarytool store-credentials`>.
# Without them the build is ad-hoc signed and only opens on the Mac that built it.
if [[ -n "${HEARTH_SIGN_IDENTITY:-}" ]]; then
    # Sign nested engine binaries first (inside-out), with hardened runtime and a secure timestamp.
    while IFS= read -r -d '' item; do
        if file -b "$item" | grep -q "Mach-O"; then
            codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$item"
        fi
    done < <(find "$APP/Contents/Resources" -type f -print0)
    # Sparkle's documented order for signing outside Xcode; Downloader keeps its sandbox entitlements.
    SPARKLE="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
    codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$SPARKLE/XPCServices/Installer.xpc"
    codesign --force --options runtime --timestamp --preserve-metadata=entitlements --sign "$HEARTH_SIGN_IDENTITY" "$SPARKLE/XPCServices/Downloader.xpc"
    codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$SPARKLE/Autoupdate" "$SPARKLE/Updater.app"
    codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$APP/Contents/Frameworks/Sparkle.framework"
    codesign --force --options runtime --timestamp --sign "$HEARTH_SIGN_IDENTITY" "$APP"
else
    echo "warning: ad-hoc signature; Gatekeeper will block this app on other Macs. Set HEARTH_SIGN_IDENTITY and HEARTH_NOTARY_PROFILE for a distributable build." >&2
    codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
mkdir -p "$OUTPUT"
ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT/$ARCHIVE"
if [[ -n "${HEARTH_NOTARY_PROFILE:-}" ]]; then
    RESULT="$(xcrun notarytool submit "$OUTPUT/$ARCHIVE" --keychain-profile "$HEARTH_NOTARY_PROFILE" --wait --output-format json)" || true
    notary_field() { python3 -c 'import json, sys
try: print(json.loads(sys.stdin.read()).get(sys.argv[1], ""))
except Exception: pass' "$1" <<< "$RESULT"; }
    STATUS="$(notary_field status)"
    if [[ "$STATUS" != "Accepted" ]]; then
        SUBMISSION="$(notary_field id)"
        echo "Notarization status: ${STATUS:-no response}." >&2
        if [[ -n "$SUBMISSION" ]]; then xcrun notarytool log "$SUBMISSION" --keychain-profile "$HEARTH_NOTARY_PROFILE" >&2 || true; fi
        rm -f "$OUTPUT/$ARCHIVE"
        exit 1
    fi
    # Staple the ticket so the app also opens offline, then re-archive the stapled bundle.
    xcrun stapler staple "$APP"
    rm "$OUTPUT/$ARCHIVE"
    ditto -c -k --norsrc --noextattr --keepParent "$APP" "$OUTPUT/$ARCHIVE"
    spctl --assess --type execute --verbose "$APP"
fi
(cd "$OUTPUT" && shasum -a 256 "$ARCHIVE" > SHA256SUMS.txt)
if [[ -e "$OUTPUT/MaxModel.app.previous" ]]; then rm -rf "$OUTPUT/MaxModel.app.previous"; fi
if [[ -e "$OUTPUT/MaxModel.app" ]]; then mv "$OUTPUT/MaxModel.app" "$OUTPUT/MaxModel.app.previous"; fi
ditto --norsrc --noextattr "$APP" "$OUTPUT/MaxModel.app"
xattr -cr "$OUTPUT/MaxModel.app"
if [[ -e "$OUTPUT/MaxModel.app.previous" ]]; then rm -rf "$OUTPUT/MaxModel.app.previous"; fi
echo "Built $PWD/$OUTPUT/MaxModel.app ($TARGET_ARCH)"
