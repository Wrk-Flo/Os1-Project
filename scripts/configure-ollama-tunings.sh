#!/usr/bin/env bash
# configure-ollama-tunings.sh
#
# Apply known-good Ollama performance tunings for 8 GB Apple Silicon Macs.
# Without these, Ollama.app runs naked defaults: KEEP_ALIVE=5m (models cold-
# load on every idle call), KV cache F16 (doubles RAM cost), no flash
# attention. With these, llama3.2:1b returns in ~0.5 s warm on an M1/8 GB.
#
# Three modes:
#   --apply        Set env via launchctl (current session) and restart
#                  Ollama.app so its serve subprocess inherits them. Default.
#   --persist      Also install a LaunchAgent at
#                  ~/Library/LaunchAgents/com.os1.ollama-env.plist so the
#                  tunings survive reboot.
#   --status       Print current Ollama serve subprocess env + ps. No writes.
#   --preload MODEL  After applying, preload the named model with
#                    keep_alive=-1 so it stays warm. Repeatable.
#
# Required tunings (justified by Ollama docs and community benchmarks for
# unified-memory Apple Silicon, 2025-2026):
#
#   OLLAMA_KEEP_ALIVE=-1
#     Keep loaded models in memory forever. The dominant cause of "Ollama
#     is slow" complaints on Apple Silicon is the default 5-minute idle
#     unload: any pause > 5 min triggers a 3-7 s cold load on the next
#     request. With -1, the first call after a fresh boot pays once.
#
#   OLLAMA_FLASH_ATTENTION=1
#     Enables Metal-backed flash attention; lowers VRAM/unified-memory
#     pressure and improves throughput for long-ish contexts. Required
#     for OLLAMA_KV_CACHE_TYPE to take effect on most builds.
#
#   OLLAMA_KV_CACHE_TYPE=q8_0
#     Compresses the K/V attention cache from F16 to Q8_0, halving its
#     memory footprint with negligible quality loss. On 8 GB Macs this is
#     the difference between a 3 B model fitting comfortably or paging
#     to swap.
#
#   OLLAMA_MAX_LOADED_MODELS=1
#     With 8 GB unified memory, two concurrently-loaded 3 B models will
#     thrash. Force the runtime to evict before loading a new one.
#
#   OLLAMA_NUM_PARALLEL=1
#     One request at a time. Concurrent requests on tight memory tank
#     latency for both. Set higher only if you actually have spare RAM
#     headroom.
#
# Why launchctl, not .zshrc / .env: Ollama.app is launched from the
# launchd user-aqua domain, not your shell. Vars exported in a shell
# rc file never reach it. `launchctl setenv` injects into the launchd
# domain Ollama.app inherits from when the supervisor (re)starts.

set -euo pipefail

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--apply | --persist | --status]
                       [--preload MODEL]... [-h|--help]

  --apply           Set Ollama tuning env via launchctl and restart
                    Ollama.app to pick them up. Default.
  --persist         Also install ~/Library/LaunchAgents/com.os1.ollama-env.plist
                    so the tunings re-apply on every login.
  --preload MODEL   After --apply, request the model with keep_alive=-1
                    so it stays loaded. Pass once per model.
  --status          Print current Ollama serve subprocess env without changes.
  -h, --help        This help.

Examples:
  $(basename "$0") --apply --preload llama3.2:1b --preload llama3.2:3b
  $(basename "$0") --persist
  $(basename "$0") --status
USAGE
}

MODE="apply"
PERSIST=0
PRELOADS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)   MODE="apply"; shift ;;
    --status)  MODE="status"; shift ;;
    --persist) MODE="apply"; PERSIST=1; shift ;;
    --preload) PRELOADS+=("$2"); shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown arg: $1" >&2; usage; exit 2 ;;
  esac
done

# Canonical tunings — keep this dict in sync with the docstring.
# OLLAMA_CONTEXT_LENGTH=65536 satisfies Hermes Agent's hard 64K minimum and
# is large enough for batch jobs that synthesize from web/file context.
# Cost on M1/8 GB with Q8_0 KV: ~1088 MiB for a 16-layer 1B model, ~3.8 GB
# for a 28-layer 3B model — only the 1B comfortably fits at this context.
declare -a TUNINGS=(
  "OLLAMA_KEEP_ALIVE=-1"
  "OLLAMA_FLASH_ATTENTION=1"
  "OLLAMA_KV_CACHE_TYPE=q8_0"
  "OLLAMA_MAX_LOADED_MODELS=1"
  "OLLAMA_NUM_PARALLEL=1"
  "OLLAMA_CONTEXT_LENGTH=65536"
)

