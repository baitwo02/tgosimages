#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL="https://gitee.com/phytium_embedded/phytium-pi-os.git"
LINUX_SRC_DIR="${BUILD_DIR}/phytium-pi-os"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/phytiumpi"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi/linux"
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi/arceos"
RTTHREAD_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi/rtthread"
ZEPHYR_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi/zephyr"
FREERTOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/phytiumpi/freertos"

# Output help information
usage() {
    printf 'Build supported OS for Phytium development board\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/phytiumpi.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build only the Linux system\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  rtthread                          Build only the RT-Thread system\n'
    printf '  zephyr                            Build only the Zephyr guest image\n'
    printf '  freertos                          Build only the FreeRTOS guest image\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/phytiumpi.sh all          # Build everything\n'
    printf '  scripts/phytiumpi.sh linux        # Build only Linux\n'
}

build_linux() {
    if [[ -d "$LINUX_SRC_DIR" ]]; then
        pushd "$LINUX_SRC_DIR" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            info "Configuring build: make phytiumpi_desktop_defconfig"
            make phytiumpi_desktop_defconfig

            info "Starting compilation: make $@"
            make $@
            
            info "Copying build artifacts: $LINUX_SRC_DIR/output/images -> $LINUX_IMAGES_DIR"
            mkdir -p "$LINUX_IMAGES_DIR"
            rsync -av --ignore-missing-args "$LINUX_SRC_DIR/output/images/fip-all.bin" \
            "$LINUX_SRC_DIR/output/images/fitImage" \
            "$LINUX_SRC_DIR/output/images/kernel.its" \
            "$LINUX_SRC_DIR/output/images/Image" \
            "$LINUX_SRC_DIR/output/images/phytiumpi_firefly.dtb" \
            "$LINUX_IMAGES_DIR/"
            mv "$LINUX_IMAGES_DIR/phytiumpi_firefly.dtb" "$LINUX_IMAGES_DIR/phytiumpi.dtb"
            gzip -dc "$LINUX_SRC_DIR/output/images/Image.gz" > "$LINUX_IMAGES_DIR/phytiumpi"
        else
            info "Cleaning: make $@"
            make $@
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
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name phytiumpi $@
}

rtthread() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/rtthread.sh" phytiumpi "--bin-dir" "$RTTHREAD_IMAGES_DIR" "--bin-name" "phytiumpi" $@
    else
        info "Cleaning RT-Thread using common rtthread.sh script"
        bash "${SCRIPT_DIR}/rtthread.sh" phytiumpi "--bin-dir" "$RTTHREAD_IMAGES_DIR" "--bin-name" "phytiumpi" "-c"
    fi
}

zephyr() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/zephyr.sh" phytiumpi --images-dir "${ZEPHYR_IMAGES_DIR}" "$@"
    else
        info "Cleaning Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/zephyr.sh" phytiumpi clean --images-dir "${ZEPHYR_IMAGES_DIR}"
    fi
}

freertos() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/freertos.sh" phytiumpi
    else
        info "Cleaning FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/freertos.sh" phytiumpi clean
    fi
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
        rtthread)
            rtthread "$@"
            ;;
        zephyr)
            zephyr "$@"
            ;;
        freertos)
            freertos "$@"
            ;;
        all)
            linux "$@"

            arceos "$@"

            rtthread "$@"

            zephyr "$@"

            freertos "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"

            rtthread "clean"

            zephyr "clean"

            freertos "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
fi
