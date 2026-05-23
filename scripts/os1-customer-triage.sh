#!/usr/bin/env bash
# os1-customer-triage.sh — read recent unread/starred Gmail messages and classify
# each by urgency + category, plus generate a draft reply option. Operator only —
# this script NEVER sends mail; the artifact is for human review.
#
# Output root (override with --output-root or OS1_TRIAGE_ROOT):
#   $HOME/Library/Application Support/OS1/triage
#
# Per-run layout:
#   runs/YYYYMMDDTHHMMSSZ/
#     triage.md              # human-readable report grouped by urgency
#     triage.json            # structured records for downstream consumers
#     provenance.json
#     data/messages-raw.json # raw Composio output
#   latest -> runs/<newest>
#
# Exit codes: 0 success, 1 hard failure, 2 usage error.

set -euo pipefail

SCRIPT_NAME="os1-customer-triage"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

WINDOW="24h"
MAX_MESSAGES=25
OUTPUT_ROOT="${OS1_TRIAGE_ROOT:-$HOME/Library/Application Support/OS1/triage}"
DRY_RUN=0
NO_LLM=0
NO_SYMLINK=0
LOCK_STALE_SECONDS="${OS1_TRIAGE_LOCK_STALE_SECONDS:-1800}"

COMPOSIO_BIN="${COMPOSIO_BIN:-$HOME/.composio/composio}"
OS1_LLM_TASK_BIN="${OS1_LLM_TASK_BIN:-$SCRIPT_DIR/llm-task-with-fallback.sh}"
MODEL="${OLLAMA_MODEL:-${OS1_FALLBACK_PRIMARY_MODEL:-llama3.2:3b}}"

usage() {
  cat <<'USAGE'
Usage: scripts/os1-customer-triage.sh [--window 24h|48h|7d] [--max-messages N]
                                      [--output-root DIR] [--model MODEL]
                                      [--dry-run] [--no-llm] [--no-symlink]

Classifies recent unread Gmail messages by urgency + category and drafts reply
options. NEVER sends mail. Artifact only.

Options:
  --window WIN      Gmail recency window (24h default, 48h, 7d).
  --max-messages N  Cap messages classified (default 25).
  --output-root DIR Sidecar root (default ~/Library/Application Support/OS1/triage).
  --model MODEL     LLM model override (default llama3.2:3b via fallback wrapper).
  --dry-run         Print plan only; no Composio call, no LLM, no writes.
  --no-llm          Skip per-message LLM classification; just write raw signal.
  --no-symlink      Skip updating the `latest` symlink.
  -h, --help        Show this help.
USAGE
}

die() { printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2; exit 1; }
log() { printf '[%s] %s: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$SCRIPT_NAME" "$*" >&2; }

expand_home_path() {
  local v="$1"
  case "$v" in
    "~")          printf '%s\n' "$HOME" ;;
    "~/"*)        printf '%s/%s\n' "$HOME" "${v#~/}" ;;
    '$HOME/'*)    printf '%s/%s\n' "$HOME" "${v#\$HOME/}" ;;
    '${HOME}/'*)  printf '%s/%s\n' "$HOME" "${v#\${HOME}/}" ;;
    *)            printf '%s\n' "$v" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --window)        [ "$#" -ge 2 ] || { usage >&2; exit 2; }; WINDOW="$2"; shift ;;
    --max-messages)  [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MAX_MESSAGES="$2"; shift ;;
    --output-root)   [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUTPUT_ROOT="$2"; shift ;;
    --model)         [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MODEL="$2"; shift ;;
    --dry-run)       DRY_RUN=1 ;;
    --no-llm)        NO_LLM=1 ;;
    --no-symlink)    NO_SYMLINK=1 ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$WINDOW" in
  24h) GMAIL_Q="newer_than:1d is:unread" ;;
  48h) GMAIL_Q="newer_than:2d is:unread" ;;
  7d)  GMAIL_Q="newer_than:7d is:unread" ;;
  *)   die "--window must be one of: 24h, 48h, 7d (got $WINDOW)" ;;
