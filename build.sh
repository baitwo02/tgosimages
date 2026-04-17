#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
PLATFORM_DIR="${SCRIPTS_DIR}/platform"
OS_DIR="${SCRIPTS_DIR}/os"
ROOTFS_DIR="${SCRIPTS_DIR}/rootfs"
TOOLS_DIR="${SCRIPTS_DIR}/tools"

PLATFORMS=(phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000)
QEMU_TARGETS=(qemu-aarch64 qemu-x86_64 qemu-riscv64)
ALL_PLATFORM_TARGETS=("${PLATFORMS[@]}" "${QEMU_TARGETS[@]}")
COMMON_OS_TARGETS=(arceos zephyr freertos rtthread nimbos)
ROOTFS_TARGETS=(busybox alpine)

usage() {
    printf '%s\n' "Usage:"
    printf '%s\n' "  $0 os <target> [options]"
    printf '%s\n' "  $0 rootfs <target> [options]"
    printf '%s\n' "  $0 release [options]"
    printf '%s\n' "  $0 <legacy-target> [options]"
    printf '%s\n' "  $0 help | -h | --help"
    printf '%s\n' ""
    printf '%s\n' "OS targets:"
    printf '%s\n' "  platform targets:"
    printf '%s\n' "    phytiumpi            -> scripts/platform/phytiumpi.sh"
    printf '%s\n' "    roc-rk3568-pc        -> scripts/platform/roc-rk3568-pc.sh"
    printf '%s\n' "    evm3588              -> scripts/platform/evm3588.sh"
    printf '%s\n' "    tac-e400-plc         -> scripts/platform/tac-e400-plc.sh"
    printf '%s\n' "    orangepi-5-plus      -> scripts/platform/orangepi-5-plus.sh"
    printf '%s\n' "    rdk-s100p            -> scripts/platform/rdk-s100p.sh"
    printf '%s\n' "    bst-a1000            -> scripts/platform/bst-a1000.sh"
    printf '%s\n' "    qemu-aarch64         -> scripts/platform/qemu.sh aarch64"
    printf '%s\n' "    qemu-x86_64          -> scripts/platform/qemu.sh x86_64"
    printf '%s\n' "    qemu-riscv64         -> scripts/platform/qemu.sh riscv64"
    printf '%s\n' "    all                  -> build all platform OS targets sequentially"
    printf '%s\n' "    clean                -> clean all platform OS targets"
    printf '%s\n' "  common OS builders:"
    printf '%s\n' "    arceos               -> scripts/os/arceos.sh"
    printf '%s\n' "    zephyr               -> scripts/os/zephyr.sh"
    printf '%s\n' "    freertos             -> scripts/os/freertos.sh"
    printf '%s\n' "    rtthread             -> scripts/os/rtthread.sh"
    printf '%s\n' "    nimbos               -> scripts/os/nimbos.sh"
    printf '%s\n' ""
    printf '%s\n' "Rootfs targets:"
    printf '%s\n' "    busybox              -> scripts/rootfs/busybox.sh"
    printf '%s\n' "    alpine               -> scripts/rootfs/alpine.sh"
    printf '%s\n' ""
    printf '%s\n' "Examples:"
    printf '%s\n' "  $0 os phytiumpi"
    printf '%s\n' "  $0 os qemu-aarch64 linux"
    printf '%s\n' "  $0 os qemu riscv64 all"
    printf '%s\n' "  $0 os arceos aarch64-dyn --bin-name arceos.bin"
    printf '%s\n' "  $0 rootfs busybox aarch64 --out_dir IMAGES/qemu/linux/aarch64"
    printf '%s\n' "  $0 rootfs alpine aarch64 --out_dir IMAGES/qemu/linux/aarch64"
    printf '%s\n' "  $0 release pack"
    printf '%s\n' ""
    printf '%s\n' "Legacy compatibility:"
    printf '%s\n' "  $0 phytiumpi"
    printf '%s\n' "  $0 qemu-aarch64"
    printf '%s\n' "  $0 all"
    printf '%s\n' "  $0 clean"
}

