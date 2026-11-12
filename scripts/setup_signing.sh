#!/bin/bash
# Creates a self-signed code-signing identity ("Zenith Local Signing") in your login keychain, so that every
# Zenith.app you build on this Mac carries the same signature and macOS keeps its privacy permissions
# (Accessibility, Screen Recording, Automation) across rebuilds. scripts/bundle_app.sh uses it automatically.
#
# Run it once, yourself:   ./scripts/setup_signing.sh
#
# Environment:
#   ZENITH_SIGN_IDENTITY            name of the identity (default "Zenith Local Signing")
#   ZENITH_SIGN_KEYCHAIN            keychain file to put it in (default: your login keychain)
#   ZENITH_SIGN_KEYCHAIN_PASSWORD   only for a separate test keychain given in ZENITH_SIGN_KEYCHAIN: unlocks it and
#                                   lets codesign use the key without a dialog. Refused for the login keychain.
#
# It does not add trust settings, does not touch any keychain other than the target, and creates nothing if the
# identity already exists.
set -euo pipefail

IDENTITY="${ZENITH_SIGN_IDENTITY:-Zenith Local Signing}"
OPENSSL=/usr/bin/openssl   # LibreSSL: its .p12 files import with `security`; a Homebrew OpenSSL 3 one may not.

fail() { echo "error: $*" >&2; exit 1; }

for tool in "$OPENSSL" /usr/bin/security /usr/bin/codesign; do
    [ -x "$tool" ] || fail "$tool is missing; it ships with macOS, so this Mac's install looks damaged."
done
[ "$IDENTITY" != "-" ] || fail "ZENITH_SIGN_IDENTITY=\"-\" means ad-hoc signing; there is nothing to set up."

LOGIN_KEYCHAIN="$(/usr/bin/security login-keychain | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
KEYCHAIN="${ZENITH_SIGN_KEYCHAIN:-$LOGIN_KEYCHAIN}"
[ -n "$KEYCHAIN" ] || fail "could not find your login keychain; set ZENITH_SIGN_KEYCHAIN to a keychain file."
[ -f "$KEYCHAIN" ] || fail "keychain \"$KEYCHAIN\" does not exist."

KEYCHAIN_PASSWORD="${ZENITH_SIGN_KEYCHAIN_PASSWORD:-}"
if [ -n "$KEYCHAIN_PASSWORD" ] && [ "$KEYCHAIN" -ef "$LOGIN_KEYCHAIN" ]; then
    fail "ZENITH_SIGN_KEYCHAIN_PASSWORD is only for a separate test keychain; this script never takes your login password."
fi

# `find-identity -v` hides untrusted identities, and a self-signed one is untrusted, so list without -v.
if /usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$IDENTITY\""; then
    echo "The signing identity \"$IDENTITY\" already exists in $KEYCHAIN. Nothing was changed."
    exit 0
fi
if /usr/bin/security find-certificate -c "$IDENTITY" "$KEYCHAIN" >/dev/null 2>&1; then
    fail "$KEYCHAIN has a certificate named like \"$IDENTITY\" but no private key for it, so it cannot sign.
Remove it in Keychain Access (search \"$IDENTITY\") and run this script again."
fi

umask 077
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/zenith-signing.XXXXXXXX")"
cleanup() { rm -rf "$WORK_DIR"; }
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM HUP

cat > "$WORK_DIR/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
basicConstraints = critical,CA:false
subjectKeyIdentifier = hash
EOF

echo "==> Creating a key and a self-signed certificate \"$IDENTITY\" (valid 10 years)..."
"$OPENSSL" req -x509 -newkey rsa:2048 -nodes -sha256 -days 3650 \
    -keyout "$WORK_DIR/key.pem" -out "$WORK_DIR/cert.pem" -config "$WORK_DIR/cert.cnf" 2>/dev/null \
    || fail "openssl could not create the certificate."

# The .p12 only carries the key into the keychain and is deleted right after, so its passphrase is random and unseen.
P12_PASS="$("$OPENSSL" rand -hex 24)"
"$OPENSSL" pkcs12 -export -inkey "$WORK_DIR/key.pem" -in "$WORK_DIR/cert.pem" -name "$IDENTITY" \
    -out "$WORK_DIR/identity.p12" -passout "pass:$P12_PASS" \
    || fail "openssl could not package the key and certificate."

if [ -n "$KEYCHAIN_PASSWORD" ]; then
    /usr/bin/security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN" || fail "could not unlock $KEYCHAIN."
fi

echo "==> Importing it into $KEYCHAIN..."
/usr/bin/security import "$WORK_DIR/identity.p12" -f pkcs12 -k "$KEYCHAIN" -P "$P12_PASS" -T /usr/bin/codesign >/dev/null \
    || fail "the keychain refused the import (is it locked?). Nothing was added."

if [ -n "$KEYCHAIN_PASSWORD" ]; then
    # Test keychains only: let codesign use the key without the access dialog.
    /usr/bin/security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null \
        || fail "could not allow codesign to use the key in $KEYCHAIN."
fi

/usr/bin/security find-identity -p codesigning "$KEYCHAIN" | grep -qF "\"$IDENTITY\"" \
    || fail "the import finished but \"$IDENTITY\" is not usable for code signing."

cat <<EOF

Done. "$IDENTITY" is now in $KEYCHAIN.
The key and certificate files used to make it have been deleted; the only copy is in that keychain.
No trust settings were added: signing does not need them, so the identity shows as "not trusted"; that is expected.

What happens next:
  - ./scripts/bundle_app.sh now signs Zenith.app with "$IDENTITY" instead of ad hoc.
  - The first time codesign uses the key, macOS asks whether codesign may use "$IDENTITY" from your keychain.
    Enter your login password and choose "Always Allow", or it asks on every build.
  - The first Zenith.app signed this way is a new app to macOS, so it asks for Accessibility, Screen Recording and
    Automation ONE more time (remove the old Zenith entries in System Settings > Privacy & Security if they linger).
    After that the permissions stay across rebuilds.

Limits:
  - The identity exists only in this Mac's keychain. On a new Mac, or if the keychain is erased, run this script
    again; macOS will then ask for the permissions once more.
  - To back it up: Keychain Access > login > My Certificates > "$IDENTITY" > File > Export Items... (.p12),
    and import that file on the other Mac.
  - To remove it: Keychain Access > My Certificates > "$IDENTITY" > Delete (removes the key too), or
    security delete-identity -c "$IDENTITY" "$KEYCHAIN". bundle_app.sh then goes back to ad-hoc signing.
  - This does NOT make Zenith pass Gatekeeper on other people's Macs. That needs a paid Apple Developer ID
    certificate and notarization; a DMG you share still opens with the "unidentified developer" warning.
EOF