OLLAMA_HOST="${OLLAMA_HOST:-http://127.0.0.1:11434}"
LAUNCHD_LABEL="com.ollama.ollama"
PERSIST_PLIST="$HOME/Library/LaunchAgents/com.os1.ollama-env.plist"

current_serve_env() {
  local pid
  pid="$(pgrep -f 'ollama serve' | head -1 || true)"
  if [ -z "$pid" ]; then
    echo "(no ollama serve running)"
    return 1
  fi
  echo "PID=$pid"
  ps -E -p "$pid" 2>/dev/null | tr ' ' '\n' | grep -E '^OLLAMA_' | sort
}

if [ "$MODE" = "status" ]; then
  current_serve_env || true
  exit 0
fi

echo "== applying Ollama tunings via launchctl setenv =="
for kv in "${TUNINGS[@]}"; do
  key="${kv%%=*}"
  val="${kv#*=}"
  launchctl setenv "$key" "$val"
  printf '  %s=%s\n' "$key" "$val"
done

echo "== cycling Ollama.app supervisor so serve subprocess inherits the env =="
launchctl stop "$LAUNCHD_LABEL" 2>/dev/null || true
sleep 2
launchctl start "$LAUNCHD_LABEL" 2>/dev/null || true
sleep 4

NEW_PID="$(pgrep -f 'ollama serve' | head -1 || true)"
if [ -z "$NEW_PID" ]; then
  echo "warn: ollama serve did not respawn after launchctl stop/start; trying open -a Ollama" >&2
  osascript -e 'quit app "Ollama"' 2>/dev/null || true
  sleep 2
  open -a Ollama || true
  sleep 5
  NEW_PID="$(pgrep -f 'ollama serve' | head -1 || true)"
fi

if [ -z "$NEW_PID" ]; then
  echo "FAIL: could not restart Ollama; check Ollama.app installation" >&2
  exit 1
fi

echo "== ollama serve PID=$NEW_PID — verifying env propagation =="
applied="$(ps -E -p "$NEW_PID" 2>/dev/null | tr ' ' '\n' | grep -E '^OLLAMA_(KEEP_ALIVE|FLASH_ATTENTION|KV_CACHE_TYPE|MAX_LOADED_MODELS|NUM_PARALLEL)=' | sort)"
echo "$applied"
missing=0
for kv in "${TUNINGS[@]}"; do
  printf '%s\n' "$applied" | grep -qx "$kv" || { echo "FAIL: $kv not present in serve env" >&2; missing=$((missing+1)); }
done
if [ "$missing" -gt 0 ]; then
  echo "FAIL: $missing tunings did not propagate" >&2
  exit 1
fi

for model in "${PRELOADS[@]:-}"; do
  [ -z "$model" ] && continue
  echo "== preloading $model with keep_alive=-1 =="
  curl -sS --max-time 60 -X POST "$OLLAMA_HOST/api/generate" \
    -H 'content-type: application/json' \
    -d "$(printf '{"model":"%s","prompt":"warm","keep_alive":-1,"stream":false}' "$model")" \
    >/dev/null && echo "  preloaded $model"
done

if [ "$PERSIST" -eq 1 ]; then
  echo "== installing persistent LaunchAgent: $PERSIST_PLIST =="
  cat > "$PERSIST_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>com.os1.ollama-env</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>-c</string>
    <string>launchctl setenv OLLAMA_KEEP_ALIVE -1; launchctl setenv OLLAMA_FLASH_ATTENTION 1; launchctl setenv OLLAMA_KV_CACHE_TYPE q8_0; launchctl setenv OLLAMA_MAX_LOADED_MODELS 1; launchctl setenv OLLAMA_NUM_PARALLEL 1; launchctl setenv OLLAMA_CONTEXT_LENGTH 65536</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><false/>
  <key>StandardOutPath</key><string>$HOME/Library/Logs/OS1/ollama-env.log</string>
  <key>StandardErrorPath</key><string>$HOME/Library/Logs/OS1/ollama-env.err.log</string>
</dict>
</plist>
PLIST
  plutil -lint "$PERSIST_PLIST"
  launchctl bootout "gui/$(id -u)" "$PERSIST_PLIST" 2>/dev/null || true
  launchctl bootstrap "gui/$(id -u)" "$PERSIST_PLIST"
  echo "  installed and loaded"
fi

echo "RESULT: ollama-tuned ($missing missing, $((${#PRELOADS[@]})) preloaded, persist=$PERSIST)"
