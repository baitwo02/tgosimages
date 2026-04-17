#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Default values
RTTHREAD_REPO_URL="${RTTHREAD_REPO_URL:-https://github.com/RT-Thread/rt-thread.git}"
RTTHREAD_SRC_DIR="${RTTHREAD_SRC_DIR:-${BUILD_DIR}/rtthread}"
RTTHREAD_PATCH_DIR="${RTTHREAD_PATCH_DIR:-${ROOT_DIR}/patches/rtthread}"

# Global variables for parsed arguments
RTTHREAD_PLATFORM_DIR=""
RTTHREAD_PLATFORM_BIN_NAME=""
RTTHREAD_BIN_DIR="IMAGES/rtthread"
RTTHREAD_BIN_NAME="rtthread"
RTTHREAD_ARGS=""

rtthread_usage() {
    printf 'RT-Thread build script for various platforms\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rtthread.sh <command> [options]\n'
    printf '\n'
    printf '<command>:                      \n'
    printf '  phytiumpi                     build for PhytiumPi\n'
    printf '  roc-rk3568-pc                 build for ROC-RK3568-PC\n'
    printf '  all                           build all supported board\n'
    printf '  clean                         Clean all supported board\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --repo-url <url>              RT-Thread repository URL (default: https://github.com/RT-Thread/rt-thread.git)\n'
    printf '  --src-dir <dir>               Source directory (default: build/rtthread)\n'
    printf '  --patch-dir <dir>             Patch directory (default: patches/rtthread)\n'
    printf '  --bin-dir <name>              Output binary directory(default: IMAGES/rtthread/rtthread)\n'
    printf '  --bin-name <name>             Output binary name\n'
    printf '  The other options will be directly passed to the ththread build system. for example:\n'
    printf '     -h, --help                 Print defined help message of ththread build system\n'
    printf '     -c, --clean                clean for specific board\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  RTTHREAD_REPO_URL             RT-Thread repository URL\n'
    printf '  RTTHREAD_SRC_DIR              RT-Thread source directory\n'
    printf '  RTTHREAD_PATCH_DIR            RT-Thread patch directory\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rtthread.sh phytiumpi --bin-name rt.bin\n'
    printf '  scripts/rtthread.sh roc-rk3568-pc -c\n'
}

rtthread_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-url)
                RTTHREAD_REPO_URL="$2"
                shift 2
                ;;
            --src-dir)
                RTTHREAD_SRC_DIR="$2"
                shift 2
                ;;
            --patch-dir)
                RTTHREAD_PATCH_DIR="$2"
                shift 2
                ;;
            --bin-dir)
                RTTHREAD_BIN_DIR="$2"
                shift 2
                ;;
            --bin-name)
                RTTHREAD_BIN_NAME="$2"
                shift 2
                ;;
            *)
                RTTHREAD_ARGS="$RTTHREAD_ARGS $1"
                shift
                ;;
        esac
    done
}

rtthread_build() {
    if [[ -d "$RTTHREAD_PLATFORM_DIR" ]]; then
        pushd "$RTTHREAD_PLATFORM_DIR" >/dev/null
        info "EXEC: scons -j$(nproc) $RTTHREAD_ARGS"
        export RTT_EXEC_PATH="/opt/arm-gnu-toolchain-11.3.rel1-x86_64-aarch64-none-elf/bin"
        scons -j$(nproc) $RTTHREAD_ARGS
        popd >/dev/null
    fi

    if [[ "${RTTHREAD_ARGS}" != *"-c"* ]]; then
        info "Copying build artifacts: $RTTHREAD_PLATFORM_DIR/rtthread_a64.bin -> $RTTHREAD_BIN_DIR/$RTTHREAD_BIN_NAME"
        mkdir -p "${RTTHREAD_BIN_DIR}"
        cp "${RTTHREAD_PLATFORM_DIR}/$RTTHREAD_PLATFORM_BIN_NAME" "${RTTHREAD_BIN_DIR}/$RTTHREAD_BIN_NAME"
    else
        info "Cleaning build artifacts in $RTTHREAD_BIN_DIR"
        rm -rf "${RTTHREAD_BIN_DIR}" || true
    fi
}

rtthread() {
    if [[ "${RTTHREAD_ARGS}" != *"-c"* ]]; then
        info "Cloning RT-Thread source repository $RTTHREAD_REPO_URL -> $RTTHREAD_SRC_DIR"
        clone_repository "$RTTHREAD_REPO_URL" "$RTTHREAD_SRC_DIR"

        info "checkout_ref "v5.2.2""
        checkout_ref "$RTTHREAD_SRC_DIR" "v5.2.2"

        if [[ -d "$RTTHREAD_PATCH_DIR" ]]; then
            info "Applying patches..."
            apply_patches "$RTTHREAD_PATCH_DIR" "$RTTHREAD_SRC_DIR"
        fi
    fi

    rtthread_build
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            rtthread_usage
            exit 0
            ;;
        phytiumpi)
            RTTHREAD_PLATFORM_DIR="$RTTHREAD_SRC_DIR/bsp/phytium/aarch64"
            RTTHREAD_PLATFORM_BIN_NAME="rtthread_a64.bin"
            ;;
        roc-rk3568-pc)
            RTTHREAD_PLATFORM_DIR="$RTTHREAD_SRC_DIR/bsp/rockchip/rk3568"
            RTTHREAD_PLATFORM_BIN_NAME="rtthread.bin"
            ;;
        all)
            for arch in phytiumpi roc-rk3568-pc; do
                "$0" "$arch" "$@" || { echo "[ERROR] $arch build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        clean)
            for arch in phytiumpi roc-rk3568-pc; do
                "$0" "$arch" "-c" || { echo "[ERROR] $arch build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac

    # Parse the other arguments
    rtthread_parse_args "$@"

    # Call the main function
    rtthread
fi
