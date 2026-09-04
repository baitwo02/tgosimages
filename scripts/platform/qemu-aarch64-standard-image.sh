#!/usr/bin/env bash
# Build the matched standard QEMU AArch64 kernel/rootfs pair used by AxVisor.
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
STANDARD_SCRIPT_DIR="${SCRIPT_DIR}"
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p build && cd build && pwd -P)"

LOG_CREATE_DEFAULT_FILE="${LOG_CREATE_DEFAULT_FILE:-0}"
source "${SCRIPT_DIR}/../lib/utils.sh"
source "${SCRIPT_DIR}/../lib/rootfs.sh"
# Sourced libraries use SCRIPT_DIR internally; restore this script's directory.
SCRIPT_DIR="${STANDARD_SCRIPT_DIR}"

IMAGE_VERSION="${IMAGE_VERSION:-0.0.13}"
LINUX_REPO_URL="${LINUX_REPO_URL:-https://github.com/torvalds/linux.git}"
LINUX_REF="${LINUX_REF:-74fe02ce122a6103f207d29fafc8b3a53de6abaf}"
LINUX_SRC_DIR="${LINUX_SRC_DIR:-${BUILD_DIR}/standard-aarch64/linux}"
AXVISOR_TOOLS_REPO_URL="${AXVISOR_TOOLS_REPO_URL:-https://github.com/baitwo02/axvisor-tools.git}"
AXVISOR_TOOLS_REF="${AXVISOR_TOOLS_REF:-da4d035063a0d3f5cd70537a109099951e7969a3}"
AXVISOR_TOOLS_SRC_DIR="${AXVISOR_TOOLS_SRC_DIR:-${BUILD_DIR}/standard-aarch64/axvisor-tools}"
AARCH64_CROSS_COMPILE="${AARCH64_CROSS_COMPILE:-aarch64-linux-gnu-}"
AARCH64_MUSL_CROSS="${AARCH64_MUSL_CROSS:-aarch64-linux-musl-}"
BUILD_JOBS="${BUILD_JOBS:-$(nproc)}"

BASE_VERSION="0.0.12"
BASE_ROOTFS_SHA256="31703a908957cf90abb2b50c626b8bdf25d42641d84322845869faba359d5ed9"
BASE_QEMU_SHA256="4078a53cbcafaa0576d65f3149fd94e3e28f3fcff3ed57a15233e4b1de9a5465"
BASE_URL="https://github.com/rcore-os/tgosimages/releases/download/v${BASE_VERSION}"
BASE_ROOTFS_ARCHIVE="${BASE_ROOTFS_ARCHIVE:-${BUILD_DIR}/image-cache/rootfs-aarch64-alpine.img.tar.xz}"
BASE_QEMU_ARCHIVE="${BASE_QEMU_ARCHIVE:-${BUILD_DIR}/image-cache/qemu-aarch64.tar.xz}"

WORK_DIR="${BUILD_DIR}/standard-aarch64"
ROOTFS_IMAGE="${ROOT_DIR}/IMAGES/rootfs/rootfs-aarch64-alpine.img"
QEMU_DIR="${ROOT_DIR}/IMAGES/qemu-aarch64"
RELEASE_DIR="${ROOT_DIR}/release"
ROOTFS_ARCHIVE="${RELEASE_DIR}/rootfs-aarch64-alpine.img.tar.xz"
QEMU_ARCHIVE="${RELEASE_DIR}/qemu-aarch64.tar.xz"

usage() {
    cat <<'USAGE'
Build a matched standard QEMU AArch64 kernel and Alpine rootfs image pair.

Usage:
  ./build.sh platform qemu-aarch64 standard-image [options]

Options:
  --base-rootfs-archive <path>  Override the pinned v0.0.12 rootfs archive
  --base-qemu-archive <path>    Override the pinned v0.0.12 QEMU bundle
  -h, --help                    Display this help

The standard rootfs receives pciutils, Linux IVC Message V1 demos/driver,
uio.ko, a kernel copy, and /opt/axvisor/ivc/manifest.toml. The matched kernel
also replaces linux/linux-qemu in the standard qemu-aarch64 bundle.
USAGE
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --base-rootfs-archive)
                [[ $# -ge 2 ]] || die "--base-rootfs-archive requires a path"
                BASE_ROOTFS_ARCHIVE="$2"
                shift 2
                ;;
            --base-qemu-archive)
                [[ $# -ge 2 ]] || die "--base-qemu-archive requires a path"
                BASE_QEMU_ARCHIVE="$2"
                shift 2
                ;;
            help|-h|--help)
                usage
                exit 0
                ;;
            *) die "Unknown standard-image option: $1" 2 ;;
        esac
    done
}

