#!/bin/bash
# Build Cockpit.app (release) and assemble a proper macOS .app bundle.
set -euo pipefail
cd "$(dirname "$0")"

APP="Cockpit"
BUNDLE="$APP.app"
CONFIG="${1:-release}"

echo "▸ Compiling ($CONFIG)…"
swift build -c "$CONFIG" 2>&1 | grep -vE '^\s*$' | tail -40

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
if [ -n "$IDENTITY" ] && codesign --force --deep --sign "$IDENTITY" --timestamp=none "$BUNDLE" 2>/dev/null; then
    echo "▸ Signed with: $IDENTITY"
else
    codesign --force --deep --sign - "$BUNDLE" >/dev/null 2>&1 || true
    echo "▸ Signed ad-hoc (no identity available; permissions will reset on each rebuild)"
fi

echo "✓ Built $BUNDLE"
