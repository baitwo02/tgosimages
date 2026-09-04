#!/usr/bin/env bash
#
# Inject pciutils (lspci) into an existing Alpine ext4 rootfs image without
# booting a guest. The flow mirrors the offline install used by
# scripts/rootfs/alpine.sh: run apk cross-arch against an extracted copy of
# the image (apk.static --root), then write the resulting files back into the
# ext4 image with debugfs, keeping /lib/apk/db/installed and /etc/apk/world
# consistent.

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p build && cd build && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

ALPINE_BASE="${ALPINE_BASE:-https://dl-cdn.alpinelinux.org/alpine}"
ALPINE_REL="${ALPINE_REL:-v3.23}"
APK_ARCH="aarch64"

# Pinned package versions (Alpine 3.23 main, aarch64) with sha256 checksums.
PCIUTILS_VERSION="3.14.0-r0"
PCIUTILS_LIBS_VERSION="3.14.0-r0"
HWDATA_PCI_VERSION="0.401-r0"
APK_TOOLS_STATIC_VERSION="3.0.7-r0"

# Repo-arch (relative to the package payload): packages come from the target
# arch repo; apk-tools-static comes from the host arch repo so it can run on
# the build host. Format: "<repo-arch>:<filename>=<sha256>".
APK_TOOLS_STATIC_SHA256_X86_64="bb547dc5ebc4ab4f998073196b43db8290dbdf8241d3ecf2e894df21765a980e"
APK_TOOLS_STATIC_SHA256_AARCH64="b5d554062d88efe555075f6c109972c7fa2abeea9b9122d2b140d37e2cdb2d96"

PACKAGE_SHA256=(
    "target:pciutils-${PCIUTILS_VERSION}.apk=5fd35827fe461e64b6433c3b09c5608e49fda19b753ce22f9de4ab67bde5047d"
    "target:pciutils-libs-${PCIUTILS_LIBS_VERSION}.apk=85a6db42e3969c22d22d54bfce961668301da00922a6451111d3b26cdd1d1bbb"
    "target:hwdata-pci-${HWDATA_PCI_VERSION}.apk=cfaf56560dde6b2fd554a58b9f67d62e60368f5d1d94de8ca695e5b8808c74e8"
)

package_entries() {
    local host_sha
    case "$(uname -m)" in
        x86_64|amd64) host_sha="${APK_TOOLS_STATIC_SHA256_X86_64}" ;;
        aarch64|arm64) host_sha="${APK_TOOLS_STATIC_SHA256_AARCH64}" ;;
    esac
    printf '%s\n' "${PACKAGE_SHA256[@]}"
    printf 'host:apk-tools-static-%s.apk=%s\n' "${APK_TOOLS_STATIC_VERSION}" "${host_sha}"
}

IMAGE_PATH="${IMAGE_PATH:-${ROOT_DIR}/IMAGES/rootfs/rootfs-aarch64-alpine.img}"
WORK_DIR="${WORK_DIR:-${BUILD_DIR}/inject-lspci}"

usage() {
    printf 'Inject pciutils (lspci) into an Alpine ext4 rootfs image\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/tools/inject-alpine-pciutils.sh [options]\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --image <path>    Target ext4 image (default: IMAGES/rootfs/rootfs-aarch64-alpine.img)\n'
    printf '  -h, --help        Display this help\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  IMAGE_PATH        Same as --image\n'
    printf '  WORK_DIR          Working directory (default: build/inject-lspci)\n'
    printf '  ALPINE_BASE       Alpine mirror base URL\n'
    printf '  ALPINE_REL        Alpine release (default: v3.23)\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Runs apk cross-arch via apk.static, no guest boot, no root required.\n'
    printf '  * Updates /lib/apk/db/installed and /etc/apk/world in the image.\n'
    printf '  * Verifies the result with e2fsck -fn and a byte-compare read-back.\n'
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --image)
                [[ $# -ge 2 ]] || die "--image requires a path"
                IMAGE_PATH="$2"
                shift 2
                ;;
            -h|--help|help)
                usage
                exit 0
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

require_build_tools() {
    local tool
    for tool in curl tar debugfs e2fsck sha256sum; do
        command -v "${tool}" >/dev/null 2>&1 || die "Missing required tool: ${tool}"
    done
}

host_apk_arch() {
    case "$(uname -m)" in
        x86_64|amd64) printf 'x86_64' ;;
        aarch64|arm64) printf 'aarch64' ;;
        *) die "Unsupported host architecture for apk.static: $(uname -m)" ;;
    esac
}

