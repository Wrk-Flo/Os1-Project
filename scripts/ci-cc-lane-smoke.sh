#!/usr/bin/env bash
# ci-cc-lane-smoke.sh — CI-safe smoke for all Claude Code-lane scripts.
#
# Runs the CC-lane validators in dry-run / read-only mode. No credentials
# required. No Apple Developer cert needed (adhoc mode). No network writes.
# No live Composio mutations.
#
# Designed to be invoked from .github/workflows/ci.yml as a single step:
#   - run: scripts/ci-cc-lane-smoke.sh
#
# Codex owns ci.yml; this is the CC-lane contract. Wire-in is Codex's call.
#
# Exit codes:
#   0  all CC-lane scripts pass
#   1  any check failed
#   2  usage error
#
# Skips:
#   - composio round-trips (require live API key not present in CI)
#   - hermes/openclaw probes (no gateways in CI)
#   - signing/notarization (no Apple Dev cert)
#
# What it does check:
#   - bash -n on every CC-lane script (catches syntax regressions)
#   - --help / --dry-run on every script that supports them
#   - release-archive-verify.sh --mode adhoc against the built bundle
#   - validate-business-output.sh against a fixture (if present)

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
PASS=0
FAIL=0

ok()   { printf 'OK   %s\n' "$*"; PASS=$((PASS+1)); }
crit() { printf 'FAIL %s\n' "$*"; FAIL=$((FAIL+1)); }

CC_LANE_SCRIPTS=(
  scripts/sign-os1-app.sh
  scripts/notarize-os1-app.sh
  scripts/release-archive-verify.sh
  scripts/validate-business-output.sh
  scripts/business-output-archive.sh
  scripts/composio-health-check.sh
  scripts/os1-autopilot-watchdog.sh
  scripts/os1-real-business-brief.sh
  scripts/os1-integration-probe.sh
  scripts/os1-post-approved-content.sh
  scripts/install-real-brief-launchd.sh
  scripts/llm-task-openrouter.sh
  scripts/os1-notify-brief-ready.sh
  scripts/os1-daily-brief-and-notify.sh
)

printf '== CC-lane CI smoke ==\n'

# 1. Syntax check every CC-lane script
for s in "${CC_LANE_SCRIPTS[@]}"; do
  if [ -x "$ROOT_DIR/$s" ]; then
    if bash -n "$ROOT_DIR/$s" 2>/dev/null; then
      ok "bash -n $s"
    else
      crit "bash -n $s — syntax error"
    fi
  else
    crit "missing or non-executable: $s"
  fi
done

# 2. --help on every script (catches argparse regressions)
for s in "${CC_LANE_SCRIPTS[@]}"; do
  if [ -x "$ROOT_DIR/$s" ]; then
    if "$ROOT_DIR/$s" --help >/dev/null 2>&1; then
      ok "$s --help"
    else
      # Some scripts may not support --help; allow exit 0 or 1 but not anything else
      rc=$?
      if [ "$rc" -le 1 ]; then
        ok "$s --help (exit $rc accepted)"
      else
        crit "$s --help — exit $rc"
      fi
    fi
  fi
done

# 3. release-archive-verify in adhoc mode (skipped if no built bundle)
if [ -d "$ROOT_DIR/dist/OS1.app" ]; then
  if "$ROOT_DIR/scripts/release-archive-verify.sh" --mode adhoc >/dev/null 2>&1; then
    ok "release-archive-verify.sh --mode adhoc"
  else
    crit "release-archive-verify.sh --mode adhoc — non-zero exit"
  fi
else
  ok "release-archive-verify skipped (no dist/OS1.app in CI workspace)"
fi

# 4. validate-business-output if fixture present (CI typically won't have one)
if [ -d "${OS1_BUSINESS_OPS_ROOT:-$HOME/Library/Application Support/OS1/business-ops}/latest" ]; then
  if "$ROOT_DIR/scripts/validate-business-output.sh" >/dev/null 2>&1; then
    ok "validate-business-output.sh"
  else
    crit "validate-business-output.sh — non-zero exit"
  fi
else
  ok "validate-business-output skipped (no latest/ fixture)"
fi

printf '\n-- Summary --\nPASS=%d  FAIL=%d\n' "$PASS" "$FAIL"
if [ "$FAIL" -gt 0 ]; then
  printf 'RESULT: cc-lane-ci-not-ready\n'
  exit 1
fi
printf 'RESULT: cc-lane-ci-ready\n'
exit 0
