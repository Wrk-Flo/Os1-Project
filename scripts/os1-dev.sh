#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWIFTPM_HOME="$ROOT_DIR/.swiftpm-home"
BUILD_PATH="$ROOT_DIR/.build"
TEST_BUILD_PATH="$ROOT_DIR/.build-tests"
ROOT_MARKER="$SWIFTPM_HOME/project-root"

mkdir -p \
    "$SWIFTPM_HOME/cache" \
    "$SWIFTPM_HOME/configuration" \
    "$SWIFTPM_HOME/security" \
    "$SWIFTPM_HOME/module-cache"

pick_sdk() {
    if [[ -n "${SDKROOT:-}" && -d "${SDKROOT}" ]]; then
        printf '%s\n' "$SDKROOT"
        return
    fi

    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"
    if [[ -n "$developer_dir" && "$developer_dir" != "/Library/Developer/CommandLineTools" ]]; then
        xcrun --show-sdk-path
        return
    fi

    local clt_sdks="/Library/Developer/CommandLineTools/SDKs"
    local selected=""

    if [[ -d "$clt_sdks" ]]; then
        selected="$(ls -d "$clt_sdks"/MacOSX15.[0-9]*.sdk 2>/dev/null | sort | tail -n 1 || true)"
        if [[ -z "$selected" ]]; then
            selected="$(ls -d "$clt_sdks"/MacOSX15*.sdk 2>/dev/null | grep -v 'MacOSX15.sdk$' | sort | tail -n 1 || true)"
        fi
        if [[ -z "$selected" ]]; then
            selected="$(ls -d "$clt_sdks"/MacOSX*.sdk 2>/dev/null | grep -v 'MacOSX26' | sort | tail -n 1 || true)"
        fi
    fi

    if [[ -z "$selected" ]]; then
        selected="$(xcrun --show-sdk-path)"
    fi

    printf '%s\n' "$selected"
}

pick_swift_testing_sdk() {
    if [[ -n "${SDKROOT:-}" && -d "${SDKROOT}" ]]; then
        printf '%s\n' "$SDKROOT"
        return
    fi

    local clt_sdks="/Library/Developer/CommandLineTools/SDKs"
    local selected=""

    if [[ -d "$clt_sdks" ]]; then
        selected="$(ls -d "$clt_sdks"/MacOSX26*.sdk 2>/dev/null | grep -v 'MacOSX26.sdk$' | sort | tail -n 1 || true)"
    fi

    if [[ -n "$selected" ]]; then
        printf '%s\n' "$selected"
        return
    fi

    pick_sdk
}

pick_frameworks_dir() {
    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"

    if [[ -n "$developer_dir" && "$developer_dir" != "/Library/Developer/CommandLineTools" ]]; then
        printf '%s\n' "$developer_dir/Library/Developer/Frameworks"
        return
    fi

    printf '%s\n' "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
}

pick_testing_interop_dir() {
    local developer_dir
    developer_dir="$(xcode-select -p 2>/dev/null || true)"

    local candidates=()
    if [[ -n "$developer_dir" ]]; then
        candidates+=(
            "$developer_dir/Library/Developer/usr/lib"
            "$developer_dir/usr/lib"
        )
    fi
    candidates+=(
        "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"
        "/Library/Developer/CommandLineTools/usr/lib"
    )

    local candidate
    for candidate in "${candidates[@]}"; do
        if [[ -f "$candidate/lib_TestingInterop.dylib" ]]; then
            printf '%s\n' "$candidate"
            return
        fi
    done
}

clean_module_caches() {
    find "$BUILD_PATH" "$TEST_BUILD_PATH" "$SWIFTPM_HOME/module-cache" \
        \( -type d -name ModuleCache -o -type d -name ModuleCache.noindex \) \
        -prune -exec rm -rf {} + 2>/dev/null || true
    find "$BUILD_PATH" "$TEST_BUILD_PATH" "$SWIFTPM_HOME/module-cache" \
        \( -name '*.pcm' -o -name '*.swiftmodule' \) \
        -delete 2>/dev/null || true
}

