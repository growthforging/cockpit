#!/bin/bash
# Make a private code-signing identity for building Cockpit, once.
#
# macOS ties the Accessibility grant (wheel flip, paste) to an app's signature. Ad-hoc
# signatures change on every build, so without a stable identity you re-grant after
# each rebuild. This creates one that stays the same from build to build, and build.sh
# picks it up automatically.
#
# It lives in its own keychain file under ~/.cockpit-signing, never in your login
# keychain, and needs none of your passwords. Nothing about it is trusted system-wide:
# it signs your own local build and does nothing else.
set -euo pipefail
trap 'echo "✗ make-signing-identity.sh failed at line $LINENO" >&2' ERR

DIR="${COCKPIT_SIGNING_DIR:-$HOME/.cockpit-signing}"
KC="$DIR/cockpit-signing.keychain-db"
NAME="Cockpit Local Signing"

if [ -f "$KC" ]; then
    echo "Already set up at $KC"
    exit 0
fi

OPENSSL=/opt/homebrew/opt/openssl@3/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=/usr/local/opt/openssl@3/bin/openssl
[ -x "$OPENSSL" ] || OPENSSL=openssl

umask 077
mkdir -p "$DIR"
chmod 700 "$DIR"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# A random passphrase for this keychain file alone, readable only by you.
PW=$("$OPENSSL" rand -hex 24)
printf '%s' "$PW" > "$DIR/password"

"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -days 3650 \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
    -addext "basicConstraints=critical,CA:false" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" 2>/dev/null

# macOS cannot read the AES-based PKCS#12 that OpenSSL 3 writes by default.
PBE=(-certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1)
"$OPENSSL" pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:"$PW" "${PBE[@]}" 2>/dev/null \
  || "$OPENSSL" pkcs12 -export -legacy -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:"$PW" 2>/dev/null

# create-keychain adds the new file to your keychain search list. Put the list back
# exactly as it was, so no other app ever stumbles on it locked and asks for a password.
ORIGINAL=()
while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line#\"}"
    line="${line%\"}"
    [ -n "$line" ] && ORIGINAL+=("$line")
done < <(security list-keychains -d user)

security create-keychain -p "$PW" "$KC"
security list-keychains -d user -s "${ORIGINAL[@]}"
security set-keychain-settings "$KC"
security unlock-keychain -p "$PW" "$KC"
security import "$TMP/identity.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
# Let codesign use the key without ever showing a dialog.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PW" "$KC" >/dev/null
security lock-keychain "$KC"

echo "Created \"$NAME\" in $KC"
echo "build.sh will sign with it from now on. Grant Accessibility once more after the next build, and it holds."
