#!/usr/bin/env bash
# os1-integration-probe.sh — fast, read-only health probe for the live data sources
# used by scripts/os1-real-business-brief.sh.
#
# Prints one line per integration:
#   OK <name>: <detail>
#   WARN <name>: <reason>
#   FAIL <name>: <reason>
# Then a final summary:
#   RESULT: ready|degraded|down
#
# Exit codes:
#   0  ready or degraded (or down without --strict)
#   1  --strict and at least one FAIL
#   2  usage error
#
# Targets are intentionally minimal so total wall time stays under ~5s with warm
# caches. Each probe is wrapped in `curl -m 3` or a short osascript call.

set -euo pipefail

SCRIPT_NAME="os1-integration-probe"

usage() {
  cat <<'USAGE'
Usage: scripts/os1-integration-probe.sh [--strict] [--quiet] [--json]

Read-only probe across the integrations used by the real-data business brief:
  ollama-server, ollama-model, composio-cli, composio-gmail, composio-linkedin,
  composio-twitter, apple-calendar-access, apple-reminders-access.

Options:
  --strict   Exit 1 if any probe reports FAIL.
  --quiet    Suppress per-probe lines; print only the RESULT line.
  --json     Emit a single JSON document instead of human lines.
  -h, --help Show this help.

Env knobs:
  OLLAMA_HOST    default http://127.0.0.1:11434
  OLLAMA_MODEL   default qwen2.5-coder:3b
  COMPOSIO_BIN   default $HOME/.composio/composio
  COMPOSIO_API_KEY_FILE default $HOME/.composio/api_key
  COMPOSIO_API_BASE default https://backend.composio.dev/api/v3
USAGE
}

STRICT=0
QUIET=0
JSON=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict) STRICT=1 ;;
    --quiet)  QUIET=1 ;;
    --json)   JSON=1 ;;
    -h|--help) usage; exit 0 ;;
    *) usage >&2; printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}"
COMPOSIO_BIN="${COMPOSIO_BIN:-$HOME/.composio/composio}"
COMPOSIO_API_KEY_FILE="${COMPOSIO_API_KEY_FILE:-$HOME/.composio/api_key}"
COMPOSIO_API_BASE="${COMPOSIO_API_BASE:-https://backend.composio.dev/api/v3}"

# Buffers for JSON / quiet modes.
PROBE_LINES=()
PROBE_JSON_ITEMS=()
HAS_FAIL=0
HAS_WARN=0
HAS_OK=0
GMAIL_OK=0
LINKEDIN_OK=0

json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' <<<"$1"
}

record() {
  # record STATUS NAME DETAIL
  local status="$1" name="$2" detail="$3"
  local line="$status $name: $detail"
  PROBE_LINES+=("$line")
  local d
  d="$(json_escape "$detail")"
  PROBE_JSON_ITEMS+=("{\"name\":\"$name\",\"status\":\"$status\",\"detail\":$d}")
  case "$status" in
    OK)   HAS_OK=$((HAS_OK + 1)) ;;
    WARN) HAS_WARN=$((HAS_WARN + 1)) ;;
    FAIL) HAS_FAIL=$((HAS_FAIL + 1)) ;;
  esac
  if [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    printf '%s\n' "$line"
  fi
}

# --- ollama-server -----------------------------------------------------------
probe_ollama_server() {
  local body
  if ! body="$(curl -sS -m 3 "${OLLAMA_HOST%/}/api/tags" 2>/dev/null)"; then
    record FAIL ollama-server "no response from $OLLAMA_HOST/api/tags"
    return 1
  fi
  local count
  count="$(printf '%s' "$body" | python3 -c 'import json,sys
try:
  d=json.load(sys.stdin)
  print(len(d.get("models",[])))
except Exception:
  print(-1)' 2>/dev/null || echo -1)"
  if [ "$count" -lt 0 ]; then
    record FAIL ollama-server "malformed /api/tags response"
    return 1
  fi
  if [ "$count" -eq 0 ]; then
    record WARN ollama-server "running but 0 models installed"
    return 0
  fi
  record OK ollama-server "$count model(s) available"
  return 0
}