repair_relocated_caches() {
    local previous=""
    if [[ -f "$ROOT_MARKER" ]]; then
        previous="$(cat "$ROOT_MARKER")"
    fi

    if [[ "$previous" != "$ROOT_DIR" ]]; then
        if [[ -n "$previous" ]]; then
            echo "Project moved from $previous; clearing module caches."
        else
            echo "Initializing OS1 build cache marker; clearing module caches once."
        fi
        clean_module_caches
        printf '%s\n' "$ROOT_DIR" > "$ROOT_MARKER"
    fi
}

COMMON_FLAGS=(
    --disable-sandbox
    --manifest-cache local
    --cache-path "$SWIFTPM_HOME/cache"
    --config-path "$SWIFTPM_HOME/configuration"
    --security-path "$SWIFTPM_HOME/security"
)

FAST_DEBUG_FLAGS=()
if [[ "${OS1_INDEX_STORE:-0}" != "1" ]]; then
    FAST_DEBUG_FLAGS+=(--disable-index-store)
fi

usage() {
    cat <<'USAGE'
Usage: scripts/os1-dev.sh <command> [args]

Commands:
  doctor                 Print toolchain and cache state.
  build                  Fast debug build of the OS1 product.
  build-tests            Compile source and test targets without running tests.
  test [swift args...]   Run the full test suite with stable defaults.
  test-fast [args...]    Run tests in parallel.
  test-filter <regex>    Run matching tests only.
  list-tests             List XCTest specifiers.
  app                    Build a fast local arm64 app bundle.
  app-universal          Build the release-style universal app bundle.
  watch-build            Re-run build when Swift files change.
  watch-test [regex]     Re-run full or filtered tests when Swift files change.
  bench                  Benchmark warm build/test commands with hyperfine.
  clean-caches           Clear module caches, preserving build artifacts.

Env:
  OS1_JOBS=8             Override SwiftPM build jobs.
  OS1_TEST_WORKERS=8     Override parallel test workers.
  SDKROOT=/path/to/sdk    Override SDK selection.
  OS1_INDEX_STORE=1      Keep index store in fast debug builds.
USAGE
}

swift_base() {
    env "${SWIFT_ENV[@]}" swift "$@"
}

swift_build_common() {
    local scratch="$1"
    shift
    local flags=("${COMMON_FLAGS[@]}" --scratch-path "$scratch")
    if [[ -n "${OS1_JOBS:-}" ]]; then
        flags+=("--jobs" "$OS1_JOBS")
    fi
    swift_base "$@" "${flags[@]}" "${FRAMEWORK_FLAGS[@]}"
}

cmd="${1:-doctor}"
if [[ $# -gt 0 ]]; then
    shift
fi

case "$cmd" in
    build-tests|test|test-fast|test-filter|list-tests)
        BUILD_SDK="$(pick_swift_testing_sdk)"
        ;;
    *)
        BUILD_SDK="$(pick_sdk)"
        ;;
esac

FRAMEWORKS_DIR="$(pick_frameworks_dir)"
TEST_SDK="$(pick_swift_testing_sdk)"
TESTING_INTEROP_DIR="$(pick_testing_interop_dir)"
SWIFT_ENV=(
    "CLANG_MODULE_CACHE_PATH=$SWIFTPM_HOME/module-cache"
    "SDKROOT=$BUILD_SDK"
    "DYLD_FRAMEWORK_PATH=$FRAMEWORKS_DIR"
)
if [[ -n "$TESTING_INTEROP_DIR" ]]; then
    SWIFT_ENV+=("DYLD_LIBRARY_PATH=$TESTING_INTEROP_DIR${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}")
