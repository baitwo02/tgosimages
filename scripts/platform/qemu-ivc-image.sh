#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p build && cd build && pwd -P)"

LOG_CREATE_DEFAULT_FILE="${LOG_CREATE_DEFAULT_FILE:-0}"
source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs.sh"

IMAGE_NAME="rootfs-aarch64-alpine-ivc-message-v1.img"
EXPECTED_BASE_ROOTFS_SHA256="31703a908957cf90abb2b50c626b8bdf25d42641d84322845869faba359d5ed9"
EXPECTED_LINUX_REF="74fe02ce122a6103f207d29fafc8b3a53de6abaf"
EXPECTED_KERNEL_RELEASE="7.1.0-rc2-g74fe02ce122a-dirty"
DEFAULT_AXVISOR_TOOLS_REF="da4d035063a0d3f5cd70537a109099951e7969a3"

BASE_ROOTFS_ARCHIVE=""
AXVISOR_TOOLS_REPO_URL="${AXVISOR_TOOLS_REPO_URL:-https://github.com/baitwo02/axvisor-tools.git}"
AXVISOR_TOOLS_REF="${AXVISOR_TOOLS_REF:-${DEFAULT_AXVISOR_TOOLS_REF}}"
AXVISOR_TOOLS_SRC_DIR="${AXVISOR_TOOLS_SRC_DIR:-${BUILD_DIR}/ivc-axvisor-tools}"
AXVISOR_TOOLS_SKIP_CHECKOUT="${AXVISOR_TOOLS_SKIP_CHECKOUT:-0}"
ARCEOS_REPO_URL="${ARCEOS_REPO_URL:-https://github.com/rcore-os/tgoskits.git}"
ARCEOS_REF="${ARCEOS_REF:-}"
ARCEOS_SRC_DIR="${ARCEOS_SRC_DIR:-${BUILD_DIR}/ivc-tgoskits}"
ARCEOS_SKIP_CHECKOUT="${ARCEOS_SKIP_CHECKOUT:-0}"
LINUX_REPO_URL="${LINUX_REPO_URL:-https://github.com/torvalds/linux.git}"
LINUX_REF="${LINUX_REF:-${EXPECTED_LINUX_REF}}"
LINUX_SRC_DIR="${LINUX_SRC_DIR:-${BUILD_DIR}/ivc-linux}"
LINUX_SKIP_CHECKOUT="${LINUX_SKIP_CHECKOUT:-0}"
AARCH64_MUSL_CROSS="${AARCH64_MUSL_CROSS:-aarch64-linux-musl-}"
AARCH64_CROSS_COMPILE="${AARCH64_CROSS_COMPILE:-aarch64-unknown-linux-musl-}"
IVC_IMAGE_JOBS="${IVC_IMAGE_JOBS:-$(nproc)}"
IVC_WORK_DIR="${BUILD_DIR}/qemu-aarch64-ivc-message-v1"
IVC_OUTPUT_DIR="${ROOT_DIR}/IMAGES/rootfs"
IVC_RELEASE_DIR="${ROOT_DIR}/release"
IMAGE_PATH="${IVC_OUTPUT_DIR}/${IMAGE_NAME}"
BUILD_INFO_PATH="${IVC_RELEASE_DIR}/${IMAGE_NAME}.build-info.txt"
ARCHIVE_PATH="${IVC_RELEASE_DIR}/${IMAGE_NAME}.tar.xz"

usage() {
    printf 'Build the dedicated QEMU AArch64 IVC Message V1 rootfs image\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  ./build.sh platform qemu-aarch64 ivc-image --base-rootfs-archive <archive>\n'
    printf '\n'
    printf 'Options:\n'
    printf '  --base-rootfs-archive <path>   Official v0.0.12 Alpine rootfs archive\n'
    printf '  -h, --help, help               Display this help\n'
    printf '\n'
    printf 'Exact source inputs:\n'
    printf '  AXVISOR_TOOLS_REF              Exact axvisor-tools commit\n'
    printf '  ARCEOS_REF                     Exact tgoskits feature commit (required)\n'
    printf '  LINUX_REF                      Exact Linux commit (frozen for this image)\n'
    printf '\n'
    printf 'Local source mode:\n'
    printf '  AXVISOR_TOOLS_SRC_DIR / AXVISOR_TOOLS_SKIP_CHECKOUT=1\n'
    printf '  ARCEOS_SRC_DIR        / ARCEOS_SKIP_CHECKOUT=1\n'
    printf '  LINUX_SRC_DIR         / LINUX_SKIP_CHECKOUT=1\n'
    printf '\n'
    printf 'Every skip-checkout source must be a clean Git root at the declared commit.\n'
    printf 'A skip-checkout Linux tree must already contain matching prepared Kbuild metadata.\n'
}