# --- ollama-model ------------------------------------------------------------
probe_ollama_model() {
  local body
  if ! body="$(curl -sS -m 3 "${OLLAMA_HOST%/}/api/tags" 2>/dev/null)"; then
    record FAIL ollama-model "ollama unreachable"
    return 1
  fi
  if printf '%s' "$body" | python3 -c '
import json,sys,os
m=os.environ.get("OLLAMA_MODEL","")
try:
  d=json.load(sys.stdin)
  names=[x.get("name","") for x in d.get("models",[])]
  sys.exit(0 if m in names else 1)
except Exception:
  sys.exit(2)' 2>/dev/null; then
    record OK ollama-model "$OLLAMA_MODEL present"
  else
    record WARN ollama-model "$OLLAMA_MODEL missing — run: ollama pull $OLLAMA_MODEL"
  fi
}

# --- composio-cli ------------------------------------------------------------
probe_composio_cli() {
  if [ ! -x "$COMPOSIO_BIN" ]; then
    record FAIL composio-cli "missing executable: $COMPOSIO_BIN"
    return 1
  fi
  local ver
  if ! ver="$("$COMPOSIO_BIN" --version 2>/dev/null | tr -d '\r' | tail -n1)"; then
    record FAIL composio-cli "--version exited non-zero"
    return 1
  fi
  if [ -z "$ver" ]; then
    record WARN composio-cli "version empty"
    return 0
  fi
  record OK composio-cli "v$ver"
  return 0
}

# --- composio-gmail ----------------------------------------------------------
probe_composio_gmail() {
  if [ ! -x "$COMPOSIO_BIN" ]; then
    record FAIL composio-gmail "composio CLI missing"
    return 1
  fi
  local body
  if ! body="$("$COMPOSIO_BIN" proxy -X GET \
        'https://gmail.googleapis.com/gmail/v1/users/me/profile' \
        --toolkit gmail </dev/null 2>/dev/null)"; then
    record FAIL composio-gmail "proxy call failed (not connected?)"
    return 1
  fi
  local email
  email="$(printf '%s' "$body" | python3 -c '
import json,sys
try:
  d=json.loads(sys.stdin.read())
  print(d.get("emailAddress",""))
except Exception:
  print("")' 2>/dev/null || true)"
  if [ -z "$email" ]; then
    record FAIL composio-gmail "no emailAddress in response"
    return 1
  fi
  record OK composio-gmail "$email"
  GMAIL_OK=1
  return 0
}

# --- composio-linkedin -------------------------------------------------------
probe_composio_linkedin() {
  if [ ! -x "$COMPOSIO_BIN" ]; then
    record FAIL composio-linkedin "composio CLI missing"
    return 1
  fi
  local body
  if ! body="$("$COMPOSIO_BIN" proxy -X GET \
        'https://api.linkedin.com/v2/userinfo' \
        --toolkit linkedin </dev/null 2>/dev/null)"; then
    record FAIL composio-linkedin "proxy call failed (not connected?)"
    return 1
  fi
  local sub
  sub="$(printf '%s' "$body" | python3 -c '
import json,sys
try:
  d=json.loads(sys.stdin.read())
  print(d.get("sub","") or d.get("name",""))
except Exception:
  print("")' 2>/dev/null || true)"
  if [ -z "$sub" ]; then
    record WARN composio-linkedin "200 but no sub/name field"
    return 0
  fi
  record OK composio-linkedin "userinfo: $sub"
  LINKEDIN_OK=1
  return 0
}

