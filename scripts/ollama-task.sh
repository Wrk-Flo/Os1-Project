#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}"
HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
NUM_PREDICT="${OLLAMA_NUM_PREDICT:-512}"
TEMPERATURE="${OLLAMA_TEMPERATURE:-0.2}"
GENERATE_URL="${HOST%/}/api/generate"

body_file="$(mktemp)"
err_file="$(mktemp)"
payload_file="$(mktemp)"

cleanup() {
  rm -f "$body_file" "$err_file" "$payload_file"
}
trap cleanup EXIT HUP INT TERM

die() {
  printf 'ollama-task: %s\n' "$*" >&2
  exit 1
}

if [ "$#" -gt 0 ]; then
  prompt="$*"
elif [ -t 0 ]; then
  die "missing prompt; pass text as arguments or pipe it on stdin"
else
  prompt="$(cat)"
fi

if [ -z "$prompt" ]; then
  die "missing prompt; prompt cannot be empty"
fi

if ! command -v curl >/dev/null 2>&1; then
  die "curl not found"
fi

if ! command -v python3 >/dev/null 2>&1; then
  die "python3 not found"
fi

if printf '%s' "$prompt" | python3 -c '
import json
import sys

model, num_predict_raw, temperature_raw = sys.argv[1:4]
prompt = sys.stdin.read()

try:
    num_predict = int(num_predict_raw)
except ValueError:
    print("ollama-task: OLLAMA_NUM_PREDICT must be an integer", file=sys.stderr)
    sys.exit(64)

try:
    temperature = float(temperature_raw)
except ValueError:
    print("ollama-task: OLLAMA_TEMPERATURE must be a number", file=sys.stderr)
    sys.exit(64)

json.dump(
    {
        "model": model,
        "prompt": prompt,
        "stream": False,
        "options": {
            "num_predict": num_predict,
            "temperature": temperature,
        },
    },
    sys.stdout,
    separators=(",", ":"),
)
' "$MODEL" "$NUM_PREDICT" "$TEMPERATURE" > "$payload_file"; then
  :
else
  status=$?
  exit "$status"
fi

if ! http_status="$(curl -sS --connect-timeout 3 --max-time 600 -o "$body_file" -w '%{http_code}' \
  -H 'Content-Type: application/json' \
  --data-binary "@$payload_file" \
  "$GENERATE_URL" 2>"$err_file")"; then
  curl_error="$(tr '\n' ' ' < "$err_file" | awk '{ if (length($0) > 240) print substr($0, 1, 240) "..."; else print $0 }')"
  if [ -n "$curl_error" ]; then
    die "native API request failed at $GENERATE_URL: $curl_error"
  fi
  die "native API request failed at $GENERATE_URL"
fi

case "$http_status" in
  2*) ;;
  *)
    api_error="$(
      python3 - "$body_file" <<'PY' 2>/dev/null || true
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception:
    sys.exit(0)

if isinstance(payload, dict) and payload.get("error"):
    print(str(payload["error"])[:240])
PY
    )"
    if [ -n "$api_error" ]; then
      die "native API returned HTTP $http_status: $api_error"
    fi
    die "native API returned HTTP $http_status at $GENERATE_URL"
    ;;
esac

python3 - "$body_file" <<'PY'
import json
import sys

try:
    with open(sys.argv[1], "r", encoding="utf-8") as handle:
        payload = json.load(handle)
except Exception as exc:
    print(f"ollama-task: native API returned invalid JSON: {exc}", file=sys.stderr)
    sys.exit(1)

if isinstance(payload, dict) and payload.get("error"):
    print(f"ollama-task: native API error: {payload['error']}", file=sys.stderr)
    sys.exit(1)

response = payload.get("response") if isinstance(payload, dict) else None
if not isinstance(response, str):
    print("ollama-task: native API response did not include a text response", file=sys.stderr)
    sys.exit(1)

sys.stdout.write(response)
PY
