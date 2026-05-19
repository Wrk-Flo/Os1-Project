#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd -P)"
HOME_DIR="${HOME:-}"
DEFAULT_PATH="$HOME_DIR/.local/bin:$HOME_DIR/.hermes/hermes-agent/venv/bin:$HOME_DIR/.cargo/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
SEARCH_PATH="${PATH:-}:$DEFAULT_PATH"

apply=0
load_services=1
manage_ollama=1
health_interval="${OS1_LOCAL_HEALTH_INTERVAL_SECONDS:-300}"
ollama_bind="${OS1_OLLAMA_BIND:-127.0.0.1:11434}"
ollama_http_host="${OLLAMA_HOST:-http://127.0.0.1:11434}"
log_dir="${OS1_LOCAL_OPS_LOG_DIR:-$HOME_DIR/Library/Logs/OS1}"
launch_agents_dir="${OS1_LAUNCH_AGENTS_DIR:-$HOME_DIR/Library/LaunchAgents}"
ollama_path="${OS1_OLLAMA_PATH:-}"

usage() {
  cat <<'EOF'
usage: scripts/install-local-ops-launchd.sh [--apply] [options]

Installs per-user LaunchAgents for local OS1 operations. Dry-run is the default.

Options:
  --apply                         Write plists and load them with launchctl.
  --no-load                       With --apply, write plists but do not bootstrap.
  --health-only, --skip-ollama    Install only the periodic OS1 health check.
  --health-interval SECONDS       Health check interval. Default: 300.
  --ollama-path PATH              Path to the ollama executable.
  --ollama-bind HOST:PORT         OLLAMA_HOST value for ollama serve. Default: 127.0.0.1:11434.
  --ollama-http-host URL          HTTP URL used by health checks. Default: http://127.0.0.1:11434.
  --log-dir PATH                  Log directory. Default: ~/Library/Logs/OS1.
  --launch-agents-dir PATH        LaunchAgents directory. Default: ~/Library/LaunchAgents.
  -h, --help                      Show this help.
EOF
}

die() {
  printf 'install-local-ops-launchd: %s\n' "$*" >&2
  exit 1
}

warn() {
  printf 'WARN: %s\n' "$*" >&2
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

xml_escape() {
  sed \
    -e 's/&/\&amp;/g' \
    -e 's/</\&lt;/g' \
    -e 's/>/\&gt;/g' \
    -e 's/"/\&quot;/g' \
    -e "s/'/\&apos;/g"
}

validate_positive_integer() {
  name="$1"
  value="$2"
  case "$value" in
    ""|*[!0-9]*)
      die "$name must be a positive integer"
      ;;
    *)
      if [ "$value" -le 0 ]; then
        die "$name must be greater than zero"
      fi
      ;;
  esac
}

render_ollama_plist() {
  target="$1"
  ollama_path_xml="$(printf '%s' "$ollama_path" | xml_escape)"
  ollama_bind_xml="$(printf '%s' "$ollama_bind" | xml_escape)"
  log_dir_xml="$(printf '%s' "$log_dir" | xml_escape)"

  cat > "$target" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.os1.local.ollama</string>
  <key>ProgramArguments</key>
  <array>
    <string>$ollama_path_xml</string>
    <string>serve</string>
  </array>
  <key>EnvironmentVariables</key>
  <dict>
    <key>OLLAMA_HOST</key>
    <string>$ollama_bind_xml</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <true/>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$log_dir_xml/ollama.out.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir_xml/ollama.err.log</string>
</dict>
</plist>
EOF
}

render_health_plist() {
  target="$1"
  repo_root_xml="$(printf '%s' "$REPO_ROOT" | xml_escape)"
  path_xml="$(printf '%s' "$DEFAULT_PATH" | xml_escape)"
  ollama_http_host_xml="$(printf '%s' "$ollama_http_host" | xml_escape)"
  log_dir_xml="$(printf '%s' "$log_dir" | xml_escape)"

  cat > "$target" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.os1.local.health</string>
  <key>ProgramArguments</key>
  <array>
    <string>/bin/bash</string>
    <string>$repo_root_xml/scripts/os1-local-ops-health.sh</string>
  </array>
  <key>WorkingDirectory</key>
  <string>$repo_root_xml</string>
  <key>EnvironmentVariables</key>
  <dict>
    <key>PATH</key>
    <string>$path_xml</string>
    <key>OLLAMA_HOST</key>
    <string>$ollama_http_host_xml</string>
    <key>OS1_LOCAL_OPS_LOG_DIR</key>
    <string>$log_dir_xml</string>
  </dict>
  <key>RunAtLoad</key>
  <true/>
  <key>StartInterval</key>
  <integer>$health_interval</integer>
  <key>ProcessType</key>
  <string>Background</string>
  <key>StandardOutPath</key>
  <string>$log_dir_xml/local-health.log</string>
  <key>StandardErrorPath</key>
  <string>$log_dir_xml/local-health.err.log</string>
</dict>
</plist>
EOF
}