ensure_script() {
    local script_path="$1"
    [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
    chmod +x "$script_path" 2>/dev/null || true
}

run_script() {
    local script_path="$1"
    shift || true
    ensure_script "$script_path"
    echo "Running: $script_path $*"
    exec "$script_path" "$@"
}

run_platform_target() {
    local target="$1"
    shift || true

    case "$target" in
        phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000)
            local script_path="${PLATFORM_DIR}/${target}.sh"
            ensure_script "$script_path"
            if [[ $# -eq 0 ]]; then
                echo "Running: $script_path all"
                exec "$script_path" all
            fi
            echo "Running: $script_path $*"
            exec "$script_path" "$@"
            ;;
        qemu-aarch64|qemu-x86_64|qemu-riscv64)
            local arch="${target#qemu-}"
            local script_path="${PLATFORM_DIR}/qemu.sh"
            ensure_script "$script_path"
            if [[ $# -eq 0 ]]; then
                echo "Running: $script_path $arch all"
                exec "$script_path" "$arch" all
            fi
            echo "Running: $script_path $arch $*"
            exec "$script_path" "$arch" "$@"
            ;;
        qemu)
            local arch="${1:-}"
            shift || true
            [[ -n "$arch" ]] || { echo "[ERROR] qemu requires an architecture: aarch64, x86_64, or riscv64" >&2; exit 2; }
            run_script "${PLATFORM_DIR}/qemu.sh" "$arch" "${@:-all}"
            ;;
        all)
            local extra_args=("$@")
            for p in "${ALL_PLATFORM_TARGETS[@]}"; do
                echo "Building: $p ${extra_args[*]}"
                "$0" os "$p" "${extra_args[@]}" || { echo "[ERROR] $p build failed" >&2; exit 1; }
            done
            ;;
        clean)
            for p in "${ALL_PLATFORM_TARGETS[@]}"; do
                echo "Cleaning: $p"
                "$0" os "$p" clean || { echo "[ERROR] $p clean failed" >&2; exit 1; }
            done
            ;;
        *)
            echo "[ERROR] Unknown OS target: $target" >&2
            usage
            exit 2
            ;;
    esac
}

run_common_os_target() {
    local target="$1"
    shift || true
    local script_path="${OS_DIR}/${target}.sh"
    ensure_script "$script_path"
    if [[ $# -eq 0 ]]; then
        case "$target" in
            arceos|zephyr|freertos|rtthread|nimbos)
                echo "[ERROR] $target requires explicit arguments; see its script usage." >&2
                exit 2
                ;;
        esac
    fi
    echo "Running: $script_path $*"
    exec "$script_path" "$@"
}

run_rootfs_target() {
    local target="$1"
    shift || true

    case "$target" in
        busybox)
            local script_path="${ROOTFS_DIR}/busybox.sh"
            ensure_script "$script_path"
            [[ $# -gt 0 ]] || { echo "[ERROR] busybox requires an architecture argument" >&2; exit 2; }
            echo "Running: $script_path $*"
            exec "$script_path" "$@"
            ;;
        alpine)
            local script_path="${ROOTFS_DIR}/alpine.sh"
            ensure_script "$script_path"
            [[ $# -gt 0 ]] || { echo "[ERROR] alpine requires an architecture argument" >&2; exit 2; }
            echo "Running: $script_path $*"
            exec "$script_path" "$@"
            ;;
        *)
            echo "[ERROR] Unknown rootfs target: $target" >&2
            usage
            exit 2
            ;;
    esac
}

run_release_target() {
    local script_path="${TOOLS_DIR}/release.sh"
    ensure_script "$script_path"
    if [[ $# -eq 0 ]]; then
        exec "$script_path" pack
    fi
    exec "$script_path" "$@"
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true

    case "$cmd" in
        help|-h|--help|"")
            usage
            exit 0
            ;;
        os)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing OS target" >&2; usage; exit 2; }
            if [[ " ${COMMON_OS_TARGETS[*]} " == *" ${target} "* ]]; then
                run_common_os_target "$target" "$@"
            else
                run_platform_target "$target" "$@"
            fi
            ;;
        rootfs)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing rootfs target" >&2; usage; exit 2; }
            run_rootfs_target "$target" "$@"
            ;;
        release)
            run_release_target "$@"
            ;;
        cleanall|distclean)
            echo "[CLEANALL] Removing build, IMAGES and release directories"
            rm -rf build IMAGES release
            echo "[CLEANALL] Removed all directories"
            ;;
        phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000|qemu-aarch64|qemu-x86_64|qemu-riscv64|qemu|all|clean)
            run_platform_target "$cmd" "$@"
            ;;
        arceos|zephyr|freertos|rtthread|nimbos)
            run_common_os_target "$cmd" "$@"
            ;;
        busybox|alpine)
            run_rootfs_target "$cmd" "$@"
            ;;
        *)
            echo "[ERROR] Unknown command or target: $cmd" >&2
            usage
            exit 2
            ;;
    esac
fi