download_and_verify() {
    local repo_url="${ALPINE_BASE}/${ALPINE_REL}/main"
    local name expected actual entry_arch pkg_arch

    mkdir -p "${WORK_DIR}/downloads"
    while IFS= read -r entry; do
        name="${entry#*:}"
        name="${name%%=*}"
        expected="${entry##*=}"
        entry_arch="${entry%%:*}"
        case "${entry_arch}" in
            target) pkg_arch="${APK_ARCH}" ;;
            host) pkg_arch="$(host_apk_arch)" ;;
            *) die "Unknown package repo-arch: ${entry_arch}" ;;
        esac
        if [[ -f "${WORK_DIR}/downloads/${name}" ]]; then
            actual="$(sha256sum "${WORK_DIR}/downloads/${name}" | awk '{print $1}')"
            if [[ "${actual}" == "${expected}" ]]; then
                info "Using cached ${name} (${pkg_arch})"
                continue
            fi
            warn "Cached ${name} checksum mismatch, re-downloading"
            rm -f "${WORK_DIR}/downloads/${name}"
        fi
        info "Downloading ${name} (${pkg_arch})"
        curl -sfL -o "${WORK_DIR}/downloads/${name}" \
            "${repo_url}/${pkg_arch}/${name}" \
            || die "Failed to download ${name}"
        actual="$(sha256sum "${WORK_DIR}/downloads/${name}" | awk '{print $1}')"
        [[ "${actual}" == "${expected}" ]] || die "Checksum mismatch for ${name}"
    done < <(package_entries)
}

extract_image_tree() {
    local fs_type
    fs_type="$(file -b "${IMAGE_PATH}")"
    [[ "${fs_type}" == *"ext4 filesystem"* || "${fs_type}" == *"ext2 filesystem"* || "${fs_type}" == *"ext3 filesystem"* ]] \
        || die "Target image is not an ext filesystem: ${IMAGE_PATH} (${fs_type})"

    rm -rf "${WORK_DIR}/rootfs"
    mkdir -p "${WORK_DIR}/rootfs"
    info "Extracting image tree to ${WORK_DIR}/rootfs"
    debugfs -R "rdump / ${WORK_DIR}/rootfs" "${IMAGE_PATH}" >/dev/null 2>&1
    [[ -d "${WORK_DIR}/rootfs/etc/apk" ]] || die "Image does not look like an Alpine rootfs: ${IMAGE_PATH}"
}

apk_install_pciutils() {
    local host_arch
    host_arch="$(host_apk_arch)"

    rm -rf "${WORK_DIR}/apktools"
    mkdir -p "${WORK_DIR}/apktools"
    tar -xzf "${WORK_DIR}/downloads/apk-tools-static-${APK_TOOLS_STATIC_VERSION}.apk" \
        -C "${WORK_DIR}/apktools"

    info "Running apk.static --arch ${APK_ARCH} add pciutils (cross-arch, no guest boot)"
    "${WORK_DIR}/apktools/sbin/apk.static" \
        --root "${WORK_DIR}/rootfs" \
        --arch "${APK_ARCH}" \
        --keys-dir "${WORK_DIR}/rootfs/etc/apk/keys" \
        --no-cache \
        --no-scripts \
        --repository "${ALPINE_BASE}/${ALPINE_REL}/main" \
        add pciutils

    [[ -x "${WORK_DIR}/rootfs/usr/bin/lspci" ]] || die "lspci missing after apk install"
}

