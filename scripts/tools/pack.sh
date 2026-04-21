#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"
START_DIR="$(pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

IMAGES_DIR="${ROOT_DIR}/IMAGES"
RELEASE_DIR="${ROOT_DIR}/release"
PACK_MODE="directory"

pack_usage() {
    printf 'Package image artifacts into release archives\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/pack.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --in_dir, --input_dir, -i <dir>   Directory containing images (default: IMAGES)\n'
    printf '  --out_dir, --output_dir, -o <dir> Output directory for packaged archives (default: release)\n'
    printf '  --mode <directory|file>           Packaging mode (default: directory)\n'
    printf '  --per-file                        Package each file into its own archive\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * directory mode packages non-empty image directories into .tar.gz files.\n'
    printf '  * file mode packages each file into an individual .tar.gz archive.\n'
    printf '  * QEMU artifacts are discovered from IMAGES/qemu/<arch>/<system>/.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/pack.sh\n'
    printf '  scripts/tools/pack.sh --in_dir IMAGES --out_dir release\n'
    printf '  scripts/tools/pack.sh --mode file --in_dir IMAGES --out_dir release\n'
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
            --mode)
                PACK_MODE="$2"
                shift 2
                ;;
            --per-file)
                PACK_MODE="file"
                shift
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

pack_path() {
    local source_path="$1"
    local package_stem="$2"
    local out_path="${RELEASE_DIR}/${package_stem}.tar.gz"

    info "Packing ${source_path} -> ${out_path}"

    if [[ -d "${source_path}" ]]; then
        tar -czf "${out_path}" -C "${source_path}" .
    else
        tar -czf "${out_path}" -C "$(dirname "${source_path}")" "$(basename "${source_path}")"
    fi
}

pack_directory() {
    pack_path "$1" "$2"
}

pack_file() {
    pack_path "$1" "$2"
}

is_valid_pack_mode() {
    case "$1" in
        directory|file)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

pack_files_in_directory() {
    local source_dir="$1"
    local rel_prefix="$2"
    local count_packed_ref="$3"
    local count_skipped_ref="$4"
    local packaged_any_ref="$5"
    local file_path
    local rel_file
    local package_stem
    local packed_any_dir=0

    shopt -s nullglob
    for file_path in "${source_dir}"/*; do
        [[ -f "${file_path}" ]] || continue
        if [[ -n "${rel_prefix}" ]]; then
            rel_file="${rel_prefix}/$(basename "${file_path}")"
        else
            rel_file="$(basename "${file_path}")"
        fi
        package_stem="${rel_file//\//_}"
        pack_file "${file_path}" "${package_stem}"
        printf -v "${count_packed_ref}" '%d' "$(( ${!count_packed_ref} + 1 ))"
        printf -v "${packaged_any_ref}" '%d' 1
        packed_any_dir=1
    done
    shopt -u nullglob

    if [[ ${packed_any_dir} -eq 0 ]]; then
        warn "Skipping directory without files ${rel_prefix}"
        printf -v "${count_skipped_ref}" '%d' "$(( ${!count_skipped_ref} + 1 ))"
    fi
}

pack_images() {
    local count_packed=0
    local count_skipped=0
    local top
    local mid
    local leaf
    local rel_path
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
                    if [[ "${PACK_MODE}" == "file" ]]; then
                        pack_files_in_directory "${leaf}" "${rel_path}" count_packed count_skipped packaged_any
                    elif find "${leaf}" -mindepth 1 | read; then
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
                if [[ "${PACK_MODE}" == "file" ]]; then
                    pack_files_in_directory "${leaf}" "${rel_path}" count_packed count_skipped packaged_any
                elif find "${leaf}" -mindepth 1 | read; then
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
        if [[ "${PACK_MODE}" == "file" ]]; then
            pack_files_in_directory "${IMAGES_DIR}" "" count_packed count_skipped packaged_any
        elif find . -mindepth 1 -maxdepth 1 | read; then
            pack_directory "${IMAGES_DIR}" "$(basename "${IMAGES_DIR}")"
            count_packed=$((count_packed + 1))
        else
            warn "Skipping empty directory $(basename "${IMAGES_DIR}")"
            count_skipped=$((count_skipped + 1))
        fi
    fi

    success "Packaging completed: ${count_packed} archives created, skipped ${count_skipped} empty directories"
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

    if ! is_valid_pack_mode "${PACK_MODE}"; then
        die "Invalid pack mode: ${PACK_MODE}. Supported values: directory, file"
    fi

    if [[ ! -d "${IMAGES_DIR}" ]]; then
        die "Input directory does not exist: ${IMAGES_DIR}"
    fi

    info "Starting to package system images under ${IMAGES_DIR} with mode=${PACK_MODE} ..."
    pack_images
fi
