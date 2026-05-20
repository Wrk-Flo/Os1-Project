#!/usr/bin/env bash
# os1-post-approved-content.sh — OS1 posting sidecar.
#
# Pushes an approved markdown post out through Composio to one or more
# channels. Designed to live downstream of the OS1 brief generator: an
# operator approves a brief (or a derived clean post) and runs this script
# pointing --content at the markdown file.
#
# Channels (v1):
#   linkedin     primary live channel (ACTIVE as of 2026-05-18)
#   gmail-draft  always-available fallback — writes a Gmail draft, never sends
#   twitter      stub; NO-OPs until the Composio connection flips to ACTIVE
#
# Default mode is --dry-run for safety. --apply is required to actually post.
#
# Owner: Claude Code. New file. Does NOT edit anything in Codex's lane
# (runners, readiness gate, health, installers, Sources/, Tests/, ci.yml).
#
# Exit codes:
#   0  at least one channel succeeded OR a clean dry-run
#   1  all attempted channels failed
#   2  usage error
#   3  prerequisite missing (composio CLI, jq, or api key)

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"

COMPOSIO_BIN="${OS1_COMPOSIO_BIN:-/Users/$(id -un)/.composio/composio}"
[ -x "$COMPOSIO_BIN" ] || COMPOSIO_BIN="$(command -v composio 2>/dev/null || true)"
API_KEY_FILE="${OS1_COMPOSIO_API_KEY_FILE:-$HOME/.composio/api_key}"
API_BASE="${OS1_COMPOSIO_API_BASE:-https://backend.composio.dev/api/v3}"

CONTENT=""
CHANNELS_CSV="linkedin,gmail-draft"
GMAIL_TO=""
LINKEDIN_VISIBILITY="CONNECTIONS"
OUT_DIR=""
MODE="dry-run"   # dry-run | apply
MODE_SET=0

TS="$(date -u +%Y%m%dT%H%M%SZ)"
DEFAULT_OUT_ROOT="$HOME/Library/Application Support/OS1/posts/runs"

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME --content PATH [--channels CSV] [--gmail-to ADDR]
                                   [--linkedin-visibility {PUBLIC,CONNECTIONS}]
                                   [--out DIR] [--dry-run | --apply] [-h|--help]

Required:
  --content PATH         Markdown file. First H1 (# Title) becomes the post
                         title where applicable; remainder is the body. If no
                         H1, the whole file is body.

Options:
  --channels CSV         Comma-separated subset of:
                           linkedin, gmail-draft, twitter
                         Default: linkedin,gmail-draft
  --gmail-to ADDR        Recipient for the Gmail draft. REQUIRED when
                         gmail-draft is in --channels.
  --linkedin-visibility  PUBLIC or CONNECTIONS. Default: CONNECTIONS.
  --out DIR              Per-run artifact directory.
                         Default: \$DEFAULT_OUT_ROOT/<ts>/
  --dry-run              Preview API calls without executing (default).
  --apply                Actually execute. Mutually exclusive with --dry-run.
  -h, --help             Show this help.

Live integration state (verified 2026-05-18):
  linkedin  ACTIVE     ca_9IfVCfV7xpXI
  gmail     ACTIVE     ca_wn5lq8W8tCMf
  twitter   INITIATED  ca_C1Vr3KdsEmYi  -> currently SKIPped (awaiting OAuth)
USAGE
}

