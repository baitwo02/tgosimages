#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"
PLATFORM_DIR="${SCRIPTS_DIR}/platform"
OS_DIR="${SCRIPTS_DIR}/os"
ROOTFS_DIR="${SCRIPTS_DIR}/rootfs"
TOOLS_DIR="${SCRIPTS_DIR}/tools"

usage() {
    printf '%s\n' "Usage:"
    printf '%s\n' "  $0 platform <target> [os] [options]"
    printf '%s\n' "  $0 os <target> <platform-or-arch> [options]"
    printf '%s\n' "  $0 rootfs <target> [arch] [options]"
    printf '%s\n' "  $0 release <pack|github> [options]"
    printf '%s\n' "  $0 help | -h | --help"
    printf '%s\n' ""
    printf '%s\n' "Platform Targets:"
    printf '%s\n' "  phytiumpi            -> scripts/platform/phytiumpi.sh"
    printf '%s\n' "  roc-rk3568-pc        -> scripts/platform/roc-rk3568-pc.sh"
    printf '%s\n' "  evm3588              -> scripts/platform/evm3588.sh"
    printf '%s\n' "  tac-e400-plc         -> scripts/platform/tac-e400-plc.sh"
    printf '%s\n' "  orangepi-5-plus      -> scripts/platform/orangepi-5-plus.sh"
    printf '%s\n' "  rdk-s100p            -> scripts/platform/rdk-s100p.sh"
    printf '%s\n' "  bst-a1000            -> scripts/platform/bst-a1000.sh"
    printf '%s\n' "  qemu-aarch64         -> scripts/platform/qemu.sh aarch64"
    printf '%s\n' "  qemu-x86_64          -> scripts/platform/qemu.sh x86_64"
    printf '%s\n' "  qemu-riscv64         -> scripts/platform/qemu.sh riscv64"
    printf '%s\n' "  qemu                 -> build qemu-aarch64, qemu-x86_64, qemu-riscv64 sequentially with rootfs and all os if applicable"
    printf '%s\n' "  all                  -> build all platform targets sequentially with rootfs and all os if applicable"
    printf '%s\n' "  clean                -> clean all platform targets"
    printf '%s\n' ""
    printf '%s\n' "OS Targets:"
    printf '%s\n' "  arceos               -> scripts/os/arceos.sh"
    printf '%s\n' "  zephyr               -> scripts/os/zephyr.sh"
    printf '%s\n' "  freertos             -> scripts/os/freertos.sh"
    printf '%s\n' "  rtthread             -> scripts/os/rtthread.sh"
    printf '%s\n' "  nimbos               -> scripts/os/nimbos.sh"
    printf '%s\n' "  all                  -> build all independent OS targets sequentially"
    printf '%s\n' "  clean                -> clean all independent OS targets"
    printf '%s\n' ""
    printf '%s\n' "Rootfs Targets:"
    printf '%s\n' "  busybox              -> scripts/rootfs/busybox.sh"
    printf '%s\n' "  alpine               -> scripts/rootfs/alpine.sh"
    printf '%s\n' "  debian               -> scripts/rootfs/debian.sh"
    printf '%s\n' "  all                  -> build all rootfs targets sequentially"
    printf '%s\n' "  clean                -> clean all rootfs targets"
    printf '%s\n' ""
    printf '%s\n' "Release:"
    printf '%s\n' "  pack                 -> scripts/tools/pack.sh"
    printf '%s\n' "  github               -> scripts/tools/github.sh"
    printf '%s\n' ""
    printf '%s\n' "Examples:"
    printf '%s\n' "  $0 platform phytiumpi             # show phytiumpi help"
    printf '%s\n' "  $0 platform phytiumpi linux"
    printf '%s\n' "  $0 platform qemu                 # build all qemu architectures with rootfs"
    printf '%s\n' "  $0 platform qemu-aarch64          # show qemu help"
    printf '%s\n' "  $0 platform qemu-aarch64 linux"
    printf '%s\n' "  $0 platform qemu all              # build all qemu architectures with default rootfs"
    printf '%s\n' "  $0 platform qemu all --rootfs alpine,debian"
    printf '%s\n' "  $0 os nimbos aarch64"
    printf '%s\n' "  $0 os arceos aarch64-dyn --bin-name arceos.bin"
    printf '%s\n' "  $0 os all <options>"
    printf '%s\n' "  $0 os clean"
    printf '%s\n' "  $0 rootfs busybox aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs alpine aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs debian riscv64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs all"
    printf '%s\n' "  $0 rootfs all aarch64 --out_dir IMAGES/rootfs"
    printf '%s\n' "  $0 rootfs clean"
    printf '%s\n' "  $0 release pack"
    printf '%s\n' "  $0 release github --token <TOKEN> --repo <owner/repo> --tag <tag>"
}