validate_plist() {
  path="$1"
  if command -v plutil >/dev/null 2>&1; then
    plutil -lint "$path" >/dev/null
  fi
}

install_plist() {
  source_path="$1"
  target_path="$2"
  install -m 644 "$source_path" "$target_path"
  printf 'installed %s\n' "$target_path"
}

load_plist() {
  label="$1"
  target_path="$2"
  domain="gui/$(id -u)"

  launchctl bootout "$domain" "$target_path" >/dev/null 2>&1 || true
  launchctl bootstrap "$domain" "$target_path"
  launchctl enable "$domain/$label" >/dev/null 2>&1 || true
  launchctl kickstart -k "$domain/$label" >/dev/null 2>&1 || true
  printf 'loaded %s/%s\n' "$domain" "$label"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      apply=1
      shift
      ;;
    --no-load)
      load_services=0
      shift
      ;;
    --health-only|--skip-ollama)
      manage_ollama=0
      shift
      ;;
    --health-interval)
      [ "$#" -ge 2 ] || die "--health-interval requires a value"
      health_interval="$2"
      shift 2
      ;;
    --ollama-path)
      [ "$#" -ge 2 ] || die "--ollama-path requires a value"
      ollama_path="$2"
      shift 2
      ;;
    --ollama-bind)
      [ "$#" -ge 2 ] || die "--ollama-bind requires a value"
      ollama_bind="$2"
      shift 2
      ;;
    --ollama-http-host)
      [ "$#" -ge 2 ] || die "--ollama-http-host requires a value"
      ollama_http_host="$2"
      shift 2
      ;;
    --log-dir)
      [ "$#" -ge 2 ] || die "--log-dir requires a value"
      log_dir="$2"
      shift 2
      ;;
    --launch-agents-dir)
      [ "$#" -ge 2 ] || die "--launch-agents-dir requires a value"
      launch_agents_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

if [ "$(id -u)" -eq 0 ]; then
  die "do not run with sudo; this installs per-user LaunchAgents"
fi

validate_positive_integer "--health-interval" "$health_interval"

log_dir="$(expand_home_path "$log_dir")"
launch_agents_dir="$(expand_home_path "$launch_agents_dir")"

if [ "$manage_ollama" -eq 1 ]; then
  if [ -z "$ollama_path" ]; then
    if resolved="$(resolve_executable "ollama")"; then
      ollama_path="$resolved"
    elif [ "$apply" -eq 1 ]; then
      die "ollama executable not found; install Ollama, pass --ollama-path, or use --health-only"
    else
      ollama_path="/usr/local/bin/ollama"
      warn "ollama executable not found; dry-run will show $ollama_path as the expected path"
    fi
  else
    ollama_path="$(expand_home_path "$ollama_path")"
  fi
fi

if [ ! -f "$REPO_ROOT/scripts/os1-local-ops-health.sh" ]; then
  die "missing health script at $REPO_ROOT/scripts/os1-local-ops-health.sh"
fi

tmp_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

ollama_plist_tmp="$tmp_dir/com.os1.local.ollama.plist"
health_plist_tmp="$tmp_dir/com.os1.local.health.plist"
if [ "$manage_ollama" -eq 1 ]; then
  render_ollama_plist "$ollama_plist_tmp"
  validate_plist "$ollama_plist_tmp"
fi
render_health_plist "$health_plist_tmp"
validate_plist "$health_plist_tmp"

ollama_target="$launch_agents_dir/com.os1.local.ollama.plist"
health_target="$launch_agents_dir/com.os1.local.health.plist"

if [ "$apply" -ne 1 ]; then
  printf 'DRY RUN: no files were written and launchd was not changed.\n\n'
  printf 'Would install:\n'
  if [ "$manage_ollama" -eq 1 ]; then
    printf '  %s\n' "$ollama_target"
  fi
  printf '  %s\n\n' "$health_target"

  printf 'Would create log directory:\n'
  printf '  %s\n\n' "$log_dir"

  printf 'Would load:\n'
  if [ "$manage_ollama" -eq 1 ]; then
    printf '  gui/%s/com.os1.local.ollama\n' "$(id -u)"
  fi
  printf '  gui/%s/com.os1.local.health\n\n' "$(id -u)"

  printf 'Write plists without loading launchd:\n'
  printf '  scripts/install-local-ops-launchd.sh --apply --no-load\n'
  exit 0
fi

mkdir -p "$launch_agents_dir" "$log_dir"
if [ "$manage_ollama" -eq 1 ]; then
  install_plist "$ollama_plist_tmp" "$ollama_target"
fi
install_plist "$health_plist_tmp" "$health_target"

if [ "$load_services" -eq 1 ]; then
  if [ "$manage_ollama" -eq 1 ]; then
    load_plist "com.os1.local.ollama" "$ollama_target"
  fi
  load_plist "com.os1.local.health" "$health_target"
else
  printf 'plists written; skipped launchctl bootstrap because --no-load was provided\n'
fi