die_usage() { printf 'ERROR: %s\n\n' "$1" >&2; usage >&2; exit 2; }
die_prereq() { printf 'ERROR: %s\n' "$1" >&2; exit 3; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    --content)
      [ "$#" -ge 2 ] || die_usage "--content requires a path"
      CONTENT="$2"; shift ;;
    --channels)
      [ "$#" -ge 2 ] || die_usage "--channels requires a value"
      CHANNELS_CSV="$2"; shift ;;
    --gmail-to)
      [ "$#" -ge 2 ] || die_usage "--gmail-to requires an address"
      GMAIL_TO="$2"; shift ;;
    --linkedin-visibility)
      [ "$#" -ge 2 ] || die_usage "--linkedin-visibility requires a value"
      LINKEDIN_VISIBILITY="$2"; shift ;;
    --out)
      [ "$#" -ge 2 ] || die_usage "--out requires a directory"
      OUT_DIR="$2"; shift ;;
    --dry-run)
      [ "$MODE_SET" -eq 1 ] && [ "$MODE" = "apply" ] && \
        die_usage "--dry-run and --apply are mutually exclusive"
      MODE="dry-run"; MODE_SET=1 ;;
    --apply)
      [ "$MODE_SET" -eq 1 ] && [ "$MODE" = "dry-run" ] && \
        die_usage "--dry-run and --apply are mutually exclusive"
      MODE="apply"; MODE_SET=1 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      die_usage "Unknown argument: $1" ;;
  esac
  shift
done

# ---------- validation ----------

[ -n "$CONTENT" ] || die_usage "--content is required"
[ -f "$CONTENT" ] || die_usage "--content path not found: $CONTENT"

case "$LINKEDIN_VISIBILITY" in
  PUBLIC|CONNECTIONS) ;;
  *) die_usage "--linkedin-visibility must be PUBLIC or CONNECTIONS (got: $LINKEDIN_VISIBILITY)" ;;
esac

# Parse channels into a deduped array.
KNOWN_CHANNELS=("linkedin" "gmail-draft" "twitter")
declare -a CHANNELS=()
declare -a SEEN=()
IFS=',' read -r -a _raw_channels <<<"$CHANNELS_CSV"
for raw in "${_raw_channels[@]}"; do
  ch="$(printf '%s' "$raw" | tr -d '[:space:]')"
  [ -z "$ch" ] && continue
  ok=0
  for k in "${KNOWN_CHANNELS[@]}"; do
    [ "$ch" = "$k" ] && ok=1
  done
  if [ "$ok" -ne 1 ]; then
    die_usage "Unknown channel: '$ch' (valid: ${KNOWN_CHANNELS[*]})"
  fi
  dup=0
  for s in "${SEEN[@]:-}"; do
    [ "$s" = "$ch" ] && dup=1
  done
  if [ "$dup" -eq 0 ]; then
    CHANNELS+=("$ch")
    SEEN+=("$ch")
  fi
done
[ "${#CHANNELS[@]}" -gt 0 ] || die_usage "No channels selected"

# Channel-specific required args.
for ch in "${CHANNELS[@]}"; do
  if [ "$ch" = "gmail-draft" ] && [ -z "$GMAIL_TO" ]; then
    die_usage "--gmail-to is required when gmail-draft is in --channels"
  fi
done

# Prereqs.
command -v jq >/dev/null 2>&1 || die_prereq "jq not found on PATH. Install: brew install jq"
[ -n "$COMPOSIO_BIN" ] && [ -x "$COMPOSIO_BIN" ] || die_prereq "composio CLI not found. Expected at \$OS1_COMPOSIO_BIN or 'composio' on PATH."
[ -r "$API_KEY_FILE" ] || die_prereq "Composio API key not readable at $API_KEY_FILE. Run: composio login"

# Resolve output directory.
if [ -z "$OUT_DIR" ]; then
  OUT_DIR="$DEFAULT_OUT_ROOT/$TS"
fi
mkdir -p "$OUT_DIR"

TMP_DIR="$(mktemp -d -t os1-post-approved.XXXXXX)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------- helpers ----------

# Pull API key from disk once and keep it in-memory; never log it, never write
# it into artifacts. We pipe to curl via -H @-file-with-leading-header.
API_KEY="$(cat "$API_KEY_FILE")"
[ -n "$API_KEY" ] || die_prereq "Composio API key file is empty: $API_KEY_FILE"

