#!/usr/bin/env bash
# os1-real-business-brief.sh — replace the OS1 hello-world smoke output with a
# live-data daily business brief generated from Gmail, Apple Calendar/Reminders,
# and (best-effort) LinkedIn. Writes a sidecar tree so it never collides with
# scripts/os1-business-ops-run.sh's output path.
#
# This script is read-only against the world: it never sends mail, posts, or
# mutates remote state. It just collects and summarizes via local Ollama.
#
# Output root (override with --output-root or OS1_BUSINESS_BRIEF_ROOT):
#   $HOME/Library/Application Support/OS1/business-brief
#
# Per-run layout:
#   runs/YYYYMMDDTHHMMSSZ/
#     summary.md           # Codex-runner-compatible field list
#     brief.md             # human-readable brief
#     provenance.json      # source/timing metadata
#     data/
#       gmail-recent.json
#       gmail-summarized.md
#       linkedin-feed.json
#       linkedin-summarized.md
#       calendar-today.txt
#       reminders-open.txt
#   latest -> runs/<newest>
#
# Exit codes: 0 brief-ready, 1 hard failure, 2 usage error.

set -euo pipefail

SCRIPT_NAME="os1-real-business-brief"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"

MODE="quick"
OUTPUT_ROOT="${OS1_BUSINESS_BRIEF_ROOT:-$HOME/Library/Application Support/OS1/business-brief}"
DRY_RUN=0
NO_SYMLINK=0
LOCK_STALE_SECONDS="${OS1_BUSINESS_BRIEF_LOCK_STALE_SECONDS:-1800}"

COMPOSIO_BIN="${COMPOSIO_BIN:-$HOME/.composio/composio}"
PROBE_BIN="$SCRIPT_DIR/os1-integration-probe.sh"

# Auto-pick the LLM backend: prefer the Ollama-first fallback wrapper. It tries
# local Ollama first and only calls OpenRouter when the local leg fails or times
# out. Override via OS1_LLM_TASK_BIN / OLLAMA_MODEL / OPENROUTER_MODEL env vars.
if [ -n "${OS1_LLM_TASK_BIN:-}" ]; then
  OLLAMA_BIN="$OS1_LLM_TASK_BIN"
elif [ -x "$SCRIPT_DIR/llm-task-with-fallback.sh" ]; then
  OLLAMA_BIN="$SCRIPT_DIR/llm-task-with-fallback.sh"
else
  OLLAMA_BIN="$SCRIPT_DIR/ollama-task.sh"
fi

# Pick a sensible default model for the chosen backend. Caller can still
# override via --model or the OLLAMA_MODEL env var.
case "$OLLAMA_BIN" in
  *llm-task-with-fallback.sh)
    MODEL="${OLLAMA_MODEL:-${OS1_FALLBACK_PRIMARY_MODEL:-llama3.2:3b}}"
    ;;
  *llm-task-openrouter.sh)
    MODEL="${OLLAMA_MODEL:-${OPENROUTER_MODEL:-z-ai/glm-4.5-air:free}}"
    ;;
  *)
    # Direct local Ollama fallback. qwen2.5-coder:1.5b is small + fast and is
    # already pulled on this Mac.
    MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
    ;;
esac
PROMPT_CAP_CHARS="${OS1_BUSINESS_BRIEF_PROMPT_CAP:-6000}"

usage() {
  cat <<'USAGE'
Usage: scripts/os1-real-business-brief.sh [--quick|--full] [--model MODEL]
                                          [--output-root DIR] [--dry-run]
                                          [--no-symlink]

Generates a real-data business operations brief from Gmail, Apple Calendar,
Apple Reminders, and (best-effort) LinkedIn, summarized via local Ollama.

Options:
  --quick           Default. Gmail last 24h, single brief pass.
  --full            Wider window (7d) and a second pass for Weekly Outlook.
  --model MODEL     Model override (default: local llama3.2:3b via the Ollama-first fallback wrapper).
  --output-root DIR Sidecar root (default ~/Library/Application Support/OS1/business-brief).
  --dry-run         Print steps only; no Ollama call, no writes.
  --no-symlink      Skip updating the `latest` symlink.
  -h, --help        Show this help.
USAGE
}

