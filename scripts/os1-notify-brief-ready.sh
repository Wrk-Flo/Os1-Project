#!/usr/bin/env bash
# os1-notify-brief-ready.sh — when a fresh real-business-brief lands, ping the
# operator via Telegram (mo2darkbot or mo2drkbot) with a short summary + a
# pointer to the local file. Designed to be invoked by the launchd job after
# the brief generator succeeds, or run manually any time.
#
# Reads the latest `brief.md` under
#   ~/Library/Application Support/OS1/business-brief/latest/
# Extracts the first 600 chars (after the H1), sends as a Telegram message.
#
# Telegram credentials:
#   - Default sender bot: mo2darkbot (token in OpenClaw config — read directly
#     so this script stays free of bot duplication).
#   - Recipient: $OS1_NOTIFY_TELEGRAM_CHAT_ID (default 7091381625, the operator).
#
# Flags:
#   --dry-run     Print what would be sent, don't call Telegram API.
#   --force       Send even if the brief is older than $OS1_NOTIFY_FRESH_HOURS.
#   --bot mo2drkbot|mo2darkbot   Pick which bot sends. Default mo2darkbot.
#
# Exit codes:
#   0  message delivered (or dry-run printed)
#   1  brief missing/stale and --force not set
#   2  Telegram API error
#   3  config error (missing bot token)

set -euo pipefail

BRIEF_ROOT="${OS1_BUSINESS_BRIEF_ROOT:-$HOME/Library/Application Support/OS1/business-brief}"
LATEST="$BRIEF_ROOT/latest/brief.md"
CHAT_ID="${OS1_NOTIFY_TELEGRAM_CHAT_ID:-7091381625}"
FRESH_HOURS="${OS1_NOTIFY_FRESH_HOURS:-26}"
BOT="mo2darkbot"
DRY_RUN=0
FORCE=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1 ;;
    --force) FORCE=1 ;;
    --bot) BOT="${2:-}"; shift ;;
    -h|--help)
      sed -n '1,25p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      printf 'unknown: %s\n' "$1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -f "$LATEST" ]; then
  printf 'brief missing: %s\n' "$LATEST" >&2
  exit 1
fi

# Freshness check (skip with --force).
if [ "$FORCE" -ne 1 ]; then
  brief_age_s="$(( $(date +%s) - $(stat -f %m "$LATEST" 2>/dev/null) ))"
  max_age_s="$(( FRESH_HOURS * 3600 ))"
  if [ "$brief_age_s" -gt "$max_age_s" ]; then
    printf 'brief stale: %ss old (limit %ss). Use --force to send anyway.\n' "$brief_age_s" "$max_age_s" >&2
    exit 1
  fi
fi

# Resolve bot token from openclaw config (mo2darkbot/mo2drkbot are both there).
OPENCLAW_CFG="$HOME/.openclaw/openclaw.json"
TOKEN=""
if [ -r "$OPENCLAW_CFG" ]; then
  TOKEN="$(python3 -c '
import json,sys
cfg=json.load(open(sys.argv[1]))
acct=(cfg.get("channels",{}).get("telegram",{}).get("accounts",{}) or {}).get(sys.argv[2],{})
print(acct.get("botToken",""))
' "$OPENCLAW_CFG" "$BOT")"
fi
if [ -z "$TOKEN" ]; then
  printf 'no bot token for %s in %s\n' "$BOT" "$OPENCLAW_CFG" >&2
  exit 3
fi

# Build the message: first H1 + first ~600 chars of the rest, capped.
MESSAGE="$(python3 - "$LATEST" "$HOME" <<'PY'
import sys
path = sys.argv[1]
home = sys.argv[2]
with open(path) as f:
    text = f.read().strip()
title = "OS1 daily brief"
body_start = 0
for i, line in enumerate(text.splitlines()):
    if line.startswith("# "):
        title = line[2:].strip()
        body_start = sum(len(l) + 1 for l in text.splitlines()[:i+1])
        break
body = text[body_start:].strip()
if len(body) > 600:
    cut = body.rfind("\n", 0, 600)
    if cut <= 0:
        cut = 600
    body = body[:cut].rstrip() + "\n..."
display_path = path.replace(home, "~")
print("Brief: " + title + "\n\n" + body + "\n\nLocal: " + display_path)
PY
)"

if [ "$DRY_RUN" -eq 1 ]; then
  printf '%s\n' "$MESSAGE"
  exit 0
fi

# Send via Telegram Bot API.
http_status="$(curl -sS --max-time 15 -o /tmp/os1-notify-brief.response \
  -w '%{http_code}' \
  "https://api.telegram.org/bot${TOKEN}/sendMessage" \
  --data-urlencode "chat_id=${CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}")"

if [ "$http_status" != "200" ]; then
  printf 'telegram API HTTP %s: %s\n' "$http_status" "$(head -c 240 /tmp/os1-notify-brief.response)" >&2
  exit 2
fi

msg_id="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("result",{}).get("message_id",""))' /tmp/os1-notify-brief.response)"
printf 'delivered via @%s (msg_id=%s, chat_id=%s)\n' "$BOT" "$msg_id" "$CHAT_ID"
