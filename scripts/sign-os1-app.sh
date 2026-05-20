#!/bin/bash
#
# sign-os1-app.sh — Developer ID Application code signing for OS1.app.
#
# Applies the hardened runtime + secure timestamp + entitlements, signs all
# nested frameworks/helpers first (--deep equivalent via explicit traversal),
# then signs the outer bundle. Verifies with --deep --strict afterward.
#
# Required env:
#   OS1_SIGNING_IDENTITY  Full identity string, e.g.
#                         "Developer ID Application: Jane Doe (ABCDE12345)"
#                         Discover via: security find-identity -v -p codesigning
#
# Flags:
#   --app PATH            Path to .app bundle (default: dist/OS1.app)
#
# Exit codes:
#   0  signed + verified
#   1  missing env / identity / app / entitlements / sign failure / verify failure
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/OS1.app"
ENTITLEMENTS="$ROOT_DIR/packaging/OS1.entitlements"

usage() {
    cat <<'USAGE'
usage: sign-os1-app.sh [--app PATH]

Required env:
  OS1_SIGNING_IDENTITY  Full Developer ID Application identity string.
                        Discover via: security find-identity -v -p codesigning
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP="$2"
            shift 2
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            usage >&2
            exit 1
            ;;
    esac
done

log() { printf '[sign-os1-app] %s\n' "$*"; }
fail() { printf '[sign-os1-app] FAIL: %s\n' "$*" >&2; exit 1; }

if [[ -z "${OS1_SIGNING_IDENTITY:-}" ]]; then
    cat >&2 <<'EOF'
[sign-os1-app] FAIL: OS1_SIGNING_IDENTITY is not set.

Remediation:
  1. List your installed code-signing identities:
       security find-identity -v -p codesigning
  2. Copy the full string in quotes, e.g.
       "Developer ID Application: Jane Doe (ABCDE12345)"
  3. Export it before re-running:
       export OS1_SIGNING_IDENTITY="Developer ID Application: Jane Doe (ABCDE12345)"

If no Developer ID Application identity is listed, see
docs/apple-credentials-setup.md to obtain and install one.
EOF
    exit 1
fi

if [[ ! -d "$APP" ]]; then
    fail "app bundle not found at: $APP"
fi

if [[ ! -f "$ENTITLEMENTS" ]]; then
    fail "entitlements plist not found at: $ENTITLEMENTS"
fi

# Confirm the identity is actually available in the keychain. We grep for the
# exact identity string. If absent, codesign will fail later with a less clear
# message — surface it now.
log "verifying identity is available in keychain…"
IDENTITIES_OUT="$(security find-identity -v -p codesigning 2>&1 || true)"
if ! grep -F -q "$OS1_SIGNING_IDENTITY" <<<"$IDENTITIES_OUT"; then
    cat >&2 <<EOF
[sign-os1-app] FAIL: identity not found in codesigning keychain:
  $OS1_SIGNING_IDENTITY

\`security find-identity -v -p codesigning\` returned:
$IDENTITIES_OUT

Remediation:
  - Check the spelling/team-id of OS1_SIGNING_IDENTITY exactly matches a line above.
  - If absent entirely, install your Developer ID Application certificate into
    the login keychain (see docs/apple-credentials-setup.md).
  - If the cert is expired, generate a new one from developer.apple.com.
EOF
    exit 1
fi

log "app:          $APP"
log "entitlements: $ENTITLEMENTS"
log "identity:     $OS1_SIGNING_IDENTITY"

# Strip extended attrs that frequently break codesign (e.g. com.apple.quarantine,
# com.apple.FinderInfo on resource forks).
log "stripping extended attributes…"
xattr -cr "$APP" 2>/dev/null || true

# Sign nested code first (frameworks, helper tools, dylibs, XPC services) from
# deepest to shallowest. We pass the entitlements file to every Mach-O so the
# hardened runtime flag is consistently applied. Apple recommends signing
# inside-out; --deep on the outer is a fallback but explicit is safer.
sign_one() {
    local target="$1"
    codesign --force \
        --options runtime \
        --timestamp \
        --entitlements "$ENTITLEMENTS" \
        --sign "$OS1_SIGNING_IDENTITY" \
        "$target"
}

log "signing nested Mach-O binaries (frameworks, dylibs, helpers)…"
# Use find -print0 / read -d '' to handle paths with spaces safely.
# We discover frameworks, .dylib, .xpc bundles, and any nested .app first.
while IFS= read -r -d '' nested; do
    log "  sign nested: ${nested#$APP/}"
    sign_one "$nested"
done < <(find "$APP/Contents" \
    \( -name "*.framework" -o -name "*.dylib" -o -name "*.xpc" -o -name "*.app" \) \
    -not -path "$APP" \
    -print0 2>/dev/null || true)

# Sign any loose executables under Contents/MacOS that aren't the main one — and
# the main executable will be re-signed when we sign the outer bundle.
while IFS= read -r -d '' exe; do
    # Skip if already a bundle we handled above.
    case "$exe" in
        *.framework/*|*.xpc/*|*.app/*) continue ;;
    esac
    log "  sign executable: ${exe#$APP/}"
    sign_one "$exe"
done < <(find "$APP/Contents/MacOS" -type f -perm +111 -print0 2>/dev/null || true)

log "signing outer bundle…"
codesign --force \
    --options runtime \
    --timestamp \
    --entitlements "$ENTITLEMENTS" \
    --sign "$OS1_SIGNING_IDENTITY" \
    "$APP"

log "verifying signature (codesign --verify --deep --strict --verbose=2)…"
if ! codesign --verify --deep --strict --verbose=2 "$APP"; then
    fail "codesign verification failed. Inspect with: codesign -dv --verbose=4 \"$APP\""
fi

log "displaying signature summary:"
codesign --display --verbose=4 "$APP" 2>&1 | sed 's/^/  /'

log "OK: $APP signed with $OS1_SIGNING_IDENTITY"