die() {
  printf '%s: %s\n' "$SCRIPT_NAME" "$*" >&2
  exit 1
}

OSA_TIMEOUT_SECONDS="${OS1_OSA_TIMEOUT_SECONDS:-25}"

# Run an AppleScript with a hard wall-clock timeout. On success sets OSA_OUT and
# returns 0; on AppleScript failure OR timeout returns non-zero so the caller's
# WARN fallback fires. A hung Reminders/Calendar app must never wedge the whole
# brief + lock (incident 2026-05-19: unguarded Reminders osascript hung ~14min
# and stalled every brief run + the launchd lock).
osa_guarded() {
  local script="$1" out_file osa_pid waited=0 rc
  out_file="$(mktemp -t os1-osa.XXXXXX)" || return 1
  osascript -e "$script" >"$out_file" 2>&1 &
  osa_pid=$!
  while kill -0 "$osa_pid" 2>/dev/null; do
    if [ "$waited" -ge "$OSA_TIMEOUT_SECONDS" ]; then
      kill -TERM "$osa_pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$osa_pid" 2>/dev/null || true
      rm -f "$out_file"
      OSA_OUT=""
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  if wait "$osa_pid"; then rc=0; else rc=$?; fi
  OSA_OUT="$(cat "$out_file" 2>/dev/null || true)"
  rm -f "$out_file"
  return "$rc"
}

expand_home_path() {
  local value="$1"
  case "$value" in
    "~")            printf '%s\n' "$HOME" ;;
    "~/"*)          printf '%s/%s\n' "$HOME" "${value#~/}" ;;
    '$HOME/'*)      printf '%s/%s\n' "$HOME" "${value#\$HOME/}" ;;
    '${HOME}/'*)    printf '%s/%s\n' "$HOME" "${value#\${HOME}/}" ;;
    *)              printf '%s\n' "$value" ;;
  esac
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick)      MODE="quick" ;;
    --full)       MODE="full" ;;
    --model)      [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MODEL="$2"; shift ;;
    --output-root) [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUTPUT_ROOT="$2"; shift ;;
    --dry-run)    DRY_RUN=1 ;;
    --no-symlink) NO_SYMLINK=1 ;;
    -h|--help)    usage; exit 0 ;;
    *) usage >&2; printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

case "$LOCK_STALE_SECONDS" in
  ""|*[!0-9]*) die "OS1_BUSINESS_BRIEF_LOCK_STALE_SECONDS must be a non-negative integer" ;;
esac

[ -x "$PROBE_BIN" ] || die "missing executable scripts/os1-integration-probe.sh (chmod +x it)"
[ -x "$OLLAMA_BIN" ] || die "missing executable scripts/ollama-task.sh"

