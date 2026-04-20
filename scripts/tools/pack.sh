#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"
START_DIR="$(pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

IMAGES_DIR="${ROOT_DIR}/IMAGES"
RELEASE_DIR="${ROOT_DIR}/release"

pack_usage() {
    printf 'Package image artifacts into release archives\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/pack.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --in_dir, --input_dir, -i <dir>   Directory containing images (default: IMAGES)\n'
    printf '  --out_dir, --output_dir, -o <dir> Output directory for packaged archives (default: release)\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Packages non-empty image directories into .tar.gz files.\n'
    printf '  * QEMU artifacts are packaged from IMAGES/qemu/<arch>/<system>/ as qemu_<arch>_<system>.tar.gz.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/pack.sh\n'
    printf '  scripts/tools/pack.sh --in_dir IMAGES --out_dir release\n'
}

pack_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --in_dir|--input_dir|-i)
                IMAGES_DIR="$2"
                shift 2
                ;;
            --out_dir|--output_dir|-o)
                RELEASE_DIR="$2"
                shift 2
                ;;
            -h|--help|help)
                pack_usage
                exit 0
                ;;
            *)
                die "Unknown option: $1" 2
                ;;
        esac
    done
}

normalize_dir_path() {
    local dir_path="$1"

    if [[ "${dir_path}" = /* ]]; then
        printf '%s\n' "${dir_path}"
    else
        printf '%s\n' "${START_DIR}/${dir_path}"
    fi
}

pack_directory() {
    local source_dir="$1"
    local package_stem="$2"
    local out_path="${RELEASE_DIR}/${package_stem}.tar.gz"

    info "Packing ${source_dir} -> ${out_path}"
    tar -czf "${out_path}" -C "${source_dir}" .
}

pack_images() {
    local count_packed=0
    local count_skipped=0
    local top
    local mid
    local leaf
    local rel_path
    local pkg_name
    local out_path
    local packaged_any=0

    mkdir -p "${RELEASE_DIR}"
    cd "${IMAGES_DIR}"

    for top in *; do
        [[ -d "${top}" ]] || continue
        if [[ "${top}" == "qemu" ]]; then
            for mid in "${top}"/*; do
                [[ -d "${mid}" ]] || continue
                for leaf in "${mid}"/*; do
                    [[ -d "${leaf}" ]] || continue
                    rel_path="${leaf#${IMAGES_DIR}/}"
                    pkg_name="${rel_path//\//_}.tar.gz"
                    out_path="${RELEASE_DIR}/${pkg_name}"
                    if find "${leaf}" -mindepth 1 | read; then
                        pack_directory "${leaf}" "${rel_path//\//_}"
                        count_packed=$((count_packed + 1))
                        packaged_any=1
                    else
                        warn "Skipping empty directory ${rel_path}"
                        count_skipped=$((count_skipped + 1))
                    fi
                done
            done
        else
            for leaf in "${top}"/*; do
                [[ -d "${leaf}" ]] || continue
                rel_path="${leaf#${IMAGES_DIR}/}"
                pkg_name="${rel_path//\//_}.tar.gz"
                out_path="${RELEASE_DIR}/${pkg_name}"
                if find "${leaf}" -mindepth 1 | read; then
                    pack_directory "${leaf}" "${rel_path//\//_}"
                    count_packed=$((count_packed + 1))
                    packaged_any=1
                else
                    warn "Skipping empty directory ${rel_path}"
                    count_skipped=$((count_skipped + 1))
                fi
            done
        fi
    done

    if [[ ${packaged_any} -eq 0 ]]; then
        if find . -mindepth 1 -maxdepth 1 | read; then
            pack_directory "${IMAGES_DIR}" "$(basename "${IMAGES_DIR}")"
            count_packed=$((count_packed + 1))
        else
            warn "Skipping empty directory $(basename "${IMAGES_DIR}")"
            count_skipped=$((count_skipped + 1))
        fi
    fi

    success "Packaging completed: ${count_packed} directories, skipped ${count_skipped} empty directories"
    cd - >/dev/null
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        pack_usage
        exit 0
    fi

    pack_parse_args "$@"

    IMAGES_DIR="$(normalize_dir_path "${IMAGES_DIR}")"
    RELEASE_DIR="$(normalize_dir_path "${RELEASE_DIR}")"

    if [[ ! -d "${IMAGES_DIR}" ]]; then
        die "Input directory does not exist: ${IMAGES_DIR}"
    fi

    info "Starting to package system images under ${IMAGES_DIR} ..."
    pack_images
fi