esac
case "$MAX_MESSAGES" in ""|*[!0-9]*) die "--max-messages must be a positive integer" ;; esac
[ "$MAX_MESSAGES" -gt 0 ] || die "--max-messages must be > 0"

OUTPUT_ROOT="$(expand_home_path "$OUTPUT_ROOT")"
case "$OUTPUT_ROOT" in /*) ;; *) die "--output-root must be absolute: $OUTPUT_ROOT" ;; esac

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'os1-customer-triage: DRY RUN\n'
  printf '  window       : %s (query: %s)\n' "$WINDOW" "$GMAIL_Q"
  printf '  max_messages : %s\n' "$MAX_MESSAGES"
  printf '  model        : %s\n' "$MODEL"
  printf '  no_llm       : %s\n' "$NO_LLM"
  printf '  output_root  : %s\n' "$OUTPUT_ROOT"
  printf '  planned run  : %s/runs/%s\n' "$OUTPUT_ROOT" "$run_id"
  printf '  composio     : %s\n' "$COMPOSIO_BIN"
  printf '  llm bin      : %s\n' "$OS1_LLM_TASK_BIN"
  printf '  steps        : list -> fetch metadata -> classify(LLM) -> write\n'
  printf '  symlink      : %s\n' "$([ "$NO_SYMLINK" -eq 1 ] && echo 'skip' || echo "update $OUTPUT_ROOT/latest")"
  printf 'RESULT: dry-run-ok\n'
  exit 0
fi

[ -x "$COMPOSIO_BIN" ] || die "missing composio CLI: $COMPOSIO_BIN"
if [ "$NO_LLM" -eq 0 ]; then
  [ -x "$OS1_LLM_TASK_BIN" ] || die "missing LLM bin: $OS1_LLM_TASK_BIN"
fi

mkdir -p "$OUTPUT_ROOT/runs" || die "could not create runs dir"

# ---- lock --------------------------------------------------------------------
lock_dir="$OUTPUT_ROOT/.triage.lock"
write_lock_owner() { { printf 'pid=%s\n' "$$"; printf 'started_at=%s\n' "$started_at"; } > "$lock_dir/owner"; }
lock_age_seconds() {
  local m now
  if stat -f %m "$lock_dir" >/dev/null 2>&1; then m="$(stat -f %m "$lock_dir")"
  elif stat -c %Y "$lock_dir" >/dev/null 2>&1; then m="$(stat -c %Y "$lock_dir")"
  else return 1; fi
  now="$(date +%s)"; [ "$now" -ge "$m" ] || return 1; printf '%s\n' "$((now - m))"
}
lock_owner_pid() { [ -f "$lock_dir/owner" ] || return 1; awk -F= '$1=="pid"{print $2; exit}' "$lock_dir/owner" 2>/dev/null; }
if ! mkdir "$lock_dir" 2>/dev/null; then
  owner="$(lock_owner_pid || true)"
  if [ -n "${owner:-}" ] && kill -0 "$owner" 2>/dev/null; then
    log "another triage run is active (pid=$owner); skipping"; exit 0
  fi
  age="$(lock_age_seconds || echo '')"
  if [ -z "$age" ] || [ "$age" -lt "$LOCK_STALE_SECONDS" ]; then die "stale-not-stale triage lock at $lock_dir (age=${age:-unknown}s)"; fi
  log "removing stale lock $lock_dir (age=${age}s)"; rm -rf "$lock_dir"; mkdir "$lock_dir" || die "could not acquire lock"
fi
write_lock_owner
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/os1-triage.XXXXXXXX")"
cleanup() { rm -f "$lock_dir/owner" 2>/dev/null || true; rmdir "$lock_dir" 2>/dev/null || true; rm -rf "$stage_dir" 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

# ---- 1. list message IDs -----------------------------------------------------
data_dir="$stage_dir/data"; mkdir -p "$data_dir"
raw_list="$data_dir/messages-raw.json"
log "listing gmail messages: q=\"$GMAIL_Q\" max=$MAX_MESSAGES"
if ! "$COMPOSIO_BIN" proxy -X GET \
      "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$(printf '%s' "$GMAIL_Q" | sed 's/ /%20/g')&maxResults=$MAX_MESSAGES" \
      --toolkit gmail </dev/null > "$raw_list" 2>"$stage_dir/composio.err"; then
  log "WARN: gmail list call failed; see $stage_dir/composio.err — emitting empty triage"
  printf '{"messages":[]}\n' > "$raw_list"
fi

msg_ids="$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  for m in d.get("messages",[])[:'"$MAX_MESSAGES"']:
    mid=m.get("id","")
    if mid: print(mid)
except Exception:
  pass' "$raw_list" 2>/dev/null || true)"

records_json="$stage_dir/records.json"
printf '[]' > "$records_json"
classified=0
total=0

# ---- 2. per-message metadata + LLM classification ----------------------------
while IFS= read -r mid; do
  [ -z "$mid" ] && continue
  total=$((total + 1))
  meta_file="$data_dir/gmail-msg-$mid.json"
  if ! "$COMPOSIO_BIN" proxy -X GET \
        "https://gmail.googleapis.com/gmail/v1/users/me/messages/$mid?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date" \
        --toolkit gmail </dev/null > "$meta_file" 2>/dev/null; then
    log "WARN: failed to fetch metadata for $mid"; continue
  fi

  meta="$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  hdrs={h["name"]:h["value"] for h in d.get("payload",{}).get("headers",[])}
  snip=d.get("snippet","")[:400].replace("\n"," ").replace("\r"," ")
  print(json.dumps({
    "id": sys.argv[2],
    "from": hdrs.get("From","?"),
    "subject": hdrs.get("Subject","(no subject)"),
    "date": hdrs.get("Date","?"),
    "snippet": snip,
  }))
except Exception as e:
  print(json.dumps({"id": sys.argv[2], "parse_error": str(e)}))' "$meta_file" "$mid" 2>/dev/null || echo '{}')"

  urgency="normal"; category="internal"; action="queue_for_review"; draft="(LLM skipped)"; rationale=""
  if [ "$NO_LLM" -eq 0 ]; then
    prompt="$(python3 -c '
import json,sys
m=json.loads(sys.argv[1])
print(f"""You are OS1 customer-triage. Classify ONE inbound email and draft a short reply option for operator review. Output EXACTLY this template, nothing else:

URGENCY: <urgent|important|normal|low>
CATEGORY: <customer_question|sales_lead|vendor|internal|billing|spam>
ACTION: <reply_now|queue_for_review|archive|forward>
RATIONALE: <one sentence>
DRAFT_REPLY:
<2-3 sentence helpful professional draft in the operators voice; sign off as Moses>

EMAIL:
From: {m.get("from","?")}
Subject: {m.get("subject","(no subject)")}
Date: {m.get("date","?")}
Snippet: {m.get("snippet","")}
""")' "$meta")"
    llm_out="$(printf '%s' "$prompt" | OLLAMA_MODEL="$MODEL" "$OS1_LLM_TASK_BIN" 2>/dev/null || true)"
    if [ -n "$llm_out" ]; then
      urgency="$(printf '%s\n' "$llm_out" | awk -F': ' '/^URGENCY:/ {print tolower($2); exit}' | tr -d '\r' | head -c 32)"
      category="$(printf '%s\n' "$llm_out" | awk -F': ' '/^CATEGORY:/ {print tolower($2); exit}' | tr -d '\r' | head -c 32)"
      action="$(printf '%s\n' "$llm_out" | awk -F': ' '/^ACTION:/ {print tolower($2); exit}' | tr -d '\r' | head -c 32)"
      rationale="$(printf '%s\n' "$llm_out" | awk -F': ' '/^RATIONALE:/ {print $2; exit}' | tr -d '\r' | head -c 400)"
      draft="$(printf '%s\n' "$llm_out" | awk '/^DRAFT_REPLY:/{flag=1;next} flag' | head -c 1200)"
      [ -z "$urgency" ] && urgency="normal"
      [ -z "$category" ] && category="internal"
      [ -z "$action" ] && action="queue_for_review"
      [ -z "$draft" ] && draft="(LLM returned no draft)"
      classified=$((classified + 1))
    fi
  fi

  python3 - "$records_json" "$meta" "$urgency" "$category" "$action" "$rationale" "$draft" <<'PY'
import json,sys
path,meta,urgency,category,action,rationale,draft=sys.argv[1:8]
arr=json.load(open(path))
m=json.loads(meta)
arr.append({
  "id": m.get("id"),
  "from": m.get("from","?"),
  "subject": m.get("subject","(no subject)"),
  "date": m.get("date","?"),
  "snippet": m.get("snippet",""),
  "urgency": urgency,
  "category": category,
  "action": action,
  "rationale": rationale,
  "draft_reply": draft,
})
json.dump(arr,open(path,"w"),indent=2)
PY
done <<< "$msg_ids"

# ---- 3. write artifacts ------------------------------------------------------
run_dir="$OUTPUT_ROOT/runs/$run_id"
mkdir -p "$run_dir/data" || die "could not create run dir"
cp "$raw_list" "$run_dir/data/messages-raw.json"
for f in "$data_dir"/gmail-msg-*.json; do [ -e "$f" ] || continue; cp "$f" "$run_dir/data/$(basename "$f")"; done

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cp "$records_json" "$run_dir/triage.json.new" && mv -f "$run_dir/triage.json.new" "$run_dir/triage.json"

python3 - "$records_json" "$run_dir/triage.md.new" "$finished_at" "$MODEL" "$WINDOW" "$total" "$classified" <<'PY'
import json,sys
records=json.load(open(sys.argv[1]))
out=open(sys.argv[2],"w")
fin,model,window,total,classified=sys.argv[3:8]
out.write(f"# OS1 Customer Triage\n\n- Generated: `{fin}`\n- Model: `{model}`\n- Window: `{window}`\n- Total: {total} | Classified: {classified}\n\n")
if not records:
  out.write("_(no unread messages in window)_\n"); out.close(); sys.exit(0)
buckets={"urgent":[],"important":[],"normal":[],"low":[]}
for r in records:
  buckets.setdefault(r.get("urgency","normal"),[]).append(r)
for u in ("urgent","important","normal","low"):
  rs=buckets.get(u,[])
  if not rs: continue
  out.write(f"## {u.title()} ({len(rs)})\n\n")
  for r in rs:
    out.write(f"### {r.get('subject','(no subject)')}\n")
    out.write(f"- From: {r.get('from','?')}\n- Date: {r.get('date','?')}\n- Category: `{r.get('category','?')}` | Action: `{r.get('action','?')}`\n")
    if r.get("rationale"): out.write(f"- Rationale: {r['rationale']}\n")
    out.write(f"- Snippet: {r.get('snippet','')[:240]}\n\n")
    out.write("**Draft reply (operator review only — NOT sent):**\n\n")
    draft=r.get("draft_reply","").strip() or "(no draft)"
    for line in draft.splitlines():
      out.write(f"> {line}\n")
    out.write("\n")
out.close()
PY
mv -f "$run_dir/triage.md.new" "$run_dir/triage.md"

python3 - "$run_dir/provenance.json.new" "$started_at" "$finished_at" "$MODEL" "$WINDOW" "$MAX_MESSAGES" "$total" "$classified" "$NO_LLM" <<'PY'
import json,sys
out,started,finished,model,window,maxm,total,classified,no_llm=sys.argv[1:10]
json.dump({
  "started_at":started,"finished_at":finished,"ollama_model":model,
  "window":window,"max_messages":int(maxm),"total":int(total),
  "classified":int(classified),"no_llm":bool(int(no_llm)),
  "sources":["gmail (composio proxy)"],
},open(out,"w"),indent=2,sort_keys=True)
PY
mv -f "$run_dir/provenance.json.new" "$run_dir/provenance.json"

if [ "$NO_SYMLINK" -eq 0 ]; then
  ln -sfn "$run_dir" "$OUTPUT_ROOT/latest" || die "could not update latest symlink"
fi

log "triage-ready: $run_dir (total=$total classified=$classified)"
printf '%s\n' "$run_dir"
exit 0
