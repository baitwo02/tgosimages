#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Default values
ARCEOS_REPO_URL="${ARCEOS_REPO_URL:-https://github.com/arceos-hypervisor/arceos.git}"
ARCEOS_SRC_DIR="${ARCEOS_SRC_DIR:-${BUILD_DIR}/arceos}"
ARCEOS_PATCH_DIR="${ARCEOS_PATCH_DIR:-${ROOT_DIR}/patches/arceos}"

# Global variables for parsed arguments
ARCEOS_PLATFORM=""
ARCEOS_BIN_DIR="IMAGES/arceos"
ARCEOS_BIN_NAME=""
ARCEOS_ARGS=""

# Platform-specific configurations
declare -A PLATFORM_CONFIGS
PLATFORM_CONFIGS[aarch64-dyn]="ld_script:link.x features:driver-dyn,page-alloc-4g,paging smp:1 log_level:info app_features:aarch64-dyn"
PLATFORM_CONFIGS[riscv64-qemu-virt]="ld_script: features:driver-dyn,page-alloc-4g,paging smp:1 log_level:info app_features:riscv64-qemu-virt"
PLATFORM_CONFIGS[x86-pc]="ld_script: features:driver-dyn,page-alloc-4g,paging smp:1 log_level:info app_features:x86-pc"

# Function to get platform-specific config value
get_platform_config() {
    local platform="$1"
    local config_key="$2"
    local config_str="${PLATFORM_CONFIGS[$platform]}"
    
    if [[ -z "$config_str" ]]; then
        die "Unsupported platform: $platform"
    fi
    
    # Parse the configuration string and return the requested value
    for item in $config_str; do
        local key="${item%%:*}"
        local value="${item#*:}"
        if [[ "$key" == "$config_key" ]]; then
            echo "$value"
            return 0
        fi
    done
    
    return 1
}

arceos_usage() {
    printf 'ArceOS build script for various platforms\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/arceos.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64-dyn                   Build for aarch64-dyn platform\n'
    printf '  riscv64-qemu-virt             Build for riscv64-qemu-virt platform\n'
    printf '  x86-pc                        Build for x86-pc platform\n'
    printf '  all                           Build all supported platforms\n'
    printf '  clean                         Clean all supported platforms\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --repo-url <url>              ArceOS repository URL (default: https://github.com/arceos-hypervisor/arceos.git)\n'
    printf '  --src-dir <dir>               Source directory (default: build/arceos)\n'
    printf '  --patch-dir <dir>             Patch directory (default: patches/arceos)\n'
    printf '  --bin-dir <name>              Output binary directory (default: IMAGES/arceos)\n'
    printf '  --bin-name <name>             Output binary name\n'
    printf '  The other options will be directly passed to the make build system. for example:\n'
    printf '     clean                      Clean for specific platform\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  ARCEOS_REPO_URL               ArceOS repository URL\n'
    printf '  ARCEOS_SRC_DIR                ArceOS source directory\n'
    printf '  ARCEOS_PATCH_DIR              ArceOS patch directory\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/arceos.sh aarch64-dyn --bin-name arceos.bin\n'
    printf '  scripts/arceos.sh riscv64-qemu-virt clean\n'
}

arceos_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --repo-url)
                ARCEOS_REPO_URL="$2"
                shift 2
                ;;
            --src-dir)
                ARCEOS_SRC_DIR="$2"
                shift 2
                ;;
            --patch-dir)
                ARCEOS_PATCH_DIR="$2"
                shift 2
                ;;
            --bin-dir)
                ARCEOS_BIN_DIR="$2"
                shift 2
                ;;
            --bin-name)
                ARCEOS_BIN_NAME="$2"
                shift 2
                ;;
            *)
                ARCEOS_ARGS="$ARCEOS_ARGS $1"
                shift
                ;;
        esac
    done
}

