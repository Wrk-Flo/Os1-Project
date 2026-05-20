#!/usr/bin/env bash
# llm-task-openrouter.sh — drop-in replacement for scripts/ollama-task.sh that
# routes the LLM call to OpenRouter instead of local Ollama.
#
# Same I/O contract as ollama-task.sh:
#   - Reads prompt from stdin (or from positional args).
#   - Writes the model's response to stdout.
#   - Honors OLLAMA_MODEL (model id), OLLAMA_TEMPERATURE, OLLAMA_NUM_PREDICT
#     (max_tokens), OLLAMA_TASK_MAX_TIME_SECONDS (timeout) so the rest of the
#     pipeline doesn't need to change. OLLAMA_MODEL falls back to a fast free
#     OpenRouter model when set to ollama-style ids.
#
# Env:
#   OPENROUTER_API_KEY     required — falls back to reading ~/.openrouter-key
#   OPENROUTER_MODEL       overrides the inferred OpenRouter model id
#   OLLAMA_MODEL           if it starts with "qwen2.5-coder" we map to a free
#                          OpenRouter model; if it contains "/" we pass through
#                          as-is (e.g. "z-ai/glm-4.5-air:free").
#   OS1_LLM_DEBUG          if set, echo wire calls to stderr.
#
# Exit codes:
#   0  success
#   1  any failure (missing key, HTTP error, timeout, invalid JSON)
#
# Wire-in (no changes required to os1-real-business-brief.sh as long as that
# script reads OS1_LLM_TASK_BIN, but it does not yet — bind via the launchd
# plist's ProgramArguments instead, or invoke this script directly when running
# the brief manually).

set -euo pipefail

MODEL_RAW="${OPENROUTER_MODEL:-${OLLAMA_MODEL:-z-ai/glm-4.5-air:free}}"
MAX_TOKENS="${OLLAMA_NUM_PREDICT:-1024}"
TEMPERATURE="${OLLAMA_TEMPERATURE:-0.2}"
MAX_TIME_SECONDS="${OLLAMA_TASK_MAX_TIME_SECONDS:-180}"
BASE_URL="${OPENROUTER_BASE_URL:-https://openrouter.ai/api/v1}"

# Map common Ollama coder ids → free OpenRouter chat models.
case "$MODEL_RAW" in
  qwen2.5-coder:*|qwen2.5:*|llama3.2:*)
    MODEL="z-ai/glm-4.5-air:free"
    ;;
  */*)
    MODEL="$MODEL_RAW"
    ;;
  *)
    MODEL="$MODEL_RAW"
    ;;
esac

# Resolve API key.
API_KEY="${OPENROUTER_API_KEY:-}"
if [ -z "$API_KEY" ] && [ -r "$HOME/.openrouter-key" ]; then
  API_KEY="$(tr -d '\r\n' < "$HOME/.openrouter-key")"
fi
if [ -z "$API_KEY" ]; then
  printf 'llm-task-openrouter: OPENROUTER_API_KEY missing (env or ~/.openrouter-key)\n' >&2
  exit 1
fi

# Read prompt.
if [ "$#" -gt 0 ]; then
  prompt="$*"
elif [ ! -t 0 ]; then
  prompt="$(cat)"
else
  printf 'llm-task-openrouter: pass prompt as args or stdin\n' >&2
  exit 1
fi

if [ -z "$prompt" ]; then
  printf 'llm-task-openrouter: empty prompt\n' >&2
  exit 1
fi

# Build the JSON payload with python (safer than jq for arbitrary text).
payload_file="$(mktemp)"
body_file="$(mktemp)"
err_file="$(mktemp)"
cleanup() { rm -f "$payload_file" "$body_file" "$err_file"; }
trap cleanup EXIT

PROMPT="$prompt" MODEL="$MODEL" MAX_TOKENS="$MAX_TOKENS" TEMPERATURE="$TEMPERATURE" \
python3 -c '
import json, os, sys
body = {
    "model": os.environ["MODEL"],
    "messages": [{"role": "user", "content": os.environ["PROMPT"]}],
    "max_tokens": int(os.environ["MAX_TOKENS"]),
    "temperature": float(os.environ["TEMPERATURE"]),
}
sys.stdout.write(json.dumps(body))
' > "$payload_file"

[ -n "${OS1_LLM_DEBUG:-}" ] && printf 'llm-task-openrouter: POST %s/chat/completions model=%s\n' "$BASE_URL" "$MODEL" >&2

if ! http_status="$(curl -sS --connect-timeout 5 --max-time "$MAX_TIME_SECONDS" \
    -H "Authorization: Bearer $API_KEY" \
    -H "Content-Type: application/json" \
    -H "HTTP-Referer: https://os1.local" \
    -H "X-Title: OS1 Real Business Brief" \
    --data-binary "@$payload_file" \
    -o "$body_file" \
    -w '%{http_code}' \
    "${BASE_URL}/chat/completions" 2>"$err_file")"; then
  printf 'llm-task-openrouter: curl failed: %s\n' "$(tr -d '\n' < "$err_file" | head -c 240)" >&2
  exit 1
fi

if [ "$http_status" != "200" ]; then
  printf 'llm-task-openrouter: HTTP %s\n' "$http_status" >&2
  head -c 480 "$body_file" >&2
  printf '\n' >&2
  exit 1
fi

# Extract content.
python3 - "$body_file" <<'PY'
import json, sys
with open(sys.argv[1]) as f:
    data = json.load(f)
choices = data.get("choices") or []
if not choices:
    sys.stderr.write("llm-task-openrouter: no choices in response\n")
    sys.exit(1)
content = choices[0].get("message", {}).get("content") or choices[0].get("text") or ""
if not content.strip():
    sys.stderr.write("llm-task-openrouter: empty content\n")
    sys.exit(1)
sys.stdout.write(content)
PY
