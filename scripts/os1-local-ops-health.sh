#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

failures=0
warnings=0

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HOME_DIR="${HOME:-}"
DEFAULT_PATH="$HOME_DIR/.local/bin:$HOME_DIR/.hermes/hermes-agent/venv/bin:$HOME_DIR/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SEARCH_PATH="${PATH:-}:$DEFAULT_PATH"
export PATH="$SEARCH_PATH"

timestamp() {
  date -u '+%Y-%m-%dT%H:%M:%SZ'
}

log_line() {
  level="$1"
  shift
  printf '%s %s: %s\n' "$(timestamp)" "$level" "$*"
}

info() {
  log_line "INFO" "$*"
}

pass() {
  log_line "OK" "$*"
}

warn() {
  warnings=$((warnings + 1))
  log_line "WARN" "$*"
}

fail() {
  failures=$((failures + 1))
  log_line "FAIL" "$*"
}

short_text() {
  awk '{ gsub(/[[:space:]]+/, " "); if (length($0) > 240) print substr($0, 1, 240) "..."; else print $0 }'
}

expand_home_path() {
  value="$1"
  case "$value" in
    "~")
      printf '%s\n' "$HOME_DIR"
      ;;
    "~/"*)
      printf '%s/%s\n' "$HOME_DIR" "${value#~/}"
      ;;
    "\$HOME/"*)
      printf '%s/%s\n' "$HOME_DIR" "${value#\$HOME/}"
      ;;
    "\${HOME}/"*)
      printf '%s/%s\n' "$HOME_DIR" "${value#\${HOME}/}"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

