#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "${SCRIPT_DIR}/../lib/utils.sh"

DEBIAN_ARCH=""
DEBIAN_OUT_DIR=""
DEBIAN_GUEST_DIR=""
DEBIAN_OUTPUT=""
DEBIAN_IMG_SIZE="${DEBIAN_IMG_SIZE:-2G}"
DEBIAN_SUITE="${DEBIAN_SUITE:-trixie}"
DEBIAN_PASSWORD="${DEBIAN_PASSWORD:-root}"

DEBIAN_DOCKER_IMAGE=""
DEBIAN_DOCKER_PLATFORM=""
DEBIAN_DPKG_ARCH=""
DEBIAN_TARGET=""
DEBIAN_ROOTFS_IMG=""
DEBIAN_MIRROR="${DEBIAN_MIRROR:-http://deb.debian.org/debian}"
DEBIAN_ARCHES=("aarch64" "riscv64" "x86_64" "loongarch64")

debian_usage() {
    printf 'Build Debian-based rootfs image\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/rootfs/debian.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                       Build Debian rootfs for aarch64\n'
    printf '  riscv64                       Build Debian rootfs for riscv64\n'
    printf '  x86_64                        Build Debian rootfs for x86_64\n'
    printf '  loongarch64                   Build Debian rootfs for loongarch64\n'
    printf '  all                           Build Debian rootfs for all supported architectures\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --out_dir <dir>               Output directory (default: IMAGES/rootfs)\n'
    printf '  --output <path>               Output image path for single-arch build\n'
    printf '  --guest <dir>                 Guest directory to copy into rootfs /guest\n'
    printf '  --img-size <size>             Output image size (default: 2G)\n'
    printf '  --debian <suite>              Debian suite (default: trixie)\n'
    printf '  --password <password>         Root password (default: root)\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  DEBIAN_IMG_SIZE               Output image size\n'
    printf '  DEBIAN_SUITE                  Debian suite\n'
    printf '  DEBIAN_PASSWORD               Root password\n'
    printf '  DEBIAN_MIRROR                 Debian mirror URL\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * Uses Docker + debootstrap to generate an ext4 rootfs image.\n'
    printf '  * Defaults to Debian trixie because riscv64 is not reliably available in bookworm here.\n'
    printf '  * The all command currently targets: aarch64, riscv64, x86_64, loongarch64.\n'
    printf '  * Debian 13 (trixie) does not currently ship loong64 packages in the main archive.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/rootfs/debian.sh aarch64\n'
    printf '  scripts/rootfs/debian.sh riscv64 --debian trixie --img-size 3G\n'
    printf '  scripts/rootfs/debian.sh x86_64 --out_dir /tmp/rootfs\n'
    printf '  scripts/rootfs/debian.sh loongarch64 --guest /path/to/guest/files\n'
    printf '  scripts/rootfs/debian.sh all --out_dir IMAGES/rootfs\n'
}

debian_parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --out_dir)
                DEBIAN_OUT_DIR="$2"
                shift 2
                ;;
            --output|-o)
                DEBIAN_OUTPUT="$2"
                shift 2
                ;;
            --guest)
                DEBIAN_GUEST_DIR="$2"
                shift 2
                ;;
            --img-size|-s)
                DEBIAN_IMG_SIZE="$2"
                shift 2
                ;;
            --debian|--suite|-d)
                DEBIAN_SUITE="$2"
                shift 2
                ;;
            --password|-p)
                DEBIAN_PASSWORD="$2"
                shift 2
                ;;
            *)
                die "Unknown option: $1"
                ;;
        esac
    done
}

debian_check_docker() {
    command -v docker >/dev/null 2>&1 || die "docker not found. Please install Docker first."
    docker info >/dev/null 2>&1 || die "Docker daemon is not running."
}

debian_validate_suite_support() {
    if [[ "${DEBIAN_ARCH}" == "loongarch64" && "${DEBIAN_SUITE}" == "trixie" ]]; then
        die "Debian ${DEBIAN_SUITE} does not provide loong64 packages in the main archive. Please use sid/unstable or a debian-ports-based workflow for loongarch64."
    fi
}

