#!/usr/bin/env bash
# Read-only Composio health validator for OS1 operator checks.

set -euo pipefail

SCRIPT_NAME="composio-health-check"

usage() {
  cat <<'USAGE'
Usage: scripts/composio-health-check.sh [options]

Read-only Composio health validator.

Options:
  --expected CSV          Expected active toolkit slugs. Default: gmail,linkedin
  --strict                Exit 1 if any probe reports FAIL.
  --json                  Emit one JSON document.
  --quiet                 Suppress per-check human output; print only RESULT.
  --timeout-seconds N     Per-request timeout. Default: 8
  -h, --help              Show this help.

Environment:
  COMPOSIO_BIN            Default: $HOME/.composio/composio
  COMPOSIO_API_KEY_FILE   Default: $HOME/.composio/api_key
  COMPOSIO_API_BASE       Default: https://backend.composio.dev/api/v3
USAGE
}

EXPECTED_CSV="gmail,linkedin"
STRICT=0
JSON=0
QUIET=0
TIMEOUT_SECONDS=8

while [ "$#" -gt 0 ]; do
  case "$1" in
    --expected)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      EXPECTED_CSV="$2"
      shift 2
      ;;
    --strict)
      STRICT=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --quiet)
      QUIET=1
      shift
      ;;
    --timeout-seconds)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      case "$2" in
        ''|*[!0-9]*)
          usage >&2
          printf '%s: --timeout-seconds requires a positive integer\n' "$SCRIPT_NAME" >&2
          exit 2
          ;;
        *)
          if [ "$2" -lt 1 ]; then
            usage >&2
            printf '%s: --timeout-seconds requires a positive integer\n' "$SCRIPT_NAME" >&2
            exit 2
          fi
          ;;
      esac
      TIMEOUT_SECONDS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
      exit 2
      ;;
  esac
done

COMPOSIO_BIN="${COMPOSIO_BIN:-$HOME/.composio/composio}"
COMPOSIO_API_KEY_FILE="${COMPOSIO_API_KEY_FILE:-$HOME/.composio/api_key}"
COMPOSIO_API_BASE="${COMPOSIO_API_BASE:-https://backend.composio.dev/api/v3}"

CHECK_JSON=()
CHECK_LINES=()
HAS_OK=0
HAS_WARN=0
HAS_FAIL=0
PRECONDITION_FAILED=0
API_KEY=""
ACCOUNTS_JSON=""

json_escape() {
  python3 -c 'import json,sys; sys.stdout.write(json.dumps(sys.stdin.read()))' <<<"$1"
}

record() {
  local status="$1" name="$2" detail="$3"
  local detail_json
  detail_json="$(json_escape "$detail")"
  CHECK_JSON+=("{\"name\":\"$name\",\"status\":\"$status\",\"detail\":$detail_json}")
  CHECK_LINES+=("$status $name: $detail")
  case "$status" in
    OK) HAS_OK=$((HAS_OK + 1)) ;;
    WARN) HAS_WARN=$((HAS_WARN + 1)) ;;
    FAIL) HAS_FAIL=$((HAS_FAIL + 1)) ;;
  esac
  if [ "$JSON" -eq 0 ] && [ "$QUIET" -eq 0 ]; then
    printf '%s %s: %s\n' "$status" "$name" "$detail"
  fi
}

precondition_fail() {
  PRECONDITION_FAILED=1
  record FAIL "$1" "$2"
}