fi
FRAMEWORK_FLAGS=(
    -Xswiftc -F
    -Xswiftc "$FRAMEWORKS_DIR"
    -Xlinker -F
    -Xlinker "$FRAMEWORKS_DIR"
    -Xlinker -rpath
    -Xlinker "$FRAMEWORKS_DIR"
)
if [[ -n "$TESTING_INTEROP_DIR" ]]; then
    FRAMEWORK_FLAGS+=(
        -Xlinker -L
        -Xlinker "$TESTING_INTEROP_DIR"
        -Xlinker -rpath
        -Xlinker "$TESTING_INTEROP_DIR"
    )
fi

case "$cmd" in
    doctor)
        repair_relocated_caches
        echo "Root: $ROOT_DIR"
        echo "Swift: $(swift --version | head -n 1)"
        echo "Developer dir: $(xcode-select -p 2>/dev/null || true)"
        echo "SDK: $BUILD_SDK"
        echo "Swift Testing SDK: $TEST_SDK"
        echo "Frameworks: $FRAMEWORKS_DIR"
        echo "Testing interop: ${TESTING_INTEROP_DIR:-missing}"
        du -sh "$BUILD_PATH" "$TEST_BUILD_PATH" "$SWIFTPM_HOME" 2>/dev/null || true
        ;;
    build)
        repair_relocated_caches
        swift_build_common "$BUILD_PATH" build --product OS1 "${FAST_DEBUG_FLAGS[@]}" "$@"
        ;;
    build-tests)
        repair_relocated_caches
        swift_build_common "$TEST_BUILD_PATH" build --build-tests "${FAST_DEBUG_FLAGS[@]}" "$@"
        ;;
    test)
        repair_relocated_caches
        swift_build_common "$TEST_BUILD_PATH" test "$@"
        ;;
    test-fast)
        repair_relocated_caches
        workers="${OS1_TEST_WORKERS:-$(sysctl -n hw.ncpu 2>/dev/null || echo 8)}"
        swift_build_common "$TEST_BUILD_PATH" test --parallel --num-workers "$workers" "$@"
        ;;
    test-filter)
        repair_relocated_caches
        if [[ $# -lt 1 ]]; then
            echo "error: test-filter requires a regex" >&2
            exit 2
        fi
        swift_build_common "$TEST_BUILD_PATH" test --filter "$1"
        ;;
    list-tests)
        repair_relocated_caches
        swift_build_common "$TEST_BUILD_PATH" test --list-tests
        ;;
    app)
        repair_relocated_caches
        HERMES_MAC_ARCHS="${HERMES_MAC_ARCHS:-arm64}" "$ROOT_DIR/scripts/build-macos-app.sh"
        ;;
    app-universal)
        repair_relocated_caches
        "$ROOT_DIR/scripts/build-macos-app.sh"
        ;;
    watch-build)
        command -v watchexec >/dev/null || { echo "error: install watchexec first" >&2; exit 127; }
        watchexec --clear --exts swift --watch Sources --watch Tests --watch Package.swift -- "$ROOT_DIR/scripts/os1-dev.sh" build
        ;;
    watch-test)
        command -v watchexec >/dev/null || { echo "error: install watchexec first" >&2; exit 127; }
        if [[ $# -gt 0 ]]; then
            watchexec --clear --exts swift --watch Sources --watch Tests --watch Package.swift -- "$ROOT_DIR/scripts/os1-dev.sh" test-filter "$1"
        else
            watchexec --clear --exts swift --watch Sources --watch Tests --watch Package.swift -- "$ROOT_DIR/scripts/os1-dev.sh" test
        fi
        ;;
    bench)
        repair_relocated_caches
        command -v hyperfine >/dev/null || { echo "error: install hyperfine first" >&2; exit 127; }
        hyperfine --warmup 1 "$ROOT_DIR/scripts/os1-dev.sh build" "$ROOT_DIR/scripts/os1-dev.sh build-tests"
        ;;
    clean-caches)
        clean_module_caches
        printf '%s\n' "$ROOT_DIR" > "$ROOT_MARKER"
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        echo "error: unknown command: $cmd" >&2
        usage >&2
        exit 2
        ;;
esac
