#!/bin/bash
#
# release-archive-verify.sh — post-build verification gate for OS1 release.
#
# Confirms the shipping artifacts are properly signed, hardened, notarized,
# stapled, and that the published checksum matches the zip. Intended as the
# final gate before publishing dist/OS1.app.zip to GitHub Releases.
#
# Flags:
#   --app PATH            Path to .app bundle (default: dist/OS1.app)
#
# Exit codes:
#   0  all critical checks PASS
#   1  any critical check FAILED
#
# Each check prints one of:
#   OK   <name>
#   WARN <name>: <details> (non-blocking)
#   FAIL <name>: <details> (blocks release)
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$ROOT_DIR/dist/OS1.app"
RELEASE_MODE="${OS1_RELEASE_MODE:-adhoc}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --app)
            APP="$2"
            shift 2
            ;;
        --mode)
            RELEASE_MODE="$2"
            shift 2
            ;;
        -h|--help)
            cat <<'USAGE'
usage: release-archive-verify.sh [--app PATH] [--mode adhoc|developer-id]

Modes:
  adhoc          (default) Distribution is intentionally ad-hoc signed.
                 Developer ID / hardened-runtime / notarization checks are
                 downgraded to WARN. End-users right-click → Open or run
                 `xattr -dr com.apple.quarantine OS1.app` to bypass Gatekeeper.
  developer-id   Public-distribution mode: requires Developer ID Application
                 signature, --options runtime, secure timestamp, notarization
                 ticket, and Gatekeeper acceptance. Any miss is FAIL.

The mode also reads from OS1_RELEASE_MODE if --mode is not passed.
USAGE
            exit 0
            ;;
        *)
            echo "error: unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

case "$RELEASE_MODE" in
    adhoc|developer-id) ;;
    *)
        echo "error: --mode must be 'adhoc' or 'developer-id' (got: $RELEASE_MODE)" >&2
        exit 1
        ;;
esac

ZIP="${APP}.zip"
SHA256_FILE="${ZIP}.sha256"

PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

ok()   { printf 'OK   %s\n'   "$*"; PASS_COUNT=$((PASS_COUNT+1)); }
warn() { printf 'WARN %s\n'   "$*"; WARN_COUNT=$((WARN_COUNT+1)); }
crit() { printf 'FAIL %s\n'   "$*"; FAIL_COUNT=$((FAIL_COUNT+1)); }

printf '== OS1 release archive verification ==\n'
printf 'app: %s\n' "$APP"
printf 'zip: %s\n' "$ZIP"
printf 'mode: %s\n' "$RELEASE_MODE"
printf '\n'

# In adhoc mode the Developer ID / hardened-runtime / notarization checks are
# expected to miss; surface them as WARN instead of FAIL so the gate exits 0
# for the ad-hoc distribution path the user has selected.
crit_or_warn() {
    if [[ "$RELEASE_MODE" == "adhoc" ]]; then
        warn "$@ (ad-hoc mode: expected miss; users right-click → Open or run xattr -dr com.apple.quarantine)"
    else
        crit "$@"
    fi
}

# ---- 1. App bundle present
if [[ ! -d "$APP" ]]; then
    crit "app-bundle-present: $APP not found. Build with scripts/build-macos-app.sh."
    # Cannot continue meaningful checks without the bundle; jump to summary.
    printf '\n-- Summary --\nPASS=%d  WARN=%d  FAIL=%d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"
    exit 1
fi
ok "app-bundle-present"

# ---- 2. Zip present + checksum matches
if [[ ! -f "$ZIP" ]]; then
    crit "zip-present: $ZIP not found. Run scripts/package-github-release.sh."
elif [[ ! -f "$SHA256_FILE" ]]; then
    crit "sha256-present: $SHA256_FILE missing. Regenerate with shasum -a 256."
else
    EXPECTED="$(awk '{print $1}' "$SHA256_FILE")"
    ACTUAL="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
    if [[ "$EXPECTED" == "$ACTUAL" ]]; then
        ok "sha256-match ($ACTUAL)"
    else
        crit "sha256-match: published=$EXPECTED actual=$ACTUAL — re-run package-github-release.sh to refresh the checksum."
    fi
fi

# ---- 3. codesign --verify --deep --strict
if codesign --verify --deep --strict --verbose=2 "$APP" 2>&1 | sed 's/^/  /'; then
    ok "codesign-deep-strict"
else
    crit "codesign-deep-strict: bundle signature invalid. Re-run scripts/sign-os1-app.sh."
fi

# ---- 4. Signature details: Developer ID, secure timestamp, hardened runtime
DETAILS="$(codesign --display --verbose=4 "$APP" 2>&1 || true)"
printf '%s\n' "$DETAILS" | sed 's/^/  /'

if grep -qE '^Authority=Developer ID Application:' <<<"$DETAILS"; then
    ok "authority-developer-id-application"
else
    crit_or_warn "authority-developer-id-application: bundle is ad-hoc, not Developer ID signed"
fi

if grep -qE '^Timestamp=' <<<"$DETAILS"; then
    ok "secure-timestamp"
else
    crit_or_warn "secure-timestamp: no Apple-TSA timestamp (ad-hoc has none)"
fi

# Hardened runtime is reported in the flags as 0x10000(runtime). Different
# codesign versions render flags differently — accept either the hex form or
# the symbolic 'runtime' attribute name.
if grep -qE 'flags=.*runtime' <<<"$DETAILS"; then
    ok "hardened-runtime"
else
    crit_or_warn "hardened-runtime: bundle not signed with --options runtime"
fi

# ---- 5. spctl Gatekeeper assessment
SPCTL_OUT="$(spctl -a -vv -t install "$APP" 2>&1 || true)"
printf '%s\n' "$SPCTL_OUT" | sed 's/^/  /'
if grep -qE 'accepted' <<<"$SPCTL_OUT"; then
    ok "spctl-gatekeeper-accept"
else
    crit_or_warn "spctl-gatekeeper-accept: Gatekeeper rejected (no notarization ticket)"
fi

# ---- 6. stapler validate (notarization ticket attached)
if xcrun stapler validate "$APP" 2>&1 | sed 's/^/  /'; then
    ok "stapler-validate"
else
    crit_or_warn "stapler-validate: no notarization ticket attached"
fi

# ---- Summary
printf '\n-- Summary --\n'
printf 'PASS=%d  WARN=%d  FAIL=%d\n' "$PASS_COUNT" "$WARN_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
    printf 'RESULT: NOT RELEASE-READY\n'
    exit 1
fi
if [[ "$RELEASE_MODE" == "adhoc" ]]; then
    printf 'RESULT: release-ready (ad-hoc distribution; end-users run xattr -dr com.apple.quarantine or right-click → Open)\n'
else
    printf 'RESULT: release-ready\n'
fi
exit 0