# --- composio-twitter --------------------------------------------------------
probe_composio_twitter() {
  if [ ! -r "$COMPOSIO_API_KEY_FILE" ]; then
    record WARN composio-twitter "api key file unreadable: $COMPOSIO_API_KEY_FILE"
    return 0
  fi
  local key
  key="$(tr -d '\r\n' < "$COMPOSIO_API_KEY_FILE")"
  if [ -z "$key" ]; then
    record WARN composio-twitter "api key file empty"
    return 0
  fi
  local body
  if ! body="$(curl -sS -m 3 \
        -H "x-api-key: $key" \
        "${COMPOSIO_API_BASE%/}/connected_accounts?toolkit_slugs=twitter" 2>/dev/null)"; then
    record FAIL composio-twitter "API request failed"
    return 1
  fi
  # Pull the first matching twitter account's status.
  local status
  status="$(printf '%s' "$body" | python3 -c '
import json,sys
try:
  d=json.loads(sys.stdin.read())
  items=d.get("items") or d.get("connectedAccounts") or d.get("data") or []
  if not items:
    print("NONE"); sys.exit(0)
  for it in items:
    s=str(it.get("status","")).upper()
    if s:
      print(s); sys.exit(0)
  print("UNKNOWN")
except Exception:
  print("ERR")' 2>/dev/null || echo ERR)"
  case "$status" in
    ACTIVE)    record OK   composio-twitter "ACTIVE" ;;
    INITIATED) record WARN composio-twitter "INITIATED — finish OAuth flow" ;;
    EXPIRED)   record FAIL composio-twitter "EXPIRED — re-link with: composio link twitter" ;;
    NONE)      record WARN composio-twitter "no twitter connected_account" ;;
    ERR)       record FAIL composio-twitter "could not parse connected_accounts response" ;;
    *)         record WARN composio-twitter "status=$status" ;;
  esac
}

# --- apple-calendar-access ---------------------------------------------------
probe_apple_calendar() {
  local out
  if ! out="$(osascript -e 'tell application "Calendar" to count of calendars' 2>&1)"; then
    record WARN apple-calendar-access "AppleScript error — System Settings → Privacy & Security → Automation → Terminal/Codex → Calendars"
    return 0
  fi
  local trimmed
  trimmed="$(printf '%s' "$out" | tr -d '\r\n[:space:]')"
  case "$trimmed" in
    ''|*[!0-9]*)
      record WARN apple-calendar-access "non-numeric reply: $out — grant access in System Settings → Privacy & Security"
      ;;
    *)
      record OK apple-calendar-access "$trimmed calendar(s) visible"
      ;;
  esac
}

# --- apple-reminders-access --------------------------------------------------
probe_apple_reminders() {
  local out
  if ! out="$(osascript -e 'tell application "Reminders" to count of lists' 2>&1)"; then
    record WARN apple-reminders-access "AppleScript error — System Settings → Privacy & Security → Reminders"
    return 0
  fi
  local trimmed
  trimmed="$(printf '%s' "$out" | tr -d '\r\n[:space:]')"
  case "$trimmed" in
    ''|*[!0-9]*)
      record WARN apple-reminders-access "non-numeric reply: $out — grant access in System Settings → Privacy & Security"
      ;;
    *)
      record OK apple-reminders-access "$trimmed list(s) visible"
      ;;
  esac
}

# Tolerate individual probe failures; we collect statuses ourselves.
probe_ollama_server   || true
probe_ollama_model    || true
probe_composio_cli    || true
probe_composio_gmail  || true
probe_composio_linkedin || true
probe_composio_twitter  || true
probe_apple_calendar    || true
probe_apple_reminders   || true

# --- determine RESULT --------------------------------------------------------
# ready   = no FAIL and (gmail or linkedin) OK
# degraded= at least one OK (incl. gmail/linkedin) but something missing/FAIL
# down    = nothing OK
RESULT="down"
if [ "$HAS_OK" -gt 0 ]; then
  if [ "$HAS_FAIL" -eq 0 ] && { [ "$GMAIL_OK" -eq 1 ] || [ "$LINKEDIN_OK" -eq 1 ]; }; then
    RESULT="ready"
  else
    RESULT="degraded"
  fi
fi

if [ "$JSON" -eq 1 ]; then
  joined="$(IFS=, ; printf '%s' "${PROBE_JSON_ITEMS[*]}")"
  printf '{"integrations":[%s],"result":"%s"}\n' "$joined" "$RESULT"
else
  printf 'RESULT: %s\n' "$RESULT"
fi

if [ "$STRICT" -eq 1 ] && [ "$HAS_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
