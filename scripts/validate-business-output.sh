#!/usr/bin/env bash
# validate-business-output.sh — downstream consumer-side validator for the
# OS1 business operations runner output.
#
# Owner: Claude Code (separate lane from Codex CLI, which owns the runner).
# This script reads ONLY the published latest/ artifacts; it does not run
# the runner and does not write into the runner's output tree.
#
# Upstream contract (mirrors scripts/os1-business-ops-run.sh):
#   - Runner publishes timestamped run dirs at:
#       $OS1_BUSINESS_OPS_OUTPUT_ROOT/runs/YYYYMMDDTHHMMSSZ/
#     (default OS1_BUSINESS_OPS_OUTPUT_ROOT is
#      "$HOME/Library/Application Support/OS1/business-ops")
#   - Runner symlinks $OS1_BUSINESS_OPS_OUTPUT_ROOT/latest -> the newest run.
#   - Each run dir contains:
#       summary.md           (markdown, status fields backtick-delimited)
#       health.log
#       storage.txt
#       business-smoke.log
#       business-smoke/      (subdir with at least daily-operations-brief.md;
#                             full mode adds customer-support-triage.md and
#                             project-task-extraction.md)
#
# Parser convention: status fields in summary.md are written as
#   "- Label: `value`"
# This matches scripts/os1-production-readiness.sh awk parser at
# summary_value() (lines ~91-101). We reuse the same convention so we do not
# drift from the readiness gate.
#
# Exit codes:
#   0  all critical checks passed
#   1  one or more FAIL checks (consumer should not trust the output)
#   2  usage error / invalid arguments

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
STRICT=0
STRICT_HISTORY="${OS1_VALIDATE_STRICT_HISTORY:-3}"
FRESH_HOURS="${OS1_FRESH_HOURS:-24}"
DEFAULT_ROOT="$HOME/Library/Application Support/OS1/business-ops"
OUTPUT_ROOT="${OS1_BUSINESS_OPS_ROOT:-$DEFAULT_ROOT}"

FAILURES=0
WARNINGS=0
PASSES=0

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--strict] [--history N] [--root DIR] [-h|--help]

Validates that the OS1 business operations runner has published a fresh and
complete artifact set that downstream operators can actually consume.

Options:
  --strict        Also require that previous N runs all succeeded.
  --history N     Strict-mode lookback (default: 3, also \$OS1_VALIDATE_STRICT_HISTORY).
  --root DIR      Override business-ops root (default: \$OS1_BUSINESS_OPS_ROOT
                  or "$DEFAULT_ROOT").
  -h, --help      Show this help.

Environment:
  OS1_BUSINESS_OPS_ROOT      Override artifact root.
  OS1_FRESH_HOURS            Max age of latest run, in hours (default: 24).
  OS1_VALIDATE_STRICT_HISTORY Strict-mode history length (default: 3).
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --strict)
      STRICT=1
      ;;
    --history)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      STRICT_HISTORY="$2"
      shift
      ;;
    --root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift
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
  shift
done

case "$FRESH_HOURS" in
  ""|*[!0-9]*)
    printf '%s: OS1_FRESH_HOURS must be a non-negative integer (got %q)\n' \
      "$SCRIPT_NAME" "$FRESH_HOURS" >&2
    exit 2
    ;;
esac
case "$STRICT_HISTORY" in
  ""|*[!0-9]*)
    printf '%s: --history must be a non-negative integer (got %q)\n' \
      "$SCRIPT_NAME" "$STRICT_HISTORY" >&2
    exit 2
    ;;
esac

pass() { PASSES=$((PASSES + 1)); printf 'OK: %s\n' "$*"; }
warn() { WARNINGS=$((WARNINGS + 1)); printf 'WARN: %s\n' "$*"; }
fail() { FAILURES=$((FAILURES + 1)); printf 'FAIL: %s\n' "$*"; }

# Match the readiness gate parser convention exactly (awk on backticked value
# in lines shaped like "- Label: `value`").
summary_value() {
  label="$1"
  path="$2"
  awk -v label="$label" '
    $0 ~ "^- " label ": `" {
      split($0, parts, "`")
      print parts[2]
      exit
    }
  ' "$path" 2>/dev/null
}

file_size_bytes() {
  path="$1"
  if stat -f %z "$path" >/dev/null 2>&1; then
    stat -f %z "$path"
  elif stat -c %s "$path" >/dev/null 2>&1; then
    stat -c %s "$path"
  else
    printf '0'
  fi
}