main() {
    parse_args "$@"
    require_build_tools
    validate_frozen_inputs
    record_builder_commit

    prepare_base_rootfs
    prepare_linux_tree
    prepare_axvisor_tools_tree
    build_linux_ivc_artifacts
    prepare_arceos_tree
    build_arceos_ivc_artifacts
    inject_ivc_artifacts
    validate_image_artifacts
    package_ivc_image

    success "Dedicated IVC image: ${IMAGE_PATH}"
    success "Release archive: ${ARCHIVE_PATH}"
    success "Build information: ${BUILD_INFO_PATH}"
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-rootfs-archive)
                [[ $# -ge 2 ]] || die "--base-rootfs-archive requires a path"
                BASE_ROOTFS_ARCHIVE="$2"
                shift 2
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                die "Unknown IVC image option: $1" 2
                ;;
        esac
    done

    [[ -n "${BASE_ROOTFS_ARCHIVE}" ]] || die "--base-rootfs-archive is required"
    BASE_ROOTFS_ARCHIVE="$(cd "$(dirname "${BASE_ROOTFS_ARCHIVE}")" && pwd -P)/$(basename "${BASE_ROOTFS_ARCHIVE}")"
    [[ -f "${BASE_ROOTFS_ARCHIVE}" ]] || die "Base rootfs archive not found: ${BASE_ROOTFS_ARCHIVE}"
}

require_build_tools() {
    local tool

    for tool in cargo cmp debugfs e2fsck file git make sha256sum tar xz; do
        command -v "${tool}" >/dev/null 2>&1 || die "Missing required build tool: ${tool}"
    done
    command -v "${AARCH64_MUSL_CROSS}gcc" >/dev/null 2>&1 \
        || die "Missing static demo compiler: ${AARCH64_MUSL_CROSS}gcc"
    command -v "${AARCH64_CROSS_COMPILE}gcc" >/dev/null 2>&1 \
        || die "Missing kernel compiler: ${AARCH64_CROSS_COMPILE}gcc"
    command -v "${AARCH64_CROSS_COMPILE}readelf" >/dev/null 2>&1 \
        || die "Missing module inspection tool: ${AARCH64_CROSS_COMPILE}readelf"
}

validate_frozen_inputs() {
    [[ "${LINUX_REF}" == "${EXPECTED_LINUX_REF}" ]] \
        || die "LINUX_REF must remain ${EXPECTED_LINUX_REF} for this image"
    [[ "${AXVISOR_TOOLS_REF}" =~ ^[0-9a-f]{40}$ ]] \
        || die "AXVISOR_TOOLS_REF must be an exact 40-character commit"
    [[ "${ARCEOS_REF}" =~ ^[0-9a-f]{40}$ ]] \
        || die "ARCEOS_REF must be an exact 40-character feature commit"
    [[ "${IVC_IMAGE_JOBS}" =~ ^[1-9][0-9]*$ ]] \
        || die "IVC_IMAGE_JOBS must be a positive integer"
}

record_builder_commit() {
    TGOSIMAGES_BUILDER_COMMIT="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
    require_clean_exact_git_checkout \
        "tgosimages builder" "${ROOT_DIR}" "${TGOSIMAGES_BUILDER_COMMIT}"
}

prepare_base_rootfs() {
    local archive_sha256
    local extract_dir="${IVC_WORK_DIR}/base-rootfs"
    local extracted_image

    archive_sha256="$(sha256sum "${BASE_ROOTFS_ARCHIVE}" | awk '{print $1}')"
    [[ "${archive_sha256}" == "${EXPECTED_BASE_ROOTFS_SHA256}" ]] \
        || die "Base rootfs checksum mismatch: expected ${EXPECTED_BASE_ROOTFS_SHA256}, got ${archive_sha256}"

    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}" "${IVC_OUTPUT_DIR}" "${IVC_RELEASE_DIR}"
    tar -xJf "${BASE_ROOTFS_ARCHIVE}" -C "${extract_dir}"
    extracted_image="$(find "${extract_dir}" -type f -name 'rootfs-aarch64-alpine.img' -print -quit)"
    [[ -n "${extracted_image}" ]] || die "Base archive does not contain rootfs-aarch64-alpine.img"

    rm -f "${IMAGE_PATH}"
    cp --reflink=auto "${extracted_image}" "${IMAGE_PATH}"
    BASE_ROOTFS_IMAGE_SHA256="$(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"
    success "Verified and extracted the official base rootfs"
}

