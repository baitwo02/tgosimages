#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

# Repository URLs

# Source directories
LINUX_REPO_URL="https://github.com/torvalds/linux.git"
LINUX_SRC_DIR="${BUILD_DIR}/qemu_linux"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/qemu"
IMAGES_BASE_DIR="${ROOT_DIR}/IMAGES/qemu"
ROOTFS_IMAGES_DIR="${ROOT_DIR}/IMAGES/rootfs"
ROOTFS_BUILDER=""
BUILD_ARGS=()
ROOTFS_STAGE_DIR=""

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
    printf '  --rootfs <busybox|alpine|debian>  Build a rootfs after OS image generation\n'
    printf '\n'
    printf 'Rootfs Packaging:\n'
    printf '  * Rootfs is generated only when --rootfs is specified.\n'
    printf '  * Build outputs from all selected systems are staged together into /guest/<system>/ inside one rootfs.\n'
    printf '  * Generated rootfs artifacts are stored directly under IMAGES/rootfs.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/qemu.sh aarch64 linux     # Build ARM64 Linux\n'
    printf '  scripts/qemu.sh x86_64 arceos     # Build x86_64 ArceOS\n'
    printf '  scripts/qemu.sh riscv64 nimbos    # Build RISC-V NimbOS\n'
    printf '  scripts/qemu.sh riscv64 all       # Build all systems for RISC-V\n'
}

build_rootfs() {
    local rootfs_script="${SCRIPT_DIR}/../rootfs/${ROOTFS_BUILDER}.sh"

    if [ ! -f "${rootfs_script}" ]; then
        die "Root filesystem script does not exist: ${rootfs_script}"
    fi

    mkdir -p "${ROOTFS_IMAGES_DIR}"
    info "Creating root filesystem: ${rootfs_script} -> ${ROOTFS_IMAGES_DIR}"

    case "${ROOTFS_BUILDER}" in
        busybox|debian)
            bash "${rootfs_script}" "${ARCH}" "--out_dir" "${ROOTFS_IMAGES_DIR}" --guest "${ROOTFS_STAGE_DIR}"
            ;;
        alpine)
            bash "${rootfs_script}" "${ARCH}" "--out_dir" "${ROOTFS_IMAGES_DIR}/rootfs-${ARCH}-alpine.img" --guest "${ROOTFS_STAGE_DIR}"
            ;;
        "")
            return 0
            ;;
        *)
            die "Unsupported rootfs builder: ${ROOTFS_BUILDER} (supported: busybox, alpine, debian)"
            ;;
    esac

    success "Root filesystem creation completed"
}

ensure_rootfs_stage_dir() {
    if [[ -n "${ROOTFS_STAGE_DIR}" ]]; then
        return 0
    fi

    ROOTFS_STAGE_DIR="$(mktemp -d "${BUILD_DIR}/qemu-rootfs-${ARCH}.XXXXXX")"
}

stage_rootfs_payload() {
    local system_name="$1"
    local source_dir="$2"
    local payload_dir

    [[ -d "${source_dir}" ]] || die "Payload source directory not found: ${source_dir}"

    ensure_rootfs_stage_dir
    payload_dir="${ROOTFS_STAGE_DIR}/${system_name}"
    rm -rf "${payload_dir}"
    mkdir -p "${payload_dir}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${source_dir}/" "${payload_dir}/"
    else
        cp -a "${source_dir}/." "${payload_dir}/"
    fi

    printf 'system=%s\narch=%s\nsource=%s\n' "${system_name}" "${ARCH}" "${source_dir}" > "${payload_dir}/manifest.txt"
}

package_system_into_rootfs() {
    local system_name="$1"
    local source_dir="$2"

    [[ -n "${ROOTFS_BUILDER}" ]] || return 0

    stage_rootfs_payload "${system_name}" "${source_dir}"
}

finalize_rootfs() {
    [[ -n "${ROOTFS_BUILDER}" ]] || return 0
    [[ -n "${ROOTFS_STAGE_DIR}" && -d "${ROOTFS_STAGE_DIR}" ]] || {
        warn "No guest payload was staged for rootfs generation"
        return 0
    }

    build_rootfs
}

