#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL=""
LINUX_SRC_DIR="${BUILD_DIR}/rdk-s100p"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/rdk-s100p"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/rdk-s100p/linux"

# Apply patches to defconfig and uboot config (remote via SSH)
apply_patches_remote() {
    local patch_dir="$1"
    local remote_host="$2"
    local remote_dir="$3"
    
    if [[ ! -d "${patch_dir}" ]]; then
        info "No patch directory: ${patch_dir}"
        return 0
    fi
    
    shopt -s nullglob
    local patch_files=("${patch_dir}"/*.patch)
    if (( ${#patch_files[@]} == 0 )); then
        info "No patch files in ${patch_dir}"
        return 0
    fi
    
    info "Found ${#patch_files[@]} patch file(s)"
    
    for patch_file in "${patch_files[@]}"; do
        [[ -f "$patch_file" ]] || continue
        local base=$(basename "$patch_file")
        local stamp_dir="${remote_dir}/.patch_stamps"
        
        # Create stamp directory and check if already applied
        ssh "${remote_host}" "mkdir -p '${stamp_dir}'"
        if ssh "${remote_host}" "[ -f '${stamp_dir}/${base}.applied' ]"; then
            info "[SKIP] ${base} (already applied)"
            continue
        fi
        
        info "[APPLY] ${base}"
        
        # Try patch -p1 first, then patch -p0
        local applied=0
        for plevel in 1 0; do
            if ssh "${remote_host}" "cd '${remote_dir}' && patch -p${plevel} --dry-run" < "${patch_file}" >/dev/null 2>&1; then
                if ssh "${remote_host}" "cd '${remote_dir}' && patch -p${plevel}" < "${patch_file}"; then
                    ssh "${remote_host}" "touch '${stamp_dir}/${base}.applied'"
                    applied=1
                    info "  patch -p${plevel} applied"
                    break
                fi
            fi
        done
        
        if [[ $applied -eq 0 ]]; then
            warn "Failed to apply ${base}"
        fi
    done
}

ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/rdk-s100p/arceos"

# Output help information
usage() {
    printf 'Build supported OS for RDK S100P development board\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rdk-s100p.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  all                               Build all supported OS\n'
    printf '  linux                             Build Linux kernel and U-Boot\n'
    printf '  arceos                            Build only the ArceOS system\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '  clean                             Clean build output artifacts\n'
    printf '\n'
    printf 'Options:\n'
    printf '  Optional, all options will be directly passed to the build system of OS\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rdk-s100p.sh all          # Build everything\n'
    printf '  scripts/rdk-s100p.sh linux        # Build only Linux\n'
}

build_linux() {
    # RDK S100P SDK is located at /share/guest-images/rdk_s100p
    REMOTE_HOST="10.3.10.194"
    REMOTE_DIR="/share/guest-images/rdk_s100p"
    BOOTLOADER_DIR="${REMOTE_DIR}/source/bootloader"
    KERNEL_DTB_REL="out/build/kernel/arch/arm64/boot/dts/hobot/rdk-s100p-v1p0.dtb"

    # Determine local IP addresses (IPv4) to detect if we are on REMOTE_HOST.
    # We collect all non-loopback IPv4 addresses assigned to the host.
    mapfile -t _local_ips < <(ip -4 -o addr show scope global | awk '{print $4}' | cut -d/ -f1)

    is_remote=true
    for ipaddr in "${_local_ips[@]:-}"; do
        if [[ "$ipaddr" == "$REMOTE_HOST" ]]; then
            is_remote=false
            break
        fi
    done

    if [[ "$@" != *"clean"* ]]; then
        if $is_remote; then
            # Apply patches before build
            apply_patches_remote "${LINUX_PATCH_DIR}" "${REMOTE_HOST}" "${REMOTE_DIR}"
            
            # Build kernel
            info "Building kernel remotely via SSH"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./mk_kernel.sh"

            # Build uboot
            info "Building uboot remotely via SSH"
            # Create img_packages directory before build (mk_hb_img.py doesn't create it)
            ssh "${REMOTE_HOST}" "mkdir -p '${BOOTLOADER_DIR}/out/target/product/img_packages'"
            ssh "${REMOTE_HOST}" "cd '${BOOTLOADER_DIR}/build' && ./xbuild.sh lunch 1 && ./xbuild.sh uboot && ./xbuild.sh pack"

            # Copy kernel and uboot artifacts
            info "Copying build artifacts: -> $LINUX_IMAGES_DIR"
            mkdir -p "${LINUX_IMAGES_DIR}"
            # Copy kernel image
            scp "${REMOTE_HOST}:${REMOTE_DIR}/out/build/kernel/arch/arm64/boot/Image" "${LINUX_IMAGES_DIR}/rdk-s100p" || true
            # Copy built kernel dtb needed for release
            scp "${REMOTE_HOST}:${REMOTE_DIR}/${KERNEL_DTB_REL}" "${LINUX_IMAGES_DIR}/" || true
            # Copy uboot.img
            scp "${REMOTE_HOST}:${BOOTLOADER_DIR}/out/target/product/img_packages/uboot.img" "${LINUX_IMAGES_DIR}/" || true
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; building locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                # Apply patches before build (locally)
                apply_patches "${LINUX_PATCH_DIR}" "${REMOTE_DIR}"
                
                # Build kernel
                info "Building kernel locally"
                (cd "$REMOTE_DIR" && ./mk_kernel.sh)

                # Build uboot
                info "Building uboot locally"
                # Create img_packages directory before build (mk_hb_img.py doesn't create it)
                mkdir -p "${BOOTLOADER_DIR}/out/target/product/img_packages"
                (cd "${BOOTLOADER_DIR}/build" && ./xbuild.sh lunch 1 && ./xbuild.sh uboot && ./xbuild.sh pack)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./mk_kernel.sh here as fallback"
                ./mk_kernel.sh
            fi

            # Copy kernel and uboot artifacts
            info "Copying build artifacts: -> $LINUX_IMAGES_DIR"
            mkdir -p "${LINUX_IMAGES_DIR}"
            # Copy kernel image
            cp "${REMOTE_DIR}/out/build/kernel/arch/arm64/boot/Image" "${LINUX_IMAGES_DIR}/rdk-s100p" 2>/dev/null || true
            # Copy built kernel dtb needed for release
            cp "${REMOTE_DIR}/${KERNEL_DTB_REL}" "${LINUX_IMAGES_DIR}/" 2>/dev/null || true
            # Copy uboot.img
            cp "${BOOTLOADER_DIR}/out/target/product/img_packages/uboot.img" "${LINUX_IMAGES_DIR}/" 2>/dev/null || true
        fi
    else
        if $is_remote; then
            info "Cleaning kernel and uboot remotely via SSH"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./mk_kernel.sh clean"
            ssh "${REMOTE_HOST}" "cd '${BOOTLOADER_DIR}/build' && ./xbuild.sh uboot clean"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; cleaning locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./mk_kernel.sh clean)
                (cd "${BOOTLOADER_DIR}/build" && ./xbuild.sh uboot clean)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./mk_kernel.sh clean here as fallback"
                ./mk_kernel.sh clean || true
            fi
        fi

        info "Removing ${LINUX_IMAGES_DIR}/*"
        rm -f ${LINUX_IMAGES_DIR}/* || true
    fi
}

linux() {
    if [[ "$@" != *"clean"* ]]; then
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
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name rdk-s100p $@
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