prepare_exact_source() {
    local label="$1"
    local repo_url="$2"
    local source_ref="$3"
    local source_dir="$4"
    local skip_checkout="$5"

    case "${skip_checkout}" in
        0)
            clone_repository "${repo_url}" "${source_dir}"
            checkout_ref "${source_dir}" "${source_ref}"
            ;;
        1)
            info "Using local ${label} checkout without checkout: ${source_dir}"
            ;;
        *)
            die "${label} skip-checkout flag must be 0 or 1"
            ;;
    esac

    require_clean_exact_git_checkout "${label}" "${source_dir}" "${source_ref}"
}

prepare_linux_tree() {
    prepare_exact_source \
        "Linux" "${LINUX_REPO_URL}" "${LINUX_REF}" \
        "${LINUX_SRC_DIR}" "${LINUX_SKIP_CHECKOUT}"

    if [[ "${LINUX_SKIP_CHECKOUT}" == "0" ]]; then
        info "Preparing Linux Kbuild metadata for ${EXPECTED_KERNEL_RELEASE}"
        make -C "${LINUX_SRC_DIR}" \
            ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= mrproper
        make -C "${LINUX_SRC_DIR}" \
            ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= defconfig
        "${LINUX_SRC_DIR}/scripts/config" --file "${LINUX_SRC_DIR}/.config" \
            --enable NVME_CORE \
            --enable BLK_DEV_NVME \
            --set-str LOCALVERSION "-g74fe02ce122a-dirty" \
            --disable LOCALVERSION_AUTO
        make -C "${LINUX_SRC_DIR}" \
            ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= olddefconfig
        make -C "${LINUX_SRC_DIR}" \
            ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= modules_prepare
        make -C "${LINUX_SRC_DIR}" -j"${IVC_IMAGE_JOBS}" \
            ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= vmlinux
        copy_required \
            "${LINUX_SRC_DIR}/vmlinux.symvers" \
            "${LINUX_SRC_DIR}/Module.symvers"
    fi

    validate_prepared_linux_tree
    require_clean_exact_git_checkout "Linux" "${LINUX_SRC_DIR}" "${LINUX_REF}"
}

validate_prepared_linux_tree() {
    local required_path
    local kernel_release

    for required_path in \
        .config \
        Module.symvers \
        include/generated/autoconf.h \
        include/config/auto.conf \
        include/config/kernel.release \
        scripts/module.lds \
        scripts/mod/modpost; do
        [[ -s "${LINUX_SRC_DIR}/${required_path}" ]] \
            || die "Prepared Linux tree is missing ${required_path}: ${LINUX_SRC_DIR}"
    done
    [[ -x "${LINUX_SRC_DIR}/scripts/mod/modpost" ]] \
        || die "Prepared Linux modpost is not executable"
    grep -qx 'CONFIG_NVME_CORE=y' "${LINUX_SRC_DIR}/.config" \
        || die "Prepared Linux config does not match the guest NVMe configuration"
    grep -qx 'CONFIG_BLK_DEV_NVME=y' "${LINUX_SRC_DIR}/.config" \
        || die "Prepared Linux config does not include built-in NVMe support"

    # The frozen release already contains the source suffix. Passing an empty
    # LOCALVERSION suppresses the extra '+' that Git adds for untagged commits.
    kernel_release="$(make -s -C "${LINUX_SRC_DIR}" \
        ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= kernelrelease)"
    [[ "${kernel_release}" == "${EXPECTED_KERNEL_RELEASE}" ]] \
        || die "Prepared Linux release ${kernel_release} does not match ${EXPECTED_KERNEL_RELEASE}"
    LINUX_CONFIG_SHA256="$(sha256sum "${LINUX_SRC_DIR}/.config" | awk '{print $1}')"
    MODULE_SYMVERS_SHA256="$(sha256sum "${LINUX_SRC_DIR}/Module.symvers" | awk '{print $1}')"
}

