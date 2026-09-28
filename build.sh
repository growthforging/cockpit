#!/bin/bash
# Build Cockpit.app (release) and assemble a proper macOS .app bundle.
set -euo pipefail
trap 'status=$?; [ $status -ne 0 ] && echo "✗ build.sh failed (line $LINENO, exit $status)" >&2' ERR
cd "$(dirname "$0")"

APP="Cockpit"
BUNDLE="$APP.app"
CONFIG="${1:-release}"

echo "▸ Compiling ($CONFIG)…"
BIN=".build/$CONFIG/$APP"
CLT=/Library/Developer/CommandLineTools

# A macOS update can leave the toolchain half-updated: an SDK built for a newer
# compiler than the one installed, or a swift-package binary that no longer links.
# Those are not compile errors in this code, and the compiler itself usually still
# works against an older SDK.
toolchain_broken() {
    echo "$1" | grep -qE "dyld\[|Symbol not found|not supported by the compiler|failed to build module 'Swift'"
}

# Build without SwiftPM, trying each installed SDK until one matches the compiler. Each
# attempt's compiler output is kept in .build/direct/<sdk>.log. An SDK made for another
# compiler is skipped; a genuine compile error stops the build and is shown.
direct_build() {
    local out=".build/direct/$APP" sdk name log failed="" real seen=" "
    mkdir -p .build/direct
    for sdk in $(ls -dr "$CLT"/SDKs/MacOSX[0-9]*.sdk "$(xcode-select -p 2>/dev/null)"/Platforms/MacOSX.platform/Developer/SDKs/MacOSX[0-9]*.sdk 2>/dev/null); do
        # MacOSX26.sdk and MacOSX26.5.sdk are one SDK, so each is tried once. Xcode's only
        # versioned name is itself an alias, which is why this follows links, not skips them.
        real=$(cd "$sdk" 2>/dev/null && pwd -P) || continue
        case "$seen" in *" $real "*) continue ;; esac
        seen="$seen$real "
        name=$(basename "$sdk" .sdk)
        log=".build/direct/${name}.log"
        printf '  %s: ' "$name"
        if xcrun swiftc -O -parse-as-library -swift-version 5 -target "$(uname -m)-apple-macos14.0" \
             -sdk "$sdk" Sources/"$APP"/*.swift -o "$out" >"$log" 2>&1; then
            echo "compiled"
            BIN="$out"
            return 0
        elif toolchain_broken "$(cat "$log")"; then
            echo "made for a different compiler, trying the next one"
        else
            echo "failed"
            failed="$log"
            break
        fi
    done
    if [ -n "$failed" ]; then
        if grep -q "error:" "$failed"; then
            grep "error:" "$failed" | head -20 >&2 || true
        else
            tail -40 "$failed" >&2
        fi
        echo "✗ Build failed (full compiler output in $failed)" >&2
        exit 1
    fi
    return 1
}

# Xcode's toolchain first. An Xcode update that hasn't had its license accepted yet
# refuses to build with a message rather than a compile error, so fall back to the
# Command Line Tools when they carry a macOS SDK, and never pretend success.
BUILT=0
if OUT=$(swift build -c "$CONFIG" 2>&1); then
    BUILT=1
elif echo "$OUT" | grep -q "Xcode license" && [ -d "$CLT/SDKs" ]; then
    echo "  Xcode wants its license accepted (sudo xcodebuild -license accept); building with the Command Line Tools instead."
    OUT=$(DEVELOPER_DIR="$CLT" swift build -c "$CONFIG" 2>&1) && BUILT=1 || true
fi

if [ "$BUILT" = 1 ]; then
    echo "$OUT" | grep -E 'error:|Build complete' | tail -5
elif toolchain_broken "$OUT"; then
    echo "  SwiftPM does not work with this Swift install, which is normal after some macOS updates."
    echo "  Compiling with swiftc directly instead. This takes about half a minute."
    direct_build || {
        echo "✗ No installed macOS SDK matches this Swift compiler. Reinstall the Command Line Tools with: xcode-select --install" >&2
        exit 1
    }
else
    echo "$OUT" | tail -40; echo "✗ Build failed" >&2; exit 1
fi

[ -f "$BIN" ] || { echo "✗ Build product not found at $BIN" >&2; exit 1; }

echo "▸ Assembling ${BUNDLE}…"
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
    # No certificate in the Keychain is the normal case for a first-time builder and for
    # CI, and grep exiting 1 there must not abort the build under `set -e`.
    IDENTITY=$(security find-identity -v -p codesigning 2>/dev/null | grep -oE '"Apple Development: [^"]+"' | head -1 | tr -d '"' || true)
fi
# The private identity made by tools/make-signing-identity.sh, kept in its own keychain.
SIGNING_DIR="${COCKPIT_SIGNING_DIR:-$HOME/.cockpit-signing}"
SIGNING_KC="$SIGNING_DIR/cockpit-signing.keychain-db"
KEYCHAIN_ARGS=()
if [ -z "$IDENTITY" ] && [ -f "$SIGNING_KC" ] && [ -f "$SIGNING_DIR/password" ]; then
    # Only ever sign from this keychain once it is unlocked. Pointed at a locked one,
    # codesign asks for its password in a dialog, and nobody knows that password.
    if security unlock-keychain -p "$(cat "$SIGNING_DIR/password")" "$SIGNING_KC" 2>/dev/null; then
        IDENTITY="Cockpit Local Signing"
        KEYCHAIN_ARGS=(--keychain "$SIGNING_KC")
    else
        echo "  The Cockpit signing keychain no longer unlocks with its stored password."
        echo "  Run tools/make-signing-identity.sh --reset to make a fresh one."
    fi
fi
if [ -z "$IDENTITY" ]; then
    # Any other code-signing identity is just as stable across rebuilds, which is all the
    # Accessibility and Keychain grants need. A self-signed one made in Keychain Access
    # works; it is listed even while macOS does not trust it as a root.
    IDENTITY=$(security find-identity -p codesigning 2>/dev/null | grep -E '^ +[0-9]+\)' | grep -oE '"[^"]+"' | head -1 | tr -d '"' || true)
fi
if [ -n "$IDENTITY" ] && codesign --force --sign "$IDENTITY" ${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"} --timestamp=none "$BUNDLE" 2>/dev/null; then
    echo "▸ Signed with: $IDENTITY"
else
    codesign --force --sign - "$BUNDLE" >/dev/null 2>&1 || true
    echo "▸ Signed ad-hoc (no identity available; permissions will reset on each rebuild)"
    echo "  Run tools/make-signing-identity.sh once to keep your permissions across rebuilds."
fi
[ -f "$SIGNING_KC" ] && security lock-keychain "$SIGNING_KC" 2>/dev/null || true

echo "✓ Built $BUNDLE"
