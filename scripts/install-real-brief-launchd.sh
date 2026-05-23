#!/usr/bin/env bash
# install-real-brief-launchd.sh — install the daily real-business-brief sidecar.
#
# Runs scripts/os1-real-business-brief.sh once a day so the user wakes up to a
# fresh brief.md ready for morning review. Independent of the hourly
# com.os1.local.business-ops runner — that one defaults to skipping the
# real-brief sidecar.
#
# CC lane. Does NOT touch scripts/install-local-ops-launchd.sh (Codex).
#
# Flags:
#   --install      Generate the plist, load it, and run once immediately.
#   --uninstall    Unload + remove the plist.
#   --status       Print launchd state + last run summary.
#
# Schedule defaults to 06:07 CDT daily (off-minute, avoids the :00 fleet
# crush). Override with OS1_REAL_BRIEF_HOUR / OS1_REAL_BRIEF_MINUTE.

set -euo pipefail

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
LABEL="com.os1.local.real-business-brief"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
HOUR="${OS1_REAL_BRIEF_HOUR:-6}"
MINUTE="${OS1_REAL_BRIEF_MINUTE:-7}"
LOG_DIR="$HOME/Library/Logs/OS1"
BRIEF="$SCRIPT_DIR/os1-daily-brief-and-notify.sh"

MODE="${1:---install}"

case "$MODE" in
  --install)
    if [ ! -x "$BRIEF" ]; then
      printf 'error: missing executable %s\n' "$BRIEF" >&2
      exit 1
    fi
    mkdir -p "$LOG_DIR"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key><string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
      <string>/bin/bash</string>
      <string>${BRIEF}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
      <key>Hour</key><integer>${HOUR}</integer>
      <key>Minute</key><integer>${MINUTE}</integer>
    </dict>
    <key>RunAtLoad</key><false/>
    <key>WorkingDirectory</key><string>${ROOT_DIR}</string>
    <key>StandardOutPath</key><string>${LOG_DIR}/real-business-brief.out.log</string>
    <key>StandardErrorPath</key><string>${LOG_DIR}/real-business-brief.err.log</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>PATH</key><string>${HOME}/.local/bin:${HOME}/.composio:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin</string>
      <key>OS1_OSA_TIMEOUT_SECONDS</key>
		<string>120</string>
		<key>OS1_LLM_TASK_BIN</key><string>${SCRIPT_DIR}/llm-task-with-fallback.sh</string>
      <key>OPENROUTER_MODEL</key><string>z-ai/glm-4.5-air:free</string>
      <key>OLLAMA_MODEL</key><string>llama3.2:3b</string>
      <key>OLLAMA_TASK_MAX_TIME_SECONDS</key><string>180</string>
      <key>OS1_FALLBACK_PRIMARY_TIMEOUT</key><string>120</string>
    </dict>
  </dict>
</plist>
PLIST
    launchctl unload "$PLIST" 2>/dev/null || true
    launchctl load "$PLIST"
    printf 'installed: %s (daily at %02d:%02d local)\n' "$PLIST" "$HOUR" "$MINUTE"
    ;;
  --uninstall)
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST"
    printf 'uninstalled: %s\n' "$PLIST"
    ;;
  --status)
    printf 'launchd: %s\n' "$PLIST"
    if launchctl print "gui/$(id -u)/$LABEL" >/dev/null 2>&1; then
      printf 'service: loaded (next fire at %02d:%02d local daily)\n' "$HOUR" "$MINUTE"
      launchctl print "gui/$(id -u)/$LABEL" 2>/dev/null | grep -E "runs|last exit" | head -3
    else
      printf 'service: not loaded — run --install\n'
    fi
    printf '\n-- latest brief --\n'
    ls -t "$HOME/Library/Application Support/OS1/business-brief/runs/" 2>/dev/null | head -3 || printf '(no briefs yet)\n'
    ;;
  -h|--help)
    sed -n '1,20p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    printf 'unknown: %s (use --install|--uninstall|--status|--help)\n' "$MODE" >&2
    exit 2
    ;;
esac
