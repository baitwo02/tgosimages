#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL="https://github.com/orangepi-xunlong/orangepi-build.git"
LINUX_SRC_DIR="${BUILD_DIR}/orangepi"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/orangepi"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/linux"
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/arceos"
ZEPHYR_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/zephyr"
FREERTOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/freertos"
UBOOT_SCRIPT="${SCRIPT_DIR}/build-u-boot-orangepi5.sh.sh"
UBOOT_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi/u-boot"

# Output help information
usage() {
    printf 'Build supported OS for orangepi-5-plus development board\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/orangepi.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build Linux system (includes U-Boot)\n'
    printf '  uboot                             Build only U-Boot\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  zephyr                            Build only the Zephyr guest image\n'
    printf '  freertos                          Build only the FreeRTOS guest image\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/orangepi.sh all           # Build everything\n'
    printf '  scripts/orangepi.sh linux         # Build Linux with U-Boot\n'
}

build_uboot() {
    info "Building U-Boot for Orange Pi 5..."
    chmod +x "${UBOOT_SCRIPT}"
    bash "${UBOOT_SCRIPT}"

    mkdir -p "${UBOOT_IMAGES_DIR}"
    cp -v "${PWD}/build/orangepi/u-boot-work/out/u-boot-orangepi5-spi.bin" "${UBOOT_IMAGES_DIR}/"
    success "U-Boot built successfully. Output: ${UBOOT_IMAGES_DIR}/u-boot-orangepi5-spi.bin"
}

build_linux() {
    if [[ -d "$LINUX_SRC_DIR" ]]; then
        pushd "$LINUX_SRC_DIR" >/dev/null
        if [[ "$@" != *"clean"* ]]; then
            # Configure GPT partition layout: EFI (FAT32) + FAT32 boot + ext4 rootfs
            local userpatches_lib_config="userpatches/lib.config"
            info "Configuring GPT partition layout (EFI + FAT32 boot + ext4 rootfs)"
            mkdir -p userpatches
            cat > "$userpatches_lib_config" <<'EOF'
IMAGE_PARTITION_TABLE=gpt
BOOTFS_TYPE=fat
BOOTSIZE=1024
EOF

            info "Starting compilation: ./build.sh BOARD=orangepi5plus BRANCH=current BUILD_OPT=image RELEASE=jammy BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no"
            ./build.sh BOARD=orangepi5plus BRANCH=current BUILD_OPT=image RELEASE=jammy BUILD_MINIMAL=no BUILD_DESKTOP=no KERNEL_CONFIGURE=no
            
            info "Copying build artifacts: $LINUX_SRC_DIR/* -> $LINUX_IMAGES_DIR/*"
            mkdir -p "$LINUX_IMAGES_DIR"
            rsync -av --ignore-missing-args "$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/Image" \
            "$LINUX_SRC_DIR/kernel/orange-pi-6.1-rk35xx/arch/arm64/boot/dts/rockchip/rk3588-orangepi-5-plus.dtb" \
            "$LINUX_IMAGES_DIR/"
            mv "$LINUX_IMAGES_DIR/Image" "$LINUX_IMAGES_DIR/orangepi-5-plus"
            mv "$LINUX_IMAGES_DIR/rk3588-orangepi-5-plus.dtb" "$LINUX_IMAGES_DIR/orangepi-5-plus.dtb"

            # Apply chosen node overlay to the DTB
            local chosen_overlay_dts="${LINUX_PATCH_DIR}/orangepi-5-plus-chosen-overlay.dts"
            local chosen_overlay_dtbo="${LINUX_IMAGES_DIR}/orangepi-5-plus-chosen.dtbo"
            if [[ -f "$chosen_overlay_dts" ]]; then
                info "Applying chosen node overlay to device tree"
                dtc -@ -I dts -O dtb -o "$chosen_overlay_dtbo" "$chosen_overlay_dts"
                fdtoverlay -i "$LINUX_IMAGES_DIR/orangepi-5-plus.dtb" \
                           -o "$LINUX_IMAGES_DIR/orangepi-5-plus.dtb" \
                           "$chosen_overlay_dtbo"
                rm -f "$chosen_overlay_dtbo"
                success "Chosen node overlay applied to orangepi-5-plus.dtb"
            fi

            popd >/dev/null

            # Build U-Boot after Linux
            build_uboot
        else
            info "Cleaning: nothing to do for Orange Pi Linux, just removing ${LINUX_IMAGES_DIR}/*"
            rm ${LINUX_IMAGES_DIR}/* || true
            rm ${UBOOT_IMAGES_DIR}/* 2>/dev/null || true
            popd >/dev/null
        fi
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
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name orangepi-5-plus $@
}

zephyr() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/zephyr.sh" orangepi-5-plus --images-dir "${ZEPHYR_IMAGES_DIR}" "$@"
    else
        info "Cleaning Zephyr using common zephyr.sh script"
        bash "${SCRIPT_DIR}/zephyr.sh" orangepi-5-plus clean --images-dir "${ZEPHYR_IMAGES_DIR}"
    fi
}

freertos() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/freertos.sh" orangepi-5-plus
    else
        info "Cleaning FreeRTOS using common freertos.sh script"
        bash "${SCRIPT_DIR}/freertos.sh" orangepi-5-plus clean
    fi
}

uboot() {
    if [[ "$@" != *"clean"* ]]; then
        info "Building U-Boot..."
    else
        info "Cleaning U-Boot build artifacts..."
        rm -rf "${PWD}/build/orangepi/u-boot-work" "${UBOOT_IMAGES_DIR}"
        return
    fi
    build_uboot
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
        uboot)
            uboot "$@"
            ;;
        arceos)
            arceos "$@"
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

            zephyr "$@"

            freertos "$@"
            ;;
        clean)
            linux "clean"

            arceos "clean"

            zephyr "clean"

            freertos "clean"
            ;;
        *)
            die "Unknown command: $cmd" >&2
            ;;
    esac
fi
