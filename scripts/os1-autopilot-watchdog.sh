#!/usr/bin/env bash
# os1-autopilot-watchdog.sh — credit-free local fallback for the OS1 production push.
#
# Purpose: keeps the OS1 build alive when Claude Code and Codex Desktop both run
# out of API credits. Performs deterministic, LLM-free health checks; restarts
# the local Hermes Telegram gateway if it crashes; surfaces overnight regressions
# in /tmp/os1-heartbeat.log; flags when an LLM-driven agent should pick back up.
#
# Designed to run from launchd every 5 minutes:
#   ~/Library/LaunchAgents/com.os1.autopilot.watchdog.plist
#
# Flags:
#   --once         Run a single check, exit. Default behavior.
#   --install      Install the launchd plist for 5-minute recurrence and load it.
#   --uninstall    Unload and remove the launchd plist.
#   --status       Print the last 20 ledger entries and current service state.
#
# Exit codes:
#   0  check completed (any restarts succeeded)
#   1  a service was found down AND restart failed
#   2  usage error
#
# This script never calls an LLM. It never touches Apple-signing files. It never
# commits. It is safe to run unattended.

set -u
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
LEDGER="${OS1_HEARTBEAT_LOG:-/tmp/os1-heartbeat.log}"
LAUNCHD_LABEL="com.os1.autopilot.watchdog"
LAUNCHD_PLIST="$HOME/Library/LaunchAgents/${LAUNCHD_LABEL}.plist"
INTERVAL_SECONDS="${OS1_AUTOPILOT_INTERVAL:-300}"
HERMES_BIN="${HERMES_BIN:-hermes}"
if [ -n "${OPENCLAW_BIN:-}" ]; then
  OPENCLAW_BIN="$OPENCLAW_BIN"
elif [ -x "$HOME/.local/bin/openclaw" ]; then
  OPENCLAW_BIN="$HOME/.local/bin/openclaw"
else
  OPENCLAW_BIN="openclaw"
fi
OPENCLAW_STATUS_TIMEOUT="${OPENCLAW_STATUS_TIMEOUT:-10}"
OPENCLAW_RESTART_TIMEOUT="${OPENCLAW_RESTART_TIMEOUT:-20}"
COMPOSIO_BIN="${COMPOSIO_BIN:-$HOME/.composio/composio}"
COMPOSIO_API_KEY_FILE="${COMPOSIO_API_KEY_FILE:-$HOME/.composio/api_key}"
TWITTER_CA_ID="${OS1_TWITTER_CA_ID:-ca_45KWg-Typfl1}"
RC=0
MODE="once"

usage() {
  sed -n '1,30p' "$0" | sed 's/^# \{0,1\}//'
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --once) MODE="once" ;;
    --install) MODE="install" ;;
    --uninstall) MODE="uninstall" ;;
    --status) MODE="status" ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; printf 'unknown argument: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

now_utc_iso() { date -u +%Y-%m-%dT%H:%MZ; }

log_entry() {
  # Single space-separated key=value line; appends atomically.
  printf '[%s] %s\n' "$(now_utc_iso)" "$*" >> "$LEDGER"
}

check_hermes() {
  local pid
  pid="$(pgrep -af "hermes_cli.main gateway" | awk 'NR==1{print $1}')"
  if [ -n "$pid" ]; then
    printf 'hermes=up(pid=%s)' "$pid"
    return 0
  fi
  printf 'hermes=down'
  if command -v "$HERMES_BIN" >/dev/null 2>&1; then
    if "$HERMES_BIN" gateway restart >/dev/null 2>&1 || "$HERMES_BIN" gateway start >/dev/null 2>&1; then
      sleep 6
      pid="$(pgrep -af "hermes_cli.main gateway" | awk 'NR==1{print $1}')"
      if [ -n "$pid" ]; then
        printf ',restarted(pid=%s)' "$pid"
        return 0
      fi
    fi
  fi
  printf ',restart-failed'
  RC=1
  return 1
}

