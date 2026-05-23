#!/usr/bin/env bash
# os1-telegram-approval-bridge.sh
#
# Long-running daemon that bridges Eden's action queue
# (http://127.0.0.1:5188/api/actions) and the operator's Telegram via the
# OpenClaw mo2darkbot account. The operator can approve / cancel pending
# Eden business actions from their phone.
#
# Flow:
#   1. Poll GET /api/actions every OS1_TG_POLL_SECONDS (default 30s)
#   2. For each new action with status="pending_approval" that we haven't
#      already notified about (tracked in seen.json), send a Telegram
#      message to the operator's chat_id with a short summary.
#   3. Long-poll Telegram getUpdates (timeout=25s) for messages from the
#      operator's chat_id. Parse free-text replies:
#        - "approve" / "yes" / "send it" (+ optional id) -> POST /api/actions/execute
#        - "cancel" / "no" / "stop"     (+ optional id) -> POST /api/actions/cancel
#        - anything else: reply "didn't understand"
#   4. Only chat_id OS1_TG_OPERATOR_CHAT_ID is authorized; all other senders
#      get an "unauthorized" reply and are ignored.
#
# Safety:
#   --dry-run         Default. Print what it would send/execute, no real
#                     Telegram messages and no Eden API writes.
#   --apply           Actually send Telegram messages and call Eden execute/
#                     cancel endpoints. Use only after you've confirmed
#                     --dry-run output looks sane.
#
# IMPORTANT: bot account choice and Telegram's getUpdates exclusivity.
#   Telegram allows only ONE consumer per bot at a time via getUpdates().
#   Both mo2darkbot (OpenClaw notifier) and mo2drkbot (Hermes DM) are already
#   being long-polled by their respective owners and will return HTTP 409
#   "Conflict: terminated by other getUpdates request" for this bridge.
#   The bridge treats 409 as a non-fatal WARN and keeps sending notifications
#   correctly — only the reply-handling (operator says "approve") needs a
#   non-conflicted bot.
#
#   Recommended: create a NEW bot via @BotFather (e.g. "os1_approval_bot"),
#   add it under `channels.telegram.accounts.<name>` in ~/.openclaw/openclaw.json
#   with `enabled: false` (so OpenClaw doesn't poll it), then set
#   OS1_TG_BOT_ACCOUNT=<name> for this bridge. That gives a dedicated approval
#   channel with no polling conflict.
#
# State files (under ~/Library/Application Support/OS1/telegram-approval/):
#   seen.json            { "<action_id>": "<utc_notified>" }
#   tg-offset            integer (Telegram getUpdates offset)
#
# Run as launchd via scripts/install-telegram-approval-bridge.sh.

set -euo pipefail

SCRIPT_NAME="os1-telegram-approval-bridge"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

# Tunables (env overrides)
EDEN_BASE_URL="${EDEN_BASE_URL:-http://127.0.0.1:5188}"
OS1_TG_POLL_SECONDS="${OS1_TG_POLL_SECONDS:-30}"
OS1_TG_OPENCLAW_JSON="${OS1_TG_OPENCLAW_JSON:-$HOME/.openclaw/openclaw.json}"
# Default to mo2drkbot (disabled in OpenClaw, no getUpdates conflict).
# mo2darkbot is OpenClaw's primary notification bot and is being long-polled
# elsewhere; Telegram only allows one getUpdates consumer per bot at a time.
OS1_TG_BOT_ACCOUNT="${OS1_TG_BOT_ACCOUNT:-mo2drkbot}"
OS1_TG_OPERATOR_CHAT_ID="${OS1_TG_OPERATOR_CHAT_ID:-7091381625}"
STATE_DIR="${OS1_TG_STATE_DIR:-$HOME/Library/Application Support/OS1/telegram-approval}"

APPLY=0  # default safe
ONESHOT=0

usage() {
  cat <<'USAGE'
Usage: scripts/os1-telegram-approval-bridge.sh [--dry-run | --apply] [--once]

  --dry-run     Default. Print what would happen; no Telegram sends, no Eden writes.
  --apply       Actually send Telegram messages and call Eden execute/cancel.
  --once        Run one iteration of the loop and exit (smoke test friendly).
  -h, --help    Show this help.

Environment overrides:
  EDEN_BASE_URL              default http://127.0.0.1:5188
  OS1_TG_POLL_SECONDS        default 30
  OS1_TG_OPENCLAW_JSON       default ~/.openclaw/openclaw.json
  OS1_TG_BOT_ACCOUNT         default mo2darkbot
  OS1_TG_OPERATOR_CHAT_ID    default 7091381625
  OS1_TG_STATE_DIR           default ~/Library/Application Support/OS1/telegram-approval
USAGE
}

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) APPLY=0; shift ;;
    --apply) APPLY=1; shift ;;
    --once) ONESHOT=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) printf 'unknown arg: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

log() { printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# ---- prereqs ----------------------------------------------------------------
command -v curl >/dev/null || die "curl not found"
command -v jq >/dev/null || die "jq not found (install via: brew install jq)"

[ -r "$OS1_TG_OPENCLAW_JSON" ] || die "openclaw config not readable: $OS1_TG_OPENCLAW_JSON"
BOT_TOKEN="$(jq -r ".channels.telegram.accounts[\"$OS1_TG_BOT_ACCOUNT\"].botToken // empty" "$OS1_TG_OPENCLAW_JSON")"
[ -n "$BOT_TOKEN" ] || die "no botToken found for $OS1_TG_BOT_ACCOUNT in $OS1_TG_OPENCLAW_JSON"

mkdir -p "$STATE_DIR" || die "cannot create state dir $STATE_DIR"
SEEN_FILE="$STATE_DIR/seen.json"
OFFSET_FILE="$STATE_DIR/tg-offset"
[ -f "$SEEN_FILE" ] || echo '{}' > "$SEEN_FILE"
[ -f "$OFFSET_FILE" ] || echo '0' > "$OFFSET_FILE"

log "starting (apply=$APPLY oneshot=$ONESHOT poll=${OS1_TG_POLL_SECONDS}s eden=$EDEN_BASE_URL bot=$OS1_TG_BOT_ACCOUNT chat=$OS1_TG_OPERATOR_CHAT_ID)"
log "state dir: $STATE_DIR  bot token prefix: ${BOT_TOKEN:0:10}..."

# ---- helpers ----------------------------------------------------------------

tg_api() {
  # tg_api <method> [curl args...]  -> echoes JSON response
  local method="$1"; shift
  curl -sS --max-time 30 "https://api.telegram.org/bot${BOT_TOKEN}/${method}" "$@"
}

tg_send_text() {
  # tg_send_text <chat_id> <text>
  local chat="$1"; local text="$2"
  if [ "$APPLY" -ne 1 ]; then
    log "DRY-RUN sendMessage chat=$chat text=$(printf '%q' "${text:0:80}")"
    return 0
  fi
  tg_api sendMessage \
    --data-urlencode "chat_id=$chat" \
    --data-urlencode "text=$text" \
    --data-urlencode "parse_mode=Markdown" >/dev/null
}

eden_get() {
  curl -sS --max-time 15 "$EDEN_BASE_URL$1"
}

eden_post() {
  # eden_post <path> <json>
  if [ "$APPLY" -ne 1 ]; then
    log "DRY-RUN POST $1 body=$(printf '%q' "${2:0:120}")"
    echo '{"ok":true,"dry_run":true}'
    return 0
  fi
  curl -sS --max-time 30 -X POST "$EDEN_BASE_URL$1" -H 'content-type: application/json' -d "$2"
}

seen_has() {
  jq -e --arg id "$1" 'has($id)' "$SEEN_FILE" >/dev/null 2>&1
}

seen_add() {
  local id="$1"; local ts; ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  local tmp="$SEEN_FILE.tmp.$$"
  jq --arg id "$id" --arg ts "$ts" '.[$id] = $ts' "$SEEN_FILE" > "$tmp" && mv "$tmp" "$SEEN_FILE"
}

# ---- step 1: notify operator about new pending actions ----------------------
process_pending() {
  local actions_json; actions_json="$(eden_get /api/actions?limit=20 || true)"
  if [ -z "$actions_json" ] || ! echo "$actions_json" | jq -e '.ok==true' >/dev/null 2>&1; then
    log "WARN: eden /api/actions returned non-ok or empty"
    return 0
  fi
  local n; n="$(echo "$actions_json" | jq '.actions | length')"
  local pending_n=0
  local notified_n=0
  local i=0
  while [ $i -lt "$n" ]; do
    local rec; rec="$(echo "$actions_json" | jq -c ".actions[$i]")"
    local status; status="$(echo "$rec" | jq -r '.status // .state // ""')"
    if [ "$status" = "pending_approval" ] || [ "$status" = "pending" ] || [ "$status" = "queued" ]; then
      pending_n=$((pending_n+1))
      local id; id="$(echo "$rec" | jq -r '.id')"
      if ! seen_has "$id"; then
        local at; at="$(echo "$rec" | jq -r '.action // .type // .actionType // "?"')"
        local risk; risk="$(echo "$rec" | jq -r '.risk // "?"')"
        local sum; sum="$(echo "$rec" | jq -r '(.summary // .label // .description // "no summary")')"
        local msg; msg="$(printf '📋 Eden queued an action for your approval.\n\n*Action:* %s\n*Risk:* %s\n*Summary:* %s\n*ID:* `%s`\n\nReply "approve %s" or just "approve" to execute.\nReply "cancel %s" or "cancel" to dismiss.' "$at" "$risk" "${sum:0:300}" "$id" "${id: -8}" "${id: -8}")"
        log "notifying operator about NEW action $id ($at $risk)"
        if tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "$msg"; then
          seen_add "$id"
          notified_n=$((notified_n+1))
        fi
      fi
    fi
    i=$((i+1))
  done
  log "step1: $n actions returned, $pending_n pending, $notified_n NEW notified"
}

# ---- step 2: read operator's Telegram replies ------------------------------
process_replies() {
  local offset; offset="$(cat "$OFFSET_FILE")"
  local resp; resp="$(tg_api getUpdates --data-urlencode "offset=$offset" --data-urlencode "timeout=10" --data-urlencode "allowed_updates=[\"message\"]" || true)"
  [ -z "$resp" ] && return 0
  if ! echo "$resp" | jq -e '.ok==true' >/dev/null 2>&1; then
    log "WARN: telegram getUpdates returned non-ok: $(echo "$resp" | head -c 200)"
    return 0
  fi
  local n; n="$(echo "$resp" | jq '.result | length')"
  local i=0
  local max_id="$offset"
  while [ $i -lt "$n" ]; do
    local upd; upd="$(echo "$resp" | jq -c ".result[$i]")"
    local upd_id; upd_id="$(echo "$upd" | jq -r '.update_id')"
    if [ "$upd_id" -ge "$max_id" ]; then max_id=$((upd_id+1)); fi
    local from_chat; from_chat="$(echo "$upd" | jq -r '.message.chat.id // empty')"
    local text; text="$(echo "$upd" | jq -r '.message.text // empty')"
    local lower; lower="$(printf '%s' "$text" | tr '[:upper:]' '[:lower:]' | tr -d '\r')"
    if [ -z "$from_chat" ] || [ -z "$text" ]; then i=$((i+1)); continue; fi
    if [ "$from_chat" != "$OS1_TG_OPERATOR_CHAT_ID" ]; then
      log "ignored message from unauthorized chat $from_chat (text=${text:0:40})"
      tg_send_text "$from_chat" "Unauthorized. This bridge only accepts approvals from the configured operator."
      i=$((i+1)); continue
    fi

    # Match approve / cancel patterns; allow optional trailing id substring
    local cmd=""
    local id_hint=""
    case "$lower" in
      approve*|yes*|"send it"*|approved*) cmd="approve"; id_hint="$(printf '%s' "$lower" | sed -E 's/^(approve|yes|approved|send it)[[:space:]]*//')" ;;
      cancel*|no|"don't send it"*|stop|"never mind"*) cmd="cancel"; id_hint="$(printf '%s' "$lower" | sed -E 's/^(cancel|no|don.t send it|stop|never mind)[[:space:]]*//')" ;;
      *) cmd="" ;;
    esac

    if [ -z "$cmd" ]; then
      log "no command match for operator message: $text"
      tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "Didn't understand. Reply *approve* or *cancel* (optionally with last 8 chars of action id)."
      i=$((i+1)); continue
    fi

    # Resolve action id: prefer id_hint match against pending queue (suffix match), else use latest pending
    local actions_json; actions_json="$(eden_get /api/actions?limit=20 || true)"
    local target_id=""
    if [ -n "$id_hint" ]; then
      target_id="$(echo "$actions_json" | jq -r --arg h "$id_hint" '.actions[] | select(.id | tostring | endswith($h)) | .id' | head -1)"
    fi
    if [ -z "$target_id" ]; then
      target_id="$(echo "$actions_json" | jq -r '[.actions[] | select(.status=="pending_approval" or .status=="pending" or .status=="queued")] | .[0].id // empty')"
    fi
    if [ -z "$target_id" ]; then
      log "no pending action to $cmd"
      tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "No pending action found. Nothing to $cmd."
      i=$((i+1)); continue
    fi

    if [ "$cmd" = "approve" ]; then
      log "OPERATOR APPROVED action $target_id"
      local body; body="$(jq -nc --arg id "$target_id" '{id:$id,approvalConfirmed:true}')"
      local rsp; rsp="$(eden_post /api/actions/execute "$body")"
      local ok; ok="$(echo "$rsp" | jq -r '.ok // false')"
      if [ "$ok" = "true" ]; then
        tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "Executed action \`${target_id: -8}\`."
      else
        local err; err="$(echo "$rsp" | jq -r '.error // .message // "unknown_error"')"
        tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "Execute failed: $err"
      fi
    elif [ "$cmd" = "cancel" ]; then
      log "OPERATOR CANCELLED action $target_id"
      local body; body="$(jq -nc --arg id "$target_id" '{id:$id}')"
      local rsp; rsp="$(eden_post /api/actions/cancel "$body")"
      local ok; ok="$(echo "$rsp" | jq -r '.ok // false')"
      if [ "$ok" = "true" ]; then
        tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "Cancelled action \`${target_id: -8}\`."
      else
        local err; err="$(echo "$rsp" | jq -r '.error // .message // "unknown_error"')"
        tg_send_text "$OS1_TG_OPERATOR_CHAT_ID" "Cancel failed: $err"
      fi
    fi
    i=$((i+1))
  done
  echo "$max_id" > "$OFFSET_FILE"
}

# ---- main loop --------------------------------------------------------------
iteration=0
while true; do
  iteration=$((iteration+1))
  log "loop iteration $iteration"
  process_pending || log "WARN: process_pending raised non-fatal error"
  process_replies || log "WARN: process_replies raised non-fatal error"
  if [ "$ONESHOT" -eq 1 ]; then
    log "oneshot done"
    exit 0
  fi
  sleep "$OS1_TG_POLL_SECONDS"
done