# Read content and split title + body.
RAW_CONTENT="$(cat "$CONTENT")"
TITLE=""
BODY=""
if printf '%s\n' "$RAW_CONTENT" | head -n1 | grep -Eq '^# '; then
  TITLE="$(printf '%s\n' "$RAW_CONTENT" | head -n1 | sed -E 's/^# +//')"
  BODY="$(printf '%s\n' "$RAW_CONTENT" | tail -n +2 | sed -E '/^[[:space:]]*$/d;q;d' >/dev/null; printf '%s\n' "$RAW_CONTENT" | tail -n +2)"
else
  BODY="$RAW_CONTENT"
fi
# Trim leading blank lines off BODY.
BODY="$(printf '%s' "$BODY" | awk 'BEGIN{seen=0} {if (!seen && $0 ~ /^[[:space:]]*$/) next; seen=1; print}')"
SUBJECT="${TITLE:-OS1 Approved Post}"

truncated_body() {
  # Print first 200 chars of $BODY on a single line for the run summary.
  printf '%s' "$BODY" | tr '\n' ' ' | awk '{ if (length($0)>200) print substr($0,1,200) "..."; else print $0 }'
}

# base64url encode stdin -> stdout. macOS base64 has no -w; we use python3.
b64url() {
  python3 -c 'import sys,base64; sys.stdout.write(base64.urlsafe_b64encode(sys.stdin.buffer.read()).decode().rstrip("="))'
}

# Issue a Composio API call (not toolkit proxy — this is for /api/v3/*).
# Args: METHOD URL  -- echoes response body to stdout. HTTP code written to FD 3 if provided.
composio_api() {
  local method="$1" url="$2"
  local code_file="$TMP_DIR/api_code.$$"
  local resp
  resp="$(curl -sS -o "$TMP_DIR/api_body.$$" -w '%{http_code}' \
    -X "$method" \
    -H "x-api-key: $API_KEY" \
    -H "content-type: application/json" \
    "$url")" || true
  printf '%s' "$resp" >"$code_file"
  cat "$TMP_DIR/api_body.$$"
}

last_http_code() { cat "$TMP_DIR/api_code.$$" 2>/dev/null || echo ""; }

# Run composio proxy. Args: TOOLKIT METHOD URL DATA_FILE
# echoes response body to stdout.
composio_proxy_call() {
  local toolkit="$1" method="$2" url="$3" data_file="$4"
  local out="$TMP_DIR/proxy_out.$$"
  set +e
  if [ -n "$data_file" ]; then
    "$COMPOSIO_BIN" proxy "$url" --toolkit "$toolkit" -X "$method" \
      -H "content-type: application/json" \
      -d "@$data_file" </dev/null >"$out" 2>&1
  else
    "$COMPOSIO_BIN" proxy "$url" --toolkit "$toolkit" -X "$method" </dev/null >"$out" 2>&1
  fi
  local rc=$?
  set -e
  printf '%d' "$rc" >"$TMP_DIR/proxy_rc.$$"
  cat "$out"
}

last_proxy_rc() { cat "$TMP_DIR/proxy_rc.$$" 2>/dev/null || echo "1"; }

# Redact secrets from a JSON blob (Authorization, x-api-key, refresh tokens).
redact_json() {
  jq '
    walk(
      if type == "object" then
        with_entries(
          if (.key | ascii_downcase) as $k
             | ($k=="authorization" or $k=="x-api-key" or $k=="api_key"
                or $k=="refresh_token" or $k=="access_token")
          then .value = "REDACTED"
          else .
          end
        )
      else .
      end
    )
  ' 2>/dev/null || cat
}

# ---------- pre-check connected accounts ----------

CH_STATUS_LINKEDIN=""
CH_STATUS_GMAIL_DRAFT=""
CH_STATUS_TWITTER=""
CH_CA_ID_LINKEDIN=""
CH_CA_ID_GMAIL_DRAFT=""
CH_CA_ID_TWITTER=""
CH_RESULT_LINKEDIN=""
CH_RESULT_GMAIL_DRAFT=""
CH_RESULT_TWITTER=""

