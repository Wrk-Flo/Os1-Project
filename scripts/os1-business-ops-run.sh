#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
MODE="${OS1_BUSINESS_OPS_MODE:-quick}"
REAL_BRIEF="${OS1_BUSINESS_OPS_REAL_BRIEF:-0}"
RETENTION_DAYS="${OS1_BUSINESS_OPS_RETENTION_DAYS:-14}"
OUTPUT_ROOT="${OS1_BUSINESS_OPS_OUTPUT_ROOT:-$HOME/Library/Application Support/OS1/business-ops}"
PRUNE=1
LOCK_STALE_SECONDS="${OS1_BUSINESS_OPS_LOCK_STALE_SECONDS:-7200}"
STAGE_TIMEOUT_SECONDS="${OS1_BUSINESS_OPS_STAGE_TIMEOUT_SECONDS:-300}"
OLLAMA_TASK_MAX_TIME_SECONDS="${OLLAMA_TASK_MAX_TIME_SECONDS:-120}"
OLLAMA_NUM_PREDICT="${OLLAMA_NUM_PREDICT:-120}"

usage() {
  cat <<'USAGE'
Usage: scripts/os1-business-ops-run.sh [--quick|--full] [--model MODEL]
                                       [--output-root DIR]
                                       [--retention-days DAYS]
                                       [--real-brief|--no-real-brief]
                                       [--no-prune]

Runs a local-only OS1 business operations cycle and writes timestamped artifacts.
No Azure, Key Vault, or cloud inference is used.

Options:
  --quick                Run the daily operations brief only. Default.
  --full                 Run all local business smoke workflows.
  --model MODEL          Ollama model. Default: qwen2.5-coder:1.5b.
  --output-root DIR      Artifact root. Default: ~/Library/Application Support/OS1/business-ops.
  --retention-days DAYS  Delete run directories older than DAYS. Default: 14.
  --real-brief           Also run the real-data business brief sidecar.
  --no-real-brief        Do not run the real-data business brief sidecar. Default.
  --no-prune             Keep all prior run directories.
  -h, --help             Show this help.
USAGE
}

die() {
  printf 'os1-business-ops-run: %s\n' "$*" >&2
  exit 1
}

expand_home_path() {
  value="$1"
  case "$value" in
    "~")
      printf '%s\n' "$HOME"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME" "${value#~/}"
      ;;
    "\$HOME/"*)
      printf '%s/%s\n' "$HOME" "${value#\$HOME/}"
      ;;
    "\${HOME}/"*)
      printf '%s/%s\n' "$HOME" "${value#\${HOME}/}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

validate_nonnegative_integer() {
  name="$1"
  value="$2"
  case "$value" in
    ""|*[!0-9]*)
      die "$name must be a non-negative integer"
      ;;
  esac
}

validate_positive_integer() {
  name="$1"
  value="$2"
  validate_nonnegative_integer "$name" "$value"
  if [ "$value" -le 0 ]; then
    die "$name must be greater than zero"
  fi
}

is_enabled_value() {
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|true|yes|on)
      return 0
      ;;
  esac
  return 1
}

run_with_timeout() {
  timeout_seconds="$1"
  shift
  if ! command -v python3 >/dev/null 2>&1; then
    "$@"
    return "$?"
  fi
  python3 - "$timeout_seconds" "$@" <<'PY'
import subprocess
import sys

timeout = int(sys.argv[1])
command = sys.argv[2:]
try:
    completed = subprocess.run(command, timeout=timeout)
except subprocess.TimeoutExpired:
    print(f"stage timed out after {timeout}s", file=sys.stderr)
    raise SystemExit(124)
raise SystemExit(completed.returncode)
PY
}