clean_rootfs_outputs() {
    [[ -n "${ROOTFS_BUILDER}" ]] || return 0

    case "${ROOTFS_BUILDER}" in
        busybox)
            rm -f "${ROOTFS_IMAGES_DIR}/initramfs-${ARCH}-busybox.cpio.gz"
            rm -f "${ROOTFS_IMAGES_DIR}/rootfs-${ARCH}-busybox.img"
            ;;
        alpine)
            rm -f "${ROOTFS_IMAGES_DIR}/rootfs-${ARCH}-alpine.img"
            ;;
        debian)
            rm -f "${ROOTFS_IMAGES_DIR}/rootfs-${ARCH}-debian.img"
            ;;
        *)
            die "Unsupported rootfs builder: ${ROOTFS_BUILDER} (supported: busybox, alpine, debian)"
            ;;
    esac
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
            
            package_system_into_rootfs "linux" "${LINUX_IMAGES_DIR}"
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
    bash "${SCRIPT_DIR}/../os/arceos.sh" "$platform" --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name "qemu-${ARCH}" "$@"
    
    if [[ "$@" != *"clean"* ]]; then
        package_system_into_rootfs "arceos" "${ARCEOS_IMAGES_DIR}"
    fi
}

nimbos() {
    local nimbos_images_dir="${IMAGES_BASE_DIR}/${ARCH}/nimbos"

    # Call the nimbos.sh script with proper parameters
    bash "${SCRIPT_DIR}/../os/nimbos.sh" "$ARCH" "--images-dir" "$IMAGES_BASE_DIR" "$@"

    if [[ "$@" != *"clean"* ]]; then
        package_system_into_rootfs "nimbos" "${nimbos_images_dir}"
    fi
}

zephyr() {
    local zephyr_images_dir="${IMAGES_BASE_DIR}/${ARCH}/zephyr"

    if [[ "${ARCH}" != "aarch64" ]]; then
        die "Zephyr guest build is currently only supported for qemu aarch64"
    fi

    bash "${SCRIPT_DIR}/../os/zephyr.sh" qemu-aarch64 --images-dir "${zephyr_images_dir}" "$@"

    if [[ "$@" != *"clean"* ]]; then
        package_system_into_rootfs "zephyr" "${zephyr_images_dir}"
    fi
}

freertos() {
    local freertos_images_dir="${IMAGES_BASE_DIR}/${ARCH}/freertos"

    if [[ "${ARCH}" != "aarch64" ]]; then
        die "FreeRTOS guest build is currently only supported for qemu aarch64"
    fi

    if [[ "$@" != *"clean"* ]]; then
        bash "${SCRIPT_DIR}/../os/freertos.sh" qemu-aarch64
        if [[ -d "${ROOT_DIR}/IMAGES/qemu/freertos" && ! -d "${freertos_images_dir}" ]]; then
            mkdir -p "$(dirname "${freertos_images_dir}")"
            rm -rf "${freertos_images_dir}"
            mv "${ROOT_DIR}/IMAGES/qemu/freertos" "${freertos_images_dir}"
        fi
        package_system_into_rootfs "freertos" "${freertos_images_dir}"
    else
        bash "${SCRIPT_DIR}/../os/freertos.sh" qemu-aarch64 clean
        rm -rf "${freertos_images_dir}" || true
    fi
}

parse_common_args() {
    BUILD_ARGS=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rootfs)
                [[ $# -ge 2 ]] || die "--rootfs requires a value"
                ROOTFS_BUILDER="$2"
                shift 2
                ;;
            *)
                BUILD_ARGS+=("$1")
                shift
                ;;
        esac
    done
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
            parse_common_args "$@"
            trap '[[ -n "${ROOTFS_STAGE_DIR}" ]] && rm -rf "${ROOTFS_STAGE_DIR}"' EXIT
            case "${SYSTEM}" in
                linux)
                    linux "${BUILD_ARGS[@]}"
                    ;;
                arceos)
                    arceos "${BUILD_ARGS[@]}"
                    ;;
                nimbos)
                    nimbos "${BUILD_ARGS[@]}"
                    ;;
                zephyr)
                    zephyr "${BUILD_ARGS[@]}"
                    ;;
                freertos)
                    freertos "${BUILD_ARGS[@]}"
                    ;;
                all)
                    linux "${BUILD_ARGS[@]}"
                    arceos "${BUILD_ARGS[@]}"
                    nimbos "${BUILD_ARGS[@]}"
                    if [[ "${ARCH}" == "aarch64" ]]; then
                        zephyr "${BUILD_ARGS[@]}"
                        freertos "${BUILD_ARGS[@]}"
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
                    clean_rootfs_outputs
                    ;;
                *)
                    die "Unknown system: ${SYSTEM} (supported: linux, arceos, nimbos, zephyr, all)"
                    ;;
            esac
            if [[ "${SYSTEM}" != "clean" ]]; then
                finalize_rootfs
            fi
            trap - EXIT
            [[ -n "${ROOTFS_STAGE_DIR}" ]] && rm -rf "${ROOTFS_STAGE_DIR}"
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
