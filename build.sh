#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
SCRIPTS_DIR="${SCRIPT_DIR}/scripts"

usage() {
    printf '%s\n' "Usage:"
    printf '%s\n' "$0 <command> [OS] [options]"
    printf '%s\n' "$0 help | -h | --help"
    printf '%s\n' ""
    printf '%s\n' "Commands:"
    printf '%s\n' "    phytiumpi            -> scripts/phytiumpi.sh"
    printf '%s\n' "    roc-rk3568-pc        -> scripts/roc-rk3568-pc.sh"
    printf '%s\n' "    evm3588              -> scripts/evm3588.sh"
    printf '%s\n' "    tac-e400-plc         -> scripts/tac-e400-plc.sh"
    printf '%s\n' "    orangepi-5-plus      -> scripts/orangepi-5-plus.sh"
    printf '%s\n' "    rdk-s100p            -> scripts/rdk-s100p.sh"
    printf '%s\n' "    bst-a1000            -> scripts/bst-a1000.sh"
    printf '%s\n' "    qemu-aarch64         -> scripts/qemu.sh aarch64"
    printf '%s\n' "    qemu-x86_64          -> scripts/qemu.sh x86_64"
    printf '%s\n' "    qemu-riscv64         -> scripts/qemu.sh riscv64"
    printf '%s\n' "    release              -> scripts/release.sh"
    printf '%s\n' "    all                  -> build all platforms sequentially"
    printf '%s\n' "    clean                Clean build output artifacts"
    printf '%s\n' "    cleanall|distclean   Remove all directories"
    printf '%s\n' ""
    printf '%s\n' "OS:"
    printf '%s\n' "    linux                build linux kernel"
    printf '%s\n' "    arceos               build ArceOS"
    printf '%s\n' "    zephyr               build Zephyr guest image"
    printf '%s\n' "    freertos             build FreeRTOS guest image"
    printf '%s\n' "    all|''               build all supported OSes, if not specified"
    printf '%s\n' "    clean                Clean build output artifacts"
    printf '%s\n' ""
    printf '%s\n' "Options:"
    printf '%s\n' "    All options will be passed to the underlying script"
    printf '%s\n' ""
    printf '%s\n' "Examples:"
    printf '%s\n' "    $0 phytiumpi"
    printf '%s\n' "    $0 roc-rk3568-pc"
    printf '%s\n' "    $0 qemu-aarch64"
    printf '%s\n' "    $0 all"
    printf '%s\n' ""
    printf '%s\n' "Environment passthrough: All current env vars are forwarded."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "${cmd}" in
        help|-h|--help|"")
            usage
            exit 0
            ;;
        phytiumpi|roc-rk3568-pc|evm3588|tac-e400-plc|orangepi-5-plus|rdk-s100p)
            script_path="${SCRIPTS_DIR}/${cmd}.sh"
            [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
            chmod +x "$script_path" 2>/dev/null || true
            if [ $# -eq 0 ]; then
                echo "Running: $script_path" "all"
                exec "$script_path" "all"
            else
                echo "Running: $script_path" "$@"
                exec "$script_path" "$@"
            fi
            ;;
        qemu-aarch64|qemu-x86_64|qemu-riscv64)
            str="${cmd}" && prefix="${str%-*}" && arch="${str#*-}"
            script_path="${SCRIPTS_DIR}/${prefix}.sh"
            [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
            chmod +x "$script_path" 2>/dev/null || true
            if [ $# -eq 0 ]; then
                echo "Running: $script_path" "${arch}" "all"
                exec "$script_path" "${arch}" "all"
            else
                echo "Running: $script_path" "${arch}" "$@"
                exec "$script_path" "${arch}" "$@"
            fi
            ;;
        all|clean)
            platforms=(phytiumpi roc-rk3568-pc evm3588 tac-e400-plc orangepi-5-plus rdk-s100p qemu-aarch64 qemu-x86_64 qemu-riscv64)
            for p in "${platforms[@]}"; do
                if [[ "$cmd" == "all" ]]; then
                    echo "Building: $p $*"
                    "$0" "$p" "$@" || { echo "[ERROR] $p build failed" >&2; exit 1; }
                else
                    echo "Cleaning: $p $*"
                    "$0" "$p" "clean" || { echo "[ERROR] $p clean failed" >&2; exit 1; }
                fi
            done
            ;;
        cleanall|distclean)
            echo "[CLEANALL] Removing build, IMAGES and release directories"
            rm -rf build IMAGES release
            echo "[CLEANALL] Removed all directories"
            ;;
        release)
            script_path="${SCRIPTS_DIR}/release.sh"
            [[ -f "$script_path" ]] || { echo "[ERROR] Script not found: $script_path" >&2; exit 1; }
            chmod +x "$script_path" 2>/dev/null || true
            if [ $# -eq 0 ]; then
                exec "$script_path" "pack"
            else
                exec "$script_path" "$@"
            fi
            ;;
        *)
            echo "[ERROR] Unknown platform: $cmd" >&2
            usage
            exit 2
            ;;
    esac
fi