run_openclaw_with_timeout() {
  local timeout output_file pid elapsed rc
  timeout="$1"
  output_file="$2"
  shift 2

  "$OPENCLAW_BIN" "$@" >"$output_file" 2>&1 &
  pid="$!"
  elapsed=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if [ "$elapsed" -ge "$timeout" ]; then
      kill "$pid" >/dev/null 2>&1 || true
      sleep 1
      kill -9 "$pid" >/dev/null 2>&1 || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done
  wait "$pid"
  rc=$?
  return "$rc"
}

openclaw_status() {
  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/os1-openclaw-status.XXXXXX")" || return 1
  if run_openclaw_with_timeout "$OPENCLAW_STATUS_TIMEOUT" "$tmp" channels status; then
    rc=0
  else
    rc=$?
  fi
  head -8 "$tmp"
  rm -f "$tmp"
  return "$rc"
}

restart_openclaw_gateway() {
  local tmp rc
  tmp="$(mktemp "${TMPDIR:-/tmp}/os1-openclaw-restart.XXXXXX")" || return 1
  if run_openclaw_with_timeout "$OPENCLAW_RESTART_TIMEOUT" "$tmp" gateway restart; then
    rc=0
  else
    rc=$?
  fi
  rm -f "$tmp"
  return "$rc"
}

check_openclaw() {
  if ! command -v "$OPENCLAW_BIN" >/dev/null 2>&1; then
    printf 'openclaw=cli-missing'
    return
  fi
  local out status_rc reason
  if out="$(openclaw_status 2>/dev/null)"; then
    status_rc=0
  else
    status_rc=$?
  fi
  if printf '%s' "$out" | grep -q 'Gateway reachable'; then
    if printf '%s' "$out" | grep -q 'mo2darkbot:.*running'; then
      printf 'openclaw=mo2darkbot-up'
      return 0
    fi
  fi

  reason="gateway-unreachable"
  if printf '%s' "$out" | grep -qiE 'Invalid config|Config invalid|models\.providers\.'; then
    printf 'openclaw=config-invalid'
    RC=1
    return 1
  elif [ "$status_rc" -eq 124 ]; then
    reason="gateway-timeout"
  elif printf '%s' "$out" | grep -q 'Gateway reachable'; then
    reason="mo2darkbot-down"
  fi

  # Unreachable gateway or mo2darkbot down — attempt a single self-heal then re-probe.
  if restart_openclaw_gateway >/dev/null 2>&1; then
    sleep 12
    out="$(openclaw_status 2>/dev/null || true)"
    if printf '%s' "$out" | grep -q 'Gateway reachable' \
      && printf '%s' "$out" | grep -q 'mo2darkbot:.*running'; then
      printf 'openclaw=%s,restarted(mo2darkbot-up)' "$reason"
      return 0
    fi
  fi
  printf 'openclaw=%s(restart-failed)' "$reason"
  RC=1
  return 1
}

check_composio_health() {
  local checker rc
  checker="$ROOT_DIR/scripts/composio-health-check.sh"
  if [ ! -x "$checker" ]; then
    printf 'composio=checker-missing'
    return
  fi
  if out="$("$checker" --quiet 2>&1)"; then
    rc=0
  else
    rc=$?
  fi
  # Extract just the RESULT line
  result="$(printf '%s\n' "$out" | grep -oE 'RESULT: [a-z]+' | head -1 | awk '{print $2}')"
  printf 'composio=%s(rc=%s)' "${result:-unknown}" "$rc"
}

check_twitter_oauth() {
  if [ ! -r "$COMPOSIO_API_KEY_FILE" ]; then
    printf 'twitter=key-missing'
    return
  fi
  local body status
  body="$(curl -sS -m 8 -H "x-api-key: $(cat "$COMPOSIO_API_KEY_FILE")" \
    "https://backend.composio.dev/api/v3/connected_accounts/${TWITTER_CA_ID}" 2>/dev/null || true)"
  status="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
    print(json.loads(sys.stdin.read()).get("status",""))
except Exception:
    print("")' 2>/dev/null)"
  printf 'twitter=%s' "${status:-unreachable}"
}