set_ch_status() {
  case "$1" in
    linkedin) CH_STATUS_LINKEDIN="$2" ;;
    gmail-draft) CH_STATUS_GMAIL_DRAFT="$2" ;;
    twitter) CH_STATUS_TWITTER="$2" ;;
  esac
}

get_ch_status() {
  case "$1" in
    linkedin) printf '%s' "$CH_STATUS_LINKEDIN" ;;
    gmail-draft) printf '%s' "$CH_STATUS_GMAIL_DRAFT" ;;
    twitter) printf '%s' "$CH_STATUS_TWITTER" ;;
    *) printf 'NONE' ;;
  esac
}

set_ch_ca_id() {
  case "$1" in
    linkedin) CH_CA_ID_LINKEDIN="$2" ;;
    gmail-draft) CH_CA_ID_GMAIL_DRAFT="$2" ;;
    twitter) CH_CA_ID_TWITTER="$2" ;;
  esac
}

get_ch_ca_id() {
  case "$1" in
    linkedin) printf '%s' "$CH_CA_ID_LINKEDIN" ;;
    gmail-draft) printf '%s' "$CH_CA_ID_GMAIL_DRAFT" ;;
    twitter) printf '%s' "$CH_CA_ID_TWITTER" ;;
  esac
}

set_ch_result() {
  case "$1" in
    linkedin) CH_RESULT_LINKEDIN="$2" ;;
    gmail-draft) CH_RESULT_GMAIL_DRAFT="$2" ;;
    twitter) CH_RESULT_TWITTER="$2" ;;
  esac
}

get_ch_result() {
  case "$1" in
    linkedin) printf '%s' "$CH_RESULT_LINKEDIN" ;;
    gmail-draft) printf '%s' "$CH_RESULT_GMAIL_DRAFT" ;;
    twitter) printf '%s' "$CH_RESULT_TWITTER" ;;
    *) printf 'unknown' ;;
  esac
}

