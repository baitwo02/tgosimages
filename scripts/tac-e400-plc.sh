#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL="git@github.com:arceos-hypervisor/tac-e400-plc.git"
LINUX_SRC_DIR="${BUILD_DIR}/tac-e400-plc"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/tac-e400-plc"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/tac-e400-plc/linux"
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/tac-e400-plc/arceos"

# Output help information
usage() {
    printf 'Build supported OS for TAC-E400 series intelligent PLC products\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tac-e400-plc.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tac-e400-plc.sh all       # Build everything\n'
    printf '  scripts/tac-e400-plc.sh linux     # Build only Linux\n'
}

build_linux() {
    if [[ -d "$LINUX_SRC_DIR" ]]; then
        pushd "$LINUX_SRC_DIR/EDGE_KERNEL" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            info "Configuring kernel: cp "$LINUX_SRC_DIR/.config" .config"
            cp "$LINUX_SRC_DIR/.config" .config

            info "Starting compilation: make -j$(nproc) $@"
            make -j$(nproc) $@ 2>&1

            info "Copying build artifacts -> $LINUX_IMAGES_DIR"
            mkdir -p "$LINUX_IMAGES_DIR"
            cp "$LINUX_SRC_DIR/EDGE_KERNEL/arch/arm64/boot/Image" "$LINUX_IMAGES_DIR/tac-e400-plc"
            cp "$LINUX_SRC_DIR/EDGE_KERNEL/arch/arm64/boot/dts/phytium/e2000q-hanwei-board.dtb" "$LINUX_IMAGES_DIR/tac-e400-plc.dtb"
        else
            info "Cleaning: make -j$(nproc) clean"
            make -j$(nproc) clean 2>&1
            info "Removing ${LINUX_IMAGES_DIR}/*"
            rm ${LINUX_IMAGES_DIR}/* || true
        fi
        popd >/dev/null
    fi
}

linux() {
    if [[ "$@" != *"clean"* ]]; then
        info "Cloning Linux source repository $LINUX_REPO_URL -> $LINUX_SRC_DIR"
        clone_repository "$LINUX_REPO_URL" "$LINUX_SRC_DIR"
        
        if [[ -d "$LINUX_PATCH_DIR" ]]; then
            info "Applying patches..."
            apply_patches "$LINUX_PATCH_DIR" "$LINUX_SRC_DIR"
        fi
        info "Building to build the Linux system..."
    else
        info "Cleaning the Linux build artifacts..."
    fi

    build_linux "$@"
}

arceos() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building ArceOS using common arceos.sh script"
    else
        info "Cleaning ArceOS using common arceos.sh script"
    fi
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name tac-e400-plc $@
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            usage
            exit 0
            ;;
        linux)
            linux "$@"
            ;;
        arceos)
            arceos "$@"
            ;;
        all)
            linux "$@"

            arceos "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
fi