require_tools() {
    local tool
    for tool in cmp curl debugfs e2fsck file git make sha256sum tar xz; do
        command -v "${tool}" >/dev/null 2>&1 || die "Missing required build tool: ${tool}"
    done
    command -v "${AARCH64_CROSS_COMPILE}gcc" >/dev/null 2>&1 \
        || die "Missing kernel compiler: ${AARCH64_CROSS_COMPILE}gcc"
    command -v "${AARCH64_CROSS_COMPILE}readelf" >/dev/null 2>&1 \
        || die "Missing module inspection tool: ${AARCH64_CROSS_COMPILE}readelf"
    command -v "${AARCH64_MUSL_CROSS}gcc" >/dev/null 2>&1 \
        || die "Missing static userspace compiler: ${AARCH64_MUSL_CROSS}gcc"
    [[ "${LINUX_REF}" =~ ^[0-9a-f]{40}$ ]] || die "LINUX_REF must be an exact commit"
    [[ "${AXVISOR_TOOLS_REF}" =~ ^[0-9a-f]{40}$ ]] || die "AXVISOR_TOOLS_REF must be an exact commit"
    [[ "${BUILD_JOBS}" =~ ^[1-9][0-9]*$ ]] || die "BUILD_JOBS must be a positive integer"
}

download_pinned_archive() {
    local path="$1"
    local url="$2"
    local expected="$3"
    local actual=""

    mkdir -p "$(dirname "${path}")"
    if [[ -f "${path}" ]]; then
        actual="$(sha256sum "${path}" | awk '{print $1}')"
    fi
    if [[ "${actual}" != "${expected}" ]]; then
        info "Downloading pinned base archive: ${url}"
        curl -fL --retry 10 --retry-delay 3 -C - -o "${path}" "${url}"
        actual="$(sha256sum "${path}" | awk '{print $1}')"
    fi
    [[ "${actual}" == "${expected}" ]] \
        || die "Archive checksum mismatch for ${path}: expected ${expected}, got ${actual}"
}

prepare_inputs() {
    download_pinned_archive \
        "${BASE_ROOTFS_ARCHIVE}" \
        "${BASE_URL}/rootfs-aarch64-alpine.img.tar.xz" \
        "${BASE_ROOTFS_SHA256}"
    download_pinned_archive \
        "${BASE_QEMU_ARCHIVE}" \
        "${BASE_URL}/qemu-aarch64.tar.xz" \
        "${BASE_QEMU_SHA256}"

    mkdir -p "$(dirname "${ROOTFS_IMAGE}")" "${RELEASE_DIR}"
    rm -rf "${WORK_DIR}/base-rootfs" "${QEMU_DIR}"
    mkdir -p "${WORK_DIR}/base-rootfs" "${QEMU_DIR}"
    tar -xJf "${BASE_ROOTFS_ARCHIVE}" -C "${WORK_DIR}/base-rootfs"
    local base_image
    base_image="$(find "${WORK_DIR}/base-rootfs" -type f -name 'rootfs-aarch64-alpine.img' -print -quit)"
    [[ -n "${base_image}" ]] || die "Pinned base archive does not contain rootfs-aarch64-alpine.img"
    cp --reflink=auto "${base_image}" "${ROOTFS_IMAGE}"

    tar -xJf "${BASE_QEMU_ARCHIVE}" -C "${QEMU_DIR}"
    [[ -f "${QEMU_DIR}/linux/linux-qemu" ]] \
        || die "Pinned QEMU archive does not contain linux/linux-qemu"
}