secure_file_mode() {
  local path="$1" mode
  if mode="$(stat -f '%OLp' "$path" 2>/dev/null)"; then
    :
  elif mode="$(stat -c '%a' "$path" 2>/dev/null)"; then
    :
  else
    return 1
  fi
  # Parse as octal. 0600 or stricter means no group/other permission bits;
  # owner bits may be read-only or read/write.
  mode="${mode#0}"
  mode=$((8#$mode))
  [ $((mode & 077)) -eq 0 ]
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT_SECONDS" "$@"
  else
    python3 - "$TIMEOUT_SECONDS" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
cmd = sys.argv[2:]
try:
    completed = subprocess.run(cmd, stdin=subprocess.DEVNULL, timeout=timeout)
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.exit(completed.returncode)
PY
  fi
}

normalize_expected() {
  printf '%s' "$EXPECTED_CSV" | python3 -c '
import sys
items = []
for raw in sys.stdin.read().split(","):
    item = raw.strip().lower()
    if item and item not in items:
        items.append(item)
print(",".join(items))
'
}

EXPECTED_CSV="$(normalize_expected)"
if [ -z "$EXPECTED_CSV" ]; then
  printf '%s: --expected must include at least one toolkit slug\n' "$SCRIPT_NAME" >&2
  exit 2
fi

probe_cli() {
  if [ ! -x "$COMPOSIO_BIN" ]; then
    precondition_fail composio-cli "missing executable: $COMPOSIO_BIN"
    return 1
  fi
  local version
  if ! version="$(run_with_timeout "$COMPOSIO_BIN" --version 2>/dev/null | tr -d '\r' | tail -n 1)"; then
    precondition_fail composio-cli "installed but --version failed"
    return 1
  fi
  if [ -z "$version" ]; then
    record WARN composio-cli "installed but version output was empty"
  else
    record OK composio-cli "installed ($version)"
  fi
}

probe_api_key() {
  if [ ! -e "$COMPOSIO_API_KEY_FILE" ]; then
    precondition_fail composio-api-key "missing: $COMPOSIO_API_KEY_FILE"
    return 1
  fi
  if [ ! -r "$COMPOSIO_API_KEY_FILE" ]; then
    precondition_fail composio-api-key "unreadable: $COMPOSIO_API_KEY_FILE"
    return 1
  fi
  if ! secure_file_mode "$COMPOSIO_API_KEY_FILE"; then
    precondition_fail composio-api-key "file mode must be 0600 or stricter"
    return 1
  fi
  API_KEY="$(tr -d '\r\n' < "$COMPOSIO_API_KEY_FILE")"
  if [ -z "$API_KEY" ]; then
    precondition_fail composio-api-key "file exists but is empty"
    return 1
  fi
  record OK composio-api-key "set"
}

curl_get() {
  local url="$1"
  curl -fsS -m "$TIMEOUT_SECONDS" \
    -H "x-api-key: $API_KEY" \
    -H "Accept: application/json" \
    "$url"
}

probe_api_reachable() {
  local body
  if ! body="$(curl_get "${COMPOSIO_API_BASE%/}/connected_accounts?limit=1" 2>/dev/null)"; then
    record FAIL composio-api "GET /connected_accounts?limit=1 failed"
    return 1
  fi
  if ! printf '%s' "$body" | python3 -m json.tool >/dev/null 2>&1; then
    record FAIL composio-api "GET /connected_accounts?limit=1 returned non-JSON"
    return 1
  fi
  record OK composio-api "reachable"
}

fetch_accounts() {
  local body
  if ! body="$(curl_get "${COMPOSIO_API_BASE%/}/connected_accounts?limit=100" 2>/dev/null)"; then
    record FAIL connected-accounts "GET /connected_accounts?limit=100 failed"
    return 1
  fi
  if ! printf '%s' "$body" | python3 -m json.tool >/dev/null 2>&1; then
    record FAIL connected-accounts "response was not JSON"
    return 1
  fi
  ACCOUNTS_JSON="$body"
  record OK connected-accounts "inventory readable"
}

probe_expected_toolkits() {
  local report status
  report="$(EXPECTED="$EXPECTED_CSV" python3 -c '
import json, os, sys

expected = [x for x in os.environ["EXPECTED"].split(",") if x]

def items_from(payload):
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("items", "data", "connected_accounts", "connectedAccounts"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            nested = items_from(value)
            if nested:
                return nested
    return []

def toolkit_of(item):
    for key in ("toolkit", "toolkit_slug", "toolkitSlug", "appName", "app_name"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value.lower()
        if isinstance(value, dict):
            slug = value.get("slug") or value.get("name")
            if isinstance(slug, str) and slug:
                return slug.lower()
    auth = item.get("auth_config") or item.get("authConfig") or {}
    if isinstance(auth, dict):
        for key in ("toolkit", "toolkit_slug", "toolkitSlug"):
            value = auth.get(key)
            if isinstance(value, str) and value:
                return value.lower()
            if isinstance(value, dict):
                slug = value.get("slug") or value.get("name")
                if isinstance(slug, str) and slug:
                    return slug.lower()
    return ""

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("FAIL\tcould not parse inventory")
    raise SystemExit(0)

by_toolkit = {}
for item in items_from(payload):
    if isinstance(item, dict):
        toolkit = toolkit_of(item)
        if toolkit:
            by_toolkit.setdefault(toolkit, []).append(str(item.get("status", "")).upper() or "UNKNOWN")

parts = []
has_fail = False
has_warn = False
for toolkit in expected:
    statuses = by_toolkit.get(toolkit, [])
    if "ACTIVE" in statuses:
        parts.append(f"{toolkit}=ACTIVE")
    elif "INITIATED" in statuses:
        parts.append(f"{toolkit}=INITIATED")
        has_warn = True
    elif statuses:
        parts.append(f"{toolkit}={statuses[0]}")
        has_fail = True
    else:
        parts.append(f"{toolkit}=missing")
        has_fail = True

if has_fail:
    print("FAIL\t" + ", ".join(parts))
elif has_warn:
    print("WARN\t" + ", ".join(parts))
else:
    print("OK\t" + ", ".join(parts))
' <<<"$ACCOUNTS_JSON")"
  status="${report%%$'\t'*}"
  record "$status" expected-toolkits "${report#*$'\t'}"
}

probe_toolkit_statuses() {
  local report status
  report="$(python3 -c '
import json, sys

def items_from(payload):
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("items", "data", "connected_accounts", "connectedAccounts"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            nested = items_from(value)
            if nested:
                return nested
    return []

def toolkit_of(item):
    for key in ("toolkit", "toolkit_slug", "toolkitSlug", "appName", "app_name"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value.lower()
        if isinstance(value, dict):
            slug = value.get("slug") or value.get("name")
            if isinstance(slug, str) and slug:
                return slug.lower()
    return "unknown"

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("FAIL\tcould not parse inventory")
    raise SystemExit(0)

counts = {}
for item in items_from(payload):
    if not isinstance(item, dict):
        continue
    toolkit = toolkit_of(item)
    status = str(item.get("status", "")).upper() or "UNKNOWN"
    counts.setdefault(toolkit, {}).setdefault(status, 0)
    counts[toolkit][status] += 1

if not counts:
    print("WARN\tno connected accounts returned")
    raise SystemExit(0)

parts = []
has_fail = False
has_warn = False
for toolkit in sorted(counts):
    status_counts = counts[toolkit]
    bits = [f"{status}:{status_counts[status]}" for status in sorted(status_counts)]
    joined = ";".join(bits)
    parts.append(f"{toolkit}({joined})")
    if any(status in status_counts for status in ("FAILED", "EXPIRED", "DELETED", "DISABLED", "ERROR")):
        has_fail = True
    if "INITIATED" in status_counts:
        has_warn = True

if has_fail:
    print("FAIL\t" + ", ".join(parts))
elif has_warn:
    print("WARN\t" + ", ".join(parts))
else:
    print("OK\t" + ", ".join(parts))
' <<<"$ACCOUNTS_JSON")"
  status="${report%%$'\t'*}"
  record "$status" toolkit-statuses "${report#*$'\t'}"
}

probe_gmail_profile() {
  if [[ ",$EXPECTED_CSV," != *",gmail,"* ]]; then
    record WARN gmail-profile "skipped; gmail not in --expected"
    return 0
  fi
  local body email
  if ! body="$(run_with_timeout "$COMPOSIO_BIN" proxy -X GET \
      'https://gmail.googleapis.com/gmail/v1/users/me/profile' \
      --toolkit gmail </dev/null 2>/dev/null)"; then
    record FAIL gmail-profile "read-only profile request failed"
    return 1
  fi
  email="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get("emailAddress", ""))
except Exception:
    print("")
' <<<"$body")"
  if [ -z "$email" ]; then
    record FAIL gmail-profile "profile response missing emailAddress"
  else
    record OK gmail-profile "roundtrip ok"
  fi
}

probe_linkedin_userinfo() {
  if [[ ",$EXPECTED_CSV," != *",linkedin,"* ]]; then
    record WARN linkedin-userinfo "skipped; linkedin not in --expected"
    return 0
  fi
  local body marker
  if ! body="$(run_with_timeout "$COMPOSIO_BIN" proxy -X GET \
      'https://api.linkedin.com/v2/userinfo' \
      --toolkit linkedin </dev/null 2>/dev/null)"; then
    record FAIL linkedin-userinfo "read-only userinfo request failed"
    return 1
  fi
  marker="$(python3 -c '
import json, sys
try:
    data = json.loads(sys.stdin.read())
    print(data.get("sub") or data.get("name") or "")
except Exception:
    print("")
' <<<"$body")"
  if [ -z "$marker" ]; then
    record FAIL linkedin-userinfo "userinfo response missing sub/name"
  else
    record OK linkedin-userinfo "roundtrip ok"
  fi
}

probe_no_orphan_accounts() {
  local report status
  report="$(EXPECTED="$EXPECTED_CSV" python3 -c '
import json, os, sys

expected = set(x for x in os.environ["EXPECTED"].split(",") if x)
bad_statuses = {"FAILED", "EXPIRED", "DELETED", "DISABLED", "ERROR"}

def items_from(payload):
    if isinstance(payload, list):
        return payload
    if not isinstance(payload, dict):
        return []
    for key in ("items", "data", "connected_accounts", "connectedAccounts"):
        value = payload.get(key)
        if isinstance(value, list):
            return value
        if isinstance(value, dict):
            nested = items_from(value)
            if nested:
                return nested
    return []

def toolkit_of(item):
    for key in ("toolkit", "toolkit_slug", "toolkitSlug", "appName", "app_name"):
        value = item.get(key)
        if isinstance(value, str) and value:
            return value.lower()
        if isinstance(value, dict):
            slug = value.get("slug") or value.get("name")
            if isinstance(slug, str) and slug:
                return slug.lower()
    return "unknown"

def account_id(item):
    return str(item.get("id") or item.get("connected_account_id") or item.get("connectedAccountId") or "unknown")

try:
    payload = json.loads(sys.stdin.read())
except Exception:
    print("FAIL\tcould not parse inventory")
    raise SystemExit(0)

orphans = []
for item in items_from(payload):
    if not isinstance(item, dict):
        continue
    toolkit = toolkit_of(item)
    status = str(item.get("status", "")).upper() or "UNKNOWN"
    if toolkit not in expected or status in bad_statuses:
        orphans.append(f"{toolkit}:{status}:{account_id(item)}")

if orphans:
    print("FAIL\t" + ", ".join(orphans[:8]))
else:
    print("OK\tno orphan or stale accounts found")
' <<<"$ACCOUNTS_JSON")"
  status="${report%%$'\t'*}"
  record "$status" no-orphan-accounts "${report#*$'\t'}"
}

probe_cli || true
probe_api_key || true

if [ "$PRECONDITION_FAILED" -eq 0 ]; then
  probe_api_reachable || true
  fetch_accounts || true
  if [ -n "$ACCOUNTS_JSON" ]; then
    probe_expected_toolkits || true
    probe_toolkit_statuses || true
    probe_no_orphan_accounts || true
  fi
  probe_gmail_profile || true
  probe_linkedin_userinfo || true
fi

RESULT="down"
if [ "$PRECONDITION_FAILED" -eq 1 ]; then
  RESULT="down"
elif [ "$HAS_FAIL" -eq 0 ]; then
  RESULT="ready"
elif [ "$HAS_OK" -gt 0 ] || [ "$HAS_WARN" -gt 0 ]; then
  RESULT="degraded"
fi

if [ "$JSON" -eq 1 ]; then
  joined="$(IFS=, ; printf '%s' "${CHECK_JSON[*]}")"
  printf '{"checks":[%s],"result":"%s"}\n' "$joined" "$RESULT"
else
  printf 'RESULT: %s\n' "$RESULT"
fi

if [ "$PRECONDITION_FAILED" -eq 1 ]; then
  exit 3
fi
if [ "$RESULT" = "down" ]; then
  exit 1
fi
if [ "$STRICT" -eq 1 ] && [ "$HAS_FAIL" -gt 0 ]; then
  exit 1
fi
exit 0