prepare_axvisor_tools_tree() {
    prepare_exact_source \
        "axvisor-tools" "${AXVISOR_TOOLS_REPO_URL}" "${AXVISOR_TOOLS_REF}" \
        "${AXVISOR_TOOLS_SRC_DIR}" "${AXVISOR_TOOLS_SKIP_CHECKOUT}"
}

build_linux_ivc_artifacts() {
    local ivc_dir="${AXVISOR_TOOLS_SRC_DIR}/ivc"

    [[ -f "${ivc_dir}/Makefile" ]] || die "axvisor-tools IVC Makefile not found: ${ivc_dir}"
    make -C "${ivc_dir}" clean
    make -C "${ivc_dir}" test
    make -C "${ivc_dir}" demo \
        ARCH=arm64 CROSS="${AARCH64_MUSL_CROSS}"
    make -C "${ivc_dir}" kernel-module \
        ARCH=arm64 \
        CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" \
        KDIR="${LINUX_SRC_DIR}" \
        LOCALVERSION=

    MODULE_PATH="${ivc_dir}/kernel_driver/axvisor.ko"
    LINUX_PUBLISH_PATH="${ivc_dir}/build/demo/publish"
    LINUX_SUBSCRIBE_PATH="${ivc_dir}/build/demo/subscribe"
    require_file "${MODULE_PATH}" "Linux IVC kernel module"
    require_static_aarch64_elf "${LINUX_PUBLISH_PATH}" "Linux IVC publisher"
    require_static_aarch64_elf "${LINUX_SUBSCRIBE_PATH}" "Linux IVC subscriber"
    validate_module_vermagic
    require_clean_exact_git_checkout \
        "axvisor-tools" "${AXVISOR_TOOLS_SRC_DIR}" "${AXVISOR_TOOLS_REF}"
}

require_file() {
    local path="$1"
    local description="$2"

    [[ -f "${path}" ]] || die "Missing ${description}: ${path}"
}

require_static_aarch64_elf() {
    local path="$1"
    local description="$2"
    local file_description

    require_file "${path}" "${description}"
    file_description="$(file -b "${path}")"
    [[ "${file_description}" == *"ARM aarch64"* && "${file_description}" == *"statically linked"* ]] \
        || die "${description} is not a static AArch64 ELF: ${file_description}"
}

validate_module_vermagic() {
    MODULE_VERMAGIC="$(
        "${AARCH64_CROSS_COMPILE}readelf" --string-dump=.modinfo "${MODULE_PATH}" \
            | sed -n 's/.*vermagic=//p' \
            | head -n1
    )"
    [[ -n "${MODULE_VERMAGIC}" ]] || die "axvisor.ko does not contain vermagic"
    [[ "${MODULE_VERMAGIC%% *}" == "${EXPECTED_KERNEL_RELEASE}" ]] \
        || die "Module vermagic does not match ${EXPECTED_KERNEL_RELEASE}: ${MODULE_VERMAGIC}"
}

prepare_arceos_tree() {
    prepare_exact_source \
        "ArceOS" "${ARCEOS_REPO_URL}" "${ARCEOS_REF}" \
        "${ARCEOS_SRC_DIR}" "${ARCEOS_SKIP_CHECKOUT}"
}