prepare_source() {
    local label="$1"
    local url="$2"
    local ref="$3"
    local dir="$4"

    clone_repository "${url}" "${dir}"
    checkout_ref "${dir}" "${ref}"
    [[ "$(git -C "${dir}" rev-parse HEAD)" == "${ref}" ]] \
        || die "${label} checkout is not at ${ref}"
}

prepare_linux() {
    prepare_source "Linux" "${LINUX_REPO_URL}" "${LINUX_REF}" "${LINUX_SRC_DIR}"
    make -C "${LINUX_SRC_DIR}" ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" mrproper
    apply_patches "${ROOT_DIR}/patches/qemu" "${LINUX_SRC_DIR}"
    make -C "${LINUX_SRC_DIR}" ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" defconfig
    "${LINUX_SRC_DIR}/scripts/config" --file "${LINUX_SRC_DIR}/.config" \
        --enable MODULES \
        --module UIO \
        --enable PCI_MSI \
        --enable ARM_GIC_V3_ITS \
        --enable NVME_CORE \
        --enable BLK_DEV_NVME \
        --set-str LOCALVERSION "-g74fe02ce122a-dirty" \
        --disable LOCALVERSION_AUTO
    make -C "${LINUX_SRC_DIR}" \
        ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= olddefconfig
    make -C "${LINUX_SRC_DIR}" -j"${BUILD_JOBS}" \
        ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= \
        Image drivers/uio/uio.ko
    if [[ -s "${LINUX_SRC_DIR}/vmlinux.symvers" ]]; then
        cp -f "${LINUX_SRC_DIR}/vmlinux.symvers" "${LINUX_SRC_DIR}/Module.symvers"
    fi

    KERNEL_PATH="${LINUX_SRC_DIR}/arch/arm64/boot/Image"
    UIO_PATH="${LINUX_SRC_DIR}/drivers/uio/uio.ko"
    [[ -s "${KERNEL_PATH}" ]] || die "Linux kernel was not produced: ${KERNEL_PATH}"
    [[ -s "${UIO_PATH}" ]] || die "uio.ko was not produced: ${UIO_PATH}"
    KERNEL_RELEASE="$(make -s -C "${LINUX_SRC_DIR}" \
        ARCH=arm64 CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" LOCALVERSION= kernelrelease)"
    KERNEL_CONFIG_SHA256="$(sha256sum "${LINUX_SRC_DIR}/.config" | awk '{print $1}')"
}

build_ivc() {
    prepare_source \
        "axvisor-tools" "${AXVISOR_TOOLS_REPO_URL}" "${AXVISOR_TOOLS_REF}" "${AXVISOR_TOOLS_SRC_DIR}"
    local ivc_dir="${AXVISOR_TOOLS_SRC_DIR}/ivc"
    [[ -f "${ivc_dir}/Makefile" ]] || die "IVC Message V1 Makefile not found: ${ivc_dir}"

    make -C "${ivc_dir}" clean
    make -C "${ivc_dir}" test
    make -C "${ivc_dir}" ARCH=arm64 CROSS="${AARCH64_MUSL_CROSS}" demo
    make -C "${ivc_dir}" ARCH=arm64 \
        CROSS_COMPILE="${AARCH64_CROSS_COMPILE}" KDIR="${LINUX_SRC_DIR}" LOCALVERSION= kernel-module

    AXVISOR_KO_PATH="${ivc_dir}/kernel_driver/axvisor.ko"
    IVC_PUBLISH_PATH="${ivc_dir}/build/demo/publish"
    IVC_SUBSCRIBE_PATH="${ivc_dir}/build/demo/subscribe"
    require_static_aarch64 "${IVC_PUBLISH_PATH}" "IVC publisher"
    require_static_aarch64 "${IVC_SUBSCRIBE_PATH}" "IVC subscriber"
    [[ -s "${AXVISOR_KO_PATH}" ]] || die "IVC kernel module was not produced"

    UIO_VERMAGIC="$(module_vermagic "${UIO_PATH}")"
    AXVISOR_VERMAGIC="$(module_vermagic "${AXVISOR_KO_PATH}")"
    [[ "${UIO_VERMAGIC%% *}" == "${KERNEL_RELEASE}" ]] \
        || die "uio.ko vermagic does not match ${KERNEL_RELEASE}: ${UIO_VERMAGIC}"
    [[ "${AXVISOR_VERMAGIC%% *}" == "${KERNEL_RELEASE}" ]] \
        || die "axvisor.ko vermagic does not match ${KERNEL_RELEASE}: ${AXVISOR_VERMAGIC}"
}

