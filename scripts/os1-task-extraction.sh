#!/usr/bin/env bash
# os1-task-extraction.sh — read a notes folder, extract actionable tasks per
# file via local LLM, deduplicate, and emit a checkbox markdown list with
# owner/date when inferable.
#
# Output root (override with --output-root or OS1_TASKS_ROOT):
#   $HOME/Library/Application Support/OS1/tasks
#
# Per-run layout:
#   runs/YYYYMMDDTHHMMSSZ/
#     tasks.md               # flat checkbox list
#     tasks.json             # structured records
#     provenance.json
#     data/                  # per-file raw LLM output
#   latest -> runs/<newest>
#
# Exit codes: 0 success, 1 hard failure, 2 usage error.

set -euo pipefail

SCRIPT_NAME="os1-task-extraction"
SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

INPUT_DIR="$HOME/Documents/OS1 Notes"
ALL_FILES=0
WINDOW_DAYS=7
OUTPUT_ROOT="${OS1_TASKS_ROOT:-$HOME/Library/Application Support/OS1/tasks}"
DRY_RUN=0
NO_LLM=0
NO_SYMLINK=0
LOCK_STALE_SECONDS="${OS1_TASKS_LOCK_STALE_SECONDS:-1800}"
PROMPT_CAP_CHARS="${OS1_TASKS_PROMPT_CAP:-6000}"

OS1_LLM_TASK_BIN="${OS1_LLM_TASK_BIN:-$SCRIPT_DIR/llm-task-with-fallback.sh}"
MODEL="${OLLAMA_MODEL:-${OS1_FALLBACK_PRIMARY_MODEL:-llama3.2:3b}}"

usage() {
  cat <<'USAGE'
Usage: scripts/os1-task-extraction.sh [--input DIR] [--all] [--model MODEL]
                                      [--output-root DIR]
                                      [--dry-run] [--no-llm] [--no-symlink]

Walks an input notes folder (default ~/Documents/OS1 Notes/), extracts
actionable tasks via local LLM, deduplicates, and writes a checkbox list.

Options:
  --input DIR       Notes folder root (default ~/Documents/OS1 Notes).
  --all             Include all files; otherwise only files modified in last 7 days.
  --model MODEL     LLM model override (default llama3.2:3b via fallback wrapper).
  --output-root DIR Sidecar root (default ~/Library/Application Support/OS1/tasks).
  --dry-run         Print plan only; no LLM, no writes.
  --no-llm          Skip LLM pass; just list candidate files in artifact.
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
    --input)        [ "$#" -ge 2 ] || { usage >&2; exit 2; }; INPUT_DIR="$2"; shift ;;
    --all)          ALL_FILES=1 ;;
    --model)        [ "$#" -ge 2 ] || { usage >&2; exit 2; }; MODEL="$2"; shift ;;
    --output-root)  [ "$#" -ge 2 ] || { usage >&2; exit 2; }; OUTPUT_ROOT="$2"; shift ;;
    --dry-run)      DRY_RUN=1 ;;
    --no-llm)       NO_LLM=1 ;;
    --no-symlink)   NO_SYMLINK=1 ;;
    -h|--help)      usage; exit 0 ;;
    *) usage >&2; printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2; exit 2 ;;
  esac
  shift
done