resolve_executable() {
  command_name="$1"
  [ -n "$command_name" ] || return 1

  case "$command_name" in
    */*)
      candidate="$(expand_home_path "$command_name")"
      if [ -f "$candidate" ] && [ -x "$candidate" ]; then
        cd "$(dirname "$candidate")" >/dev/null 2>&1 && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")"
        return 0
      fi
      return 1
      ;;
  esac

  old_ifs="$IFS"
  IFS=:
  for directory in $SEARCH_PATH; do
    [ -n "$directory" ] || continue
    candidate="$directory/$command_name"
    if [ -f "$candidate" ] && [ -x "$candidate" ]; then
      IFS="$old_ifs"
      cd "$(dirname "$candidate")" >/dev/null 2>&1 && printf '%s/%s\n' "$(pwd -P)" "$(basename "$candidate")"
      return 0
    fi
  done
  IFS="$old_ifs"
  return 1
}

first_non_empty_line() {
  awk 'NF { print; exit }'
}

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

utc_epoch_from_run_id() {
  run_id="$1"
  if date -u -j -f "%Y%m%dT%H%M%SZ" "$run_id" "+%s" >/dev/null 2>&1; then
    date -u -j -f "%Y%m%dT%H%M%SZ" "$run_id" "+%s"
  elif date -u -d "$run_id" "+%s" >/dev/null 2>&1; then
    date -u -d "$run_id" "+%s"
  else
    return 1
  fi
}

status_of_env_flag() {
  name="$1"
  eval "value=\${$name-}"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    1|true|yes|on)
      fail "Azure mutation opt-in is enabled in this environment: $name"
      ;;
    "")
      pass "$name is unset"
      ;;
    *)
      warn "$name is set but not an enable value"
      ;;
  esac
}

check_repo() {
  info "repo root: $REPO_ROOT"
  if [ -f "$REPO_ROOT/Package.swift" ] && [ -d "$REPO_ROOT/Sources/OS1" ]; then
    pass "OS1 SwiftPM project files found"
  else
    fail "OS1 repo check failed; expected Package.swift and Sources/OS1 under $REPO_ROOT"
  fi

  if command -v git >/dev/null 2>&1; then
    if git_root="$(git -C "$REPO_ROOT" rev-parse --show-toplevel 2>/dev/null)"; then
      git_root="$(cd "$git_root" && pwd -P)"
      if [ "$git_root" = "$REPO_ROOT" ]; then
        revision="$(git -C "$REPO_ROOT" rev-parse --short HEAD 2>/dev/null || true)"
        branch="$(git -C "$REPO_ROOT" branch --show-current 2>/dev/null || true)"
        pass "git worktree detected${branch:+ on $branch}${revision:+ at $revision}"
      else
        fail "git worktree root mismatch: expected $REPO_ROOT, got $git_root"
      fi
    else
      fail "OS1 repo is not a readable git worktree"
    fi
  else
    warn "git not found; repository metadata was not checked"
  fi
}

check_azure_disabled() {
  status_of_env_flag "OS1_AZURE_ALLOW_MUTATIONS"
  status_of_env_flag "OS1_AZURE_ALLOW_SECRET_SYNC"
}

hermes_home_path() {
  if [ -n "${HERMES_HOME:-}" ]; then
    expand_home_path "$HERMES_HOME"
  else
    printf '%s/.hermes\n' "$HOME_DIR"
  fi
}

infer_ollama_model_from_hermes() {
  config_path="$(hermes_home_path)/config.yaml"
  [ -r "$config_path" ] || return 1

  awk '
    BEGIN { in_model = 0 }
    /^[[:space:]]*#/ { next }
    /^[^[:space:]].*:/ {
      in_model = ($0 ~ /^model:[[:space:]]*$/)
      next
    }
    in_model && /^[[:space:]]+default:[[:space:]]*/ {
      line = $0
      sub(/^[[:space:]]+default:[[:space:]]*/, "", line)
      gsub(/^[\"\047]|[\"\047]$/, "", line)
      if (line != "") {
        print line
        exit
      }
    }
  ' "$config_path"
}

check_hermes() {
  hermes_command="${HERMES_CLI:-hermes}"
  if hermes_path="$(resolve_executable "$hermes_command")"; then
    pass "Hermes CLI found: $hermes_path"
    hermes_output="$("$hermes_path" version 2>&1)"
    hermes_status=$?
    hermes_label="$(printf '%s\n' "$hermes_output" | first_non_empty_line)"
    if [ "$hermes_status" -eq 0 ]; then
      pass "Hermes CLI version check passed${hermes_label:+: $hermes_label}"
    else
      detail="$(printf '%s\n' "$hermes_output" | short_text)"
      fail "Hermes CLI version check failed with exit $hermes_status${detail:+: $detail}"
    fi
  else
    fail "Hermes CLI not found; install Hermes Agent or set HERMES_CLI"
  fi

  hermes_home="$(hermes_home_path)"
  if [ -d "$hermes_home" ]; then
    pass "Hermes home exists: $hermes_home"
    if [ -r "$hermes_home/config.yaml" ]; then
      pass "Hermes config is readable"
    else
      warn "Hermes config is missing or unreadable at $hermes_home/config.yaml"
    fi
  else
    warn "Hermes home does not exist yet: $hermes_home"
  fi
}

check_ollama_fallback() {
  host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
  tags_url="${host%/}/api/tags"
  body_file="$(mktemp)"
  err_file="$(mktemp)"
  trap 'rm -f "$body_file" "$err_file"' RETURN

  if ! command -v curl >/dev/null 2>&1; then
    fail "curl not found; Ollama endpoint cannot be checked"
    return 0
  fi

  if http_status="$(curl -sS --connect-timeout 3 --max-time 10 -o "$body_file" -w '%{http_code}' "$tags_url" 2>"$err_file")"; then
    case "$http_status" in
      2*)
        pass "Ollama native endpoint reachable: $tags_url"
        ;;
      *)
        detail="$(short_text < "$body_file")"
        fail "Ollama native endpoint returned HTTP $http_status${detail:+: $detail}"
        return 0
        ;;
    esac
  else
    detail="$(short_text < "$err_file")"
    fail "Ollama native endpoint unavailable at $tags_url${detail:+: $detail}"
    return 0
  fi

  if ! command -v python3 >/dev/null 2>&1; then
    warn "python3 not found; local model list could not be parsed"
    return 0
  fi

  model_names="$(python3 - "$body_file" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as handle:
    payload = json.load(handle)

models = payload.get("models", []) if isinstance(payload, dict) else []
for item in models:
    if isinstance(item, dict):
        name = item.get("name") or item.get("model")
        if name:
            print(name)
PY
  )"
  if [ -z "$model_names" ]; then
    fail "Ollama returned no local models"
    return 0
  fi

  model="${OLLAMA_MODEL:-}"
  if [ -z "$model" ]; then
    warn "OLLAMA_MODEL is unset; local models are installed but no specific model was asserted"
    printf '%s\n' "$model_names" | awk '{ print "INFO: Ollama model: " $0 }'
    return 0
  fi

  if printf '%s\n' "$model_names" | grep -Fx -- "$model" >/dev/null 2>&1; then
    pass "selected Ollama model is installed: $model"
  else
    fail "selected Ollama model is not installed: $model"
  fi
}