build_arceos_ivc_artifacts() {
    local arceos_images_dir="${IVC_WORK_DIR}/arceos"
    local config_dir="${IVC_WORK_DIR}/arceos-config"
    local package
    local config_path

    rm -rf "${arceos_images_dir}" "${config_dir}"
    mkdir -p "${arceos_images_dir}" "${config_dir}"

    for package in arceos-ivc-publisher arceos-ivc-subscriber; do
        config_path="${config_dir}/${package}.toml"
        cat > "${config_path}" <<'CONFIG'
features = ["arceos"]
log = "Warn"
CONFIG
        ARCEOS_REPO_URL="${ARCEOS_REPO_URL}" \
        ARCEOS_REF="${ARCEOS_REF}" \
        ARCEOS_SRC_DIR="${ARCEOS_SRC_DIR}" \
        ARCEOS_SKIP_CHECKOUT=1 \
            bash "${SCRIPT_DIR}/../os/arceos.sh" \
                aarch64-dyn \
                --images-dir "${arceos_images_dir}" \
                --image-name "${package}.bin" \
                --package "${package}" \
                --target aarch64-unknown-none-softfloat \
                --config "${config_path}"
    done

    ARCEOS_PUBLISH_PATH="${arceos_images_dir}/arceos-ivc-publisher.bin"
    ARCEOS_SUBSCRIBE_PATH="${arceos_images_dir}/arceos-ivc-subscriber.bin"
    require_file "${ARCEOS_PUBLISH_PATH}" "ArceOS IVC publisher"
    require_file "${ARCEOS_SUBSCRIBE_PATH}" "ArceOS IVC subscriber"
    require_clean_exact_git_checkout "ArceOS" "${ARCEOS_SRC_DIR}" "${ARCEOS_REF}"
}

inject_ivc_artifacts() {
    local overlay_dir="${IVC_WORK_DIR}/rootfs-overlay"

    rm -rf "${overlay_dir}"
    mkdir -p "${overlay_dir}/root" "${overlay_dir}/guest/arceos"
    copy_required "${MODULE_PATH}" "${overlay_dir}/root/axvisor.ko"
    copy_required "${LINUX_PUBLISH_PATH}" "${overlay_dir}/root/ivc-publish"
    copy_required "${LINUX_SUBSCRIBE_PATH}" "${overlay_dir}/root/ivc-subscribe"
    copy_required \
        "${ARCEOS_PUBLISH_PATH}" \
        "${overlay_dir}/guest/arceos/arceos-ivc-publisher.bin"
    copy_required \
        "${ARCEOS_SUBSCRIBE_PATH}" \
        "${overlay_dir}/guest/arceos/arceos-ivc-subscriber.bin"
    chmod 0644 "${overlay_dir}/root/axvisor.ko"
    chmod 0755 \
        "${overlay_dir}/root/ivc-publish" \
        "${overlay_dir}/root/ivc-subscribe" \
        "${overlay_dir}/guest/arceos/arceos-ivc-publisher.bin" \
        "${overlay_dir}/guest/arceos/arceos-ivc-subscriber.bin"

    rootfs_inject_overlay_stage "${IMAGE_PATH}" "${overlay_dir}"
}

validate_image_artifacts() {
    local dump_dir="${IVC_WORK_DIR}/image-dump"

    rm -rf "${dump_dir}"
    mkdir -p "${dump_dir}"
    compare_image_file "${MODULE_PATH}" /root/axvisor.ko "${dump_dir}/axvisor.ko"
    compare_image_file "${LINUX_PUBLISH_PATH}" /root/ivc-publish "${dump_dir}/ivc-publish"
    compare_image_file "${LINUX_SUBSCRIBE_PATH}" /root/ivc-subscribe "${dump_dir}/ivc-subscribe"
    compare_image_file \
        "${ARCEOS_PUBLISH_PATH}" \
        /guest/arceos/arceos-ivc-publisher.bin \
        "${dump_dir}/arceos-ivc-publisher.bin"
    compare_image_file \
        "${ARCEOS_SUBSCRIBE_PATH}" \
        /guest/arceos/arceos-ivc-subscriber.bin \
        "${dump_dir}/arceos-ivc-subscriber.bin"

    e2fsck -fn "${IMAGE_PATH}"
    IMAGE_SHA256="$(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"
    AXVISOR_KO_SHA256="$(sha256sum "${MODULE_PATH}" | awk '{print $1}')"
    IVC_PUBLISH_SHA256="$(sha256sum "${LINUX_PUBLISH_PATH}" | awk '{print $1}')"
    IVC_SUBSCRIBE_SHA256="$(sha256sum "${LINUX_SUBSCRIBE_PATH}" | awk '{print $1}')"
    ARCEOS_IVC_PUBLISHER_SHA256="$(sha256sum "${ARCEOS_PUBLISH_PATH}" | awk '{print $1}')"
    ARCEOS_IVC_SUBSCRIBER_SHA256="$(sha256sum "${ARCEOS_SUBSCRIBE_PATH}" | awk '{print $1}')"
}

