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
    printf '  --per-file                        Package each direct child of <dir> into its own archive\n'
    printf '  help, -h, --help                  Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * directory mode packages all direct children of <dir> into one .tar.gz archive.\n'
    printf '  * file mode packages each direct child of <dir> into an individual .tar.gz archive.\n'
    printf '  * Direct children can be either files or directories.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/pack.sh\n'
    printf '  scripts/tools/pack.sh --in_dir IMAGES --out_dir release\n'
    printf '  scripts/tools/pack.sh --per-file --in_dir IMAGES --out_dir release\n'
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

pack_child_paths() {
    local source_dir="$1"
    local child_path

    shopt -s nullglob dotglob
    for child_path in "${source_dir}"/*; do
        [[ -e "${child_path}" ]] || continue
        printf '%s\n' "${child_path}"
    done
    shopt -u nullglob dotglob
}

pack_images() {
    local count_packed=0
    local count_skipped=0
    local input_basename
    local child_path
    local package_stem
    local child_count=0

    mkdir -p "${RELEASE_DIR}"
    input_basename="$(basename "${IMAGES_DIR}")"

    while IFS= read -r child_path; do
        [[ -n "${child_path}" ]] || continue
        child_count=$((child_count + 1))
        if [[ "${PACK_MODE}" == "file" ]]; then
            package_stem="$(basename "${child_path}")"
            pack_path "${child_path}" "${package_stem}"
            count_packed=$((count_packed + 1))
        fi
    done < <(pack_child_paths "${IMAGES_DIR}")

    if [[ ${child_count} -eq 0 ]]; then
        warn "Skipping empty directory ${IMAGES_DIR}"
        count_skipped=$((count_skipped + 1))
    elif [[ "${PACK_MODE}" == "directory" ]]; then
        info "Packing contents of ${IMAGES_DIR} -> ${RELEASE_DIR}/${input_basename}.tar.gz"
        tar -czf "${RELEASE_DIR}/${input_basename}.tar.gz" -C "${IMAGES_DIR}" .
        count_packed=$((count_packed + 1))
    fi

    success "Packaging completed: ${count_packed} archives created, skipped ${count_skipped} empty directories"
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