run_checked_script() {
    local script_path="$1"
    shift || true
    [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
    chmod +x "$script_path" 2>/dev/null || true
    echo "Running: $script_path $*"
    exec "$script_path" "$@"
}

run_script() {
    local script_path="$1"
    shift || true
    run_checked_script "$script_path" "$@"
}

run_platform_target() {
    local target="$1"
    shift || true

    case "$target" in
        phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000)
            local script_path="${PLATFORM_DIR}/${target}.sh"
            if [[ $# -eq 0 ]]; then
                run_checked_script "$script_path"
            fi
            run_checked_script "$script_path" "$@"
            ;;
        qemu-aarch64|qemu-x86_64|qemu-riscv64)
            local arch="${target#qemu-}"
            local script_path="${PLATFORM_DIR}/qemu.sh"
            if [[ $# -eq 0 ]]; then
                run_checked_script "$script_path" "$arch"
            fi
            run_checked_script "$script_path" "$arch" "$@"
            ;;
        qemu)
            local qemu_arches=(aarch64 x86_64 riscv64)
            local extra_args=("$@")

            for arch in "${qemu_arches[@]}"; do
                if [[ ${#extra_args[@]} -eq 0 ]]; then
                    echo "Building: qemu-${arch} all --rootfs busybox,alpine,debian"
                    "$0" platform "qemu-${arch}" all --rootfs busybox,alpine,debian || {
                        echo "[ERROR] qemu-${arch} build failed" >&2
                        exit 1
                    }
                else
                    echo "Building: qemu-${arch} ${extra_args[*]}"
                    "$0" platform "qemu-${arch}" "${extra_args[@]}" || {
                        echo "[ERROR] qemu-${arch} build failed" >&2
                        exit 1
                    }
                fi
            done
            ;;
        all)
            local extra_args=("$@")
            for p in phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000 qemu-aarch64 qemu-x86_64 qemu-riscv64; do
                if [[ ${#extra_args[@]} -eq 0 ]]; then
                    if [[ "$p" == qemu-* ]]; then
                        echo "Building: $p all --rootfs busybox,alpine,debian"
                        "$0" platform "$p" all --rootfs busybox,alpine,debian || { echo "[ERROR] $p build failed" >&2; exit 1; }
                    else
                        echo "Building: $p all"
                        "$0" platform "$p" all || { echo "[ERROR] $p build failed" >&2; exit 1; }
                    fi
                else
                    echo "Building: $p ${extra_args[*]}"
                    "$0" platform "$p" "${extra_args[@]}" || { echo "[ERROR] $p build failed" >&2; exit 1; }
                fi
            done
            ;;
        clean)
            for p in phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p bst-a1000 qemu-aarch64 qemu-x86_64 qemu-riscv64; do
                echo "Cleaning: $p"
                "$0" platform "$p" clean || { echo "[ERROR] $p clean failed" >&2; exit 1; }
            done
            ;;
    esac
}

run_os_target() {
    local target="$1"
    shift || true
    local script_path="${OS_DIR}/${target}.sh"
    run_checked_script "$script_path" "$@"
}

run_rootfs_target() {
    local target="$1"
    shift || true
    local script_path="${ROOTFS_DIR}/${target}.sh"
    run_checked_script "$script_path" "$@"
}

run_release_target() {
    local subcmd="${1:-pack}"
    shift || true

    case "$subcmd" in
        pack)
            run_checked_script "${TOOLS_DIR}/pack.sh" "$@"
            ;;
        github)
            run_checked_script "${TOOLS_DIR}/github.sh" "$@"
            ;;
        *)
            echo "[ERROR] Unknown release subcommand: $subcmd" >&2
            usage
            exit 2
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true

    case "$cmd" in
        help|-h|--help|"")
            usage
            exit 0
            ;;
        platform)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing platform target" >&2; usage; exit 2; }
            case "$target" in
                phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p|bst-a1000|qemu-aarch64|qemu-x86_64|qemu-riscv64|qemu|all|clean)
                    run_platform_target "$target" "$@"
                    ;;
                *)
                    echo "[ERROR] Unknown platform target: $target" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        os)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing OS target" >&2; usage; exit 2; }
            case "$target" in
                all)
                    os_args=("$@")
                    for os_target in arceos zephyr freertos rtthread nimbos; do
                        if [[ ${#os_args[@]} -eq 0 ]]; then
                            echo "Building OS target: $os_target all"
                            "$0" os "$os_target" all || { echo "[ERROR] $os_target build failed" >&2; exit 1; }
                        else
                            echo "Building OS target: $os_target ${os_args[*]}"
                            "$0" os "$os_target" "${os_args[@]}" || { echo "[ERROR] $os_target build failed" >&2; exit 1; }
                        fi
                    done
                    ;;
                clean)
                    for os_target in arceos zephyr freertos rtthread nimbos; do
                        echo "Cleaning OS target: $os_target"
                        "$0" os "$os_target" clean || { echo "[ERROR] $os_target clean failed" >&2; exit 1; }
                    done
                    ;;
                arceos|zephyr|freertos|rtthread|nimbos)
                    run_os_target "$target" "$@"
                    ;;
                *)
                    echo "[ERROR] Unknown independent OS target: $target" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        rootfs)
            target="${1:-}"
            shift || true
            [[ -n "$target" ]] || { echo "[ERROR] Missing rootfs target" >&2; usage; exit 2; }
            case "$target" in
                all)
                    rootfs_args=("$@")
                    if [[ ${#rootfs_args[@]} -eq 0 ]]; then
                        rootfs_args=("all")
                    fi
                    for rootfs_target in busybox alpine debian; do
                        echo "Running rootfs target: $rootfs_target ${rootfs_args[*]}"
                        "$0" rootfs "$rootfs_target" "${rootfs_args[@]}" || { echo "[ERROR] $rootfs_target build failed" >&2; exit 1; }
                    done
                    ;;
                clean)
                    rootfs_args=("$@")
                    for rootfs_target in busybox alpine debian; do
                        echo "Cleaning rootfs target: $rootfs_target ${rootfs_args[*]}"
                        "$0" rootfs "$rootfs_target" clean "${rootfs_args[@]}" || { echo "[ERROR] $rootfs_target clean failed" >&2; exit 1; }
                    done
                    ;;
                busybox|alpine|debian)
                    run_rootfs_target "$target" "$@"
                    ;;
                *)
                    echo "[ERROR] Unknown rootfs target: $target" >&2
                    usage
                    exit 2
                    ;;
            esac
            ;;
        release)
            run_release_target "$@"
            ;;
        cleanall|distclean)
            echo "[CLEANALL] Removing build, IMAGES and release directories"
            rm -rf build IMAGES release
            echo "[CLEANALL] Removed all directories"
            ;;
        *)
            echo "[ERROR] Unknown command or target: $cmd" >&2
            usage
            exit 2
            ;;
    esac
fi
