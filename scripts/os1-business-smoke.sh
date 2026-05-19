#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}"
NUM_PREDICT="${OLLAMA_NUM_PREDICT:-220}"
TEMPERATURE="${OLLAMA_TEMPERATURE:-0.2}"
OUTPUT_DIR=""
QUICK=0

usage() {
  cat <<'USAGE'
Usage: scripts/os1-business-smoke.sh [--quick] [--model MODEL] [--output-dir DIR]

Runs local-only business workflow smokes through Ollama. No files are written
unless --output-dir is provided.

Options:
  --quick           Run only the daily operations brief smoke.
  --model MODEL     Ollama model. Default: qwen2.5-coder:3b.
  --output-dir DIR  Write each response as a Markdown file.
  -h, --help        Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --quick)
      QUICK=1
      ;;
    --model)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      MODEL="$2"
      shift
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || {
        usage >&2
        exit 64
      }
      OUTPUT_DIR="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf 'os1-business-smoke: unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
  shift
done

if [ ! -x "$ROOT_DIR/scripts/ollama-task.sh" ]; then
  printf 'os1-business-smoke: missing executable scripts/ollama-task.sh\n' >&2
  exit 1
fi

if [ -n "$OUTPUT_DIR" ]; then
  mkdir -p "$OUTPUT_DIR"
fi

trimmed_length() {
  awk 'BEGIN { n = 0 } { gsub(/[[:space:]]+/, " "); n += length($0) } END { print n }'
}

slug_for_case() {
  case "$1" in
    "daily operations brief")
      printf 'daily-operations-brief'
      ;;
    "customer support triage")
      printf 'customer-support-triage'
      ;;
    "project task extraction")
      printf 'project-task-extraction'
      ;;
  esac
}

prompt_for_case() {
  case "$1" in
    "daily operations brief")
      cat <<'PROMPT'
You are OS1 running locally for a small business operator.
Create a compact daily operations brief from these signals:
- local health monitor is green
- disk has 57 GiB free
- Azure is disabled
- open risks: CUA driver installed but not running, public release not notarized
- today's focus: customer follow-up, invoice review, and project delivery

Return exactly these four Markdown bullet lines and no other text:
- Status: ...
- Priorities: ...
- Risks: ...
- Next Action: ...
PROMPT
      ;;
    "customer support triage")
      cat <<'PROMPT'
You are OS1 running locally for customer support triage.
Classify these three inbound messages:
1. "I cannot open the app after downloading it."
2. "Can you summarize yesterday's project notes?"
3. "The local model feels slow on my MacBook Air."

Return a compact Markdown table with columns: customer issue, category, urgency, owner action.
PROMPT
      ;;
    "project task extraction")
      cat <<'PROMPT'
You are OS1 running locally for project management.
Extract tasks from this note:
"Finish the local production readiness gate, update the launchd runbook, verify GitHub CI, then prepare a draft release plan once Developer ID signing is available."

Return Markdown checkboxes only. Each checkbox must start with an imperative verb.
PROMPT
      ;;
  esac
}

validate_daily_operations_brief() {
  response="$1"
  nonblank_count="$(printf '%s\n' "$response" | awk 'NF { n += 1 } END { print n + 0 }')"
  if [ "$nonblank_count" -ne 4 ]; then
    printf 'FAIL: daily operations brief must contain exactly four non-empty lines\n' >&2
    return 1
  fi

  for label in Status Priorities Risks "Next Action"; do
    if ! printf '%s\n' "$response" | grep -Eiq "^[[:space:]]*[-*][[:space:]]+(\*\*)?$label(\*\*)?:|^[[:space:]]*[-*][[:space:]]+(\*\*)?$label:\*\*" ; then
      printf 'FAIL: daily operations brief missing bullet label: %s\n' "$label" >&2
      return 1
    fi
  done
}

