#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository URLs

# Source directories
LINUX_REPO_URL="https://github.com/torvalds/linux.git"
LINUX_SRC_DIR="${BUILD_DIR}/qemu_linux"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/qemu"
IMAGES_BASE_DIR="${ROOT_DIR}/IMAGES/qemu"
FS_IMAGES_DIR="${ROOT_DIR}/IMAGES/fs"

# Display help information
usage() {
    printf 'Build supported OS for QEMU\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/qemu.sh <command> <system> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  aarch64                           Build all systems for AArch64 architecture\n'
    printf '  x86_64                            Build all systems for x86_64 architecture\n'
    printf '  riscv64                           Build all systems for RISC-V architecture\n'
    printf '  all                               Build all supported architectures and systems\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Systems:\n'
    printf '  linux                             Build the Linux system\n'
    printf '  arceos                            Build the ArceOS system\n'
    printf '  nimbos                            Build the NimbOS system\n'
    printf '  zephyr                            Build the Zephyr guest image (aarch64 only)\n'
    printf '  freertos                          Build the FreeRTOS guest image (aarch64 only)\n'
    printf '  all|""                            Build all systems (default)\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the specific build system\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/qemu.sh aarch64 linux     # Build ARM64 Linux\n'
    printf '  scripts/qemu.sh x86_64 arceos     # Build x86_64 ArceOS\n'
    printf '  scripts/qemu.sh riscv64 nimbos    # Build RISC-V NimbOS\n'
    printf '  scripts/qemu.sh riscv64 all       # Build all systems for RISC-V\n'
}

build_rootfs() {
    if [ ! -f "${SCRIPT_DIR}/mkfs.sh" ]; then
        die "Root filesystem script does not exist: ${SCRIPT_DIR}/mkfs.sh"
    fi
    bash "${SCRIPT_DIR}/mkfs.sh" "${ARCH}" "--out_dir" "${FS_IMAGES_DIR}" --guest "./guest"
    success "Root filesystem creation completed"
}

