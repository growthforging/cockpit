#!/bin/bash
# Build Cockpit, then replace /Applications/Cockpit.app with it and relaunch.
#
# It refuses to install an ad-hoc build over a properly signed one: macOS ties the
# Accessibility grant to the signature, and an ad-hoc copy would quietly lose it.
set -euo pipefail
cd "$(dirname "$0")/.."

./build.sh

DEST=/Applications/Cockpit.app
# The first Authority line names the signing identity; an ad-hoc signature has none.
signer() { codesign -dvv "$1" 2>&1 | awk -F= '/^Authority=/ && !seen { print $2; seen = 1 }'; }
NEW=$(signer Cockpit.app)
OLD=$( [ -d "$DEST" ] && signer "$DEST" || true )

if [ -z "$NEW" ] && [ -n "$OLD" ]; then
    echo "✗ Not installing: this build is signed ad-hoc and the installed copy is signed by \"$OLD\"." >&2
    echo "  Installing it would switch off Cockpit's Accessibility permission. Fix signing first (see build.sh's output above)." >&2
    exit 1
fi

echo "▸ Installing to $DEST…"
# Stage beside the old copy and swap by renaming, so a refusal half way never leaves
# you without Cockpit. macOS can refuse a terminal permission to change apps in
# /Applications (App Management, under Privacy & Security).
STAGE="/Applications/Cockpit-new.app"
BACKUP="/Applications/Cockpit-old.app"
rm -rf "$STAGE" "$BACKUP" 2>/dev/null || true
ditto Cockpit.app "$STAGE"

osascript -e 'quit app id "com.growthforging.cockpit"' >/dev/null 2>&1 || true
for _ in 1 2 3 4 5 6 7 8 9 10; do pgrep -xq Cockpit || break; sleep 0.3; done
pkill -x Cockpit 2>/dev/null || true

if [ -e "$DEST" ] && ! mv "$DEST" "$BACKUP" 2>/dev/null; then
    rm -rf "$STAGE" 2>/dev/null || true
    open "$DEST"
    echo "✗ macOS would not let this terminal replace $DEST, so the old copy is still there and running." >&2
    echo "  Allow your terminal under Privacy & Security → App Management, or drag Cockpit.app from $(pwd) into Applications in Finder." >&2
    exit 1
fi
mv "$STAGE" "$DEST"
rm -rf "$BACKUP" 2>/dev/null || true
open "$DEST"
echo "✓ Installed and relaunched ($(signer "$DEST"))"
