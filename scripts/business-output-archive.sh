#!/usr/bin/env bash
# business-output-archive.sh — periodic archiver for OS1 business-ops runs.
#
# Moves run directories older than OS1_ARCHIVE_DAYS out of the live runs/
# tree into a sibling archive/ directory, gzipping each as a tarball. The
# runner (scripts/os1-business-ops-run.sh) already prunes by retention; this
# script provides a softer-than-delete tier: archive before delete.
#
# Defaults to dry-run. Pass --apply to actually move and tar.
#
# Owner: Claude Code. Does NOT edit or interfere with the runner.
#
# Exit codes:
#   0  ok (including dry-run with proposed actions)
#   1  archive failure during --apply
#   2  usage error

set -euo pipefail

SCRIPT_NAME="$(basename "${BASH_SOURCE[0]}")"
DEFAULT_ROOT="$HOME/Library/Application Support/OS1/business-ops"
OUTPUT_ROOT="${OS1_BUSINESS_OPS_ROOT:-$DEFAULT_ROOT}"
ARCHIVE_DAYS="${OS1_ARCHIVE_DAYS:-30}"
APPLY=0

usage() {
  cat <<USAGE
Usage: $SCRIPT_NAME [--apply] [--root DIR] [--days N] [-h|--help]

Archives business-ops run directories older than \$OS1_ARCHIVE_DAYS (default 30)
into \$OS1_BUSINESS_OPS_ROOT/archive/ as gzipped tarballs.

Default mode is dry-run. The script is idempotent: already-archived runs are
skipped, and existing tarballs are not overwritten.

Options:
  --apply       Actually move and tar; otherwise print what would happen.
  --root DIR    Override business-ops root (default: \$OS1_BUSINESS_OPS_ROOT
                or "$DEFAULT_ROOT").
  --days N      Archive runs older than N days (default: 30, also \$OS1_ARCHIVE_DAYS).
  -h, --help    Show this help.
USAGE
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --root)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      OUTPUT_ROOT="$2"
      shift
      ;;
    --days)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      ARCHIVE_DAYS="$2"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      printf '%s: unknown argument: %s\n' "$SCRIPT_NAME" "$1" >&2
      exit 2
      ;;
  esac
  shift
done

case "$ARCHIVE_DAYS" in
  ""|*[!0-9]*)
    printf '%s: --days must be a non-negative integer (got %q)\n' \
      "$SCRIPT_NAME" "$ARCHIVE_DAYS" >&2
    exit 2
    ;;
esac

runs_root="$OUTPUT_ROOT/runs"
archive_root="$OUTPUT_ROOT/archive"

printf 'OS1 business-ops archiver\n'
printf 'Root:    %s\n' "$OUTPUT_ROOT"
printf 'Runs:    %s\n' "$runs_root"
printf 'Archive: %s\n' "$archive_root"
printf 'Older than: %s day(s)\n' "$ARCHIVE_DAYS"
if [ "$APPLY" -eq 1 ]; then
  printf 'Mode: APPLY (will move and tar)\n'
else
  printf 'Mode: dry-run (use --apply to execute)\n'
fi

if [ ! -d "$runs_root" ]; then
  printf 'INFO: runs/ directory does not exist yet; nothing to archive.\n'
  exit 0
fi

if [ "$APPLY" -eq 1 ]; then
  mkdir -p "$archive_root" || {
    printf '%s: could not create archive root: %s\n' "$SCRIPT_NAME" "$archive_root" >&2
    exit 1
  }
fi

# Resolve latest target so we never archive whatever latest points at.
latest_target=""
if [ -L "$OUTPUT_ROOT/latest" ]; then
  if rl="$(readlink "$OUTPUT_ROOT/latest" 2>/dev/null)"; then
    case "$rl" in
      /*) latest_target="$(basename "$rl")" ;;
      *)  latest_target="$(basename "$rl")" ;;
    esac
  fi
fi

# Find candidate run dirs older than ARCHIVE_DAYS.
# -mindepth 1 -maxdepth 1 -type d -mtime +N matches the runner's prune logic.
candidates=""
if find_out="$(find "$runs_root" -mindepth 1 -maxdepth 1 -type d -mtime +"$ARCHIVE_DAYS" 2>/dev/null)"; then
  candidates="$find_out"
fi

if [ -z "$candidates" ]; then
  printf 'INFO: no run directories older than %s day(s); nothing to archive.\n' "$ARCHIVE_DAYS"
  exit 0
fi

archived=0
skipped=0
failed=0

old_ifs="$IFS"
IFS='
'
for run_path in $candidates; do
  [ -n "$run_path" ] || continue
  run_id="$(basename "$run_path")"

  if [ -n "$latest_target" ] && [ "$run_id" = "$latest_target" ]; then
    printf 'SKIP: %s (currently pointed to by latest)\n' "$run_id"
    skipped=$((skipped + 1))
    continue
  fi

  tar_path="$archive_root/${run_id}.tar.gz"

  if [ -f "$tar_path" ]; then
    printf 'SKIP: %s (archive already exists: %s)\n' "$run_id" "$tar_path"
    skipped=$((skipped + 1))
    continue
  fi

  if [ "$APPLY" -eq 0 ]; then
    printf 'WOULD: tar+gzip %s -> %s, then rm -rf %s\n' "$run_id" "$tar_path" "$run_path"
    archived=$((archived + 1))
    continue
  fi

  # Apply mode: write to a temp file in the same dir, then rename for atomicity.
  tmp_path="${tar_path}.partial.$$"
  if ! tar -czf "$tmp_path" -C "$runs_root" "$run_id" 2>/dev/null; then
    printf 'FAIL: tar failed for %s\n' "$run_id" >&2
    rm -f "$tmp_path" 2>/dev/null || true
    failed=$((failed + 1))
    continue
  fi
  if ! mv "$tmp_path" "$tar_path"; then
    printf 'FAIL: could not finalize archive %s\n' "$tar_path" >&2
    rm -f "$tmp_path" 2>/dev/null || true
    failed=$((failed + 1))
    continue
  fi
  if ! rm -rf "$run_path"; then
    printf 'WARN: archive written but could not remove source: %s\n' "$run_path" >&2
    # Counted as archived; the tarball is in place.
  fi
  printf 'ARCHIVED: %s -> %s\n' "$run_id" "$tar_path"
  archived=$((archived + 1))
done
IFS="$old_ifs"

printf '\n== Archive Summary ==\n'
printf 'Archived: %d  Skipped: %d  Failed: %d\n' "$archived" "$skipped" "$failed"
if [ "$failed" -gt 0 ]; then
  exit 1
fi
exit 0