build_linux() {
    local commands=("$@")
    case "${ARCH}" in
        aarch64)
            local linux_arch="arm64"
            local cross_compile="${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}"
            local defconfig="defconfig"
            local kimg_subpath="arch/arm64/boot/Image"
            ;;
        riscv64)
            local linux_arch="riscv"
            local cross_compile="${RISCV64_CROSS_COMPILE:-riscv64-linux-gnu-}"
            local defconfig="defconfig"
            local kimg_subpath="arch/riscv/boot/Image"
            ;;
        x86_64)
            local linux_arch="x86"
            local cross_compile="${X86_CROSS_COMPILE:-}"
            local defconfig="x86_64_defconfig"
            local kimg_subpath="arch/x86/boot/bzImage"
            ;;
        *)
            die "Unsupported Linux architecture: ${ARCH}"
            ;;
    esac
    
    pushd "${LINUX_SRC_DIR}" >/dev/null

    # info "Cleaning Linux: make distclean"
    # make distclean || true

    if [[ "$@" != *"clean"* ]]; then
        if [[ ${#commands[@]} -eq 0 ]] || [[ "${commands[0]}" == "all" ]]; then
            info "Configuring Linux: make ARCH=${linux_arch} CROSS_COMPILE=${cross_compile} ${defconfig}"
            make ARCH="${linux_arch}" CROSS_COMPILE="${cross_compile}" "${defconfig}"
        fi
        
        info "Building Linux: make -j$(nproc) ARCH=${linux_arch} CROSS_COMPILE=${cross_compile} ${commands[@]}"
        make -j"$(nproc)" ARCH="${linux_arch}" CROSS_COMPILE="${cross_compile}" "${commands[@]}"
        
        popd >/dev/null

        # If it's a full build, copy the image and create the root filesystem
        if [[ ${#commands[@]} -eq 0 ]] || [[ "${commands[0]}" == "all" ]]; then
            LINUX_IMAGES_DIR="${IMAGES_BASE_DIR}/${ARCH}/linux"
            mkdir -p "${LINUX_IMAGES_DIR}"
            KIMG_PATH="${LINUX_SRC_DIR}/${kimg_subpath}"
            [[ -f "${KIMG_PATH}" ]] || die "Kernel image not found: ${KIMG_PATH}"
            info "Copying image: ${KIMG_PATH} -> ${LINUX_IMAGES_DIR}/qemu-${ARCH}"
            cp -f "${KIMG_PATH}" "${LINUX_IMAGES_DIR}/qemu-${ARCH}"
            
            FS_IMAGES_DIR=${LINUX_IMAGES_DIR}
            info "Creating root filesystem: ${SCRIPT_DIR}/mkfs.sh -> ${FS_IMAGES_DIR}"
            build_rootfs
        fi
    else
        info "Building Linux: make -j$(nproc) ARCH=${linux_arch} CROSS_COMPILE=${cross_compile} clean"
        make -j"$(nproc)" ARCH="${linux_arch}" CROSS_COMPILE="${cross_compile}" "clean"
        LINUX_IMAGES_DIR="${IMAGES_BASE_DIR}/${ARCH}/linux"
        info "Removing ${LINUX_IMAGES_DIR}/*"
        rm -rf ${LINUX_IMAGES_DIR}/* || true
    fi
}

linux() {
    info "Cloning ${ARCH} Linux source repository $LINUX_REPO_URL"
    clone_repository "$LINUX_REPO_URL" "$LINUX_SRC_DIR"

    info "Applying patches..."
    apply_patches "$LINUX_PATCH_DIR" "$LINUX_SRC_DIR"

    info "Starting to build ${ARCH} Linux system..."
    build_linux "$@"
}

arceos() {
    case "${ARCH}" in
        aarch64)
            local platform="aarch64-dyn"
            ;;
        riscv64)
            local platform="riscv64-qemu-virt"
            ;;
        x86_64)
            local platform="x86-pc"
            ;;
        *)
            die "Unsupported ArceOS architecture: ${ARCH}"
            ;;
    esac

    ARCEOS_IMAGES_DIR="${IMAGES_BASE_DIR}/${ARCH}/arceos"
    info "Building ArceOS using common arceos.sh script for platform: $platform -> $ARCEOS_IMAGES_DIR"
    
    # Call the arceos.sh script with proper parameters
    bash "${SCRIPT_DIR}/arceos.sh" "$platform" --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name "qemu-${ARCH}" "$@"
    
    if [[ "$@" != *"clean"* ]]; then
        FS_IMAGES_DIR=${ARCEOS_IMAGES_DIR}
        info "Creating root filesystem: ${SCRIPT_DIR}/mkfs.sh -> ${FS_IMAGES_DIR}"
        build_rootfs
    fi
}

nimbos() {
    # Call the nimbos.sh script with proper parameters
    bash "${SCRIPT_DIR}/nimbos.sh" "$ARCH" "--images-dir" "$IMAGES_BASE_DIR" "$@"
}

zephyr() {
    if [[ "${ARCH}" != "aarch64" ]]; then
        die "Zephyr guest build is currently only supported for qemu aarch64"
    fi

    bash "${SCRIPT_DIR}/zephyr.sh" qemu-aarch64 --images-dir "${IMAGES_BASE_DIR}/${ARCH}/zephyr" "$@"
}

freertos() {
    if [[ "${ARCH}" != "aarch64" ]]; then
        die "FreeRTOS guest build is currently only supported for qemu aarch64"
    fi

    if [[ "$@" != *"clean"* ]]; then
        bash "${SCRIPT_DIR}/freertos.sh" qemu
    else
        bash "${SCRIPT_DIR}/freertos.sh" qemu clean
    fi
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift 1 || true
    case "${cmd}" in
        ""|help|-h|--help)
            usage
            exit 0
            ;;
        aarch64|riscv64|x86_64)
            ARCH="$cmd"
            SYSTEM="${1:-all}"
            shift 1 || true
            case "${SYSTEM}" in
                linux)
                    linux "$@"
                    ;;
                arceos)
                    arceos "$@"
                    ;;
                nimbos)
                    nimbos "$@"
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
                    nimbos "$@"
                    if [[ "${ARCH}" == "aarch64" ]]; then
                        zephyr "$@"
                        freertos "$@"
                    fi
                    ;;
                clean)
                    linux "clean"
                    arceos "clean"
                    nimbos "clean"
                    if [[ "${ARCH}" == "aarch64" ]]; then
                        zephyr "clean"
                        freertos "clean"
                    fi
                    ;;
                *)
                    die "Unknown system: ${SYSTEM} (supported: linux, arceos, nimbos, zephyr, all)"
                    ;;
            esac
            ;;
        all)
            for arch in aarch64 riscv64 x86_64; do
                "$0" "$arch" "$@" || { echo "[ERROR] $arch build failed" >&2; exit 1; }
            done
            ;;
        clean)
            for arch in aarch64 riscv64 x86_64; do
                "$0" "$arch" "clean" || { echo "[ERROR] $arch build failed" >&2; exit 1; }
            done
            ;;
        *)
        die "Unknown command: $cmd" >&2
        ;;
    esac
fi
