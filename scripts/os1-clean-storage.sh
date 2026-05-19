#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true
if [ -n "${ZSH_VERSION:-}" ]; then
  setopt NULL_GLOB 2>/dev/null || true
fi

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
HOME_DIR="${HOME:-}"
APPLY=0
CLEAN_BUILD=0
CLEAN_TESTS=0
CLEAN_DIST=0
CLEAN_LOGS=0
MODEL_REPORT=0
REQUESTED_TARGET=0
REMOVED_OR_PLANNED=0

usage() {
  cat <<'USAGE'
Usage: scripts/os1-clean-storage.sh [flags]

Dry-run is the default. Add --apply to remove selected repo-local targets.

Cleanup targets:
  --build-caches    Remove .build and .swiftpm-home.
  --test-caches     Remove .build-tests.
  --dist            Remove dist release/app artifacts.
  --logs            Remove repo-local logs, .logs, and .worktrace directories.
  --all             Select build caches, test caches, dist, and logs.

Reporting:
  --models-report   Report model cache sizes only. Models are never deleted.

Execution:
  --dry-run         Print what would be removed. This is the default.
  --apply           Actually remove the selected repo-local targets.
  -h, --help        Show this help.

Examples:
  scripts/os1-clean-storage.sh --all
  scripts/os1-clean-storage.sh --build-caches --test-caches --apply
  scripts/os1-clean-storage.sh --models-report
USAGE
}

die() {
  printf 'os1-clean-storage: %s\n' "$*" >&2
  exit 1
}

