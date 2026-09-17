#!/bin/bash
# Build Cockpit.app (release) and assemble a proper macOS .app bundle.
set -euo pipefail
trap 'status=$?; [ $status -ne 0 ] && echo "✗ build.sh failed (line $LINENO, exit $status)" >&2' ERR
cd "$(dirname "$0")"

APP="Cockpit"
BUNDLE="$APP.app"
CONFIG="${1:-release}"

echo "▸ Compiling ($CONFIG)…"
# Xcode's toolchain first. An Xcode update that hasn't had its license accepted yet
# refuses to build with a message rather than a compile error, so fall back to the
# Command Line Tools when they carry a macOS SDK, and never pretend success.
CLT=/Library/Developer/CommandLineTools
if ! OUT=$(swift build -c "$CONFIG" 2>&1); then
    if echo "$OUT" | grep -q "Xcode license" && [ -d "$CLT/SDKs" ]; then
        echo "  Xcode wants its license accepted (sudo xcodebuild -license accept); building with the Command Line Tools instead."
        OUT=$(DEVELOPER_DIR="$CLT" swift build -c "$CONFIG" 2>&1) || { echo "$OUT" | tail -40; echo "✗ Build failed" >&2; exit 1; }
    else
        echo "$OUT" | tail -40; echo "✗ Build failed" >&2; exit 1
    fi
fi
echo "$OUT" | grep -E 'error:|Build complete' | tail -5

BIN=".build/$CONFIG/$APP"
[ -f "$BIN" ] || { echo "✗ Build product not found at $BIN" >&2; exit 1; }

echo "▸ Assembling $BUNDLE…"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/$APP"
cp Info.plist "$BUNDLE/Contents/Info.plist"
[ -f "Resources/$APP.icns" ] && cp "Resources/$APP.icns" "$BUNDLE/Contents/Resources/$APP.icns"

# Sign with a real identity when one exists. macOS ties Accessibility and Keychain
# grants to the signing identity: ad-hoc signatures change on every rebuild and
# silently void the grants, an Apple Development identity stays the same.
IDENTITY="${CODESIGN_IDENTITY:-}"
if [ -z "$IDENTITY" ]; then
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"')
fi
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" --timestamp=none "$BUNDLE" 2>/dev/null; then
    echo "▸ Signed with: $IDENTITY"
else
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
    echo "▸ Signed ad-hoc (no identity available; permissions will reset on each rebuild)"
fi

echo "✓ Built $BUNDLE"
