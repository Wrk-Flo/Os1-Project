#!/usr/bin/env bash
# llm-task-with-fallback.sh — try local Ollama first, fall back to OpenRouter on
# failure. Same I/O contract as scripts/ollama-task.sh and
# scripts/llm-task-openrouter.sh:
#   - Reads prompt from stdin (or from positional args).
#   - Writes the model's response to stdout.
#   - Honors OLLAMA_MODEL, OLLAMA_TEMPERATURE, OLLAMA_NUM_PREDICT,
#     OLLAMA_TASK_MAX_TIME_SECONDS so the rest of the pipeline doesn't change.
#
# Designed for the daily real-business-brief launchd job: local-first keeps the
# brief working through OpenRouter outages, and OpenRouter remains the fallback
# when local Ollama is offline, the model isn't pulled, or the call times out.
#
# Env knobs (all optional):
#   OS1_FALLBACK_PRIMARY_TIMEOUT  seconds to wait on the primary (local Ollama)
#                                 before failing over. Default 60.
#   OS1_FALLBACK_PRIMARY_MODEL    OLLAMA_MODEL override applied to the primary
#                                 call only. Default: inherit OLLAMA_MODEL or
#                                 fall back to llama3.2:3b (Hermes new primary).
#   OS1_FALLBACK_DISABLE          if non-empty, skip the primary and go straight
#                                 to OpenRouter (useful for debugging).
#   OS1_LLM_DEBUG                 if set, echo which leg ran to stderr.
#
# Exit codes:
#   0  success (one of the legs returned content)
#   1  both legs failed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRIMARY="$SCRIPT_DIR/ollama-task.sh"
FALLBACK="$SCRIPT_DIR/llm-task-openrouter.sh"

PRIMARY_TIMEOUT="${OS1_FALLBACK_PRIMARY_TIMEOUT:-60}"
PRIMARY_MODEL_DEFAULT="${OS1_FALLBACK_PRIMARY_MODEL:-${OLLAMA_MODEL:-llama3.2:3b}}"

debug() {
  if [ -n "${OS1_LLM_DEBUG:-}" ]; then
    printf 'llm-task-with-fallback: %s\n' "$*" >&2
  fi
}

# Read prompt once so both legs see the same input.
if [ "$#" -gt 0 ]; then
  prompt="$*"
elif [ ! -t 0 ]; then
  prompt="$(cat)"
else
  printf 'llm-task-with-fallback: pass prompt as args or stdin\n' >&2
  exit 1
fi

if [ -z "$prompt" ]; then
  printf 'llm-task-with-fallback: empty prompt\n' >&2
  exit 1
fi

run_fallback() {
  debug "running fallback: $FALLBACK"
  if [ ! -x "$FALLBACK" ]; then
    printf 'llm-task-with-fallback: fallback %s not executable\n' "$FALLBACK" >&2
    return 1
  fi
  printf '%s' "$prompt" | "$FALLBACK"
}

if [ -n "${OS1_FALLBACK_DISABLE:-}" ]; then
  debug "primary disabled via OS1_FALLBACK_DISABLE; using fallback only"
  run_fallback
  exit $?
fi

if [ ! -x "$PRIMARY" ]; then
  debug "primary $PRIMARY not executable; using fallback"
  run_fallback
  exit $?
fi

# Try the primary (local Ollama). Capture stdout to a temp file so we only emit
# it on success — otherwise we'd mix half-finished output with the fallback's.
primary_out="$(mktemp -t os1-llm-primary.XXXXXX)"
primary_err="$(mktemp -t os1-llm-primary-err.XXXXXX)"
cleanup_primary() { rm -f "$primary_out" "$primary_err"; }
trap cleanup_primary EXIT

debug "running primary: OLLAMA_MODEL=$PRIMARY_MODEL_DEFAULT timeout=${PRIMARY_TIMEOUT}s"

primary_rc=0
OLLAMA_MODEL="$PRIMARY_MODEL_DEFAULT" \
OLLAMA_TASK_MAX_TIME_SECONDS="$PRIMARY_TIMEOUT" \
  printf '%s' "$prompt" | "$PRIMARY" > "$primary_out" 2> "$primary_err" || primary_rc=$?

# Treat any non-zero rc as failure and fall through. Also treat empty stdout as
# failure even on rc=0 (paranoia: Ollama has been known to return empty bodies
# under load).
if [ "$primary_rc" -eq 0 ] && [ -s "$primary_out" ]; then
  debug "primary succeeded; emitting $(wc -c <"$primary_out") bytes"
  cat "$primary_out"
  exit 0
fi

debug "primary failed (rc=$primary_rc, bytes=$(wc -c <"$primary_out" 2>/dev/null || echo 0)); falling back"
if [ -s "$primary_err" ] && [ -n "${OS1_LLM_DEBUG:-}" ]; then
  debug "primary stderr (first 240 chars): $(head -c 240 "$primary_err")"
fi

run_fallback