require_static_aarch64() {
    local path="$1"
    local label="$2"
    local description
    [[ -s "${path}" ]] || die "${label} was not produced: ${path}"
    description="$(file -b "${path}")"
    [[ "${description}" == *"ARM aarch64"* && "${description}" == *"statically linked"* ]] \
        || die "${label} is not a static AArch64 ELF: ${description}"
}

module_vermagic() {
    "${AARCH64_CROSS_COMPILE}readelf" --string-dump=.modinfo "$1" \
        | sed -n 's/.*vermagic=//p' | head -n1
}

write_manifest() {
    local manifest="$1"
    local builder_commit kernel_sha uio_sha axvisor_sha publish_sha subscribe_sha
    builder_commit="$(git -C "${ROOT_DIR}" rev-parse HEAD)"
    kernel_sha="$(sha256sum "${KERNEL_PATH}" | awk '{print $1}')"
    uio_sha="$(sha256sum "${UIO_PATH}" | awk '{print $1}')"
    axvisor_sha="$(sha256sum "${AXVISOR_KO_PATH}" | awk '{print $1}')"
    publish_sha="$(sha256sum "${IVC_PUBLISH_PATH}" | awk '{print $1}')"
    subscribe_sha="$(sha256sum "${IVC_SUBSCRIBE_PATH}" | awk '{print $1}')"

    cat >"${manifest}" <<MANIFEST
schema_version = 1
arch = "aarch64"
image_version = "${IMAGE_VERSION}"
protocol = "ivc-message-v1"
linux_commit = "${LINUX_REF}"
kernel_release = "${KERNEL_RELEASE}"
kernel_config_sha256 = "${KERNEL_CONFIG_SHA256}"
kernel_sha256 = "${kernel_sha}"
axvisor_tools_commit = "${AXVISOR_TOOLS_REF}"
uio_sha256 = "${uio_sha}"
uio_vermagic = "${UIO_VERMAGIC}"
axvisor_ko_sha256 = "${axvisor_sha}"
axvisor_vermagic = "${AXVISOR_VERMAGIC}"
ivc_publish_sha256 = "${publish_sha}"
ivc_subscribe_sha256 = "${subscribe_sha}"
pciutils_version = "3.14.0-r0"
builder_commit = "${builder_commit}"
base_image_version = "${BASE_VERSION}"
base_rootfs_archive_sha256 = "${BASE_ROOTFS_SHA256}"
base_qemu_archive_sha256 = "${BASE_QEMU_SHA256}"
MANIFEST
}

inject_assets() {
    bash "${SCRIPT_DIR}/../tools/inject-alpine-pciutils.sh" --image "${ROOTFS_IMAGE}"

    local overlay="${WORK_DIR}/overlay"
    rm -rf "${overlay}"
    mkdir -p \
        "${overlay}/guest/linux" \
        "${overlay}/opt/axvisor/ivc/bin" \
        "${overlay}/opt/axvisor/ivc/lib/modules"
    cp -f "${KERNEL_PATH}" "${overlay}/guest/linux/linux-qemu"
    cp -f "${IVC_PUBLISH_PATH}" "${overlay}/opt/axvisor/ivc/bin/ivc-publish"
    cp -f "${IVC_SUBSCRIBE_PATH}" "${overlay}/opt/axvisor/ivc/bin/ivc-subscribe"
    cp -f "${AXVISOR_KO_PATH}" "${overlay}/opt/axvisor/ivc/lib/modules/axvisor.ko"
    cp -f "${UIO_PATH}" "${overlay}/opt/axvisor/ivc/lib/modules/uio.ko"
    chmod 0755 "${overlay}/opt/axvisor/ivc/bin/ivc-publish" "${overlay}/opt/axvisor/ivc/bin/ivc-subscribe"
    write_manifest "${overlay}/opt/axvisor/ivc/manifest.toml"
    rootfs_inject_overlay_stage "${ROOTFS_IMAGE}" "${overlay}"

    cp -f "${KERNEL_PATH}" "${QEMU_DIR}/linux/linux-qemu"
}

