#!/bin/bash
#
# notarize-os1-app.sh — Submit OS1.app to Apple notary service, wait for
# acceptance, staple the ticket, and re-zip the resulting bundle.
#
# Required env / setup:
#   OS1_NOTARY_PROFILE   Name of a keychain credentials profile created via
#                        `xcrun notarytool store-credentials`. Default: OS1_NOTARY.
#
# To create the profile (one-time):
#   xcrun notarytool store-credentials OS1_NOTARY \
#     --apple-id "you@example.com" \
#     --team-id "ABCDE12345" \
#     --password "app-specific-password"
#
# Flags:
#   --app PATH            Path to .app bundle (default: dist/OS1.app)
#
# Exit codes:
#   0  notarized + stapled + re-zipped
#   1  missing profile / submission failed / staple failed
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/OS1.app"
OS1_NOTARY_PROFILE="${OS1_NOTARY_PROFILE:-OS1_NOTARY}"

usage() {
    cat <<'USAGE'
usage: notarize-os1-app.sh [--app PATH]

Env:
  OS1_NOTARY_PROFILE  Keychain notarytool profile (default: OS1_NOTARY)

One-time setup if profile is missing:
  xcrun notarytool store-credentials OS1_NOTARY \
    --apple-id "you@example.com" \
    --team-id "ABCDE12345" \
    --password "app-specific-password"
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

log() { printf '[notarize-os1-app] %s\n' "$*"; }
fail() { printf '[notarize-os1-app] FAIL: %s\n' "$*" >&2; exit 1; }

if [[ ! -d "$APP" ]]; then
    fail "app bundle not found at: $APP"
fi

ZIP="${APP}.zip"

# Verify the notarytool profile exists. There's no direct list command, but
# attempting `history` against it returns a credential error if it's missing.
log "verifying keychain profile '$OS1_NOTARY_PROFILE' is present…"
if ! xcrun notarytool history --keychain-profile "$OS1_NOTARY_PROFILE" --output-format plist >/dev/null 2>&1; then
    cat >&2 <<EOF
[notarize-os1-app] FAIL: notarytool profile '$OS1_NOTARY_PROFILE' is missing or invalid.

Remediation — create it once with your Apple ID + team ID + app-specific password:

  xcrun notarytool store-credentials $OS1_NOTARY_PROFILE \\
    --apple-id "you@example.com" \\
    --team-id "ABCDE12345" \\
    --password "app-specific-password"

App-specific passwords are generated at https://appleid.apple.com/account/manage
(Sign-In and Security → App-Specific Passwords). See docs/apple-credentials-setup.md.
EOF
    exit 1
fi

log "creating zip for submission: $ZIP"
rm -f "$ZIP"
# ditto with --keepParent preserves the .app wrapper directory and extended
# attributes — required so the notary service sees the bundle structure.
ditto -c -k --keepParent "$APP" "$ZIP"

log "submitting to Apple notary service (this can take several minutes)…"
SUBMIT_OUT="$(mktemp -t os1-notarize-XXXXXX)"
trap 'rm -f "$SUBMIT_OUT"' EXIT

set +e
xcrun notarytool submit "$ZIP" \
    --keychain-profile "$OS1_NOTARY_PROFILE" \
    --wait \
    --output-format plist \
    > "$SUBMIT_OUT" 2>&1
SUBMIT_RC=$?
set -e

# Print the raw output for transparency.
cat "$SUBMIT_OUT" | sed 's/^/  /'

# Extract submission id + status. The plist contains an `id` and `status` key.
SUBMISSION_ID="$(/usr/libexec/PlistBuddy -c 'Print :id' "$SUBMIT_OUT" 2>/dev/null || true)"
STATUS="$(/usr/libexec/PlistBuddy -c 'Print :status' "$SUBMIT_OUT" 2>/dev/null || true)"

log "submission id: ${SUBMISSION_ID:-<unknown>}"
log "status:        ${STATUS:-<unknown>}"

if [[ "$SUBMIT_RC" -ne 0 || "$STATUS" != "Accepted" ]]; then
    log "submission did not reach Accepted state — fetching log…"
    if [[ -n "${SUBMISSION_ID:-}" ]]; then
        xcrun notarytool log "$SUBMISSION_ID" \
            --keychain-profile "$OS1_NOTARY_PROFILE" 2>&1 | sed 's/^/  /' || true
    else
        log "no submission id available; cannot fetch log."
    fi
    fail "notarization failed (status=$STATUS, rc=$SUBMIT_RC). See log above for the rejection reasons; fix and re-run."
fi

log "stapling notarization ticket to bundle…"
if ! xcrun stapler staple "$APP"; then
    fail "stapler staple failed. The notary accepted the submission but the ticket could not be attached. Run \`xcrun stapler staple -v $APP\` for details."
fi

log "validating staple…"
if ! xcrun stapler validate "$APP"; then
    fail "stapler validate failed after staple — bundle is not properly notarized."
fi

log "re-zipping stapled bundle: $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

log "OK: $APP notarized + stapled. Zip at: $ZIP"
