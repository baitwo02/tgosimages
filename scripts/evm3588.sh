#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Repository and directory configuration
LINUX_REPO_URL=""
LINUX_SRC_DIR="${BUILD_DIR}/evm3588"
LINUX_PATCH_DIR="${ROOT_DIR}/patches/evm3588"
LINUX_IMAGES_DIR="${ROOT_DIR}/IMAGES/evm3588/linux"
ARCEOS_IMAGES_DIR="${ROOT_DIR}/IMAGES/evm3588/arceos"

# Output help information
usage() {
    printf 'Build supported OS for EVM3588 development board\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/evm3588.sh <command> [options]\n'
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
    printf '  scripts/evm3588.sh all            # Build everything\n'
    printf '  scripts/evm3588.sh linux          # Build only Linux\n'
}

build_linux() {
    # Since the Linux SDK from Rockchip is managed by a large repository using repo, and manufacturers usually do not provide online repositories (typically only compressed packages), we log in to a prepared SDK server via SSH for building.
    REMOTE_HOST="10.3.10.194"
    REMOTE_DIR="/share/guest-images/evm3588_linux_sdk_v1.0.3"

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
            info "Building remotely via SSH：ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh $@"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./build.sh $@"

            info "Copying build artifacts: -> $LINUX_IMAGES_DIR"
            mkdir -p "${LINUX_IMAGES_DIR}"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/boot.img" "${LINUX_IMAGES_DIR}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/MiniLoaderAll.bin" "${LINUX_IMAGES_DIR}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/rockdev/parameter.txt" "${LINUX_IMAGES_DIR}/"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${LINUX_IMAGES_DIR}/evm3588"
            scp "${REMOTE_HOST}:${REMOTE_DIR}/kernel/arch/arm64/boot/dts/rockchip/evm3588.dtb" "${LINUX_IMAGES_DIR}/evm3588.dtb"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; building locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./build.sh $@)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./build.sh here as fallback"
                ./build.sh $@
            fi

            info "Copying build artifacts: -> $LINUX_IMAGES_DIR"
            mkdir -p "${LINUX_IMAGES_DIR}"
            cp "${REMOTE_DIR}/rockdev/boot.img" "${LINUX_IMAGES_DIR}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/rockdev/MiniLoaderAll.bin" "${LINUX_IMAGES_DIR}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/rockdev/parameter.txt" "${LINUX_IMAGES_DIR}/" 2>/dev/null || true
            cp "${REMOTE_DIR}/kernel/arch/arm64/boot/Image" "${LINUX_IMAGES_DIR}/evm3588" 2>/dev/null || true
            cp "${REMOTE_DIR}/kernel/arch/arm64/boot/dts/rockchip/evm3588.dtb" "${LINUX_IMAGES_DIR}/evm3588.dtb" 2>/dev/null || true
        fi
    else
        if $is_remote; then
            info "Cleaning remotely via SSH：ssh ${REMOTE_HOST} cd '${REMOTE_DIR}' && ./build.sh cleanall"
            ssh "${REMOTE_HOST}" "cd '${REMOTE_DIR}' && ./build.sh cleanall"
        else
            info "Detected REMOTE_HOST ($REMOTE_HOST) is the current machine; cleaning locally in ${REMOTE_DIR}"
            if [[ -d "$REMOTE_DIR" ]]; then
                (cd "$REMOTE_DIR" && ./build.sh cleanall)
            else
                info "Local REMOTE_DIR ${REMOTE_DIR} not found; running ./build.sh cleanall here as fallback"
                ./build.sh cleanall || true
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
    bash "${SCRIPT_DIR}/arceos.sh" aarch64-dyn --bin-dir "$ARCEOS_IMAGES_DIR" --bin-name evm3588_arceos $@
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