compare_image_file() {
    local source_path="$1"
    local image_path="$2"
    local dump_path="$3"

    rm -f "${dump_path}"
    debugfs -R "dump -p ${image_path} ${dump_path}" "${IMAGE_PATH}" >/dev/null 2>&1 \
        || die "Failed to read ${image_path} back from ${IMAGE_NAME}"
    cmp --silent "${source_path}" "${dump_path}" \
        || die "Injected image artifact differs from ${source_path}: ${image_path}"
}

package_ivc_image() {
    local pack_input_dir="${IVC_WORK_DIR}/pack-input"
    local archive_sha256

    rm -rf "${pack_input_dir}"
    mkdir -p "${pack_input_dir}/rootfs" "${IVC_RELEASE_DIR}"
    ln "${IMAGE_PATH}" "${pack_input_dir}/rootfs/${IMAGE_NAME}"
    rm -f "${ARCHIVE_PATH}" "${ARCHIVE_PATH}.sha256" "${BUILD_INFO_PATH}"
    bash "${SCRIPT_DIR}/../tools/pack.sh" \
        --in_dir "${pack_input_dir}" \
        --out_dir "${IVC_RELEASE_DIR}"
    require_file "${ARCHIVE_PATH}" "dedicated IVC release archive"

    archive_sha256="$(sha256sum "${ARCHIVE_PATH}" | awk '{print $1}')"
    printf '%s  %s\n' "${archive_sha256}" "$(basename "${ARCHIVE_PATH}")" \
        > "${ARCHIVE_PATH}.sha256"
    write_build_info "${archive_sha256}"
}

write_build_info() {
    local archive_sha256="$1"

    cat > "${BUILD_INFO_PATH}" <<BUILD_INFO
tgoskits_feature_commit=${ARCEOS_REF}
axvisor_tools_commit=${AXVISOR_TOOLS_REF}
tgosimages_builder_commit=${TGOSIMAGES_BUILDER_COMMIT}
linux_ref=${LINUX_REF}
kernel_release=${EXPECTED_KERNEL_RELEASE}
base_rootfs_archive_sha256=${EXPECTED_BASE_ROOTFS_SHA256}
base_rootfs_image_sha256=${BASE_ROOTFS_IMAGE_SHA256}
linux_config_sha256=${LINUX_CONFIG_SHA256}
module_symvers_sha256=${MODULE_SYMVERS_SHA256}
module_vermagic=${MODULE_VERMAGIC}
axvisor_ko_sha256=${AXVISOR_KO_SHA256}
ivc_publish_sha256=${IVC_PUBLISH_SHA256}
ivc_subscribe_sha256=${IVC_SUBSCRIBE_SHA256}
arceos_ivc_publisher_sha256=${ARCEOS_IVC_PUBLISHER_SHA256}
arceos_ivc_subscriber_sha256=${ARCEOS_IVC_SUBSCRIBER_SHA256}
image_sha256=${IMAGE_SHA256}
archive_sha256=${archive_sha256}
validation_axvisor_tools_host_tests=passed
validation_static_aarch64_demos=passed
validation_module_vermagic=passed
validation_injected_byte_comparison=passed
validation_e2fsck_fn=passed
BUILD_INFO
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