OUTPUT_ROOT="$(expand_home_path "$OUTPUT_ROOT")"
case "$OUTPUT_ROOT" in
  /*) ;;
  *) die "--output-root must be absolute: $OUTPUT_ROOT" ;;
esac

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'os1-real-business-brief: DRY RUN\n'
  printf '  mode         : %s\n' "$MODE"
  printf '  model        : %s\n' "$MODEL"
  printf '  output_root  : %s\n' "$OUTPUT_ROOT"
  printf '  planned run  : %s/runs/%s\n' "$OUTPUT_ROOT" "$run_id"
  printf '  probe        : %s --quiet --json\n' "$PROBE_BIN"
  printf '  gmail window : %s\n' "$([ "$MODE" = full ] && echo '7d (full)' || echo '24h (quick)')"
  printf '  steps        : probe -> gmail -> calendar -> reminders -> linkedin -> ollama -> write\n'
  printf '  symlink      : %s\n' "$([ "$NO_SYMLINK" -eq 1 ] && echo 'skip' || echo "update $OUTPUT_ROOT/latest")"
  printf 'RESULT: dry-run-ok\n'
  exit 0
fi

mkdir -p "$OUTPUT_ROOT/runs" || die "could not create runs dir: $OUTPUT_ROOT/runs"

# ---- lock --------------------------------------------------------------------
lock_dir="$OUTPUT_ROOT/.brief.lock"
write_lock_owner() {
  {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "$started_at"
  } > "$lock_dir/owner"
}
lock_age_seconds() {
  local m now
  if stat -f %m "$lock_dir" >/dev/null 2>&1; then
    m="$(stat -f %m "$lock_dir")"
  elif stat -c %Y "$lock_dir" >/dev/null 2>&1; then
    m="$(stat -c %Y "$lock_dir")"
  else
    return 1
  fi
  now="$(date +%s)"
  [ "$now" -ge "$m" ] || return 1
  printf '%s\n' "$((now - m))"
}
lock_owner_pid() {
  [ -f "$lock_dir/owner" ] || return 1
  awk -F= '$1=="pid"{print $2; exit}' "$lock_dir/owner" 2>/dev/null
}

if ! mkdir "$lock_dir" 2>/dev/null; then
  owner="$(lock_owner_pid || true)"
  if [ -n "${owner:-}" ] && kill -0 "$owner" 2>/dev/null; then
    printf 'INFO: another brief run is active (pid=%s); skipping\n' "$owner"
    exit 0
  fi
  age="$(lock_age_seconds || echo '')"
  if [ -z "$age" ] || [ "$age" -lt "$LOCK_STALE_SECONDS" ]; then
    die "stale-not-stale brief lock at $lock_dir (age=${age:-unknown}s)"
  fi
  printf 'WARN: removing stale lock %s (age=%ss)\n' "$lock_dir" "$age" >&2
  rm -rf "$lock_dir"
  mkdir "$lock_dir" || die "could not acquire brief lock: $lock_dir"
fi
write_lock_owner
cleanup_lock() { rm -f "$lock_dir/owner" 2>/dev/null || true; rmdir "$lock_dir" 2>/dev/null || true; }
trap cleanup_lock EXIT
trap 'cleanup_lock; exit 130' HUP INT TERM

# ---- 1. probe ----------------------------------------------------------------
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/os1-brief.XXXXXXXX")"
trap 'cleanup_lock; rm -rf "$stage_dir" 2>/dev/null || true' EXIT

probe_json_path="$stage_dir/probe.json"
if ! "$PROBE_BIN" --quiet --json > "$probe_json_path" 2>/dev/null; then
  : # probe may exit 0 in non-strict mode anyway; preserve file
fi
probe_result="$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(d.get("result","down"))
except Exception:
  print("down")' "$probe_json_path" 2>/dev/null || echo down)"

if [ "$probe_result" = "down" ]; then
  die "FAIL: integration probe — RESULT=down"
fi

# ---- 2. gmail ----------------------------------------------------------------
data_dir="$stage_dir/data"
mkdir -p "$data_dir"
gmail_q="newer_than:1d"
[ "$MODE" = "full" ] && gmail_q="newer_than:7d"

gmail_raw="$data_dir/gmail-recent.json"
gmail_md="$data_dir/gmail-summarized.md"
: > "$gmail_md"

if [ -x "$COMPOSIO_BIN" ]; then
  if "$COMPOSIO_BIN" proxy -X GET \
        "https://gmail.googleapis.com/gmail/v1/users/me/messages?q=$gmail_q&maxResults=25" \
        --toolkit gmail </dev/null > "$gmail_raw" 2>/dev/null; then
    # Extract message IDs and fetch metadata.
    msg_ids="$(python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  for m in d.get("messages",[])[:25]:
    print(m.get("id",""))
except Exception:
  pass' "$gmail_raw" 2>/dev/null || true)"
    {
      printf '# Gmail (last %s)\n\n' "$gmail_q"
      count=0
      while IFS= read -r mid; do
        [ -z "$mid" ] && continue
        meta_file="$data_dir/gmail-msg-$mid.json"
        if "$COMPOSIO_BIN" proxy -X GET \
              "https://gmail.googleapis.com/gmail/v1/users/me/messages/$mid?format=metadata&metadataHeaders=Subject&metadataHeaders=From&metadataHeaders=Date" \
              --toolkit gmail </dev/null > "$meta_file" 2>/dev/null; then
          python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  hdrs={h["name"]:h["value"] for h in d.get("payload",{}).get("headers",[])}
  snip=d.get("snippet","")[:200].replace("\n"," ")
  print(f"- From: {hdrs.get(\"From\",\"?\")}")
  print(f"  Subject: {hdrs.get(\"Subject\",\"(no subject)\")}")
  print(f"  Date: {hdrs.get(\"Date\",\"?\")}")
  print(f"  Snippet: {snip}")
except Exception as e:
  print(f"- (parse error: {e})")' "$meta_file" 2>/dev/null || true
          count=$((count + 1))
        fi
      done <<< "$msg_ids"
      printf '\n_Total messages summarized: %d_\n' "$count"
    } > "$gmail_md"
  else
    printf 'WARN: gmail proxy call failed; skipping inbox section.\n' > "$gmail_md"
  fi
else
  printf 'WARN: composio CLI missing at %s\n' "$COMPOSIO_BIN" > "$gmail_md"
fi

# Ensure Calendar.app and Reminders.app are running before osascript queries
# them. Under launchd, neither app is launched on demand; the osascript call
# returns `-600 Application isn't running` for Calendar and the iteration of
# `whose completed is false` for Reminders is much slower against a cold UI
# process. -j keeps them background-launched (no foreground steal).
/usr/bin/open -a Calendar -j 2>/dev/null || true
/usr/bin/open -a Reminders -j 2>/dev/null || true

# ---- 3. calendar -------------------------------------------------------------
cal_file="$data_dir/calendar-today.txt"
osa_cal='
set out to ""
try
  tell application "Calendar"
    set today_start to (current date) - (time of (current date))
    set tomorrow_start to today_start + (1 * days)
    repeat with c in calendars
      try
        with timeout of 6 seconds
          set cal_title to title of c
          set evs to (every event of c whose start date is greater than or equal to today_start and start date is less than tomorrow_start)
          if (count of evs) > 0 then
            set ev_summaries to summary of evs
            set ev_starts to start date of evs
            set ev_ends to end date of evs
            repeat with i from 1 to count of evs
              set out to out & (item i of ev_summaries) & " | " & ((item i of ev_starts) as string) & " - " & ((item i of ev_ends) as string) & " [" & cal_title & "]" & linefeed
            end repeat
          end if
        end timeout
      end try
    end repeat
  end tell
on error errMsg
  set out to "ERROR: " & errMsg
end try
return out'
if osa_guarded "$osa_cal"; then
  cal_out="$OSA_OUT"
  if [ -z "$cal_out" ]; then
    printf '(no events today)\n' > "$cal_file"
  else
    printf '%s\n' "$cal_out" > "$cal_file"
  fi
else
  printf 'WARN: calendar access denied, AppleScript failed, or timed out after %ss.\nSystem Settings > Privacy & Security > Automation > grant Calendar access to the terminal/parent app.\n' "$OSA_TIMEOUT_SECONDS" > "$cal_file"
fi

# ---- 4. reminders ------------------------------------------------------------
rem_file="$data_dir/reminders-open.txt"
osa_rem='
set out to ""
try
  tell application "Reminders"
    repeat with L in lists
      try
        with timeout of 8 seconds
          set list_name to name of L
          -- Bulk-fetch names in one AppleEvent rather than iterating per-reminder
          set incomplete_names to name of (reminders of L whose completed is false)
          repeat with n in incomplete_names
            set out to out & (n as string) & " [" & list_name & "]" & linefeed
          end repeat
        end timeout
      end try
    end repeat
  end tell
on error errMsg
  set out to "ERROR: " & errMsg
end try
return out'
if osa_guarded "$osa_rem"; then
  rem_out="$OSA_OUT"
  if [ -z "$rem_out" ]; then
    printf '(no open reminders)\n' > "$rem_file"
  else
    printf '%s\n' "$rem_out" > "$rem_file"
  fi
else
  printf 'WARN: reminders access denied or timed out after %ss.\n' "$OSA_TIMEOUT_SECONDS" > "$rem_file"
fi

# ---- 5. linkedin -------------------------------------------------------------
li_raw="$data_dir/linkedin-feed.json"
li_md="$data_dir/linkedin-summarized.md"
: > "$li_raw"; : > "$li_md"
if [ -x "$COMPOSIO_BIN" ]; then
  if "$COMPOSIO_BIN" proxy -X GET \
        'https://api.linkedin.com/v2/userinfo' \
        --toolkit linkedin </dev/null > "$li_raw" 2>/dev/null; then
    python3 -c '
import json,sys
try:
  d=json.load(open(sys.argv[1]))
  print(f"# LinkedIn identity\n\n- Name: {d.get(\"name\",\"?\")}\n- Sub: {d.get(\"sub\",\"?\")}\n")
except Exception:
  print("WARN: linkedin response unparseable")' "$li_raw" > "$li_md" 2>/dev/null || true
  else
    printf 'WARN: linkedin proxy call failed; skipping.\n' > "$li_md"
  fi
else
  printf 'WARN: composio CLI missing\n' > "$li_md"
fi

# ---- 6. assemble prompt and call ollama --------------------------------------
prompt_file="$stage_dir/prompt.txt"
{
  printf 'You are OS1, the local-only business operations assistant. Produce a concise daily brief in markdown using ONLY the data below. Do not invent facts. If a section has no data, write "(none)".\n\n'
  printf 'Sections required, in order, with these exact H2 headings:\n'
  printf '## Status\n## Top Inbox (last 24h)\n## Calendar (today)\n## Open Reminders\n## LinkedIn Signal\n## Suggested Actions\n## Risks\n\n'
  printf -- '---\n## Source: Gmail\n'
  cat "$gmail_md" 2>/dev/null || true
  printf '\n## Source: Calendar\n'
  cat "$cal_file" 2>/dev/null || true
  printf '\n## Source: Reminders\n'
  cat "$rem_file" 2>/dev/null || true
  printf '\n## Source: LinkedIn\n'
  cat "$li_md" 2>/dev/null || true
} > "$prompt_file"

# Cap to PROMPT_CAP_CHARS.
prompt_full_bytes="$(wc -c < "$prompt_file" | tr -d ' ')"
if [ "$prompt_full_bytes" -gt "$PROMPT_CAP_CHARS" ]; then
  head -c "$PROMPT_CAP_CHARS" "$prompt_file" > "$prompt_file.capped"
  printf '\n\n[truncated for prompt cap %s chars]\n' "$PROMPT_CAP_CHARS" >> "$prompt_file.capped"
  mv "$prompt_file.capped" "$prompt_file"
fi

brief_body_file="$stage_dir/brief.md"
weekly_outlook_file="$stage_dir/weekly.md"
: > "$brief_body_file"; : > "$weekly_outlook_file"

if ! OLLAMA_MODEL="$MODEL" "$OLLAMA_BIN" < "$prompt_file" > "$brief_body_file" 2>"$stage_dir/ollama.err"; then
  printf '%s: ollama call failed; see %s — degrading to data-only brief\n' "$SCRIPT_NAME" "$stage_dir/ollama.err" >&2
  {
    printf '## Summary\n\n'
    printf '_LLM summary unavailable: the local Ollama call failed or timed out '
    printf '(model `%s`). The live source sections below are still real data._\n' "$MODEL"
  } > "$brief_body_file"
fi

if [ "$MODE" = "full" ]; then
  {
    printf 'You are OS1. Based on the daily brief below, produce a short "Weekly Outlook" (3-6 bullets) covering follow-ups, scheduled commitments, and watch items. Markdown only.\n\n'
    cat "$brief_body_file"
  } > "$stage_dir/weekly-prompt.txt"
  OLLAMA_MODEL="$MODEL" "$OLLAMA_BIN" < "$stage_dir/weekly-prompt.txt" > "$weekly_outlook_file" 2>>"$stage_dir/ollama.err" || true
fi

# ---- 7. compose final files, write atomically -------------------------------
run_dir="$OUTPUT_ROOT/runs/$run_id"
mkdir -p "$run_dir/data" || die "could not create run dir: $run_dir"

# Move data files in.
for f in "$data_dir"/*; do
  [ -e "$f" ] || continue
  cp "$f" "$run_dir/data/$(basename "$f")"
done

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# brief.md (final human file)
{
  printf '# OS1 Real Business Brief\n\n'
  printf -- '- Generated: `%s`\n' "$finished_at"
  printf -- '- Model: `%s`\n' "$MODEL"
  printf -- '- Mode: `%s`\n' "$MODE"
  printf -- '- Probe: `%s`\n\n' "$probe_result"
  printf -- '---\n\n'
  cat "$brief_body_file"
  if [ "$MODE" = "full" ] && [ -s "$weekly_outlook_file" ]; then
    printf '\n\n## Weekly Outlook\n\n'
    cat "$weekly_outlook_file"
  fi
} > "$run_dir/brief.md.new"
mv -f "$run_dir/brief.md.new" "$run_dir/brief.md"

# summary.md — same field convention as os1-business-ops-run.sh
{
  printf '# OS1 Real Business Brief Run\n\n'
  printf -- '- Started: `%s`\n' "$started_at"
  printf -- '- Finished: `%s`\n' "$finished_at"
  printf -- '- Model: `%s`\n' "$MODEL"
  printf -- '- Mode: `%s`\n' "$MODE"
  printf -- '- Probe: `%s`\n' "$probe_result"
  printf -- '- Run directory: `%s`\n\n' "$run_dir"
  printf '## Artifacts\n\n'
  printf -- '- `brief.md`\n'
  printf -- '- `data/gmail-recent.json`\n'
  printf -- '- `data/gmail-summarized.md`\n'
  printf -- '- `data/calendar-today.txt`\n'
  printf -- '- `data/reminders-open.txt`\n'
  printf -- '- `data/linkedin-feed.json`\n'
  printf -- '- `data/linkedin-summarized.md`\n'
} > "$run_dir/summary.md.new"
mv -f "$run_dir/summary.md.new" "$run_dir/summary.md"

# provenance.json
python3 - "$run_dir/provenance.json.new" "$started_at" "$finished_at" "$MODEL" "$probe_result" "$probe_json_path" "$MODE" <<'PY'
import json,sys,os
out,started,finished,model,probe_result,probe_path,mode=sys.argv[1:8]
sources=[
  "gmail (composio proxy)",
  "apple-calendar (osascript)",
  "apple-reminders (osascript)",
  "linkedin (composio proxy, best-effort)",
]
probe={}
try:
  with open(probe_path) as f:
    probe=json.load(f)
except Exception:
  probe={"result":probe_result,"integrations":[]}
doc={
  "started_at": started,
  "finished_at": finished,
  "ollama_model": model,
  "mode": mode,
  "integration_probe_result": probe_result,
  "integration_probe": probe,
  "sources": sources,
}
with open(out,"w") as f:
  json.dump(doc,f,indent=2,sort_keys=True)
PY
mv -f "$run_dir/provenance.json.new" "$run_dir/provenance.json"

# latest symlink (atomic-ish on macOS via ln -sfn)
if [ "$NO_SYMLINK" -eq 0 ]; then
  ln -sfn "$run_dir" "$OUTPUT_ROOT/latest" || die "could not update latest symlink"
fi

printf 'RESULT: brief-ready RUN=%s\n' "$run_dir"
exit 0
