#!/usr/bin/env bash
set -u
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
PROFILE="local"
FAILURES=0
WARNINGS=0

usage() {
  cat <<'USAGE'
Usage: scripts/os1-production-readiness.sh [--local|--public]

Profiles:
  --local    Check local 24/7 business-operations readiness. Default.
  --public   Check public distribution readiness; Developer ID signing and
             notarization blockers become hard failures.

The script is read-only. It does not print secrets or mutate Azure.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --local)
      PROFILE="local"
      ;;
    --public)
      PROFILE="public"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf 'os1-production-readiness: unknown argument: %s\n' "$1" >&2
      exit 64
      ;;
  esac
  shift
done

section() {
  printf '\n== %s ==\n' "$*"
}

pass() {
  printf 'OK: %s\n' "$*"
}

warn() {
  WARNINGS=$((WARNINGS + 1))
  printf 'WARN: %s\n' "$*"
}

fail() {
  FAILURES=$((FAILURES + 1))
  printf 'FAIL: %s\n' "$*"
}

require_for_public() {
  if [ "$PROFILE" = "public" ]; then
    fail "$*"
  else
    warn "$*"
  fi
}

is_enabled_value() {
  value="$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')"
  case "$value" in
    1|true|yes|on)
      return 0
      ;;
  esac
  return 1
}

env_status() {
  name="$1"
  eval "value=\${$name-}"
  if [ -n "$value" ]; then
    printf 'set'
  else
    printf 'missing'
  fi
}

check_git() {
  section "Git"

  if ! command -v git >/dev/null 2>&1; then
    fail "git is required for readiness checks"
    return
  fi

  if ! git_root="$(git -C "$ROOT_DIR" rev-parse --show-toplevel 2>/dev/null)"; then
    fail "not a readable git worktree: $ROOT_DIR"
    return
  fi
  git_root="$(CDPATH= cd "$git_root" && pwd -P)"
  if [ "$git_root" != "$ROOT_DIR" ]; then
    fail "git root mismatch: expected $ROOT_DIR, got $git_root"
    return
  fi

  head="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || true)"
  branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
  pass "worktree detected${branch:+ on $branch}${head:+ at $head}"

  if [ -n "$(git -C "$ROOT_DIR" status --porcelain)" ]; then
    if [ "$PROFILE" = "public" ]; then
      fail "working tree has uncommitted changes"
    else
      warn "working tree has uncommitted changes"
    fi
  else
    pass "working tree is clean"
  fi

  upstream="$(git -C "$ROOT_DIR" rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  if [ -n "$upstream" ]; then
    local_rev="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
    remote_rev="$(git -C "$ROOT_DIR" rev-parse "$upstream" 2>/dev/null || true)"
    if [ -n "$local_rev" ] && [ "$local_rev" = "$remote_rev" ]; then
      pass "HEAD matches upstream: $upstream"
    else
      warn "HEAD does not match upstream: $upstream"
    fi
  else
    warn "no upstream branch configured"
  fi
}

check_azure_flags() {
  section "Azure Disabled"

  for name in OS1_AZURE_ALLOW_MUTATIONS OS1_AZURE_ALLOW_SECRET_SYNC; do
    eval "value=\${$name-}"
    if is_enabled_value "$value"; then
      fail "$name is enabled; local-first readiness requires Azure mutations disabled"
    elif [ -n "$value" ]; then
      warn "$name is set but not an enable value"
    else
      pass "$name is unset"
    fi
  done
}

run_local_ops_health() {
  section "Local Runtime"

  if [ ! -x "$ROOT_DIR/scripts/os1-local-ops-health.sh" ]; then
    fail "missing executable scripts/os1-local-ops-health.sh"
    return
  fi

  if "$ROOT_DIR/scripts/os1-local-ops-health.sh"; then
    pass "local operations health passed"
  else
    fail "local operations health failed"
  fi
}

check_storage_report() {
  section "Storage"

  if [ ! -x "$ROOT_DIR/scripts/os1-storage-report.sh" ]; then
    fail "missing executable scripts/os1-storage-report.sh"
    return
  fi

  if "$ROOT_DIR/scripts/os1-storage-report.sh"; then
    pass "storage report completed"
  else
    fail "storage report failed"
  fi
}

