#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

MODEL="${OLLAMA_MODEL:-qwen2.5-coder:1.5b}"
HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
HOST="${HOST%/}"
NATIVE_TAGS_URL="$HOST/api/tags"
OPENAI_MODELS_URL="$HOST/v1/models"

failures=0
warnings=0
python_ok=0
curl_ok=0

native_body="$(mktemp)"
native_err="$(mktemp)"
openai_body="$(mktemp)"
openai_err="$(mktemp)"

cleanup() {
  rm -f "$native_body" "$native_err" "$openai_body" "$openai_err"
}
trap cleanup EXIT HUP INT TERM

info() {
  printf 'INFO: %s\n' "$*"
}

pass() {
  printf 'OK: %s\n' "$*"
}

warn() {
  warnings=$((warnings + 1))
  printf 'WARN: %s\n' "$*"
}

fail() {
  failures=$((failures + 1))
  printf 'FAIL: %s\n' "$*"
}

short_file() {
  if [ -s "$1" ]; then
    tr '\n' ' ' < "$1" | awk '{ if (length($0) > 240) print substr($0, 1, 240) "..."; else print $0 }'
  fi
  return 0
}

http_get() {
  url="$1"
  body_file="$2"
  err_file="$3"
  curl -sS --connect-timeout 3 --max-time 10 -o "$body_file" -w '%{http_code}' "$url" 2>"$err_file"
}

json_error_message() {
  python3 - "$1" <<'PY'
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
}

native_model_summary() {
  python3 - "$1" <<'PY'
import json
import sys

def human_size(value):
    try:
        size = float(value)
    except Exception:
        return "unknown size"

    units = ("B", "KiB", "MiB", "GiB", "TiB")
    for unit in units:
        if size < 1024 or unit == units[-1]:
            if unit == "B":
                return f"{int(size)} {unit}"
            return f"{size:.1f} {unit}"
        size /= 1024

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

models = payload.get("models", []) if isinstance(payload, dict) else []
for item in models:
    if not isinstance(item, dict):
        continue
    name = item.get("name") or item.get("model")
    if not name:
        continue
    print(f"  - {name} ({human_size(item.get('size'))})")
PY
}

native_model_names() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

models = payload.get("models", []) if isinstance(payload, dict) else []
for item in models:
    if not isinstance(item, dict):
        continue
    for key in ("name", "model"):
        name = item.get(key)
        if name:
            print(name)
PY
}

openai_model_ids() {
  python3 - "$1" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

data = payload.get("data", []) if isinstance(payload, dict) else []
for item in data:
    if isinstance(item, dict) and item.get("id"):
        print(item["id"])
PY
}

report_disk() {
  path="${HOME:-.}"
  if command -v df >/dev/null 2>&1; then
    if disk_line="$(df -h "$path" 2>/dev/null | awk -v path="$path" 'NR == 2 { printf "%s available of %s at %s used for %s", $4, $2, $5, path; found = 1 } END { exit found ? 0 : 1 }')"; then
      info "disk: $disk_line"
    else
      warn "could not read disk space for $path"
    fi
  else
    warn "df not found; disk space was not checked"
  fi
}

report_memory() {
  if command -v sysctl >/dev/null 2>&1 && total_bytes="$(sysctl -n hw.memsize 2>/dev/null)" && [ -n "$total_bytes" ]; then
    total_gib="$(awk -v bytes="$total_bytes" 'BEGIN { printf "%.1f", bytes / 1073741824 }')"
    if command -v vm_stat >/dev/null 2>&1 && command -v pagesize >/dev/null 2>&1; then
      page_size="$(pagesize)"
      available_gib="$(vm_stat 2>/dev/null | awk -v page_size="$page_size" '
        /Pages free/ { gsub(/[^0-9]/, "", $3); free = $3 }
        /Pages inactive/ { gsub(/[^0-9]/, "", $3); inactive = $3 }
        /Pages speculative/ { gsub(/[^0-9]/, "", $3); speculative = $3 }
        END {
          available = (free + inactive + speculative) * page_size / 1073741824
          if (available > 0) {
            printf "%.1f", available
          }
        }
      ' || true)"
      if [ -n "$available_gib" ]; then
        info "memory: ${total_gib} GiB total, approx ${available_gib} GiB readily available"
      else
        info "memory: ${total_gib} GiB total"
      fi
    else
      info "memory: ${total_gib} GiB total"
    fi
  elif command -v free >/dev/null 2>&1; then
    if memory_line="$(free -h | awk '/^Mem:/ { printf "%s total, %s available", $2, $7; found = 1 } END { exit found ? 0 : 1 }')"; then
      info "memory: $memory_line"
    else
      warn "could not read memory from free"
    fi
  elif [ -r /proc/meminfo ]; then
    if memory_line="$(awk '
      /^MemTotal:/ { total = $2 }
      /^MemAvailable:/ { available = $2 }
      END {
        if (total > 0) {
          printf "%.1f GiB total", total / 1048576
          if (available > 0) {
            printf ", %.1f GiB available", available / 1048576
          }
        } else {
          exit 1
        }
      }
    ' /proc/meminfo)"; then
      info "memory: $memory_line"
    else
      warn "could not read memory from /proc/meminfo"
    fi
  else
    warn "memory was not checked on this platform"
  fi
}

