#!/usr/bin/env bash
# install-telegram-approval-bridge.sh
#
# Install (or refresh) the user LaunchAgent that runs
# os1-telegram-approval-bridge.sh as a long-running daemon. Default
# install posture is --dry-run (no real Telegram sends, no Eden writes)
# so the operator can verify the bridge sees actions correctly before
# flipping to --apply.
#
# Usage:
#   scripts/install-telegram-approval-bridge.sh                 # dry-run install (safe default)
#   scripts/install-telegram-approval-bridge.sh --apply         # install in real mode (USES TELEGRAM)
#   scripts/install-telegram-approval-bridge.sh --uninstall     # remove the LaunchAgent
#   scripts/install-telegram-approval-bridge.sh --print         # print the plist without writing
#
# After install you can:
#   launchctl print gui/$(id -u)/com.os1.telegram-approval-bridge   # status
#   tail -f ~/Library/Logs/OS1/telegram-approval-bridge.{out,err}.log
#   launchctl kickstart -k gui/$(id -u)/com.os1.telegram-approval-bridge  # force restart

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
PLIST_LABEL="com.os1.telegram-approval-bridge"
PLIST_PATH="$HOME/Library/LaunchAgents/${PLIST_LABEL}.plist"
LOG_DIR="$HOME/Library/Logs/OS1"
BRIDGE_BIN="$SCRIPT_DIR/os1-telegram-approval-bridge.sh"

MODE="install"
APPLY_FLAG="--dry-run"

while [ $# -gt 0 ]; do
  case "$1" in
    --apply) APPLY_FLAG="--apply"; shift ;;
    --dry-run) APPLY_FLAG="--dry-run"; shift ;;
    --uninstall) MODE="uninstall"; shift ;;
    --print) MODE="print"; shift ;;
    -h|--help)
      sed -n '2,21p' "$0"; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; exit 2 ;;
  esac
done

[ -x "$BRIDGE_BIN" ] || { printf 'bridge script not executable: %s\n' "$BRIDGE_BIN" >&2; exit 1; }
mkdir -p "$LOG_DIR"

write_plist() {
  cat > "$PLIST_PATH" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>${PLIST_LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-lc</string>
    <string>${BRIDGE_BIN} ${APPLY_FLAG}</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key>
  <dict>
    <key>SuccessfulExit</key><false/>
  </dict>
  <key>ThrottleInterval</key><integer>30</integer>
  <key>StandardOutPath</key><string>${LOG_DIR}/telegram-approval-bridge.out.log</string>
  <key>StandardErrorPath</key><string>${LOG_DIR}/telegram-approval-bridge.err.log</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.composio:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
    <key>HOME</key><string>${HOME}</string>
  </dict>
  <key>WorkingDirectory</key><string>${HOME}</string>
</dict>
</plist>
PLIST
  plutil -lint "$PLIST_PATH" >/dev/null
}

case "$MODE" in
  print)
    APPLY_FLAG="$APPLY_FLAG" write_plist
    cat "$PLIST_PATH"
    rm -f "$PLIST_PATH"
    ;;
  uninstall)
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    printf 'uninstalled %s\n' "$PLIST_LABEL"
    ;;
  install)
    write_plist
    launchctl bootout "gui/$(id -u)" "$PLIST_PATH" 2>/dev/null || true
    launchctl bootstrap "gui/$(id -u)" "$PLIST_PATH"
    printf 'installed %s (mode=%s)\n' "$PLIST_LABEL" "$APPLY_FLAG"
    printf '  logs: %s/telegram-approval-bridge.{out,err}.log\n' "$LOG_DIR"
    printf '  status: launchctl print gui/$(id -u)/%s\n' "$PLIST_LABEL"
    if [ "$APPLY_FLAG" = "--dry-run" ]; then
      printf '\n  SAFE-DEFAULT: --dry-run. To enable real Telegram sends + Eden writes,\n  re-run: %s --apply\n' "$0"
    fi
    ;;
esac
