#!/bin/bash
# Signs a built Zenith.app, inside out: the libraries in Contents/Frameworks and any
# extra executable in Contents/MacOS first, then the app. Called by bundle_app.sh; safe to run on a copy.
#
# Usage: scripts/sign_app.sh path/to/Zenith.app
#
# Identity:
#   ZENITH_SIGN_IDENTITY   a codesign identity (name or SHA-1); "-" forces ad-hoc signing.
#   (unset)                "Zenith Local Signing" if it exists (see scripts/setup_signing.sh), otherwise ad hoc.
#   ZENITH_SIGN_KEYCHAIN   keychain file to look in and to pass to codesign --keychain (default: the search list).
#
# A failure with the chosen identity stops the build: falling back to ad hoc would quietly make macOS forget the
# app's privacy permissions. No hardened runtime (--options runtime): there is no notarization here.
set -euo pipefail

DEFAULT_IDENTITY="Zenith Local Signing"
APP="${1:-}"

fail() { echo "error: $*" >&2; exit 1; }

[ -n "$APP" ] || fail "usage: $0 path/to/App.app"
[ -d "$APP/Contents/MacOS" ] || fail "$APP is not an app bundle."
[ -x /usr/bin/codesign ] && [ -x /usr/bin/security ] || fail "codesign or security is missing."

KEYCHAIN="${ZENITH_SIGN_KEYCHAIN:-}"
KEYCHAIN_ARGS=()
if [ -n "$KEYCHAIN" ]; then
    [ -f "$KEYCHAIN" ] || fail "ZENITH_SIGN_KEYCHAIN=$KEYCHAIN does not exist."
    KEYCHAIN_ARGS=(--keychain "$KEYCHAIN")
fi

# Prints the SHA-1 of the code-signing identity called exactly $1. `find-identity -v` hides untrusted (self-signed)
# identities, so list without it. Signing by hash also avoids codesign's "ambiguous" error for duplicate names.
find_identity_hash() {
    local listing hashes count
    if [ -n "$KEYCHAIN" ]; then
        listing="$(/usr/bin/security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null || true)"
    else
        listing="$(/usr/bin/security find-identity -p codesigning 2>/dev/null || true)"
    fi
    hashes="$(printf '%s\n' "$listing" | grep -F "\"$1\"" | awk '{print $2}' | sort -u || true)"
    count="$(printf '%s' "$hashes" | grep -c . || true)"
    if [ "$count" -gt 1 ]; then
        fail "there are $count identities called \"$1\"; delete the extras in Keychain Access so builds keep one signature."
    fi
    printf '%s' "$hashes"
}

IDENTITY_LABEL=""
if [ -n "${ZENITH_SIGN_IDENTITY:-}" ]; then
    SIGN_WITH="$ZENITH_SIGN_IDENTITY"
    IDENTITY_LABEL="$ZENITH_SIGN_IDENTITY"
else
    SIGN_WITH="$(find_identity_hash "$DEFAULT_IDENTITY")"
    if [ -n "$SIGN_WITH" ]; then
        IDENTITY_LABEL="$DEFAULT_IDENTITY"
    else
        SIGN_WITH="-"
    fi
fi

if [ "$SIGN_WITH" = "-" ]; then
    echo "==> Signing $(basename "$APP") ad hoc"
    if [ -z "${ZENITH_SIGN_IDENTITY:-}" ]; then
        echo "    (macOS asks for its permissions again after every ad-hoc rebuild; run scripts/setup_signing.sh once to keep them)"
    fi
else
    echo "==> Signing $(basename "$APP") with \"$IDENTITY_LABEL\" ($SIGN_WITH)"
fi

BUNDLE_ID="$(/usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" "$APP/Contents/Info.plist" 2>/dev/null)" \
    || fail "$APP/Contents/Info.plist has no CFBundleIdentifier."
MAIN_EXECUTABLE="$(/usr/libexec/PlistBuddy -c "Print :CFBundleExecutable" "$APP/Contents/Info.plist" 2>/dev/null)" \
    || fail "$APP/Contents/Info.plist has no CFBundleExecutable."

sign() {
    # --timestamp=none: a self-signed signature gets no Apple timestamp, and asking for one needs the network.
    /usr/bin/codesign --force --timestamp=none "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" --sign "$SIGN_WITH" "$@" \
        || fail "codesign could not sign ${*: -1} with \"${IDENTITY_LABEL:-ad hoc}\" (was access to the key denied?).
Nothing fell back to ad-hoc signing. Fix the cause and build again, or set ZENITH_SIGN_IDENTITY=- to sign ad hoc."
}

# Nested code first. The Now Playing adapter must be signed: perl refuses to load it otherwise.
shopt -s nullglob
for lib in "$APP"/Contents/Frameworks/*.dylib; do
    sign --identifier "$BUNDLE_ID.$(basename "$lib" .dylib)" "$lib"
    /usr/bin/codesign --verify --strict "$lib" || fail "$lib does not verify after signing."
done
# Extra executables beside the main one, if a bundle ever carries any.
for exe in "$APP"/Contents/MacOS/*; do
    [ -f "$exe" ] && [ "$(basename "$exe")" != "$MAIN_EXECUTABLE" ] || continue
    sign --identifier "$BUNDLE_ID.$(basename "$exe")" "$exe"
done
shopt -u nullglob

sign "$APP"
/usr/bin/codesign --verify --deep --strict "$APP" || fail "$APP does not verify after signing."