check_ollama() {
  if [ -x "$REPO_ROOT/scripts/ollama-health.sh" ]; then
    if [ -z "${OLLAMA_MODEL:-}" ]; then
      info "OLLAMA_MODEL is unset; delegated Ollama health check will use its local default"
    fi
    info "running delegated Ollama health check"
    ollama_output="$("$REPO_ROOT/scripts/ollama-health.sh" 2>&1)"
    ollama_status=$?
    printf '%s\n' "$ollama_output" | awk '{ print "OLLAMA: " $0 }'
    if [ "$ollama_status" -eq 0 ]; then
      pass "delegated Ollama health check passed"
    else
      fail "delegated Ollama health check failed with exit $ollama_status"
    fi
  elif [ -f "$REPO_ROOT/scripts/ollama-health.sh" ]; then
    warn "scripts/ollama-health.sh exists but is not executable; using built-in Ollama check"
    check_ollama_fallback
  else
    warn "scripts/ollama-health.sh not found; using built-in Ollama check"
    check_ollama_fallback
  fi
}

check_cua() {
  if [ "$(uname -s 2>/dev/null || printf unknown)" != "Darwin" ]; then
    warn "CUA driver check skipped; this host is not macOS"
    return 0
  fi

  if [ -x "$REPO_ROOT/scripts/configure-cua-api-key.sh" ]; then
    cua_key_status="$("$REPO_ROOT/scripts/configure-cua-api-key.sh" --status 2>/dev/null || true)"
    case "$cua_key_status" in
      "cua_api_key=set")
        pass "CUA API key: set"
        ;;
      "cua_api_key=missing")
        warn "CUA API key: missing"
        ;;
      "cua_api_key=unreadable")
        warn "CUA API key: unreadable"
        ;;
      *)
        warn "CUA API key status could not be checked"
        ;;
    esac
  else
    warn "CUA API key helper is missing; status was not checked"
  fi

  cua_command="${CUA_DRIVER_CLI:-cua-driver}"
  if cua_path="$(resolve_executable "$cua_command")"; then
    pass "cua-driver found: $cua_path"
    set +e
    cua_output="$("$cua_path" --version 2>&1)"
    cua_status=$?
    set -e
    cua_label="$(printf '%s\n' "$cua_output" | first_non_empty_line)"
    if [ "$cua_status" -eq 0 ]; then
      pass "cua-driver version check passed${cua_label:+: $cua_label}"
    else
      warn "cua-driver is installed but --version exited $cua_status"
    fi

    if "$cua_path" status >/dev/null 2>&1; then
      pass "CUA driver daemon is running"
    elif command -v pgrep >/dev/null 2>&1; then
      if pgrep -x "cua-driver" >/dev/null 2>&1 || pgrep -x "CuaDriver" >/dev/null 2>&1; then
        warn "CUA driver process exists, but daemon status did not confirm running"
      else
        warn "cua-driver is installed but no running CUA driver daemon was detected"
      fi
    else
      warn "pgrep not found; CUA process status was not checked"
    fi
  elif [ -d "/Applications/CuaDriver.app" ] || [ -d "$HOME_DIR/Applications/CuaDriver.app" ]; then
    warn "CuaDriver app is installed, but cua-driver CLI was not found on PATH"
  else
    warn "cua-driver not found; local computer-use remains unavailable until installed"
  fi
}

normalize_threshold_gib() {
  value="$1"
  fallback="$2"
  case "$value" in
    ""|*[!0-9]*)
      printf '%s\n' "$fallback"
      ;;
    *)
      printf '%s\n' "$value"
      ;;
  esac
}

nearest_existing_path() {
  candidate="$(expand_home_path "$1")"
  while [ ! -e "$candidate" ] && [ "$candidate" != "/" ]; do
    candidate="$(dirname "$candidate")"
  done
  printf '%s\n' "$candidate"
}