arceos_build() {
    # Get platform-specific configuration
    local ld_script=$(get_platform_config "$ARCEOS_PLATFORM" "ld_script")
    local features=$(get_platform_config "$ARCEOS_PLATFORM" "features")
    local smp=$(get_platform_config "$ARCEOS_PLATFORM" "smp")
    local log_level=$(get_platform_config "$ARCEOS_PLATFORM" "log_level")
    local app_features=$(get_platform_config "$ARCEOS_PLATFORM" "app_features")
    
    if [[ -d "$ARCEOS_SRC_DIR" ]]; then
        pushd "$ARCEOS_SRC_DIR" >/dev/null
        info "EXEC: make clean"
        make clean || true

        # Special case for aarch64-dyn platform (needs LD_SCRIPT parameter)
        if [[ "$ARCEOS_PLATFORM" == "aarch64-dyn" ]]; then
            local make_cmd="A=examples/helloworld-myplat LOG=$log_level MYPLAT=axplat-$ARCEOS_PLATFORM APP_FEATURES=$app_features LD_SCRIPT=$ld_script FEATURES=$features SMP=$smp $ARCEOS_ARGS"
            info "EXEC: make $make_cmd"
            make $make_cmd
        else
            local make_cmd="A=examples/helloworld-myplat LOG=$log_level MYPLAT=axplat-$ARCEOS_PLATFORM APP_FEATURES=$app_features FEATURES=$features SMP=$smp $ARCEOS_ARGS"
            info "EXEC: make $make_cmd"
            make $make_cmd
        fi
        popd >/dev/null
    fi

    if [[ "${ARCEOS_ARGS}" != *"clean"* ]]; then
        # Set default bin name if not specified
        if [[ -z "$ARCEOS_BIN_NAME" ]]; then
            ARCEOS_BIN_NAME="$ARCEOS_PLATFORM"
        fi
        
        info "Copying build artifacts: $ARCEOS_SRC_DIR/examples/helloworld-myplat/helloworld-myplat_$app_features.bin -> $ARCEOS_BIN_DIR/$ARCEOS_BIN_NAME"
        mkdir -p "${ARCEOS_BIN_DIR}"
        cp "$ARCEOS_SRC_DIR/examples/helloworld-myplat/helloworld-myplat_$app_features.bin" "${ARCEOS_BIN_DIR}/$ARCEOS_BIN_NAME"
    else
        info "Cleaning build artifacts in $ARCEOS_BIN_DIR"
        rm -rf "${ARCEOS_BIN_DIR}" || true
    fi
}

arceos() {
    if [[ "${ARCEOS_ARGS}" != *"clean"* ]]; then
        info "Cloning ArceOS source repository $ARCEOS_REPO_URL -> $ARCEOS_SRC_DIR"
        clone_repository "$ARCEOS_REPO_URL" "$ARCEOS_SRC_DIR"

        if [[ -d "$ARCEOS_PATCH_DIR" ]]; then
            info "Applying patches..."
            apply_patches "$ARCEOS_PATCH_DIR" "$ARCEOS_SRC_DIR"
        fi
    fi

    arceos_build
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            arceos_usage
            exit 0
            ;;
        aarch64-dyn)
            ARCEOS_PLATFORM="aarch64-dyn"
            ;;
        riscv64-qemu-virt)
            ARCEOS_PLATFORM="riscv64-qemu-virt"
            ;;
        x86-pc)
            ARCEOS_PLATFORM="x86-pc"
            ;;
        all)
            for platform in aarch64-dyn riscv64-qemu-virt x86-pc; do
                "$0" "$platform" "$@" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        clean)
            for platform in aarch64-dyn riscv64-qemu-virt x86-pc; do
                "$0" "$platform" "clean" || { echo "[ERROR] $platform build failed" >&2; exit 1; }
            done
            exit 0
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac

    # Parse the other arguments
    arceos_parse_args "$@"

    # Call the main function
    arceos
fi