debian_init_config() {
    case "${DEBIAN_ARCH}" in
        aarch64)
            DEBIAN_TARGET="aarch64-unknown-none-softfloat"
            DEBIAN_DOCKER_PLATFORM="linux/arm64"
            DEBIAN_DPKG_ARCH="arm64"
            ;;
        riscv64)
            DEBIAN_TARGET="riscv64gc-unknown-none-elf"
            DEBIAN_DOCKER_PLATFORM="linux/riscv64"
            DEBIAN_DPKG_ARCH="riscv64"
            ;;
        x86_64)
            DEBIAN_TARGET="x86_64-unknown-none"
            DEBIAN_DOCKER_PLATFORM="linux/amd64"
            DEBIAN_DPKG_ARCH="amd64"
            ;;
        loongarch64)
            DEBIAN_TARGET="loongarch64-unknown-none"
            DEBIAN_DOCKER_PLATFORM="linux/loong64"
            DEBIAN_DPKG_ARCH="loong64"
            ;;
        *)
            die "Unsupported Debian architecture: ${DEBIAN_ARCH}"
            ;;
    esac

    DEBIAN_DOCKER_IMAGE="debian:${DEBIAN_SUITE}"

    if [[ -n "${DEBIAN_GUEST_DIR}" ]]; then
        DEBIAN_GUEST_DIR="$(cd "${DEBIAN_GUEST_DIR}" 2>/dev/null && pwd -P)" || {
            warn "Guest directory ${DEBIAN_GUEST_DIR} does not exist or is not accessible"
            DEBIAN_GUEST_DIR=""
        }
    fi

    if [[ -n "${DEBIAN_OUTPUT}" ]]; then
        DEBIAN_ROOTFS_IMG="${DEBIAN_OUTPUT}"
    else
        local output_dir="${DEBIAN_OUT_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
        DEBIAN_ROOTFS_IMG="${output_dir}/debian-rootfs-${DEBIAN_ARCH}.img"
    fi

    mkdir -p "$(dirname "${DEBIAN_ROOTFS_IMG}")" "${BUILD_DIR}/debian/${DEBIAN_ARCH}"
}