check_disk_path() {
  label="$1"
  requested_path="$2"
  warn_gib="$(normalize_threshold_gib "${OS1_LOCAL_OPS_DISK_WARN_GIB:-25}" 25)"
  fail_gib="$(normalize_threshold_gib "${OS1_LOCAL_OPS_DISK_FAIL_GIB:-10}" 10)"
  warn_kib=$((warn_gib * 1024 * 1024))
  fail_kib=$((fail_gib * 1024 * 1024))
  check_path="$(nearest_existing_path "$requested_path")"

  if [ -z "$check_path" ] || [ ! -e "$check_path" ]; then
    warn "disk check skipped for $label; no existing parent found for $requested_path"
    return 0
  fi

  if ! df_line="$(df -Pk "$check_path" 2>/dev/null | awk 'NR == 2 { print $4 " " $6 }')"; then
    warn "disk check failed for $label at $check_path"
    return 0
  fi

  available_kib="$(printf '%s\n' "$df_line" | awk '{ print $1 }')"
  mount_point="$(printf '%s\n' "$df_line" | awk '{ print $2 }')"
  available_gib="$(awk -v kib="$available_kib" 'BEGIN { printf "%.1f", kib / 1048576 }')"

  if [ "$available_kib" -lt "$fail_kib" ]; then
    fail "disk critically low for $label: ${available_gib} GiB free on $mount_point; fail threshold is ${fail_gib} GiB"
  elif [ "$available_kib" -lt "$warn_kib" ]; then
    warn "disk low for $label: ${available_gib} GiB free on $mount_point; warn threshold is ${warn_gib} GiB"
  else
    pass "disk free for $label: ${available_gib} GiB on $mount_point"
  fi
}

check_disk() {
  check_disk_path "OS1 repo" "$REPO_ROOT"
  check_disk_path "Hermes home" "$(hermes_home_path)"

  if [ -n "${OS1_LOCAL_OPS_LOG_DIR:-}" ]; then
    check_disk_path "OS1 logs" "$OS1_LOCAL_OPS_LOG_DIR"
  fi

  if [ -n "${OS1_LOCAL_OPS_EXTRA_DISK_PATHS:-}" ]; then
    old_ifs="$IFS"
    IFS=:
    for extra_path in $OS1_LOCAL_OPS_EXTRA_DISK_PATHS; do
      [ -n "$extra_path" ] || continue
      check_disk_path "extra path $extra_path" "$extra_path"
    done
    IFS="$old_ifs"
  fi
}

check_business_ops_catchup() {
  if [ "$(uname -s 2>/dev/null || printf unknown)" != "Darwin" ]; then
    return 0
  fi
  if [ "${OS1_LOCAL_OPS_KICK_BUSINESS_OPS:-1}" = "0" ]; then
    return 0
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    return 0
  fi

  label="com.os1.local.business-ops"
  domain="gui/$(id -u)"
  if ! state="$(launchctl print "$domain/$label" 2>/dev/null)"; then
    return 0
  fi

  output_root="${OS1_BUSINESS_OPS_OUTPUT_ROOT:-$HOME_DIR/Library/Application Support/OS1/business-ops}"
  latest_summary="$output_root/latest/summary.md"
  [ -f "$latest_summary" ] || return 0

  run_dir="$(summary_value "Run directory" "$latest_summary")"
  run_id="$(basename "$run_dir" 2>/dev/null || true)"
  if ! latest_epoch="$(utc_epoch_from_run_id "$run_id" 2>/dev/null)"; then
    warn "business operations catch-up skipped; latest run id could not be parsed: ${run_id:-missing}"
    return 0
  fi

  interval="$(printf '%s\n' "$state" | awk -F'= ' '/run interval =/ { print $2; exit }')"
  case "$interval" in
    ""|*[!0-9]*)
      interval=3600
      ;;
  esac
  catchup_seconds="${OS1_BUSINESS_OPS_CATCHUP_SECONDS:-$((interval * 2))}"
  case "$catchup_seconds" in
    ""|*[!0-9]*)
      warn "business operations catch-up skipped; OS1_BUSINESS_OPS_CATCHUP_SECONDS is invalid"
      return 0
      ;;
  esac

  now_epoch="$(date -u "+%s")"
  age_seconds="$((now_epoch - latest_epoch))"
  if [ "$age_seconds" -lt 0 ] || [ "$age_seconds" -le "$catchup_seconds" ]; then
    return 0
  fi

  if launchctl kickstart -k "$domain/$label" >/dev/null 2>&1; then
    pass "business operations catch-up kicked $label after ${age_seconds}s without a fresh run"
  else
    warn "business operations catch-up failed to kick $label after ${age_seconds}s without a fresh run"
  fi
}

info "OS1 local operations health check started"
check_repo
check_azure_disabled
check_hermes
check_ollama
check_cua
check_disk
check_business_ops_catchup

if [ "$failures" -eq 0 ]; then
  pass "health check completed with $warnings warning(s)"
  exit 0
fi

log_line "SUMMARY" "$failures hard failure(s), $warnings warning(s)"
exit 1
