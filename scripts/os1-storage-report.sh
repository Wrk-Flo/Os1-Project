#!/usr/bin/env bash
set -eu
set -o pipefail 2>/dev/null || true

SCRIPT_DIR="$(CDPATH= cd "$(dirname "$0")" && pwd -P)"
ROOT_DIR="$(CDPATH= cd "$SCRIPT_DIR/.." && pwd -P)"
HOME_DIR="${HOME:-}"

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

report_path() {
  label="$1"
  path="$2"
  size="$(size_for_path "$path")"
  printf '%-34s %10s  %s\n' "$label" "$size" "$(display_path "$path")"
}

report_existing_path() {
  label="$1"
  path="$2"
  if [ -e "$path" ] || [ -L "$path" ]; then
    report_path "$label" "$path"
  fi
}

report_disk() {
  label="$1"
  path="$2"
  probe="$path"
  if [ ! -d "$probe" ]; then
    probe="$(dirname "$probe")"
  fi
  if [ -d "$probe" ] && command -v df >/dev/null 2>&1; then
    df -h "$probe" 2>/dev/null | awk -v label="$label" '
      NR == 2 {
        printf "%-34s %10s  %s total, %s used, mounted on %s\n", label, $4, $2, $5, $NF
        found = 1
      }
      END {
        if (!found) {
          printf "%-34s %10s  unavailable\n", label, "unknown"
        }
      }
    '
  else
    printf '%-34s %10s  unavailable\n' "$label" "unknown"
  fi
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

printf 'OS1 local storage report\n'
printf 'Root: %s\n' "$ROOT_DIR"
printf 'Note: reports filesystem sizes only; no env files, keys, tokens, or config contents are read.\n'
printf '\nRepository storage\n'
report_path "repo total" "$ROOT_DIR"
report_path ".build" "$ROOT_DIR/.build"
report_path ".build-tests" "$ROOT_DIR/.build-tests"
report_path ".swiftpm-home" "$ROOT_DIR/.swiftpm-home"
report_path "dist" "$ROOT_DIR/dist"
report_path ".git" "$ROOT_DIR/.git"

printf '\nModel and developer caches\n'
if ollama_path="$(ollama_models_path)" && [ -n "$ollama_path" ]; then
  report_path "Ollama model cache" "$ollama_path"
fi
if llama_path="$(llama_cache_path)" && [ -n "$llama_path" ]; then
  report_path "llama.cpp cache" "$llama_path"
fi
if [ -n "$HOME_DIR" ]; then
  report_existing_path "llama.cpp macOS cache" "$HOME_DIR/Library/Caches/llama.cpp"
fi
if hf_path="$(hf_cache_path)" && [ -n "$hf_path" ]; then
  report_existing_path "Hugging Face hub cache" "$hf_path"
fi
report_existing_path "repo DerivedData" "$ROOT_DIR/DerivedData"
if [ -n "$HOME_DIR" ]; then
  report_existing_path "Xcode DerivedData" "$HOME_DIR/Library/Developer/Xcode/DerivedData"
fi

printf '\nDisk free\n'
report_disk "repo volume available" "$ROOT_DIR"
if [ -n "$HOME_DIR" ]; then
  report_disk "home volume available" "$HOME_DIR"
fi
if [ -n "${ollama_path:-}" ] && { [ -e "$ollama_path" ] || [ -d "$(dirname "$ollama_path")" ]; }; then
  report_disk "Ollama volume available" "$ollama_path"
fi
if [ -n "${llama_path:-}" ] && { [ -e "$llama_path" ] || [ -d "$(dirname "$llama_path")" ]; }; then
  report_disk "llama.cpp volume available" "$llama_path"
fi