INPUT_DIR="$(expand_home_path "$INPUT_DIR")"
OUTPUT_ROOT="$(expand_home_path "$OUTPUT_ROOT")"
case "$OUTPUT_ROOT" in /*) ;; *) die "--output-root must be absolute: $OUTPUT_ROOT" ;; esac

# Create input dir as placeholder if missing (per spec).
if [ ! -d "$INPUT_DIR" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    log "INFO: input dir $INPUT_DIR does not exist (would create on real run)"
  else
    mkdir -p "$INPUT_DIR" || die "could not create input dir: $INPUT_DIR"
    log "INFO: created placeholder input dir $INPUT_DIR"
  fi
fi

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')"

# Collect candidate files (always so dry-run reports a real count).
candidates_file="$(mktemp -t os1-tasks-cand.XXXXXX)"
trap 'rm -f "$candidates_file" 2>/dev/null || true' EXIT
if [ -d "$INPUT_DIR" ]; then
  if [ "$ALL_FILES" -eq 1 ]; then
    find "$INPUT_DIR" -type f \( -name '*.md' -o -name '*.txt' -o -name '*.rtf' \) > "$candidates_file" 2>/dev/null || true
  else
    find "$INPUT_DIR" -type f \( -name '*.md' -o -name '*.txt' -o -name '*.rtf' \) -mtime "-$WINDOW_DAYS" > "$candidates_file" 2>/dev/null || true
  fi
fi
candidate_count="$(wc -l < "$candidates_file" | tr -d ' ')"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'os1-task-extraction: DRY RUN\n'
  printf '  input_dir    : %s\n' "$INPUT_DIR"
  printf '  window       : %s\n' "$([ "$ALL_FILES" -eq 1 ] && echo 'all files' || echo "last ${WINDOW_DAYS}d")"
  printf '  candidates   : %s\n' "$candidate_count"
  printf '  model        : %s\n' "$MODEL"
  printf '  no_llm       : %s\n' "$NO_LLM"
  printf '  output_root  : %s\n' "$OUTPUT_ROOT"
  printf '  planned run  : %s/runs/%s\n' "$OUTPUT_ROOT" "$run_id"
  printf '  llm bin      : %s\n' "$OS1_LLM_TASK_BIN"
  printf '  steps        : walk -> filter -> classify(LLM) -> dedupe -> write\n'
  printf '  symlink      : %s\n' "$([ "$NO_SYMLINK" -eq 1 ] && echo 'skip' || echo "update $OUTPUT_ROOT/latest")"
  printf 'RESULT: dry-run-ok\n'
  exit 0
fi

if [ "$NO_LLM" -eq 0 ]; then
  [ -x "$OS1_LLM_TASK_BIN" ] || die "missing LLM bin: $OS1_LLM_TASK_BIN"
fi

mkdir -p "$OUTPUT_ROOT/runs" || die "could not create runs dir"

# ---- lock --------------------------------------------------------------------
lock_dir="$OUTPUT_ROOT/.tasks.lock"
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
    log "another tasks run is active (pid=$owner); skipping"; exit 0
  fi
  age="$(lock_age_seconds || echo '')"
  if [ -z "$age" ] || [ "$age" -lt "$LOCK_STALE_SECONDS" ]; then die "stale-not-stale tasks lock at $lock_dir (age=${age:-unknown}s)"; fi
  log "removing stale lock $lock_dir (age=${age}s)"; rm -rf "$lock_dir"; mkdir "$lock_dir" || die "could not acquire lock"
fi
write_lock_owner
stage_dir="$(mktemp -d "${TMPDIR:-/tmp}/os1-tasks.XXXXXXXX")"
cleanup() { rm -f "$lock_dir/owner" 2>/dev/null || true; rmdir "$lock_dir" 2>/dev/null || true; rm -rf "$stage_dir" 2>/dev/null || true; rm -f "$candidates_file" 2>/dev/null || true; }
trap cleanup EXIT
trap 'cleanup; exit 130' HUP INT TERM

data_dir="$stage_dir/data"; mkdir -p "$data_dir"
tasks_json="$stage_dir/tasks.json"; printf '[]' > "$tasks_json"

# ---- per-file extraction -----------------------------------------------------
file_idx=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  [ -f "$f" ] || continue
  file_idx=$((file_idx + 1))
  base="$(basename "$f")"
  raw_text="$stage_dir/data/file-${file_idx}-raw.txt"
  llm_out="$stage_dir/data/file-${file_idx}-llm.txt"

  # Read content; .rtf gets striped via textutil best-effort.
  case "$f" in
    *.rtf) textutil -convert txt -stdout "$f" 2>/dev/null > "$raw_text" || cp "$f" "$raw_text" ;;
    *)     cp "$f" "$raw_text" ;;
  esac

  # Cap content.
  bytes="$(wc -c < "$raw_text" | tr -d ' ')"
  if [ "$bytes" -gt "$PROMPT_CAP_CHARS" ]; then
    head -c "$PROMPT_CAP_CHARS" "$raw_text" > "$raw_text.capped" && mv "$raw_text.capped" "$raw_text"
  fi

  if [ "$NO_LLM" -eq 1 ]; then
    continue
  fi

  prompt="$(python3 -c '
import sys
src=open(sys.argv[1]).read()
fname=sys.argv[2]
print(f"""You are OS1 task-extractor. Read the note below and emit ONLY actionable tasks in EXACTLY this format, one per line, no preamble, no explanations:

- [ ] <task description>  (owner: <name|me|TBD>) (due: <YYYY-MM-DD|TBD>)

Rules:
- Skip aspirational language, status updates, or completed work.
- Use "me" as owner when the note is in first person.
- Use "TBD" when owner or due date cannot be inferred.
- If there are zero actionable tasks, output exactly: NONE

NOTE FILE: {fname}
---
{src}
---
""")' "$raw_text" "$base")"

  if ! printf '%s' "$prompt" | OLLAMA_MODEL="$MODEL" "$OS1_LLM_TASK_BIN" > "$llm_out" 2>/dev/null; then
    log "WARN: LLM call failed for $base"; continue
  fi

  # Parse: each line matching the pattern -> append record.
  python3 - "$tasks_json" "$llm_out" "$f" "$raw_text" <<'PY'
import json,re,sys
path,llm_out,src,raw=sys.argv[1:5]
arr=json.load(open(path))
text=open(llm_out).read()
excerpt=open(raw).read()[:280].replace("\n"," ").strip()
pat=re.compile(r"^-\s*\[\s*\]\s*(?P<desc>.+?)\s*\(owner:\s*(?P<owner>[^)]*)\)\s*\(due:\s*(?P<due>[^)]*)\)\s*$")
seen={(r["task"].lower()) for r in arr}
for line in text.splitlines():
  line=line.strip()
  if not line or line.upper()=="NONE": continue
  m=pat.match(line)
  if not m: continue
  desc=m.group("desc").strip()
  owner=m.group("owner").strip() or "TBD"
  due=m.group("due").strip() or "TBD"
  if desc.lower() in seen: continue
  seen.add(desc.lower())
  arr.append({
    "task": desc, "owner": owner, "due": due,
    "source_file": src, "source_excerpt": excerpt,
  })
json.dump(arr,open(path,"w"),indent=2)
PY
done < "$candidates_file"

task_count="$(python3 -c 'import json,sys;print(len(json.load(open(sys.argv[1]))))' "$tasks_json" 2>/dev/null || echo 0)"

# ---- write artifacts ---------------------------------------------------------
run_dir="$OUTPUT_ROOT/runs/$run_id"
mkdir -p "$run_dir/data" || die "could not create run dir"
for f in "$data_dir"/*; do [ -e "$f" ] || continue; cp "$f" "$run_dir/data/$(basename "$f")"; done
finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

cp "$tasks_json" "$run_dir/tasks.json.new" && mv -f "$run_dir/tasks.json.new" "$run_dir/tasks.json"

python3 - "$tasks_json" "$run_dir/tasks.md.new" "$finished_at" "$MODEL" "$INPUT_DIR" "$candidate_count" "$task_count" <<'PY'
import json,sys
tasks=json.load(open(sys.argv[1]))
out=open(sys.argv[2],"w")
fin,model,inp,cand,n=sys.argv[3:8]
out.write(f"# OS1 Task Extraction\n\n- Generated: `{fin}`\n- Model: `{model}`\n- Input: `{inp}`\n- Files scanned: {cand} | Tasks extracted: {n}\n\n")
if not tasks:
  out.write("_(no actionable tasks found)_\n"); out.close(); sys.exit(0)
for t in tasks:
  out.write(f"- [ ] {t['task']}  (owner: {t.get('owner','TBD')}) (due: {t.get('due','TBD')})\n")
  out.write(f"  _source: {t.get('source_file','?')}_\n")
out.close()
PY
mv -f "$run_dir/tasks.md.new" "$run_dir/tasks.md"

python3 - "$run_dir/provenance.json.new" "$started_at" "$finished_at" "$MODEL" "$INPUT_DIR" "$candidate_count" "$task_count" "$ALL_FILES" "$NO_LLM" <<'PY'
import json,sys
out,started,finished,model,inp,cand,n,all_f,no_llm=sys.argv[1:10]
json.dump({
  "started_at":started,"finished_at":finished,"ollama_model":model,
  "input_dir":inp,"files_scanned":int(cand),"tasks_extracted":int(n),
  "all_files":bool(int(all_f)),"no_llm":bool(int(no_llm)),
  "sources":["filesystem notes"],
},open(out,"w"),indent=2,sort_keys=True)
PY
mv -f "$run_dir/provenance.json.new" "$run_dir/provenance.json"

if [ "$NO_SYMLINK" -eq 0 ]; then
  ln -sfn "$run_dir" "$OUTPUT_ROOT/latest" || die "could not update latest symlink"
fi

log "tasks-ready: $run_dir (files=$candidate_count tasks=$task_count)"
printf '%s\n' "$run_dir"
exit 0