check_readiness() {
  local gate rc
  gate="$ROOT_DIR/scripts/os1-production-readiness.sh"
  if [ ! -x "$gate" ]; then
    printf 'readiness=missing'
    return
  fi
  if "$gate" --local >/dev/null 2>&1; then
    printf 'readiness=ok'
  else
    rc=$?
    printf 'readiness=fail(rc=%s)' "$rc"
    RC=1
  fi
}

check_pairing_pending() {
  # Surfaces any pending hermes pairing request — operator's signal to paste the
  # code into OS1's Messaging panel. Not a regression, just an actionable line.
  if ! command -v "$HERMES_BIN" >/dev/null 2>&1; then
    return
  fi
  local out
  out="$("$HERMES_BIN" pairing list 2>/dev/null | head -20 || true)"
  if printf '%s' "$out" | grep -qiE 'pending|code'; then
    code="$(printf '%s' "$out" | grep -oE '[A-Z0-9]{8}' | head -1 || true)"
    if [ -n "$code" ]; then
      printf ' pairing=PENDING(code=%s)' "$code"
    else
      printf ' pairing=PENDING(see-hermes-pairing-list)'
    fi
  fi
}

run_once() {
  local line hermes_status openclaw_status composio_status twitter_status readiness_status pairing_status
  local check_rc=0

  if hermes_status="$(check_hermes)"; then
    :
  else
    check_rc=1
  fi
  if openclaw_status="$(check_openclaw)"; then
    :
  else
    check_rc=1
  fi
  composio_status="$(check_composio_health)"
  twitter_status="$(check_twitter_oauth)"
  if readiness_status="$(check_readiness)"; then
    :
  else
    check_rc=1
  fi
  pairing_status="$(check_pairing_pending)"

  line="$hermes_status $openclaw_status $composio_status $twitter_status $readiness_status$pairing_status"
  RC="$check_rc"
  log_entry "$line"
  printf '%s\n' "$line"
}

run_status() {
  printf '== os1-autopilot-watchdog status ==\n'
  printf 'ledger: %s\n' "$LEDGER"
  printf 'launchd: %s\n' "$LAUNCHD_PLIST"
  if launchctl print "gui/$(id -u)/$LAUNCHD_LABEL" >/dev/null 2>&1; then
    printf 'service: loaded\n'
  else
    printf 'service: not loaded\n'
  fi
  printf '\n-- last 20 ledger entries --\n'
  tail -20 "$LEDGER" 2>/dev/null || printf '(empty)\n'
}

run_install() {
  mkdir -p "$(dirname "$LAUNCHD_PLIST")"
  cat > "$LAUNCHD_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>${LAUNCHD_LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${SCRIPT_DIR}/os1-autopilot-watchdog.sh</string>
      <string>--once</string>
    </array>
    <key>StartInterval</key><integer>${INTERVAL_SECONDS}</integer>
    <key>RunAtLoad</key><true/>
    <key>WorkingDirectory</key><string>${ROOT_DIR}</string>
    <key>StandardOutPath</key><string>${HOME}/Library/Logs/OS1/autopilot-watchdog.out.log</string>
    <key>StandardErrorPath</key><string>${HOME}/Library/Logs/OS1/autopilot-watchdog.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.composio:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
      <key>OS1_HEARTBEAT_LOG</key><string>${LEDGER}</string>
    </dict>
  </dict>
</plist>
PLIST
  mkdir -p "$HOME/Library/Logs/OS1"
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  launchctl load "$LAUNCHD_PLIST"
  printf 'installed: %s (every %ss)\n' "$LAUNCHD_PLIST" "$INTERVAL_SECONDS"
  printf 'ledger: %s\n' "$LEDGER"
}

run_uninstall() {
  launchctl unload "$LAUNCHD_PLIST" 2>/dev/null || true
  rm -f "$LAUNCHD_PLIST"
  printf 'uninstalled: %s\n' "$LAUNCHD_PLIST"
}

case "$MODE" in
  once)      run_once ;;
  install)   run_install ;;
  uninstall) run_uninstall ;;
  status)    run_status ;;
esac

exit "$RC"