display_path() {
  path="$1"
  if [ -n "$HOME_DIR" ]; then
    case "$path" in
      "$HOME_DIR")
        printf '~'
        return
        ;;
      "$HOME_DIR"/*)
        printf '~/%s' "${path#"$HOME_DIR"/}"
        return
        ;;
    esac
  fi
  printf '%s' "$path"
}

size_for_path() {
  path="$1"
  if [ -e "$path" ] || [ -L "$path" ]; then
    du -sh "$path" 2>/dev/null | awk '{ print $1; found = 1; exit } END { if (!found) print "unreadable" }'
  else
    printf 'missing'
  fi
}

is_safe_repo_child() {
  target="$1"
  [ -n "$target" ] || return 1

  case "$target" in
    /|"$ROOT_DIR"|"$ROOT_DIR"/)
      return 1
      ;;
  esac

  parent="$(dirname "$target")"
  base="$(basename "$target")"
  case "$base" in
    .|..|'')
      return 1
      ;;
  esac

  [ -d "$parent" ] || return 1
  parent_real="$(CDPATH= cd "$parent" && pwd -P)" || return 1

  case "$parent_real/$base" in
    "$ROOT_DIR"/*)
      return 0
      ;;
  esac

  return 1
}

remove_path() {
  label="$1"
  target="$2"

  if ! is_safe_repo_child "$target"; then
    die "refusing unsafe path for $label: $target"
  fi

  if [ ! -e "$target" ] && [ ! -L "$target" ]; then
    printf 'skip missing: %-14s %s\n' "$label" "$(display_path "$target")"
    return
  fi

  REMOVED_OR_PLANNED=$((REMOVED_OR_PLANNED + 1))
  size="$(size_for_path "$target")"

  if [ "$APPLY" -eq 1 ]; then
    printf 'remove:      %-14s %10s  %s\n' "$label" "$size" "$(display_path "$target")"
    rm -rf "$target"
  else
    printf 'dry-run:     %-14s %10s  %s\n' "$label" "$size" "$(display_path "$target")"
  fi
}

report_model_cache() {
  label="$1"
  target="$2"
  [ -n "$target" ] || return 0
  printf 'model report: %-18s %10s  %s\n' "$label" "$(size_for_path "$target")" "$(display_path "$target")"
}

ollama_models_path() {
  if [ -n "${OLLAMA_MODELS:-}" ]; then
    printf '%s\n' "$OLLAMA_MODELS"
  elif [ -n "$HOME_DIR" ]; then
    printf '%s\n' "$HOME_DIR/.ollama/models"
  fi
}

llama_cache_path() {
  if [ -n "${LLAMA_CPP_CACHE_DIR:-}" ]; then
    printf '%s\n' "$LLAMA_CPP_CACHE_DIR"
  elif [ -n "${LLAMA_CACHE:-}" ]; then
    printf '%s\n' "$LLAMA_CACHE"
  elif [ -n "$HOME_DIR" ]; then
    printf '%s\n' "$HOME_DIR/.cache/llama.cpp"
  fi
}

hf_cache_path() {
  if [ -n "${HUGGINGFACE_HUB_CACHE:-}" ]; then
    printf '%s\n' "$HUGGINGFACE_HUB_CACHE"
  elif [ -n "${HF_HOME:-}" ]; then
    printf '%s\n' "${HF_HOME%/}/hub"
  elif [ -n "$HOME_DIR" ]; then
    printf '%s\n' "$HOME_DIR/.cache/huggingface/hub"
  fi
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --dry-run)
      APPLY=0
      ;;
    --build-caches)
      CLEAN_BUILD=1
      REQUESTED_TARGET=1
      ;;
    --test-caches)
      CLEAN_TESTS=1
      REQUESTED_TARGET=1
      ;;
    --dist)
      CLEAN_DIST=1
      REQUESTED_TARGET=1
      ;;
    --logs)
      CLEAN_LOGS=1
      REQUESTED_TARGET=1
      ;;
    --all)
      CLEAN_BUILD=1
      CLEAN_TESTS=1
      CLEAN_DIST=1
      CLEAN_LOGS=1
      REQUESTED_TARGET=1
      ;;
    --models-report|--model-report|--report-models)
      MODEL_REPORT=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "unknown flag: $1"
      ;;
  esac
  shift
done

if [ "$REQUESTED_TARGET" -eq 0 ] && [ "$MODEL_REPORT" -eq 0 ]; then
  usage >&2
  exit 64
fi

printf 'OS1 storage cleanup (%s)\n' "$(if [ "$APPLY" -eq 1 ]; then printf 'apply'; else printf 'dry-run'; fi)"
printf 'Root: %s\n' "$ROOT_DIR"

if [ "$CLEAN_BUILD" -eq 1 ]; then
  remove_path "build cache" "$ROOT_DIR/.build"
  remove_path "SwiftPM home" "$ROOT_DIR/.swiftpm-home"
fi

if [ "$CLEAN_TESTS" -eq 1 ]; then
  remove_path "test cache" "$ROOT_DIR/.build-tests"
fi

if [ "$CLEAN_DIST" -eq 1 ]; then
  remove_path "dist" "$ROOT_DIR/dist"
fi

if [ "$CLEAN_LOGS" -eq 1 ]; then
  remove_path "logs" "$ROOT_DIR/logs"
  remove_path ".logs" "$ROOT_DIR/.logs"
  remove_path ".worktrace" "$ROOT_DIR/.worktrace"
  for log_file in "$ROOT_DIR"/*.log "$ROOT_DIR"/*.log.*; do
    [ -e "$log_file" ] || [ -L "$log_file" ] || continue
    remove_path "log file" "$log_file"
  done
fi

if [ "$MODEL_REPORT" -eq 1 ]; then
  printf '\nModel caches are report-only; this script never deletes model files.\n'
  if ollama_path="$(ollama_models_path)" && [ -n "$ollama_path" ]; then
    report_model_cache "Ollama" "$ollama_path"
  fi
  if llama_path="$(llama_cache_path)" && [ -n "$llama_path" ]; then
    report_model_cache "llama.cpp" "$llama_path"
  fi
  if [ -n "$HOME_DIR" ] && [ -e "$HOME_DIR/Library/Caches/llama.cpp" ]; then
    report_model_cache "llama.cpp macOS" "$HOME_DIR/Library/Caches/llama.cpp"
  fi
  if hf_path="$(hf_cache_path)" && [ -n "$hf_path" ]; then
    report_model_cache "Hugging Face hub" "$hf_path"
  fi
fi

if [ "$REQUESTED_TARGET" -eq 1 ] && [ "$REMOVED_OR_PLANNED" -eq 0 ]; then
  printf 'No selected repo-local cleanup targets exist.\n'
fi