check_launchagent() {
  section "LaunchAgent"

  if [ "$(uname -s 2>/dev/null || printf unknown)" != "Darwin" ]; then
    warn "launchd check skipped; not running on macOS"
    return
  fi
  if ! command -v launchctl >/dev/null 2>&1; then
    warn "launchctl not found"
    return
  fi

  label="com.os1.local.health"
  if ! state="$(launchctl print "gui/$(id -u)/$label" 2>/dev/null)"; then
    fail "$label is not loaded"
    return
  fi

  path="$(printf '%s\n' "$state" | awk -F'= ' '/path =/ { print $2; exit }')"
  runs="$(printf '%s\n' "$state" | awk -F'= ' '/runs =/ { print $2; exit }')"
  last_exit="$(printf '%s\n' "$state" | awk -F'= ' '/last exit code =/ { print $2; exit }')"
  interval="$(printf '%s\n' "$state" | awk -F'= ' '/run interval =/ { print $2; exit }')"
  expected_plist="$HOME/Library/LaunchAgents/$label.plist"
  expected_log_dir="$HOME/Library/Logs/OS1"

  pass "$label is loaded${path:+ at $path}"
  [ -n "$runs" ] && pass "$label runs count: $runs"
  [ -n "$interval" ] && pass "$label interval: $interval"
  if [ -n "$path" ] && [ "$path" != "$expected_plist" ]; then
    warn "$label is loaded from an unexpected path: $path"
  fi

  plist_path="${path:-$expected_plist}"
  if [ -f "$plist_path" ]; then
    if command -v plutil >/dev/null 2>&1 && plutil -lint "$plist_path" >/dev/null 2>&1; then
      pass "$label plist is valid"
    else
      fail "$label plist is not valid"
    fi

    if command -v /usr/libexec/PlistBuddy >/dev/null 2>&1; then
      program0="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$plist_path" 2>/dev/null || true)"
      program1="$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$plist_path" 2>/dev/null || true)"
      working_dir="$(/usr/libexec/PlistBuddy -c 'Print :WorkingDirectory' "$plist_path" 2>/dev/null || true)"
      plist_host="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_HOST' "$plist_path" 2>/dev/null || true)"
      plist_model="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OLLAMA_MODEL' "$plist_path" 2>/dev/null || true)"
      plist_log_dir="$(/usr/libexec/PlistBuddy -c 'Print :EnvironmentVariables:OS1_LOCAL_OPS_LOG_DIR' "$plist_path" 2>/dev/null || true)"
      stdout_path="$(/usr/libexec/PlistBuddy -c 'Print :StandardOutPath' "$plist_path" 2>/dev/null || true)"

      [ "$program0" = "/bin/bash" ] && pass "$label uses /bin/bash" || fail "$label ProgramArguments[0] should be /bin/bash"
      [ "$program1" = "$ROOT_DIR/scripts/os1-local-ops-health.sh" ] && pass "$label points at os1-local-ops-health.sh" || fail "$label ProgramArguments[1] does not point at this repo health script"
      [ "$working_dir" = "$ROOT_DIR" ] && pass "$label WorkingDirectory matches repo" || fail "$label WorkingDirectory does not match this repo"
      [ "$plist_host" = "${OLLAMA_HOST:-http://127.0.0.1:11434}" ] && pass "$label OLLAMA_HOST is configured" || warn "$label OLLAMA_HOST differs from expected local host"
      [ "$plist_model" = "${OLLAMA_MODEL:-qwen2.5-coder:3b}" ] && pass "$label OLLAMA_MODEL is configured" || warn "$label OLLAMA_MODEL is missing or differs from expected local model"
      [ "$plist_log_dir" = "$expected_log_dir" ] && pass "$label log directory is configured" || warn "$label OS1_LOCAL_OPS_LOG_DIR differs from expected local log directory"
      [ "$stdout_path" = "$expected_log_dir/local-health.log" ] && pass "$label stdout log path is configured" || warn "$label StandardOutPath differs from expected local-health.log"
    else
      warn "PlistBuddy not found; detailed $label plist checks skipped"
    fi
  else
    fail "$label plist file is missing: $plist_path"
  fi

  if [ -z "$last_exit" ]; then
    warn "$label has not recorded a last exit code yet"
  elif [ "$last_exit" = "0" ]; then
    pass "$label last exit code is 0"
  else
    fail "$label last exit code is $last_exit"
  fi
}