require_absolute_path() {
  name="$1"
  value="$2"
  case "$value" in
    /*) ;;
    *) die "$name must resolve to an absolute path: $value" ;;
  esac
}

write_lock_metadata() {
  {
    printf 'pid=%s\n' "$$"
    printf 'started_at=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  } > "$lock_dir/owner"
}

lock_pid() {
  [ -f "$lock_dir/owner" ] || return 1
  awk -F= '$1 == "pid" { print $2; exit }' "$lock_dir/owner" 2>/dev/null
}

lock_age_seconds() {
  if stat -f %m "$lock_dir" >/dev/null 2>&1; then
    modified_at="$(stat -f %m "$lock_dir")"
  elif stat -c %Y "$lock_dir" >/dev/null 2>&1; then
    modified_at="$(stat -c %Y "$lock_dir")"
  else
    return 1
  fi
  now="$(date +%s)"
  [ "$now" -ge "$modified_at" ] || return 1
  printf '%s\n' "$((now - modified_at))"
}

write_summary() {
  summary_path="$1"
  started="$2"
  finished="$3"
  health_status="$4"
  storage_status="$5"
  smoke_status="$6"
  run_dir="$7"
  real_brief_status="${8:-skipped}"
  real_brief_run_dir="${9:-}"

  {
    printf '# OS1 Business Operations Run\n\n'
    printf -- '- Started: `%s`\n' "$started"
    printf -- '- Finished: `%s`\n' "$finished"
    printf -- '- Model: `%s`\n' "$MODEL"
    printf -- '- Mode: `%s`\n' "$MODE"
    printf -- '- Health: `%s`\n' "$health_status"
    printf -- '- Storage: `%s`\n' "$storage_status"
    printf -- '- Business smoke: `%s`\n' "$smoke_status"
    printf -- '- Real business brief: `%s`\n' "$real_brief_status"
    if [ -n "$real_brief_run_dir" ]; then
      printf -- '- Real business brief run directory: `%s`\n' "$real_brief_run_dir"
    fi
    printf -- '- Run directory: `%s`\n\n' "$run_dir"
    printf '## Artifacts\n\n'
    printf -- '- `health.log`\n'
    printf -- '- `storage.txt`\n'
    printf -- '- `business-smoke.log`\n'
    printf -- '- `business-smoke/`\n'
    if [ "$real_brief_status" != "skipped" ]; then
      printf -- '- `real-business-brief.log`\n'
      printf -- '- `real-business-brief/`\n'
    fi
  } > "$summary_path"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick)
      MODE="quick"
      ;;
    --full)
      MODE="full"
      ;;
    --model)
      [ "$#" -ge 2 ] || die "--model requires a value"
      MODEL="$2"
      shift
      ;;
    --output-root)
      [ "$#" -ge 2 ] || die "--output-root requires a value"
      OUTPUT_ROOT="$2"
      shift
      ;;
    --retention-days)
      [ "$#" -ge 2 ] || die "--retention-days requires a value"
      RETENTION_DAYS="$2"
      shift
      ;;
    --real-brief)
      REAL_BRIEF=1
      ;;
    --no-real-brief)
      REAL_BRIEF=0
      ;;
    --no-prune)
      PRUNE=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

case "$MODE" in
  quick|full) ;;
  *) die "mode must be quick or full" ;;
esac
validate_nonnegative_integer "--retention-days" "$RETENTION_DAYS"
validate_nonnegative_integer "OS1_BUSINESS_OPS_LOCK_STALE_SECONDS" "$LOCK_STALE_SECONDS"
validate_positive_integer "OS1_BUSINESS_OPS_STAGE_TIMEOUT_SECONDS" "$STAGE_TIMEOUT_SECONDS"
validate_positive_integer "OLLAMA_TASK_MAX_TIME_SECONDS" "$OLLAMA_TASK_MAX_TIME_SECONDS"
validate_positive_integer "OLLAMA_NUM_PREDICT" "$OLLAMA_NUM_PREDICT"
export OLLAMA_TASK_MAX_TIME_SECONDS OLLAMA_NUM_PREDICT

[ -x "$ROOT_DIR/scripts/os1-local-ops-health.sh" ] || die "missing executable scripts/os1-local-ops-health.sh"
[ -x "$ROOT_DIR/scripts/os1-storage-report.sh" ] || die "missing executable scripts/os1-storage-report.sh"
[ -x "$ROOT_DIR/scripts/os1-business-smoke.sh" ] || die "missing executable scripts/os1-business-smoke.sh"
if is_enabled_value "$REAL_BRIEF" && [ ! -x "$ROOT_DIR/scripts/os1-real-business-brief.sh" ]; then
  die "missing executable scripts/os1-real-business-brief.sh"
fi

OUTPUT_ROOT="$(expand_home_path "$OUTPUT_ROOT")"
require_absolute_path "--output-root" "$OUTPUT_ROOT"
runs_root="$OUTPUT_ROOT/runs"
mkdir -p "$runs_root" || die "could not create runs directory: $runs_root"

lock_dir="$OUTPUT_ROOT/.lock"
if ! mkdir "$lock_dir" 2>/dev/null; then
  owner_pid="$(lock_pid || true)"
  if [ -n "$owner_pid" ] && kill -0 "$owner_pid" 2>/dev/null; then
    printf 'INFO: another OS1 business operations run is already active; skipping\n'
    exit 0
  fi

  lock_age="$(lock_age_seconds || printf '')"
  if [ -z "$lock_age" ] || [ "$lock_age" -lt "$LOCK_STALE_SECONDS" ]; then
    printf 'FAIL: business operations lock exists but no active owner was confirmed: %s\n' "$lock_dir" >&2
    exit 1
  fi

  printf 'WARN: removing stale business operations lock: %s\n' "$lock_dir" >&2
  rm -rf "$lock_dir" || die "could not remove stale business operations lock: $lock_dir"
  if ! mkdir "$lock_dir" 2>/dev/null; then
    printf 'FAIL: could not acquire business operations lock: %s\n' "$lock_dir" >&2
    exit 1
  fi
fi
write_lock_metadata || die "could not write business operations lock metadata: $lock_dir/owner"
cleanup() {
  rm -f "$lock_dir/owner" 2>/dev/null || true
  rmdir "$lock_dir" 2>/dev/null || true
}
abort() {
  cleanup
  exit 130
}
trap cleanup EXIT
trap abort HUP INT TERM

started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
run_id="$(date -u '+%Y%m%dT%H%M%SZ')"
run_dir="$runs_root/$run_id"
smoke_dir="$run_dir/business-smoke"
mkdir -p "$smoke_dir" || die "could not create business smoke directory: $smoke_dir"

printf 'OS1 business operations run\n'
printf 'Run: %s\n' "$run_id"
printf 'Model: %s\n' "$MODEL"
printf 'Mode: %s\n' "$MODE"
printf 'Output: %s\n' "$run_dir"

health_status="failed"
if OS1_LOCAL_OPS_KICK_BUSINESS_OPS=0 run_with_timeout "$STAGE_TIMEOUT_SECONDS" \
    "$ROOT_DIR/scripts/os1-local-ops-health.sh" > "$run_dir/health.log" 2>&1; then
  health_status="passed"
fi

storage_status="failed"
if run_with_timeout "$STAGE_TIMEOUT_SECONDS" \
    "$ROOT_DIR/scripts/os1-storage-report.sh" > "$run_dir/storage.txt" 2>&1; then
  storage_status="passed"
fi

smoke_args=(--output-dir "$smoke_dir" --model "$MODEL")
if [ "$MODE" = "quick" ]; then
  smoke_args=(--quick "${smoke_args[@]}")
fi

smoke_status="failed"
if run_with_timeout "$STAGE_TIMEOUT_SECONDS" \
    "$ROOT_DIR/scripts/os1-business-smoke.sh" "${smoke_args[@]}" > "$run_dir/business-smoke.log" 2>&1; then
  smoke_status="passed"
fi

real_brief_status="skipped"
real_brief_run_dir=""
if is_enabled_value "$REAL_BRIEF"; then
  real_brief_status="failed"
  real_brief_root="$run_dir/real-business-brief"
  if run_with_timeout "$STAGE_TIMEOUT_SECONDS" \
      "$ROOT_DIR/scripts/os1-real-business-brief.sh" \
      "--$MODE" \
      --model "$MODEL" \
      --output-root "$real_brief_root" \
      --no-symlink > "$run_dir/real-business-brief.log" 2>&1; then
    real_brief_status="passed"
    real_brief_run_dir="$(
      awk '/^RESULT: brief-ready RUN=/ { sub(/^RESULT: brief-ready RUN=/, ""); print; exit }' \
        "$run_dir/real-business-brief.log" 2>/dev/null
    )"
  fi
fi

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
write_summary "$run_dir/summary.md" "$started_at" "$finished_at" "$health_status" "$storage_status" "$smoke_status" "$run_dir" "$real_brief_status" "$real_brief_run_dir" || die "could not write business operations summary: $run_dir/summary.md"

if ! ln -sfn "$run_dir" "$OUTPUT_ROOT/latest" 2>/dev/null; then
  printf 'FAIL: could not update latest business operations summary link: %s/latest\n' "$OUTPUT_ROOT" >&2
  exit 1
fi

if [ "$PRUNE" -eq 1 ] && [ "$RETENTION_DAYS" -gt 0 ]; then
  find "$runs_root" -mindepth 1 -maxdepth 1 -type d -mtime +"$RETENTION_DAYS" -print -exec rm -rf {} + 2>/dev/null || true
fi

printf 'Health: %s\n' "$health_status"
printf 'Storage: %s\n' "$storage_status"
printf 'Business smoke: %s\n' "$smoke_status"
printf 'Real business brief: %s\n' "$real_brief_status"
printf 'Summary: %s\n' "$run_dir/summary.md"

if [ "$health_status" = "passed" ] && [ "$storage_status" = "passed" ] && [ "$smoke_status" = "passed" ] && { [ "$real_brief_status" = "skipped" ] || [ "$real_brief_status" = "passed" ]; }; then
  printf 'OK: OS1 business operations run completed\n'
  exit 0
fi

printf 'FAIL: OS1 business operations run completed with failures\n' >&2
exit 1