validate_output() {
    local dump="${WORK_DIR}/validation"
    rm -rf "${dump}"
    mkdir -p "${dump}"
    compare_image_file "${KERNEL_PATH}" /guest/linux/linux-qemu "${dump}/linux-qemu"
    compare_image_file "${UIO_PATH}" /opt/axvisor/ivc/lib/modules/uio.ko "${dump}/uio.ko"
    compare_image_file "${AXVISOR_KO_PATH}" /opt/axvisor/ivc/lib/modules/axvisor.ko "${dump}/axvisor.ko"
    compare_image_file "${IVC_PUBLISH_PATH}" /opt/axvisor/ivc/bin/ivc-publish "${dump}/ivc-publish"
    compare_image_file "${IVC_SUBSCRIBE_PATH}" /opt/axvisor/ivc/bin/ivc-subscribe "${dump}/ivc-subscribe"
    debugfs -R "dump /usr/bin/lspci ${dump}/lspci" "${ROOTFS_IMAGE}" >/dev/null 2>&1 \
        || die "pciutils lspci is missing from the standard rootfs"
    debugfs -R "dump /opt/axvisor/ivc/manifest.toml ${dump}/manifest.toml" \
        "${ROOTFS_IMAGE}" >/dev/null 2>&1 || die "IVC manifest is missing from the standard rootfs"
    grep -qx 'protocol = "ivc-message-v1"' "${dump}/manifest.toml" \
        || die "IVC manifest protocol is incorrect"
    cmp -s "${KERNEL_PATH}" "${QEMU_DIR}/linux/linux-qemu" \
        || die "qemu-aarch64 and rootfs kernels are not identical"
    e2fsck -fn "${ROOTFS_IMAGE}" >/dev/null 2>&1 \
        || die "e2fsck validation failed for ${ROOTFS_IMAGE}"
}

compare_image_file() {
    local source="$1"
    local image_path="$2"
    local output="$3"
    debugfs -R "dump ${image_path} ${output}" "${ROOTFS_IMAGE}" >/dev/null 2>&1 \
        || die "Missing rootfs asset: ${image_path}"
    cmp -s "${source}" "${output}" || die "Rootfs asset differs after injection: ${image_path}"
}

package_output() {
    local pack_input="${WORK_DIR}/pack-input"
    rm -rf "${pack_input}"
    mkdir -p "${pack_input}/rootfs"
    ln "${ROOTFS_IMAGE}" "${pack_input}/rootfs/rootfs-aarch64-alpine.img"
    ln -s "${QEMU_DIR}" "${pack_input}/qemu-aarch64"
    rm -f "${ROOTFS_ARCHIVE}" "${QEMU_ARCHIVE}"
    bash "${SCRIPT_DIR}/../tools/pack.sh" --in_dir "${pack_input}" --out_dir "${RELEASE_DIR}"
    [[ -s "${ROOTFS_ARCHIVE}" && -s "${QEMU_ARCHIVE}" ]] \
        || die "Standard image archives were not produced"
    sha256sum "${ROOTFS_ARCHIVE}" "${QEMU_ARCHIVE}" | tee "${RELEASE_DIR}/v${IMAGE_VERSION}.sha256"
}

main() {
    parse_args "$@"
    require_tools
    prepare_inputs
    prepare_linux
    build_ivc
    inject_assets
    validate_output
    package_output
    success "Standard rootfs archive: ${ROOTFS_ARCHIVE}"
    success "Matched QEMU archive: ${QEMU_ARCHIVE}"
}

main "$@"