debian_build_rootfs() {
    local volume_name="starry-debian-rootfs-${DEBIAN_ARCH}-$$"
    local guest_mount=()

    if [[ -n "${DEBIAN_GUEST_DIR}" ]]; then
        guest_mount=(-v "${DEBIAN_GUEST_DIR}:/guest-src:ro")
    fi

    info "Building Debian ${DEBIAN_SUITE} rootfs for ${DEBIAN_ARCH} (${DEBIAN_DPKG_ARCH})"
    info "Docker image: ${DEBIAN_DOCKER_IMAGE} (${DEBIAN_DOCKER_PLATFORM})"
    info "Output image: ${DEBIAN_ROOTFS_IMG}"

    docker volume create "${volume_name}" >/dev/null

    cleanup_volume() {
        docker volume rm "${volume_name}" >/dev/null 2>&1 || true
    }
    trap cleanup_volume EXIT

    info "Configuring Debian rootfs contents via debootstrap..."
    docker run --rm \
        --platform "${DEBIAN_DOCKER_PLATFORM}" \
        -v "${volume_name}:/rootfs" \
        "${guest_mount[@]}" \
        "${DEBIAN_DOCKER_IMAGE}" \
        bash -lc "
            set -euo pipefail

            export DEBIAN_FRONTEND=noninteractive

            apt-get update
            apt-get install -y debootstrap e2fsprogs busybox-static bash

            debootstrap \
                --arch='${DEBIAN_DPKG_ARCH}' \
                --variant=minbase \
                --no-merged-usr \
                '${DEBIAN_SUITE}' \
                /rootfs \
                '${DEBIAN_MIRROR}'

            ROOTFS=/rootfs

            printf '%s\n' starry > \"\$ROOTFS/etc/hostname\"
            cat > \"\$ROOTFS/etc/hosts\" <<'EOF_HOSTS'
127.0.0.1 localhost starry
EOF_HOSTS

            cat > \"\$ROOTFS/etc/fstab\" <<'EOF_FSTAB'
/dev/vda  /  ext4  defaults,noatime  0  1
EOF_FSTAB

            chroot \"\$ROOTFS\" /usr/sbin/chpasswd <<'EOF_PASSWD'
root:${DEBIAN_PASSWORD}
EOF_PASSWD

            chroot \"\$ROOTFS\" apt-get update
            chroot \"\$ROOTFS\" apt-get install -y --reinstall libc6
            chroot \"\$ROOTFS\" apt-get install -y busybox-static bash

            if [ ! -e \"\$ROOTFS/sbin/init\" ]; then
                ln -sf /bin/busybox \"\$ROOTFS/sbin/init\"
            fi

            cat > \"\$ROOTFS/etc/inittab\" <<'EOF_INITTAB'
# /etc/inittab - busybox init for Starry OS
::sysinit:/etc/init.d/rcS
::respawn:-/bin/sh
::shutdown:/bin/umount -a -r
EOF_INITTAB

            mkdir -p \"\$ROOTFS/etc/init.d\"
            cat > \"\$ROOTFS/etc/init.d/rcS\" <<'EOF_RCS'
#!/bin/sh
mount -t proc proc /proc 2>/dev/null
mount -t sysfs sysfs /sys 2>/dev/null
mount -t devtmpfs devtmpfs /dev 2>/dev/null
mkdir -p /dev/pts
mount -t devpts devpts /dev/pts 2>/dev/null
hostname starry
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EOF_RCS
            chmod +x \"\$ROOTFS/etc/init.d/rcS\"

            mkdir -p \"\$ROOTFS/etc/apt/apt.conf.d\"
            printf '%s\n' 'APT::Sandbox::User \"root\";' > \"\$ROOTFS/etc/apt/apt.conf.d/99no-sandbox\"
            printf '%s\n' 'APT::Cache-Start \"67108864\";' > \"\$ROOTFS/etc/apt/apt.conf.d/99cache-start\"

            mkdir -p \"\$ROOTFS/root\"
            cat > \"\$ROOTFS/root/init.sh\" <<'EOF_INIT_SH'
#!/bin/sh
export HOME=/root
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
echo ''
echo 'Welcome to Starry OS (Debian GNU/Linux)'
echo ''
echo 'Use apt to install packages.'
echo ''
cd ~
sh --login
EOF_INIT_SH
            chmod +x \"\$ROOTFS/root/init.sh\"

            cat > \"\$ROOTFS/root/.profile\" <<'EOF_PROFILE'
export PS1='starry:~# '
EOF_PROFILE

            mkdir -p \"\$ROOTFS/etc/network\"
            cat > \"\$ROOTFS/etc/network/interfaces\" <<'EOF_NET'
auto eth0
iface eth0 inet dhcp
EOF_NET

            cat > \"\$ROOTFS/etc/resolv.conf\" <<'EOF_RESOLV'
# SLIRP default DNS server
# See https://wiki.qemu.org/Documentation/Networking#User_Networking_(SLIRP)
nameserver 10.0.2.3
EOF_RESOLV

            if [ -d /guest-src ]; then
                mkdir -p \"\$ROOTFS/guest\"
                cp -a /guest-src/. \"\$ROOTFS/guest/\"
            fi

            chroot \"\$ROOTFS\" apt-get clean
            rm -rf \"\$ROOTFS/var/lib/apt/lists/\"*
            rm -rf \"\$ROOTFS/var/cache/apt/archives/\"*.deb
        "

    info "Packing ext4 image ${DEBIAN_ROOTFS_IMG} (${DEBIAN_IMG_SIZE})..."
    docker run --rm --privileged \
        --platform "${DEBIAN_DOCKER_PLATFORM}" \
        -v "${volume_name}:/rootfs:ro" \
        -v "$(dirname "${DEBIAN_ROOTFS_IMG}"):/output" \
        "${DEBIAN_DOCKER_IMAGE}" \
        bash -lc "
            set -euo pipefail

            apt-get update
            apt-get install -y e2fsprogs

            cd /output
            rm -f '$(basename "${DEBIAN_ROOTFS_IMG}")'
            dd if=/dev/zero of='$(basename "${DEBIAN_ROOTFS_IMG}")' bs=1 count=0 seek='${DEBIAN_IMG_SIZE}' 2>/dev/null
            mkfs.ext4 -F -L starry-rootfs '$(basename "${DEBIAN_ROOTFS_IMG}")'
            mkdir -p /mnt/rootfs
            mount -o loop '$(basename "${DEBIAN_ROOTFS_IMG}")' /mnt/rootfs
            cp -a /rootfs/. /mnt/rootfs/
            sync
            umount /mnt/rootfs
            rmdir /mnt/rootfs
        "

    trap - EXIT
    cleanup_volume

    success "Debian rootfs created: ${DEBIAN_ROOTFS_IMG}"
}

debian_build_one() {
    DEBIAN_ARCH="$1"
    debian_init_config
    debian_validate_suite_support
    debian_check_docker
    debian_build_rootfs
}

debian_build_all() {
    if [[ -n "${DEBIAN_OUTPUT}" ]]; then
        die "--output can only be used for a single architecture build"
    fi

    debian_check_docker

    local arch
    for arch in "${DEBIAN_ARCHES[@]}"; do
        DEBIAN_ARCH="${arch}"
        debian_init_config
        debian_validate_suite_support
        debian_build_rootfs
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true

    case "${cmd}" in
        ""|-h|--help|help)
            debian_usage
            exit 0
            ;;
        aarch64|riscv64|x86_64|loongarch64)
            debian_parse_args "$@"
            debian_build_one "${cmd}"
            ;;
        all)
            debian_parse_args "$@"
            debian_build_all
            ;;
        *)
            die "Unknown command: ${cmd}"
            ;;
    esac
fi