info "Ollama host: $HOST"
info "Selected model: $MODEL"

if [ "${OLLAMA_API_KEY+x}" = "x" ]; then
  if [ -n "$OLLAMA_API_KEY" ]; then
    info "OLLAMA_API_KEY: set"
  else
    info "OLLAMA_API_KEY: empty"
  fi
else
  info "OLLAMA_API_KEY: missing"
fi

if command -v python3 >/dev/null 2>&1; then
  python_ok=1
  pass "python3 found"
else
  fail "python3 not found; JSON responses cannot be checked"
fi

if command -v curl >/dev/null 2>&1; then
  curl_ok=1
  pass "curl found"
else
  fail "curl not found; Ollama HTTP endpoints cannot be checked"
fi

if command -v ollama >/dev/null 2>&1; then
  if ollama_version="$(ollama --version 2>&1 | awk 'NR == 1 { print; exit }')" && [ -n "$ollama_version" ]; then
    pass "ollama CLI found: $ollama_version"
  else
    pass "ollama CLI found"
  fi
else
  warn "ollama CLI not found on PATH"
fi

report_disk
report_memory

if [ "$curl_ok" -eq 1 ]; then
  if native_status="$(http_get "$NATIVE_TAGS_URL" "$native_body" "$native_err")"; then
    case "$native_status" in
      2*)
        pass "native API reachable: $NATIVE_TAGS_URL (HTTP $native_status)"
        if [ "$python_ok" -eq 1 ]; then
          if model_summary="$(native_model_summary "$native_body")" && model_names="$(native_model_names "$native_body")"; then
            if [ -n "$model_summary" ]; then
              info "installed local models:"
              printf '%s\n' "$model_summary"
              if printf '%s\n' "$model_names" | grep -Fx -- "$MODEL" >/dev/null 2>&1; then
                pass "selected model is installed: $MODEL"
              else
                fail "selected model is not installed: $MODEL"
              fi
            else
              fail "no local models returned by native API"
            fi
          else
            fail "native API returned invalid JSON at $NATIVE_TAGS_URL"
          fi
        fi
        ;;
      *)
        if [ "$python_ok" -eq 1 ]; then
          native_error="$(json_error_message "$native_body")"
        else
          native_error="$(short_file "$native_body")"
        fi
        if [ -n "$native_error" ]; then
          fail "native API returned HTTP $native_status: $native_error"
        else
          fail "native API returned HTTP $native_status at $NATIVE_TAGS_URL"
        fi
        ;;
    esac
  else
    native_error="$(short_file "$native_err")"
    if [ -n "$native_error" ]; then
      fail "native API unavailable at $NATIVE_TAGS_URL: $native_error"
    else
      fail "native API unavailable at $NATIVE_TAGS_URL"
    fi
  fi

  if openai_status="$(http_get "$OPENAI_MODELS_URL" "$openai_body" "$openai_err")"; then
    case "$openai_status" in
      2*)
        pass "OpenAI-compatible endpoint reachable: $OPENAI_MODELS_URL (HTTP $openai_status)"
        if [ "$python_ok" -eq 1 ]; then
          if openai_ids="$(openai_model_ids "$openai_body")"; then
            if [ -n "$openai_ids" ]; then
              info "OpenAI-compatible models:"
              printf '%s\n' "$openai_ids" | awk '{ print "  - " $0 }'
              if printf '%s\n' "$openai_ids" | grep -Fx -- "$MODEL" >/dev/null 2>&1; then
                pass "selected model is exposed by /v1/models: $MODEL"
              else
                fail "selected model is not exposed by /v1/models: $MODEL"
              fi
            else
              warn "OpenAI-compatible endpoint returned no model ids"
            fi
          else
            fail "OpenAI-compatible endpoint returned invalid JSON at $OPENAI_MODELS_URL"
          fi
        fi
        ;;
      *)
        if [ "$python_ok" -eq 1 ]; then
          openai_error="$(json_error_message "$openai_body")"
        else
          openai_error="$(short_file "$openai_body")"
        fi
        if [ -n "$openai_error" ]; then
          fail "OpenAI-compatible endpoint returned HTTP $openai_status: $openai_error"
        else
          fail "OpenAI-compatible endpoint returned HTTP $openai_status at $OPENAI_MODELS_URL"
        fi
        ;;
    esac
  else
    openai_error="$(short_file "$openai_err")"
    if [ -n "$openai_error" ]; then
      fail "OpenAI-compatible endpoint unavailable at $OPENAI_MODELS_URL: $openai_error"
    else
      fail "OpenAI-compatible endpoint unavailable at $OPENAI_MODELS_URL"
    fi
  fi
fi

if [ "$failures" -eq 0 ]; then
  pass "health check completed with $warnings warning(s)"
  exit 0
fi

printf 'SUMMARY: %s failure(s), %s warning(s)\n' "$failures" "$warnings"
exit 1