write_back() {
    local pkg_dir extract_dir rel target link

    debugfs_cmd() { debugfs -w -R "$1" "${IMAGE_PATH}" >/dev/null 2>&1; }

    info "Writing package payloads back into ${IMAGE_PATH}"

    for pkg in \
        "hwdata-pci-${HWDATA_PCI_VERSION}" \
        "pciutils-libs-${PCIUTILS_LIBS_VERSION}" \
        "pciutils-${PCIUTILS_VERSION}"; do
        pkg_dir="${WORK_DIR}/extract/${pkg}"
        rm -rf "${pkg_dir}"
        mkdir -p "${pkg_dir}"
        tar -xzf "${WORK_DIR}/downloads/${pkg}.apk" -C "${pkg_dir}" 2>/dev/null

        while IFS= read -r rel; do
            target="/${rel}"
            debugfs_cmd "mkdir $(dirname "${target}")"
            debugfs_cmd "rm ${target}"
            debugfs_cmd "write ${pkg_dir}/${rel} ${target}" \
                || die "debugfs write failed for ${target}"
        done < <(find "${pkg_dir}" -type f ! -name '.PKGINFO' ! -name '.SIGN.*' -printf '%P\n' | sort)

        while IFS= read -r rel; do
            target="/${rel}"
            link="$(readlink "${pkg_dir}/${rel}")"
            debugfs_cmd "rm ${target}"
            debugfs_cmd "symlink ${target} ${link}" \
                || die "debugfs symlink failed for ${target}"
        done < <(find "${pkg_dir}" -type l ! -name '.SIGN.*' -printf '%P\n' 2>/dev/null | sort)
    done

    # apk database metadata
    extract_dir="${WORK_DIR}/extract/meta"
    rm -rf "${extract_dir}"
    mkdir -p "${extract_dir}/lib/apk/db" "${extract_dir}/etc/apk"
    cp -f "${WORK_DIR}/rootfs/lib/apk/db/installed" "${extract_dir}/lib/apk/db/installed"
    cp -f "${WORK_DIR}/rootfs/etc/apk/world" "${extract_dir}/etc/apk/world"
    debugfs_cmd "rm /lib/apk/db/installed"
    debugfs_cmd "write ${extract_dir}/lib/apk/db/installed /lib/apk/db/installed"
    debugfs_cmd "rm /etc/apk/world"
    debugfs_cmd "write ${extract_dir}/etc/apk/world /etc/apk/world"
}

validate_result() {
    local dump_path

    e2fsck -fn "${IMAGE_PATH}" >/dev/null 2>&1 \
        || die "e2fsck -fn failed after injection: ${IMAGE_PATH}"

    dump_path="${WORK_DIR}/lspci.readback"
    rm -f "${dump_path}"
    debugfs -R "dump /usr/bin/lspci ${dump_path}" "${IMAGE_PATH}" >/dev/null 2>&1 \
        || die "Failed to read /usr/bin/lspci back from ${IMAGE_PATH}"
    cmp --silent "${dump_path}" "${WORK_DIR}/rootfs/usr/bin/lspci" \
        || die "Read-back of /usr/bin/lspci differs from installed payload"

    # Read fully into variables first: with pipefail, `debugfs | grep -q`
    # fails with SIGPIPE (141) because grep exits early on the match.
    local apk_db apk_world
    apk_db="$(debugfs -R "cat /lib/apk/db/installed" "${IMAGE_PATH}" 2>/dev/null || true)"
    grep -qx 'P:pciutils' <<<"${apk_db}" || die "apk database does not contain pciutils"
    apk_world="$(debugfs -R "cat /etc/apk/world" "${IMAGE_PATH}" 2>/dev/null || true)"
    grep -qx 'pciutils' <<<"${apk_world}" || die "/etc/apk/world does not contain pciutils"
}

main() {
    parse_args "$@"
    [[ -f "${IMAGE_PATH}" ]] || die "Image not found: ${IMAGE_PATH}"
    require_build_tools
    download_and_verify
    extract_image_tree
    apk_install_pciutils
    write_back
    validate_result
    success "lspci injected into: ${IMAGE_PATH}"
    info "Image sha256: $(sha256sum "${IMAGE_PATH}" | awk '{print $1}')"
}

main "$@"
