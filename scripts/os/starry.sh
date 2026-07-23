#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p build && cd build && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

STARRY_REPO_URL="${STARRY_REPO_URL:-https://github.com/rcore-os/tgoskits.git}"
STARRY_REF="${STARRY_REF:-dev}"
STARRY_SRC_DIR="${STARRY_SRC_DIR:-${BUILD_DIR}/tgoskits-starry}"
STARRY_IMAGES_DIR="${ROOT_DIR}/IMAGES/starry"
STARRY_RELEASE_IMAGES_DIR="${ROOT_DIR}/IMAGES/orangepi-5-plus-starry"
STARRY_IMAGE_NAME="orangepi-5-plus"
STARRY_CONFIG="os/StarryOS/configs/board/orangepi-5-plus.toml"
STARRY_ARGS=()

starry_usage() {
    cat <<'EOF'
Build a StarryOS guest kernel from tgoskits

Usage:
  scripts/os/starry.sh orangepi-5-plus [options]
  scripts/os/starry.sh clean [options]

Options:
  --repo-url <url>             tgoskits repository URL
  --ref <commit-or-ref>        tgoskits commit/ref (default: latest dev)
  --src-dir <dir>              source checkout (default: build/tgoskits-starry)
  --config <path>              config path relative to tgoskits
  --images-dir <dir>           guest-layout output directory
  --release-images-dir <dir>   independent release staging directory
  --image-name <name>          output image name

Unknown options are passed to `cargo xtask starry build`.
EOF
}

starry_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)
                STARRY_REPO_URL="$2"
                shift 2
                ;;
            --ref)
                STARRY_REF="$2"
                shift 2
                ;;
            --src-dir)
                STARRY_SRC_DIR="$2"
                shift 2
                ;;
            --config|-c)
                STARRY_CONFIG="$2"
                shift 2
                ;;
            --images-dir)
                STARRY_IMAGES_DIR="$2"
                shift 2
                ;;
            --release-images-dir)
                STARRY_RELEASE_IMAGES_DIR="$2"
                shift 2
                ;;
            --image-name)
                STARRY_IMAGE_NAME="$2"
                shift 2
                ;;
            *)
                STARRY_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

starry_write_release_metadata() {
    local image_path="$1"
    local output_dir="$2"
    local source_commit="$3"

    mkdir -p "${output_dir}"
    install -m 0644 "${image_path}" "${output_dir}/${STARRY_IMAGE_NAME}"
    (
        cd "${output_dir}"
        sha256sum "${STARRY_IMAGE_NAME}" > SHA256SUMS
    )
    cat > "${output_dir}/manifest.toml" <<EOF
schema_version = 1
os = "starry"
platform = "orangepi-5-plus"
arch = "aarch64"
image = "${STARRY_IMAGE_NAME}"
source_repository = "${STARRY_REPO_URL}"
source_commit = "${source_commit}"
build_config = "${STARRY_CONFIG}"
EOF
}

starry_build() {
    local config_path
    local artifact_path
    local artifact_candidate
    local source_commit
    local build_cmd

    clone_repository "${STARRY_REPO_URL}" "${STARRY_SRC_DIR}"
    if [[ "${STARRY_REF}" == "dev" ]]; then
        info "Fetching latest tgoskits dev branch"
        git -C "${STARRY_SRC_DIR}" fetch --quiet --no-tags --depth=1 origin dev
        checkout_ref "${STARRY_SRC_DIR}" FETCH_HEAD
    else
        checkout_ref "${STARRY_SRC_DIR}" "${STARRY_REF}"
    fi

    config_path="${STARRY_SRC_DIR}/${STARRY_CONFIG}"
    [[ -f "${config_path}" ]] || die "StarryOS build config not found: ${config_path}"

    build_cmd=(cargo xtask starry build -c "${STARRY_CONFIG}")
    build_cmd+=("${STARRY_ARGS[@]}")
    info "Building StarryOS from ${STARRY_REF}"
    info "EXEC: ${build_cmd[*]}"
    (
        cd "${STARRY_SRC_DIR}"
        "${build_cmd[@]}"
    )

    artifact_path=""
    for artifact_candidate in \
        "${STARRY_SRC_DIR}/target/aarch64-unknown-none-softfloat/release/starryos.bin" \
        "${STARRY_SRC_DIR}/target/aarch64-unknown-linux-musl/release/starryos.bin"; do
        if [[ -f "${artifact_candidate}" ]]; then
            artifact_path="${artifact_candidate}"
            break
        fi
    done
    [[ -n "${artifact_path}" ]] || die "StarryOS build artifact not found under target/aarch64-unknown-{none-softfloat,linux-musl}/release"
    source_commit="$(git -C "${STARRY_SRC_DIR}" rev-parse HEAD)"

    mkdir -p "${STARRY_IMAGES_DIR}"
    install -m 0644 "${artifact_path}" "${STARRY_IMAGES_DIR}/${STARRY_IMAGE_NAME}"
    success "StarryOS guest image: ${STARRY_IMAGES_DIR}/${STARRY_IMAGE_NAME}"

    if [[ -n "${STARRY_RELEASE_IMAGES_DIR}" ]]; then
        starry_write_release_metadata "${artifact_path}" "${STARRY_RELEASE_IMAGES_DIR}" "${source_commit}"
        success "StarryOS release staging: ${STARRY_RELEASE_IMAGES_DIR}"
    fi
}

starry_clean() {
    info "Removing StarryOS image outputs"
    rm -rf "${STARRY_IMAGES_DIR}"
    if [[ -n "${STARRY_RELEASE_IMAGES_DIR}" ]]; then
        rm -rf "${STARRY_RELEASE_IMAGES_DIR}"
    fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    cmd="${1:-}"
    shift || true

    case "${cmd}" in
        ""|-h|--help|help)
            starry_usage
            exit 0
            ;;
        orangepi-5-plus)
            starry_parse_args "$@"
            starry_build
            ;;
        clean)
            starry_parse_args "$@"
            starry_clean
            ;;
        *)
            die "Unknown StarryOS target: ${cmd}"
            ;;
    esac
fi