check_ollama() {
  section "Ollama"

  if [ ! -x "$ROOT_DIR/scripts/ollama-health.sh" ]; then
    fail "missing executable scripts/ollama-health.sh"
    return
  fi

  if OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}" "$ROOT_DIR/scripts/ollama-health.sh"; then
    pass "Ollama model health passed"
  else
    fail "Ollama model health failed"
  fi
}

check_ci() {
  section "GitHub CI"

  if ! command -v gh >/dev/null 2>&1; then
    require_for_public "gh not found; GitHub CI status was not checked"
    return
  fi

  origin_url="$(git -C "$ROOT_DIR" config --get remote.origin.url 2>/dev/null || true)"
  repo="$(
    printf '%s' "$origin_url" | sed -E \
      -e 's#^https://github.com/##' \
      -e 's#^git@github.com:##' \
      -e 's#\.git$##'
  )"
  case "$repo" in
    */*) ;;
    *)
      repo="$(gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null || true)"
      ;;
  esac
  if [ -z "$repo" ]; then
    require_for_public "gh is unavailable or not authenticated; GitHub CI status was not checked"
    return
  fi

  branch="$(git -C "$ROOT_DIR" branch --show-current 2>/dev/null || true)"
  head_sha="$(git -C "$ROOT_DIR" rev-parse HEAD 2>/dev/null || true)"
  if [ -z "$branch" ] || [ -z "$head_sha" ]; then
    require_for_public "could not determine branch/HEAD for CI lookup"
    return
  fi

  runs_json="$(gh run list --repo "$repo" --branch "$branch" --workflow CI --limit 10 --json headSha,status,conclusion,url,databaseId,workflowName 2>/dev/null || true)"
  if [ -z "$runs_json" ]; then
    require_for_public "no CI workflow runs returned for $repo $branch"
    return
  fi

  ci_result="$(printf '%s' "$runs_json" | python3 -c '
import json
import sys

head = sys.argv[1]
try:
    runs = json.load(sys.stdin)
except Exception:
    runs = []

for run in runs:
    if run.get("headSha") == head and run.get("workflowName") == "CI":
        print(json.dumps(run, separators=(",", ":")))
        break
' "$head_sha")"

  if [ -z "$ci_result" ]; then
    require_for_public "no CI workflow run found for current HEAD"
    return
  fi

  status="$(printf '%s' "$ci_result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("status",""))')"
  conclusion="$(printf '%s' "$ci_result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("conclusion",""))')"
  url="$(printf '%s' "$ci_result" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("url",""))')"

  if [ "$status" = "completed" ] && [ "$conclusion" = "success" ]; then
    pass "GitHub CI passed for HEAD${url:+: $url}"
  elif [ "$status" = "completed" ]; then
    if [ "$PROFILE" = "public" ]; then
      fail "GitHub CI completed with conclusion: ${conclusion:-unknown}${url:+ ($url)}"
    else
      warn "GitHub CI completed with conclusion: ${conclusion:-unknown}${url:+ ($url)}"
    fi
  else
    require_for_public "GitHub CI is not complete for HEAD: ${status:-unknown}${url:+ ($url)}"
  fi
}

check_app_bundle() {
  section "App Bundle"

  app_path="$ROOT_DIR/dist/OS1.app"
  zip_path="$ROOT_DIR/dist/OS1.app.zip"
  checksum_path="$ROOT_DIR/dist/OS1.app.zip.sha256"

  if [ ! -d "$app_path" ]; then
    require_for_public "dist/OS1.app is missing; run scripts/package-github-release.sh"
    return
  fi

  pass "app bundle exists: $app_path"
  if codesign --verify --deep --strict "$app_path" >/dev/null 2>&1; then
    pass "codesign verification passed"
  else
    fail "codesign verification failed"
  fi

  signature_details="$(codesign -dv --verbose=4 "$app_path" 2>&1 || true)"
  if printf '%s\n' "$signature_details" | grep -q "Authority=Developer ID Application:"; then
    pass "Developer ID Application signature present"
  else
    require_for_public "Developer ID Application signature is missing"
  fi

  if printf '%s\n' "$signature_details" | grep -q "flags=.*runtime"; then
    pass "hardened runtime is enabled"
  else
    require_for_public "hardened runtime is missing"
  fi

  if [ -f "$zip_path" ]; then
    pass "release zip exists: $zip_path"
  else
    require_for_public "release zip is missing"
  fi

  if [ -f "$checksum_path" ]; then
    if (cd "$ROOT_DIR" && shasum -a 256 -c "dist/OS1.app.zip.sha256" >/dev/null 2>&1); then
      pass "release zip checksum verifies"
    else
      fail "release zip checksum does not verify"
    fi
  else
    require_for_public "release zip checksum is missing"
  fi

  if command -v spctl >/dev/null 2>&1; then
    if spctl -a -vvv -t exec "$app_path" >/dev/null 2>&1; then
      pass "spctl accepts app execution"
    else
      require_for_public "spctl does not accept app execution"
    fi
  fi

  if [ "$PROFILE" = "public" ]; then
    if command -v xcrun >/dev/null 2>&1; then
      if xcrun stapler validate "$app_path" >/dev/null 2>&1; then
        pass "stapled notarization ticket validates"
      else
        fail "stapled notarization ticket is missing or invalid"
      fi
    else
      fail "xcrun not found; stapled notarization ticket was not checked"
    fi
  fi
}

check_business_smoke() {
  section "Business Smoke"

  if [ ! -x "$ROOT_DIR/scripts/os1-business-smoke.sh" ]; then
    fail "missing executable scripts/os1-business-smoke.sh"
    return
  fi

  if OLLAMA_MODEL="${OLLAMA_MODEL:-qwen2.5-coder:3b}" "$ROOT_DIR/scripts/os1-business-smoke.sh" --quick; then
    pass "business smoke passed"
  else
    fail "business smoke failed"
  fi
}

check_public_credentials() {
  section "Public Release Credentials"

  codesign_status="missing"
  if [ "$(env_status OS1_CODESIGN_IDENTITY)" = "set" ] || [ "$(env_status HERMES_CODESIGN_IDENTITY)" = "set" ]; then
    codesign_status="set"
  elif command -v security >/dev/null 2>&1 && security find-identity -v -p codesigning 2>/dev/null | grep -q "Developer ID Application:"; then
    codesign_status="available in keychain"
  fi

  if [ "$codesign_status" = "missing" ]; then
    require_for_public "Developer ID signing identity is missing"
  else
    pass "Developer ID signing identity: $codesign_status"
  fi

  notary_status="missing"
  if [ "$(env_status OS1_NOTARY_KEYCHAIN_PROFILE)" = "set" ]; then
    notary_status="keychain profile set"
  elif [ "$(env_status OS1_NOTARY_KEY)" = "set" ] && [ "$(env_status OS1_NOTARY_KEY_ID)" = "set" ]; then
    notary_status="API key fields set"
  fi

  if [ "$notary_status" = "missing" ]; then
    require_for_public "notarization credentials are missing"
  else
    pass "notarization credentials: $notary_status"
  fi
}

printf 'OS1 production readiness (%s profile)\n' "$PROFILE"
printf 'Root: %s\n' "$ROOT_DIR"

check_git
check_azure_flags
run_local_ops_health
check_launchagent
check_ollama
check_business_smoke
check_storage_report
check_ci
check_app_bundle
check_public_credentials

printf '\n== Summary ==\n'
if [ "$FAILURES" -eq 0 ]; then
  pass "readiness passed with $WARNINGS warning(s)"
  exit 0
fi

fail "readiness failed with $FAILURES failure(s), $WARNINGS warning(s)"
exit 1
