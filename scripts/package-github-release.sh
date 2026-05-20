#!/bin/bash

set -euo pipefail
set +x

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$ROOT_DIR/dist/OS1.app"
ZIP_PATH="$ROOT_DIR/dist/OS1.app.zip"
SHA256_PATH="$ZIP_PATH.sha256"

create_archive() {
    rm -f "$ZIP_PATH"
    xattr -cr "$APP_PATH" 2>/dev/null || true
    ditto -c -k --norsrc --keepParent "$APP_PATH" "$ZIP_PATH"
    xattr -c "$ZIP_PATH" 2>/dev/null || true
}

write_checksum() {
    (
        # Record the bare archive name so `shasum -a 256 -c OS1.app.zip.sha256`
        # works from the directory an end user downloads both files into.
        cd "$ROOT_DIR/dist"
        shasum -a 256 "OS1.app.zip" > "$SHA256_PATH"
    )
    # Also drop a sibling symlink at the project root pointing at the dist zip
    # so the readiness gate's `shasum -c dist/OS1.app.zip.sha256` (run from
    # project root) finds the bare `OS1.app.zip` reference in the .sha256.
    ln -sf "dist/OS1.app.zip" "$ROOT_DIR/OS1.app.zip"
}

require_developer_id_signature() {
    local signature_details
    signature_details="$(codesign -dv --verbose=4 "$APP_PATH" 2>&1 || true)"

    if ! grep -q "Authority=Developer ID Application:" <<<"$signature_details"; then
        echo "error: notarization requires a Developer ID Application signature." >&2
        echo "Set OS1_CODESIGN_IDENTITY or HERMES_CODESIGN_IDENTITY to a Developer ID Application identity." >&2
        exit 1
    fi

    if ! grep -q "flags=.*runtime" <<<"$signature_details"; then
        echo "error: notarization requires hardened runtime signing." >&2
        echo "Leave OS1_CODESIGN_RUNTIME=1 when OS1_NOTARIZE=1." >&2
        exit 1
    fi
}

notarytool_auth_args() {
    # OS1_NOTARY_PROFILE is the canonical keychain-profile name shared with
    # scripts/notarize-os1-app.sh and docs/apple-credentials-setup.md.
    # OS1_NOTARY_KEYCHAIN_PROFILE is accepted for back-compat with older
    # RELEASE.md examples.
    local keychain_profile="${OS1_NOTARY_KEYCHAIN_PROFILE:-${OS1_NOTARY_PROFILE:-}}"
    if [[ -n "$keychain_profile" ]]; then
        printf '%s\0%s\0' --keychain-profile "$keychain_profile"
        if [[ -n "${OS1_NOTARY_KEYCHAIN:-}" ]]; then
            printf '%s\0%s\0' --keychain "$OS1_NOTARY_KEYCHAIN"
        fi
        return
    fi

    if [[ -n "${OS1_NOTARY_KEY:-}" && -n "${OS1_NOTARY_KEY_ID:-}" ]]; then
        printf '%s\0%s\0%s\0%s\0' --key "$OS1_NOTARY_KEY" --key-id "$OS1_NOTARY_KEY_ID"
        if [[ -n "${OS1_NOTARY_ISSUER:-}" ]]; then
            printf '%s\0%s\0' --issuer "$OS1_NOTARY_ISSUER"
        fi
        return
    fi

    echo "error: missing notarization credentials." >&2
    echo "Use OS1_NOTARY_PROFILE (keychain profile, same var as scripts/notarize-os1-app.sh), or OS1_NOTARY_KEY plus OS1_NOTARY_KEY_ID and optional OS1_NOTARY_ISSUER." >&2
    exit 1
}

notarize_and_staple() {
    local auth_args=()
    local arg

    require_developer_id_signature
    while IFS= read -r -d '' arg; do
        auth_args+=("$arg")
    done < <(notarytool_auth_args)

    create_archive
    echo "Submitting OS1.app.zip for notarization..."
    xcrun notarytool submit "$ZIP_PATH" \
        --wait \
        --timeout "${OS1_NOTARY_TIMEOUT:-30m}" \
        "${auth_args[@]}"

    echo "Stapling notarization ticket to OS1.app..."
    xcrun stapler staple "$APP_PATH"
    xcrun stapler validate "$APP_PATH"
    codesign --verify --deep --strict "$APP_PATH" >/dev/null
    spctl --assess --type execute -vvv "$APP_PATH"

    # Recreate the release archive after stapling so users download the
    # notarized bundle, not only the pre-submit archive.
    create_archive
}

"$ROOT_DIR/scripts/build-macos-app.sh"

if [[ "${OS1_NOTARIZE:-0}" == "1" ]]; then
    notarize_and_staple
else
    create_archive
fi

write_checksum

echo
echo "Release archive created:"
echo "  $ZIP_PATH"
echo "Checksum:"
echo "  $SHA256_PATH"
