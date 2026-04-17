#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL="git@github.com:arceos-hypervisor/bst-a1000.git"
LINUX_SRC_DIR="${BUILD_DIR}/bst-a1000"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/bst-a1000"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/bst-a1000/linux"
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/bst-a1000/arceos"

# Output help information
usage() {
    printf 'Build supported OS for BST-A1000 products\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/bst-a1000.sh <command> [options]\n'
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
    printf '  scripts/bst-a1000.sh all          # Build everything\n'
    printf '  scripts/bst-a1000.sh linux        # Build only Linux\n'
}

build_linux() {
    if [[ -d "$LINUX_SRC_DIR" ]]; then
        pushd "$LINUX_SRC_DIR/kernel" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            info "Configuring kernel: make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 O=build_bst bsta1000b_release_defconfig"
            chmod -R 755 scripts/
            make CROSS_COMPILE=aarch64-linux-gnu- ARCH=arm64 O=build_bst bsta1000b_release_defconfig

            info "Starting compilation: make CROSS_COMPILE=aarch64-linux-gnu-  ARCH=arm64 O=build_bst -j$(nproc) $@"
            make CROSS_COMPILE=aarch64-linux-gnu-  ARCH=arm64 O=build_bst -j$(nproc) $@ 2>&1

            info "Copying build artifacts -> $LINUX_IMAGES_DIR"
            mkdir -p "$LINUX_IMAGES_DIR"
            cp "$LINUX_SRC_DIR/build_bst/arch/arm64/boot/Image" "$LINUX_IMAGES_DIR/"
            cp "$LINUX_SRC_DIR/../bst_dt/bsta1000b-fada.dtb" "$LINUX_IMAGES_DIR/"
            cp "$LINUX_SRC_DIR/../bst_dt/bsta1000b-fadb.dtb" "$LINUX_IMAGES_DIR/"
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
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name bst-a1000 $@
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