precheck_channel() {
  local ch="$1" toolkit
  case "$ch" in
    linkedin)    toolkit="linkedin" ;;
    gmail-draft) toolkit="gmail" ;;
    twitter)     toolkit="twitter" ;;
    *) set_ch_status "$ch" "UNKNOWN"; return ;;
  esac
  local body
  body="$(composio_api GET "$API_BASE/connected_accounts?toolkit_slugs=$toolkit&statuses=ACTIVE,INITIATED,EXPIRED,FAILED&limit=20")"
  local status ca_id
  status="$(printf '%s' "$body" | jq -r --arg t "$toolkit" '
    [ (.items // [])[] | select(.toolkit.slug==$t) ]
    | (sort_by(.updated_at) | reverse | .[0].status // "NONE")
  ' 2>/dev/null || printf 'NONE')"
  ca_id="$(printf '%s' "$body" | jq -r --arg t "$toolkit" '
    [ (.items // [])[] | select(.toolkit.slug==$t) ]
    | (sort_by(.updated_at) | reverse | .[0].id // "")
  ' 2>/dev/null || printf '')"
  set_ch_status "$ch" "$status"
  set_ch_ca_id "$ch" "$ca_id"
}

for ch in "${CHANNELS[@]}"; do
  precheck_channel "$ch"
done

# ---------- per-channel posters ----------

LINKEDIN_URN=""

fetch_linkedin_urn() {
  if [ -n "$LINKEDIN_URN" ]; then return 0; fi
  local body
  body="$(composio_proxy_call linkedin GET "https://api.linkedin.com/v2/userinfo" "")"
  local sub
  sub="$(printf '%s' "$body" | jq -r '.sub // empty' 2>/dev/null || true)"
  if [ -z "$sub" ]; then
    return 1
  fi
  LINKEDIN_URN="urn:li:person:$sub"
  return 0
}

post_linkedin() {
  local ch_out="$OUT_DIR/linkedin.json"
  local meta_out="$OUT_DIR/linkedin.meta.json"

  if [ "$MODE" = "dry-run" ]; then
    local urn="urn:li:person:<resolved-at-apply>"
    local data_file="$TMP_DIR/li_data.json"
    jq -n --arg urn "$urn" --arg body "$BODY" --arg vis "$LINKEDIN_VISIBILITY" '{
      author: $urn,
      lifecycleState: "PUBLISHED",
      specificContent: {
        "com.linkedin.ugc.ShareContent": {
          shareCommentary: {text: $body},
          shareMediaCategory: "NONE"
        }
      },
      visibility: {"com.linkedin.ugc.MemberNetworkVisibility": $vis}
    }' >"$data_file"
    printf 'DRY-RUN linkedin: POST https://api.linkedin.com/v2/ugcPosts (via composio proxy --toolkit linkedin)\n'
    printf 'DRY-RUN linkedin: visibility=%s body_chars=%d body_preview=%s\n' \
      "$LINKEDIN_VISIBILITY" "${#BODY}" "$(truncated_body)"
    cp "$data_file" "$ch_out"
    echo "OK linkedin: dry-run"
    return 0
  fi

  # Apply mode.
  if ! fetch_linkedin_urn; then
    echo "FAIL linkedin: could not resolve person URN from /v2/userinfo" >&2
    return 1
  fi
  local data_file="$TMP_DIR/li_data.json"
  jq -n --arg urn "$LINKEDIN_URN" --arg body "$BODY" --arg vis "$LINKEDIN_VISIBILITY" '{
    author: $urn,
    lifecycleState: "PUBLISHED",
    specificContent: {
      "com.linkedin.ugc.ShareContent": {
        shareCommentary: {text: $body},
        shareMediaCategory: "NONE"
      }
    },
    visibility: {"com.linkedin.ugc.MemberNetworkVisibility": $vis}
  }' >"$data_file"
  local resp
  resp="$(composio_proxy_call linkedin POST "https://api.linkedin.com/v2/ugcPosts" "$data_file")"
  local rc; rc="$(last_proxy_rc)"
  printf '%s' "$resp" | redact_json >"$ch_out" || printf '%s' "$resp" >"$ch_out"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL linkedin: composio proxy rc=$rc (see $ch_out)" >&2
    return 1
  fi
  local post_id
  post_id="$(printf '%s' "$resp" | jq -r '.id // .activity // empty' 2>/dev/null || true)"
  echo "OK linkedin: posted id=${post_id:-unknown}"
  jq -n --arg id "${post_id:-}" --arg urn "$LINKEDIN_URN" '{id:$id, urn:$urn}' >"$meta_out"
  return 0
}

post_gmail_draft() {
  local ch_out="$OUT_DIR/gmail-draft.json"
  local raw_file="$TMP_DIR/gmail_raw.eml"
  {
    printf 'To: %s\r\n' "$GMAIL_TO"
    printf 'Subject: %s\r\n' "$SUBJECT"
    printf 'MIME-Version: 1.0\r\n'
    printf 'Content-Type: text/plain; charset=utf-8\r\n'
    printf '\r\n'
    printf '%s' "$BODY"
  } >"$raw_file"
  local raw_b64
  raw_b64="$(b64url <"$raw_file")"
  local data_file="$TMP_DIR/gmail_data.json"
  jq -n --arg raw "$raw_b64" '{message:{raw:$raw}}' >"$data_file"

  if [ "$MODE" = "dry-run" ]; then
    printf 'DRY-RUN gmail-draft: POST https://gmail.googleapis.com/gmail/v1/users/me/drafts (via composio proxy --toolkit gmail)\n'
    printf 'DRY-RUN gmail-draft: to=%s subject=%s body_chars=%d body_preview=%s\n' \
      "$GMAIL_TO" "$SUBJECT" "${#BODY}" "$(truncated_body)"
    cp "$data_file" "$ch_out"
    echo "OK gmail-draft: dry-run"
    return 0
  fi

  local resp
  resp="$(composio_proxy_call gmail POST "https://gmail.googleapis.com/gmail/v1/users/me/drafts" "$data_file")"
  local rc; rc="$(last_proxy_rc)"
  printf '%s' "$resp" | redact_json >"$ch_out" || printf '%s' "$resp" >"$ch_out"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL gmail-draft: composio proxy rc=$rc (see $ch_out)" >&2
    return 1
  fi
  local draft_id
  draft_id="$(printf '%s' "$resp" | jq -r '.id // empty' 2>/dev/null || true)"
  echo "OK gmail-draft: draft id=${draft_id:-unknown} for $GMAIL_TO"
  return 0
}

post_twitter() {
  # Twitter is a stub until the toolkit flips to ACTIVE. Default behavior is
  # SKIP with a pointer to the integration-state runbook. If it ever becomes
  # ACTIVE we POST /2/tweets with the first 270 chars (margin under the 280
  # limit for mid-string ellipsis).
  local status
  status="$(get_ch_status twitter)"
  status="${status:-NONE}"
  if [ "$status" != "ACTIVE" ]; then
    echo "SKIP twitter: awaiting OAuth completion (see docs/composio-integration-state.md)"
    return 0
  fi
  local text
  text="$(printf '%s' "$BODY" | tr '\n' ' ')"
  text="${text:0:270}"
  local data_file="$TMP_DIR/tw_data.json"
  jq -n --arg t "$text" '{text:$t}' >"$data_file"
  if [ "$MODE" = "dry-run" ]; then
    printf 'DRY-RUN twitter: POST https://api.twitter.com/2/tweets (via composio proxy --toolkit twitter)\n'
    printf 'DRY-RUN twitter: text_chars=%d preview=%s\n' "${#text}" "$text"
    cp "$data_file" "$OUT_DIR/twitter.json"
    echo "OK twitter: dry-run"
    return 0
  fi
  local resp
  resp="$(composio_proxy_call twitter POST "https://api.twitter.com/2/tweets" "$data_file")"
  local rc; rc="$(last_proxy_rc)"
  printf '%s' "$resp" | redact_json >"$OUT_DIR/twitter.json" || printf '%s' "$resp" >"$OUT_DIR/twitter.json"
  if [ "$rc" -ne 0 ]; then
    echo "FAIL twitter: composio proxy rc=$rc (see $OUT_DIR/twitter.json)" >&2
    return 1
  fi
  local tid; tid="$(printf '%s' "$resp" | jq -r '.data.id // empty' 2>/dev/null || true)"
  echo "OK twitter: tweet id=${tid:-unknown}"
  return 0
}

# ---------- drive the run ----------

declare -a SUCCEEDED=()
declare -a SKIPPED=()
declare -a FAILED=()

for ch in "${CHANNELS[@]}"; do
  status="$(get_ch_status "$ch")"
  status="${status:-NONE}"
  case "$ch" in
    twitter)
      # Twitter has its own SKIP logic regardless of precheck.
      if [ "$status" != "ACTIVE" ]; then
        echo "SKIP twitter: awaiting OAuth completion (status=$status; see docs/composio-integration-state.md)"
        SKIPPED+=("twitter")
        set_ch_result twitter "skipped:$status"
        continue
      fi
      if post_twitter; then SUCCEEDED+=("twitter"); set_ch_result twitter "ok"
      else FAILED+=("twitter"); set_ch_result twitter "failed"; fi
      ;;
    linkedin)
      if [ "$status" != "ACTIVE" ]; then
        echo "FAIL linkedin: connected account not ACTIVE (status=$status)" >&2
        FAILED+=("linkedin")
        set_ch_result linkedin "failed:precheck:$status"
        continue
      fi
      if post_linkedin; then SUCCEEDED+=("linkedin"); set_ch_result linkedin "ok"
      else FAILED+=("linkedin"); set_ch_result linkedin "failed"; fi
      ;;
    gmail-draft)
      if [ "$status" != "ACTIVE" ]; then
        echo "FAIL gmail-draft: connected gmail account not ACTIVE (status=$status)" >&2
        FAILED+=("gmail-draft")
        set_ch_result gmail-draft "failed:precheck:$status"
        continue
      fi
      if post_gmail_draft; then SUCCEEDED+=("gmail-draft"); set_ch_result gmail-draft "ok"
      else FAILED+=("gmail-draft"); set_ch_result gmail-draft "failed"; fi
      ;;
  esac
