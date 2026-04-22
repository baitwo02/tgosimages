#!/usr/bin/env bash

set -euo pipefail

TOOLS_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${TOOLS_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"
START_DIR="$(pwd -P)"

source "${TOOLS_DIR}/../lib/utils.sh"

GITHUB_TOKEN=""
REPO="arceos-hypervisor/axvisor-guest"
TAG="v0.0.10"
PACK_INPUT_DIR="${ROOT_DIR}/IMAGES"
ASSET_DIR="${ROOT_DIR}/release"
PACK_BEFORE_PUBLISH=0

github_usage() {
    printf 'Publish release assets to GitHub Releases\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/github.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --token <GITHUB_TOKEN>      GitHub access token (required)\n'
    printf '  --repo <owner/repo>         GitHub repository (required)\n'
    printf '  --tag <tag>                 Release tag (required)\n'
    printf '  --pack [in_dir,out_dir]     Pack in_dir, then publish files from out_dir\n'
    printf '  help, -h, --help            Display this help information\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * --pack defaults to IMAGES,release when no value is provided.\n'
    printf '  * --pack first runs scripts/tools/pack.sh with <in_dir> and <out_dir>.\n'
    printf '  * After packing, github.sh publishes the files currently present in <out_dir>.\n'
    printf '  * If the release tag already exists, the existing release is reused.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/github.sh --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
    printf '  scripts/tools/github.sh --pack --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
    printf '  scripts/tools/github.sh --pack IMAGES,release --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
}

parse_pack_spec() {
    local pack_spec="$1"
    local in_dir=""
    local out_dir=""

    IFS=',' read -r in_dir out_dir <<< "${pack_spec}"

    [[ -n "${in_dir}" ]] && PACK_INPUT_DIR="${in_dir}"
    [[ -n "${out_dir}" ]] && ASSET_DIR="${out_dir}"
}

github_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --token)
                GITHUB_TOKEN="$2"
                shift 2
                ;;
            --repo)
                REPO="$2"
                shift 2
                ;;
            --tag)
                TAG="$2"
                shift 2
                ;;
            --pack)
                PACK_BEFORE_PUBLISH=1
                if [[ $# -ge 2 && "${2}" != --* ]]; then
                    parse_pack_spec "$2"
                    shift 2
                else
                    shift
                fi
                ;;
            -h|--help|help)
                github_usage
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

github_extract_upload_url() {
    local response_body="$1"
    echo "${response_body}" | grep -oP '"upload_url":\s*"\K[^"{]+'
}

github_get_release_upload_url() {
    local repo="$1"
    local tag="$2"
    local response
    local status_code
    local response_body

    response=$(curl -s -w "%{http_code}" "https://api.github.com/repos/${repo}/releases/tags/${tag}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 200 ]]; then
        github_extract_upload_url "${response_body}"
        return 0
    fi

    return 1
}

github_create_release() {
    local repo="$1"
    local tag="$2"
    local response
    local status_code
    local response_body

    response=$(curl -s -w "%{http_code}" -X POST "https://api.github.com/repos/${repo}/releases" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Accept: application/vnd.github.v3+json" \
        -d "{\"tag_name\": \"${tag}\", \"name\": \"Release ${tag}\", \"body\": \"Auto-generated release\", \"draft\": false, \"prerelease\": false}")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 201 ]]; then
        github_extract_upload_url "${response_body}"
        return 0
    fi

    warn "Failed to create release (HTTP ${status_code})"
    echo "${response_body}" >&2
    return 1
}

github_upload() {
    local base_url="$1"
    local file_path="$2"
    local file_name
    local upload_url
    local response
    local status_code
    local response_body

    file_name=$(basename "${file_path}")
    upload_url="${base_url%%\{*}?name=${file_name}"

    response=$(curl -s -w "%{http_code}" -X POST "${upload_url}" \
        -H "Authorization: token ${GITHUB_TOKEN}" \
        -H "Content-Type: application/octet-stream" \
        -H "Accept: application/vnd.github.v3+json" \
        --data-binary @"${file_path}")
    status_code=${response: -3}
    response_body=${response:0:${#response}-3}

    if [[ "${status_code}" -eq 201 ]]; then
        success "Upload successful: ${upload_url}"
        return 0
    fi

    warn "Upload failed: ${upload_url} (HTTP ${status_code})"
    echo "${response_body}" >&2
    return 1
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    if [[ $# -eq 0 ]]; then
        github_usage
        exit 0
    fi

    github_parse_args "$@"
    PACK_INPUT_DIR="$(normalize_dir_path "${PACK_INPUT_DIR}")"
    ASSET_DIR="$(normalize_dir_path "${ASSET_DIR}")"

    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 && ! -d "${PACK_INPUT_DIR}" ]]; then
        die "Input directory does not exist: ${PACK_INPUT_DIR}"
    fi

    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 ]]; then
        local_pack_args=(--in_dir "${PACK_INPUT_DIR}" --out_dir "${ASSET_DIR}")
        info "Packing release assets before publishing..."
        bash "${TOOLS_DIR}/pack.sh" "${local_pack_args[@]}"
    fi

    if [[ -z "${GITHUB_TOKEN}" ]]; then
        die "GITHUB_TOKEN must be set via --token"
    fi
    if [[ -z "${REPO}" ]]; then
        die "REPO must be set via --repo"
    fi
    if [[ -z "${TAG}" ]]; then
        die "TAG must be set via --tag"
    fi
    if [[ ! -d "${ASSET_DIR}" ]]; then
        die "Asset directory does not exist: ${ASSET_DIR}"
    fi

    info "GitHub repository: ${REPO}"
    info "Release tag: ${TAG}"
    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 ]]; then
        info "Pack input directory: ${PACK_INPUT_DIR}"
    fi
    info "Asset directory: ${ASSET_DIR}"
    info "Number of asset files: $(find "${ASSET_DIR}" -maxdepth 1 -type f | wc -l)"
    info "Resolving release..."

    upload_url="$(github_get_release_upload_url "${REPO}" "${TAG}" || true)"
    if [[ -n "${upload_url}" ]]; then
        success "Using existing release for tag ${TAG}"
    else
        info "Creating release..."
        upload_url=$(github_create_release "${REPO}" "${TAG}") || exit 1
        success "Release created successfully"
    fi
    [[ -n "${upload_url}" ]] || die "Failed to create release"
    info "Starting to upload asset files..."

    uploaded_count=0
    skipped_count=0
    shopt -s nullglob dotglob
    files=("${ASSET_DIR}"/*)
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Asset directory is empty, no files to upload."
    else
        IFS=$'\n' files=($(printf '%s\n' "${files[@]}" | sort))
        for file in "${files[@]}"; do
            if [[ -f "${file}" ]]; then
                if github_upload "${upload_url}" "${file}"; then
                    ((uploaded_count++))
                fi
            else
                warn "Skipping non-file asset: ${file}"
                ((skipped_count++))
            fi
        done
    fi
    shopt -u nullglob dotglob

    success "Number of files uploaded: ${uploaded_count}"
    if [[ "${skipped_count}" -gt 0 ]]; then
        warn "Number of skipped non-file assets: ${skipped_count}"
    fi
    info "Release URL: https://github.com/${REPO}/releases/tag/${TAG}"
fi