validate_customer_support_triage() {
  response="$1"
  if ! printf '%s\n' "$response" | grep -Eiq '^\|.*customer issue.*\|.*category.*\|.*urgency.*\|.*owner action.*\|[[:space:]]*$'; then
    printf 'FAIL: customer support triage missing expected Markdown table header\n' >&2
    return 1
  fi
  if ! printf '%s\n' "$response" | grep -Eq '^\|[[:space:]]*:?-{3,}:?[[:space:]]*\|'; then
    printf 'FAIL: customer support triage missing Markdown table separator\n' >&2
    return 1
  fi
  data_rows="$(printf '%s\n' "$response" | awk '
    /^\|/ && $0 !~ /customer issue/i && $0 !~ /^[|[:space:]:-]+$/ { n += 1 }
    END { print n + 0 }
  ')"
  if [ "$data_rows" -lt 3 ]; then
    printf 'FAIL: customer support triage must include at least three data rows\n' >&2
    return 1
  fi
}

validate_project_task_extraction() {
  response="$1"
  checkbox_rows="$(printf '%s\n' "$response" | awk '/^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+[[:alpha:]]+/ { n += 1 } END { print n + 0 }')"
  if [ "$checkbox_rows" -lt 3 ]; then
    printf 'FAIL: project task extraction must include at least three Markdown checkboxes\n' >&2
    return 1
  fi

  if printf '%s\n' "$response" | awk '
    NF && $0 !~ /^[[:space:]]*[-*][[:space:]]+\[[ xX]\][[:space:]]+/ { bad = 1 }
    END { exit bad ? 0 : 1 }
  '; then
    printf 'FAIL: project task extraction must return Markdown checkboxes only\n' >&2
    return 1
  fi
}

validate_case() {
  name="$1"
  response="$2"

  case "$name" in
    "daily operations brief")
      validate_daily_operations_brief "$response"
      ;;
    "customer support triage")
      validate_customer_support_triage "$response"
      ;;
    "project task extraction")
      validate_project_task_extraction "$response"
      ;;
  esac
}

run_case() {
  name="$1"
  prompt="$(prompt_for_case "$name")"

  printf '\n== %s ==\n' "$name"
  if ! response="$(
    printf '%s' "$prompt" | \
      OLLAMA_MODEL="$MODEL" \
      OLLAMA_NUM_PREDICT="$NUM_PREDICT" \
      OLLAMA_TEMPERATURE="$TEMPERATURE" \
      "$ROOT_DIR/scripts/ollama-task.sh"
  )"; then
    printf 'FAIL: %s smoke failed\n' "$name" >&2
    return 1
  fi

  if [ "$(printf '%s' "$response" | trimmed_length)" -le 0 ]; then
    printf 'FAIL: %s smoke returned an empty response\n' "$name" >&2
    return 1
  fi

  printf '%s\n' "$response"

  if ! validate_case "$name" "$response"; then
    return 1
  fi

  if [ -n "$OUTPUT_DIR" ]; then
    slug="$(slug_for_case "$name")"
    {
      printf '# %s\n\n' "$name"
      printf 'Model: `%s`\n\n' "$MODEL"
      printf '%s\n' "$response"
    } > "$OUTPUT_DIR/$slug.md"
    printf 'Wrote %s\n' "$OUTPUT_DIR/$slug.md"
  fi
}

printf 'OS1 local business smoke\n'
printf 'Model: %s\n' "$MODEL"

CASES="daily operations brief"
if [ "$QUICK" -ne 1 ]; then
  CASES="$CASES
customer support triage
project task extraction"
fi

failures=0
old_ifs="$IFS"
IFS='
'
for case_name in $CASES; do
  [ -n "$case_name" ] || continue
  if ! run_case "$case_name"; then
    failures=$((failures + 1))
  fi
done
IFS="$old_ifs"

if [ "$failures" -eq 0 ]; then
  printf '\nOK: business smoke completed\n'
  exit 0
fi

printf '\nFAIL: business smoke completed with %s failure(s)\n' "$failures" >&2
exit 1