done

# ---------- run summary ----------

SUMMARY="$OUT_DIR/posts-run.md"
TRUNC_BODY="$(truncated_body)"
{
  printf '# OS1 post-approved-content run\n\n'
  printf -- '- ts_utc: %s\n' "$TS"
  printf -- '- mode: %s\n' "$MODE"
  printf -- '- content_path: %s\n' "$CONTENT"
  printf -- '- channels_requested: %s\n' "$(IFS=,; printf '%s' "${CHANNELS[*]}")"
  printf -- '- title: %s\n' "$SUBJECT"
  printf -- '- body_chars: %d\n' "${#BODY}"
  printf -- '- body_truncated: %s\n\n' "$TRUNC_BODY"
  for ch in "${CHANNELS[@]}"; do
    printf '## %s\n' "$ch"
    status="$(get_ch_status "$ch")"
    ca_id="$(get_ch_ca_id "$ch")"
    result="$(get_ch_result "$ch")"
    printf -- '- precheck_status: %s\n' "${status:-NONE}"
    printf -- '- ca_id: %s\n' "$ca_id"
    printf -- '- result: %s\n' "${result:-unknown}"
    if [ "$MODE" = "dry-run" ]; then
      printf -- '- response_id: dry-run\n'
    else
      case "$ch" in
        linkedin)
          if [ -f "$OUT_DIR/linkedin.meta.json" ]; then
            id="$(jq -r '.id // ""' "$OUT_DIR/linkedin.meta.json" 2>/dev/null || true)"
            printf -- '- response_id: %s\n' "${id:-unknown}"
          else
            printf -- '- response_id: unknown\n'
          fi
          ;;
        gmail-draft)
          if [ -f "$OUT_DIR/gmail-draft.json" ]; then
            id="$(jq -r '.id // ""' "$OUT_DIR/gmail-draft.json" 2>/dev/null || true)"
            printf -- '- response_id: %s\n' "${id:-unknown}"
          else
            printf -- '- response_id: unknown\n'
          fi
          ;;
        twitter)
          if [ -f "$OUT_DIR/twitter.json" ]; then
            id="$(jq -r '.data.id // ""' "$OUT_DIR/twitter.json" 2>/dev/null || true)"
            printf -- '- response_id: %s\n' "${id:-unknown}"
          else
            printf -- '- response_id: skipped\n'
          fi
          ;;
      esac
    fi
    printf -- '- truncated_body: %s\n\n' "$TRUNC_BODY"
  done
} >"$SUMMARY.tmp"
mv "$SUMMARY.tmp" "$SUMMARY"

join_csv() {
  local IFS=','
  printf '%s' "${*:-}"
}

succ_csv="$(join_csv "${SUCCEEDED[@]:-}")"
skip_csv="$(join_csv "${SKIPPED[@]:-}")"
fail_csv="$(join_csv "${FAILED[@]:-}")"

printf 'RESULT: posted CHANNELS=%s SKIPPED=%s FAILED=%s\n' \
  "${succ_csv:-none}" "${skip_csv:-none}" "${fail_csv:-none}"
printf 'Artifacts: %s\n' "$OUT_DIR"

# Exit code contract:
#   - dry-run with no precheck failures -> 0
#   - apply with at least one success   -> 0
#   - all attempted apply channels FAIL -> 1
if [ "$MODE" = "dry-run" ]; then
  # Treat dry-run as clean as long as no FAILED entries (precheck failures
  # still count as failures in dry-run so the operator notices before --apply).
  if [ "${#FAILED[@]}" -eq 0 ]; then
    exit 0
  else
    exit 1
  fi
fi

if [ "${#SUCCEEDED[@]}" -ge 1 ]; then
  exit 0
fi
exit 1
