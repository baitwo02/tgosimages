#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

GITHUB_TOKEN=""
REPO="arceos-hypervisor/axvisor-guest"
TAG="v0.0.10"
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
    printf '  --dir <asset_dir>           Directory of release assets (default: release)\n'
    printf '  --pack                      Run scripts/tools/pack.sh before publishing\n'
    printf '  help, -h, --help            Display this help information\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/tools/github.sh --token <TOKEN> --repo owner/repo --tag v1.0.0 --dir release\n'
    printf '  scripts/tools/github.sh --pack --token <TOKEN> --repo owner/repo --tag v1.0.0\n'
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
            --dir)
                ASSET_DIR="$2"
                shift 2
                ;;
            --pack)
                PACK_BEFORE_PUBLISH=1
                shift
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
        echo "${response_body}" | grep -oP '"upload_url":\s*"\K[^"{]+'
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

    if [[ "${PACK_BEFORE_PUBLISH}" -eq 1 ]]; then
        info "Packing release assets before publishing..."
        bash "${SCRIPT_DIR}/pack.sh" --in_dir "${ROOT_DIR}/IMAGES" --out_dir "${ASSET_DIR}"
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
    info "Asset directory: ${ASSET_DIR}"
    info "Number of asset files: $(find "${ASSET_DIR}" -maxdepth 1 -type f | wc -l)"
    info "Creating release..."

    upload_url=$(github_create_release "${REPO}" "${TAG}") || exit 1
    [[ -n "${upload_url}" ]] || die "Failed to create release"

    success "Release created successfully"
    info "Starting to upload asset files..."

    uploaded_count=0
    shopt -s nullglob dotglob
    files=("${ASSET_DIR}"/*)
    if [[ ${#files[@]} -eq 0 ]]; then
        warn "Asset directory is empty, no files to upload."
    else
        for file in "${files[@]}"; do
            if [[ -f "${file}" ]]; then
                if github_upload "${upload_url}" "${file}"; then
                    ((uploaded_count++))
                fi
            fi
        done
    fi
    shopt -u nullglob dotglob

    success "Number of files uploaded: ${uploaded_count}"
    info "Release URL: https://github.com/${REPO}/releases/tag/${TAG}"
fi