file_mtime_epoch() {
  path="$1"
  if stat -f %m "$path" >/dev/null 2>&1; then
    stat -f %m "$path"
  elif stat -c %Y "$path" >/dev/null 2>&1; then
    stat -c %Y "$path"
  else
    printf '0'
  fi
}

printf 'OS1 business output validation\n'
printf 'Root: %s\n' "$OUTPUT_ROOT"
printf 'Freshness window: %s hour(s)\n' "$FRESH_HOURS"
[ "$STRICT" -eq 1 ] && printf 'Strict mode: history=%s\n' "$STRICT_HISTORY"

# --- 1. latest/ presence ---------------------------------------------------
latest_dir="$OUTPUT_ROOT/latest"
if [ ! -e "$latest_dir" ]; then
  fail "latest/ is missing: $latest_dir"
  printf '\nValidation aborted: no latest run to inspect.\n' >&2
  exit 1
fi
if [ ! -d "$latest_dir" ]; then
  fail "latest/ exists but is not a directory: $latest_dir"
  exit 1
fi
pass "latest/ exists: $latest_dir"

# Resolve real path for diagnostics; tolerate symlink or plain dir.
resolved_latest="$latest_dir"
if [ -L "$latest_dir" ]; then
  if rl="$(readlink "$latest_dir" 2>/dev/null)"; then
    case "$rl" in
      /*) resolved_latest="$rl" ;;
      *)  resolved_latest="$OUTPUT_ROOT/$rl" ;;
    esac
  fi
fi

# --- 2. freshness ----------------------------------------------------------
now_epoch="$(date -u '+%s')"
latest_mtime="$(file_mtime_epoch "$latest_dir")"
if [ "$latest_mtime" -le 0 ]; then
  warn "could not determine mtime for latest/"
else
  age_seconds=$((now_epoch - latest_mtime))
  max_seconds=$((FRESH_HOURS * 3600))
  if [ "$age_seconds" -lt 0 ]; then
    warn "latest/ mtime is in the future by $((-age_seconds))s (clock skew?)"
  elif [ "$age_seconds" -le "$max_seconds" ]; then
    pass "latest/ is fresh: ${age_seconds}s old (limit ${max_seconds}s)"
  else
    fail "latest/ is stale: ${age_seconds}s old (limit ${max_seconds}s)"
  fi
fi

# --- 3. summary.md status fields ------------------------------------------
summary_path="$latest_dir/summary.md"
if [ ! -f "$summary_path" ]; then
  fail "summary.md is missing: $summary_path"
else
  size="$(file_size_bytes "$summary_path")"
  if [ "$size" -gt 100 ]; then
    pass "summary.md is present and >100 bytes (${size} bytes)"
  else
    fail "summary.md is too small: ${size} bytes (expected >100)"
  fi

  health_val="$(summary_value "Health" "$summary_path")"
  storage_val="$(summary_value "Storage" "$summary_path")"
  smoke_val="$(summary_value "Business smoke" "$summary_path")"

  # Upstream writes "passed"/"failed"; the readiness gate treats anything but
  # "passed" as failure. We accept either "passed" or "OK" defensively while
  # staying aligned with the gate's strict comparison.
  for pair in \
      "Health|$health_val" \
      "Storage|$storage_val" \
      "Business smoke|$smoke_val"; do
    label="${pair%%|*}"
    value="${pair#*|}"
    case "$value" in
      passed|OK)
        pass "summary.md $label = $value"
        ;;
      "")
        fail "summary.md $label is missing"
        ;;
      *)
        fail "summary.md $label = $value (expected passed)"
        ;;
    esac
  done

  run_dir_val="$(summary_value "Run directory" "$summary_path")"
  if [ -n "$run_dir_val" ]; then
    pass "summary.md Run directory recorded: $run_dir_val"
  else
    warn "summary.md Run directory is missing"
  fi
fi

# --- 4. expected artifact set ---------------------------------------------
# Per scripts/os1-business-ops-run.sh write_summary(), the runner publishes:
#   summary.md, health.log, storage.txt, business-smoke.log, business-smoke/
# business-smoke/ contains at least daily-operations-brief.md (quick mode);
# full mode also adds customer-support-triage.md and project-task-extraction.md.
expected_files="summary.md health.log storage.txt business-smoke.log"
for fname in $expected_files; do
  fpath="$latest_dir/$fname"
  if [ ! -f "$fpath" ]; then
    fail "expected artifact missing: $fname"
    continue
  fi
  size="$(file_size_bytes "$fpath")"
  if [ "$size" -gt 0 ]; then
    pass "$fname present and non-empty (${size} bytes)"
  else
    fail "$fname is 0 bytes"
  fi
done

smoke_subdir="$latest_dir/business-smoke"
if [ ! -d "$smoke_subdir" ]; then
  fail "expected directory missing: business-smoke/"
else
  pass "business-smoke/ directory exists"
  md_count=0
  for md in "$smoke_subdir"/*.md; do
    [ -f "$md" ] || continue
    md_count=$((md_count + 1))
    size="$(file_size_bytes "$md")"
    if [ "$size" -gt 0 ]; then
      pass "business-smoke/$(basename "$md") present and non-empty (${size} bytes)"
    else
      fail "business-smoke/$(basename "$md") is 0 bytes"
    fi
  done
  if [ "$md_count" -eq 0 ]; then
    fail "business-smoke/ has no *.md artifacts (expected at least daily-operations-brief.md)"
  fi

  daily_brief="$smoke_subdir/daily-operations-brief.md"
  if [ -f "$daily_brief" ]; then
    pass "daily-operations-brief.md present (canonical quick-mode artifact)"
  else
    fail "daily-operations-brief.md missing from business-smoke/"
  fi
fi

# Optional: any *.json artifacts. The current runner does not produce JSON,
# but if it ever does they should be non-empty. We never FAIL on absence.
json_count=0
for j in "$latest_dir"/*.json "$smoke_subdir"/*.json; do
  [ -f "$j" ] || continue
  json_count=$((json_count + 1))
  size="$(file_size_bytes "$j")"
  if [ "$size" -gt 0 ]; then
    pass "JSON artifact $(basename "$j") present and non-empty (${size} bytes)"
  else
    fail "JSON artifact $(basename "$j") is 0 bytes"
  fi
done
if [ "$json_count" -eq 0 ]; then
  printf 'INFO: no *.json artifacts in latest/ (none expected by current runner)\n'
fi

# --- 5. strict-mode history check -----------------------------------------
if [ "$STRICT" -eq 1 ]; then
  runs_root="$OUTPUT_ROOT/runs"
  if [ ! -d "$runs_root" ]; then
    fail "strict mode: runs/ directory is missing: $runs_root"
  elif [ "$STRICT_HISTORY" -eq 0 ]; then
    pass "strict mode: history depth is 0; nothing to walk"
  else
    # Newest-first listing of run dirs (sortable by run id, which is UTC stamp).
    history_runs=""
    if ls -- "$runs_root" >/dev/null 2>&1; then
      history_runs="$(ls -- "$runs_root" 2>/dev/null | sort -r)"
    fi
    if [ -z "$history_runs" ]; then
      fail "strict mode: no historical runs under $runs_root"
    else
      checked=0
      strict_failed=0
      old_ifs="$IFS"
      IFS='
'
      for rid in $history_runs; do
        [ -n "$rid" ] || continue
        [ "$checked" -lt "$STRICT_HISTORY" ] || break
        checked=$((checked + 1))
        rsum="$runs_root/$rid/summary.md"
        if [ ! -f "$rsum" ]; then
          fail "strict mode: run $rid has no summary.md"
          strict_failed=$((strict_failed + 1))
          continue
        fi
        h="$(summary_value "Health" "$rsum")"
        s="$(summary_value "Storage" "$rsum")"
        b="$(summary_value "Business smoke" "$rsum")"
        if [ "$h" = "passed" ] && [ "$s" = "passed" ] && [ "$b" = "passed" ]; then
          pass "strict mode: run $rid all green"
        else
          fail "strict mode: run $rid status health=$h storage=$s smoke=$b"
          strict_failed=$((strict_failed + 1))
        fi
      done
      IFS="$old_ifs"
      if [ "$checked" -lt "$STRICT_HISTORY" ]; then
        warn "strict mode: only $checked of $STRICT_HISTORY requested runs were available"
      fi
      if [ "$strict_failed" -eq 0 ] && [ "$checked" -gt 0 ]; then
        pass "strict mode: last $checked run(s) all passed"
      fi
    fi
  fi
fi

# --- summary ---------------------------------------------------------------
printf '\n== Validation Summary ==\n'
printf 'Checks: %d pass, %d fail, %d warn\n' "$PASSES" "$FAILURES" "$WARNINGS"
if [ "$FAILURES" -eq 0 ]; then
  printf 'OK: business output is consumable\n'
  exit 0
fi
printf 'FAIL: business output is NOT consumable (%d failure(s))\n' "$FAILURES" >&2
exit 1
