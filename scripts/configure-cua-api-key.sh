#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SERVICE="${OS1_CUA_KEYCHAIN_SERVICE:-ai.os1.cua.api-key}"
ACCOUNT="${OS1_CUA_KEYCHAIN_ACCOUNT:-default}"

usage() {
  cat <<'USAGE'
usage: scripts/configure-cua-api-key.sh [--status|--prompt|--delete]

Stores or checks the OS1 CUA API key in the macOS Keychain. The key is never
printed. Default mode is --status.

Options:
  --status   Print set/missing/unreadable status only. Default.
  --prompt   Read the key from a hidden terminal prompt and save it.
  --delete   Remove the saved key.
  -h, --help Show this help.
USAGE
}

die() {
  printf 'configure-cua-api-key: %s\n' "$*" >&2
  exit 1
}

require_macos_keychain() {
  [ "$(uname -s 2>/dev/null || printf unknown)" = "Darwin" ] || die "macOS Keychain is required"
  command -v security >/dev/null 2>&1 || die "security CLI not found"
}

status() {
  require_macos_keychain
  set +e
  security find-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1
  rc="$?"
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'cua_api_key=set\n'
    return 0
  fi

  case "$rc" in
    44)
      printf 'cua_api_key=missing\n'
      ;;
    *)
      printf 'cua_api_key=unreadable\n'
      return 1
      ;;
  esac
}

save_from_prompt() {
  require_macos_keychain
  if [ ! -t 0 ]; then
    die "--prompt requires an interactive terminal"
  fi

  printf 'CUA API key: ' >&2
  stty_state="$(stty -g)"
  trap 'stty "$stty_state" 2>/dev/null || true' EXIT HUP INT TERM
  stty -echo
  IFS= read -r api_key
  stty "$stty_state"
  trap - EXIT HUP INT TERM
  printf '\n' >&2

  [ -n "$api_key" ] || die "empty key was not saved"

  security add-generic-password -U -s "$SERVICE" -a "$ACCOUNT" -w "$api_key" >/dev/null
  printf 'cua_api_key=set\n'
}

delete_key() {
  require_macos_keychain
  set +e
  security delete-generic-password -s "$SERVICE" -a "$ACCOUNT" >/dev/null 2>&1
  rc="$?"
  set -e
  if [ "$rc" -eq 0 ]; then
    printf 'cua_api_key=missing\n'
    return 0
  fi

  case "$rc" in
    44)
      printf 'cua_api_key=missing\n'
      ;;
    *)
      printf 'cua_api_key=unreadable\n'
      return 1
      ;;
  esac
}

mode="status"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --status)
      mode="status"
      ;;
    --prompt)
      mode="prompt"
      ;;
    --delete)
      mode="delete"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown argument: $1"
      ;;
  esac
  shift
done

case "$mode" in
  status) status ;;
  prompt) save_from_prompt ;;
  delete) delete_key ;;
esac
