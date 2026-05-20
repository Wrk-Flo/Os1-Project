#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

LOG_DIR="${OS1_LOCAL_OPS_LOG_DIR:-$HOME/Library/Logs/OS1}"
LOG_PATH="${OS1_CUA_DRIVER_LOG:-$LOG_DIR/cua-driver.log}"
CUA_DRIVER_CLI="${CUA_DRIVER_CLI:-cua-driver}"

usage() {
  cat <<'USAGE'
usage: scripts/manage-cua-driver.sh [status|start|stop|doctor]

Manages the optional local CUA driver daemon for guarded computer-use sessions.
This does not run a computer-use task; it only starts or stops the local driver.

Commands:
  status   Report whether the daemon is running. Default.
  start    Start cua-driver serve in the background.
  stop     Stop the running daemon.
  doctor   Run cua-driver doctor.
USAGE
}

die() {
  printf 'manage-cua-driver: %s\n' "$*" >&2
  exit 1
}

require_driver() {
  command -v "$CUA_DRIVER_CLI" >/dev/null 2>&1 || die "$CUA_DRIVER_CLI not found; run hermes computer-use install"
}

ensure_log_dir() {
  mkdir -p "$(dirname "$LOG_PATH")"
}

status() {
  require_driver
  if "$CUA_DRIVER_CLI" status >/dev/null 2>&1; then
    printf 'cua_driver=running\n'
  else
    printf 'cua_driver=stopped\n'
  fi
}

start() {
  require_driver
  if "$CUA_DRIVER_CLI" status >/dev/null 2>&1; then
    printf 'cua_driver=running\n'
    printf 'log=%s\n' "$LOG_PATH"
    return 0
  fi

  ensure_log_dir
  nohup "$CUA_DRIVER_CLI" serve --no-relaunch > "$LOG_PATH" 2>&1 &
  driver_pid="$!"
  attempt=0
  while [ "$attempt" -lt "${OS1_CUA_DRIVER_START_ATTEMPTS:-10}" ]; do
    sleep 1
    if "$CUA_DRIVER_CLI" status >/dev/null 2>&1; then
      printf 'cua_driver=running\n'
      printf 'pid=%s\n' "$driver_pid"
      printf 'log=%s\n' "$LOG_PATH"
      return 0
    fi
    if ! kill -0 "$driver_pid" 2>/dev/null; then
      break
    fi
    attempt=$((attempt + 1))
  done

  printf 'cua_driver=stopped\n'
  printf 'pid=%s\n' "$driver_pid"
  printf 'log=%s\n' "$LOG_PATH"
  return 1
}

stop() {
  require_driver
  "$CUA_DRIVER_CLI" stop >/dev/null 2>&1 || true
  sleep 1
  if "$CUA_DRIVER_CLI" status >/dev/null 2>&1; then
    printf 'cua_driver=running\n'
    return 1
  else
    printf 'cua_driver=stopped\n'
  fi
}

doctor() {
  require_driver
  "$CUA_DRIVER_CLI" doctor
}

command_name="${1:-status}"
case "$command_name" in
  status)
    status
    ;;
  start)
    start
    ;;
  stop)
    stop
    ;;
  doctor)
    doctor
    ;;
  -h|--help)
    usage
    ;;
  *)
    usage >&2
    die "unknown command: $command_name"
    ;;
esac
