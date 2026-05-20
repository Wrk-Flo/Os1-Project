#!/usr/bin/env bash
# os1-daily-brief-and-notify.sh — single-shot wrapper for the daily launchd:
# generate the real business brief, then Telegram-notify the operator with a
# 600-char excerpt + local path. Designed to be the ProgramArguments target
# of com.os1.local.real-business-brief.plist.
#
# Honors the same env vars as os1-real-business-brief.sh + os1-notify-brief-ready.sh.
#
# Exit codes:
#   0  brief generated AND notification sent (or notification fell through to
#      "brief ready, notify failed" — surfaced in stderr but not a hard fail)
#   1  brief generation itself failed (no notify attempted)

set -u
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
BRIEF="$SCRIPT_DIR/os1-real-business-brief.sh"
NOTIFY="$SCRIPT_DIR/os1-notify-brief-ready.sh"
NOTIFY_ENABLED="${OS1_DAILY_BRIEF_NOTIFY:-1}"

case "${1:-}" in
  -h|--help)
    sed -n '1,15p' "$0" | sed 's/^# \{0,1\}//'
    exit 0
    ;;
esac

if [ ! -x "$BRIEF" ]; then
  printf 'os1-daily-brief-and-notify: missing %s\n' "$BRIEF" >&2
  exit 1
fi

if ! "$BRIEF" --quick; then
  printf 'os1-daily-brief-and-notify: brief generator failed; skipping notify\n' >&2
  exit 1
fi

if [ "$NOTIFY_ENABLED" != "1" ]; then
  printf 'os1-daily-brief-and-notify: notify disabled (OS1_DAILY_BRIEF_NOTIFY=%s); skipping\n' "$NOTIFY_ENABLED"
  exit 0
fi

if [ ! -x "$NOTIFY" ]; then
  printf 'os1-daily-brief-and-notify: missing %s; brief ready but no notify\n' "$NOTIFY" >&2
  exit 0
fi

if ! "$NOTIFY"; then
  printf 'os1-daily-brief-and-notify: notify failed; brief is still ready locally\n' >&2
fi

exit 0
