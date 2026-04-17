#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source $SCRIPT_DIR/utils.sh

# Default values
BUSYBOX_REPO_URL="${BUSYBOX_REPO_URL:-git://busybox.net/busybox.git}"
BUSYBOX_SRC_DIR="${BUSYBOX_SRC_DIR:-${BUILD_DIR}/busybox}"
BUSYBOX_PATCH_DIR="${BUSYBOX_PATCH_DIR:-${ROOT_DIR}/patches/busybox}"

# Global variables for parsed arguments
MKFS_ARCH=""
MKFS_OUT_DIR=""
MKFS_GUEST_DIR=""
MKFS_ARGS=""

mkfs_usage() {
    printf 'Generate a filesystem image containing BusyBox and basic device nodes\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/mkfs.sh <command> [options]\n'
    printf '\n'
    printf '<command>:\n'
    printf '  aarch64                       Build minimal filesystem for aarch64\n'
    printf '  riscv64                       Build minimal filesystem for riscv64\n'
    printf '  x86_64                        Build minimal filesystem for x86_64\n'
    printf '  help, -h, --help              Display this help information\n'
    printf '\n'
    printf '[options]:\n'
    printf '  --out_dir <dir>               Output directory (default: IMAGES/qemu/linux/<arch>)\n'
    printf '  --guest <dir>                 Guest directory to copy into rootfs /guest\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  BUSYBOX_REPO_URL              BusyBox repository URL\n'
    printf '  BUSYBOX_SRC_DIR               BusyBox source directory\n'
    printf '  BUSYBOX_PATCH_DIR             BusyBox patch directory\n'
    printf '\n'
    printf 'Notes:\n'
    printf '  * If BusyBox is dynamically linked, required shared libraries are copied automatically.\n'
    printf '  * The init script drops to an interactive shell after mounting basic pseudo filesystems.\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/mkfs.sh aarch64\n'
    printf '  scripts/mkfs.sh riscv64 --out_dir /tmp/output\n'
    printf '  scripts/mkfs.sh aarch64 --guest /path/to/guest/files\n'
}

mkfs_parse_args() {
    while [[ $# -gt 0 ]]; do
        case $1 in
            --out_dir)
                MKFS_OUT_DIR="$2"
                shift 2
                ;;
            --guest)
                MKFS_GUEST_DIR="$2"
                shift 2
                ;;
            *)
                MKFS_ARGS="$MKFS_ARGS $1"
                shift
                ;;
        esac
    done
}

mkfs_build_busybox() {
    local cross=""
    if [[ "$MKFS_ARCH" == "x86_64" ]]; then
        cross=""
    else
        cross="${MKFS_ARCH}-linux-gnu-"
    fi
    pushd "$BUSYBOX_SRC_DIR" >/dev/null
    info "Cleaning: make distclean"
    make distclean

    info "Configuring: make defconfig"
    make defconfig

    info "Building: make -j$(nproc) CROSS_COMPILE=$cross"
    sed -i 's/^# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y$/# CONFIG_TC is not set/' .config
    make -j$(nproc) CROSS_COMPILE="$cross"
    popd >/dev/null
}

mkfs_create_init() {
    printf '%s\n' \
        '#!/bin/sh' \
        'export PATH=/bin:/sbin:/usr/bin:/usr/sbin' \
        '' \
        'if [ -x /bin/busybox ]; then' \
        '    /bin/busybox --install -s >/dev/null 2>&1' \
        'fi' \
        '' \
        'TTY_DEV=/dev/console' \
        '[ -c /dev/ttyAMA0 ] && TTY_DEV=/dev/ttyAMA0' \
        '[ -c /dev/ttyS0 ] && TTY_DEV=/dev/ttyS0' \
        '' \
        'if [ ! -w "$TTY_DEV" ]; then' \
        '    echo "[ERROR] TTY_DEV ($TTY_DEV) is not writable. Falling back to /dev/console."' \
        '    TTY_DEV=/dev/console' \
        'fi' \
        '' \
        '/bin/busybox mkdir -p /proc /sys /dev /dev/pts /etc/init.d' \
        '/bin/busybox mount -t proc proc /proc >/dev/null 2>&1' \
        '/bin/busybox mount -t sysfs sysfs /sys >/dev/null 2>&1' \
        '/bin/busybox mount -t devtmpfs devtmpfs /dev >/dev/null 2>&1 || true' \
        '/bin/busybox mount -t devpts devpts /dev/pts >/dev/null 2>&1 || true' \
        '' \
        'echo "test pass!" > "$TTY_DEV" 2>/dev/null || echo "test pass!"' \
        'if command -v cttyhack >/dev/null 2>&1; then' \
        '    exec /bin/busybox cttyhack /bin/sh -i' \
        'elif command -v setsid >/dev/null 2>&1; then' \
        '    exec /bin/busybox setsid /bin/sh -i' \
        'else' \
        '    exec /bin/sh -i' \
        'fi' \
        > init
    chmod +x init
    # Create /etc/init.d/rcS to avoid busybox init errors
    mkdir -p etc/init.d
    echo '#!/bin/sh' > etc/init.d/rcS
    echo 'echo rcS running' >> etc/init.d/rcS
    chmod +x etc/init.d/rcS
}

mkfs_pack_fs() {
    # 0. Prepare working directory
    OUTPUT_DIR="${MKFS_OUT_DIR:-${ROOT_DIR}/IMAGES/qemu/linux/${MKFS_ARCH}}"
    mkdir -p "$OUTPUT_DIR"
    
    # Convert guest directory to absolute path before changing directory
    if [[ -n "$MKFS_GUEST_DIR" ]]; then
        MKFS_GUEST_DIR="$(cd "$MKFS_GUEST_DIR" 2>/dev/null && pwd -P)" || {
            warn "Guest directory $MKFS_GUEST_DIR does not exist or is not accessible"
            MKFS_GUEST_DIR=""
        }
    fi
    
    TMP_DIR=$(mktemp -d)
    cleanup() { rm -rf "$TMP_DIR"; }
    trap cleanup EXIT
    cd "$TMP_DIR"
    echo "Creating minimal ramfs in $TMP_DIR"

    # 1. Create necessary directory structure
    mkdir -p bin sbin usr/bin usr/sbin dev dev/pts etc proc sys
    # 1.5 Copy guest directory if specified
    if [[ -n "$MKFS_GUEST_DIR" ]]; then
        if [[ -d "$MKFS_GUEST_DIR" ]]; then
            info "Copying guest directory: $MKFS_GUEST_DIR -> guest/"
            # Use rsync or cp with proper flags to ensure directory is copied
            if command -v rsync >/dev/null 2>&1; then
                rsync -a "$MKFS_GUEST_DIR/" guest/ 2>/dev/null || true
            else
                # Fallback to cp with recursive and archive flags
                cp -a "$MKFS_GUEST_DIR"/. guest/ 2>/dev/null || true
            fi
            # Verify guest directory was created
            if [[ -d "guest" ]]; then
                info "Guest directory copied successfully, contents:"
                ls -la guest/ || true
            else
                warn "Failed to create guest directory"
            fi
        else
            warn "Guest directory $MKFS_GUEST_DIR does not exist, skipping..."
        fi
    fi
    # 2. Use fakeroot to create device nodes
    fakeroot bash -c '
        mknod dev/console c 5 1 || true
        mknod dev/null c 1 3 || true
        mknod dev/zero c 1 5 || true
        mknod dev/tty c 5 0 || true
        mknod dev/ttyS0 c 4 64 || true
    '
    # 3. Install busybox (if dynamically linked, copy required shared libraries) and create necessary symlinks
    cp "$BUSYBOX_SRC_DIR/busybox" bin/
    if command -v ldd >/dev/null 2>&1; then
        ldd_output="$(ldd "$BUSYBOX_SRC_DIR/busybox" 2>&1 || true)"
        if ! printf '%s' "$ldd_output" | grep -q "not a dynamic executable"; then
            echo "BusyBox is dynamically linked; copying dependent libraries..."
            printf '%s' "$ldd_output" | awk '{ if ($3 ~ /^\//) print $3; else if ($1 ~ /^\//) print $1 }' | sort -u | while IFS= read -r lib; do
                [ -f "$lib" ] || continue
                rel_dir="${lib%/*}"
                mkdir -p ".${rel_dir}"
                cp -u "$lib" ".${lib}" 2>/dev/null || cp "$lib" ".${lib}" || true
            done
        fi
    fi
    [[ -e bin/sh ]] || ln -s busybox bin/sh
    # 4. Create init script
    mkfs_create_init
    [[ -e bin/init ]] || ln -s ../init bin/init

    # 5. Pack ramfs
    local abs_out="$OUTPUT_DIR/initramfs.cpio.gz"
    echo "Packing ramfs -> $abs_out"
    chmod 755 . || true
    find . -print0 | sort -z 2>/dev/null | cpio --null -H newc -o 2>/dev/null | gzip -9 > "$abs_out"
    echo "Minimal ramfs created: $abs_out"
    du -h "$abs_out" | awk '{print "Size: "$1}'

    # 6. Pack ext4 rootfs.img
    local img_out="$OUTPUT_DIR/rootfs.img"
    local size_mb=32
    echo "Packing ext4 rootfs (debugfs write) -> $img_out"
    dd if=/dev/zero of="$img_out" bs=1M count=$size_mb status=none
    mkfs.ext4 -q -F "$img_out"
    if ! command -v debugfs >/dev/null 2>&1; then
        echo "Error: debugfs not found. Please install: sudo apt install e2fsprogs" >&2
        return 1
    fi
    find . -type d | while read -r d; do
        debugfs -w -R "mkdir ${d#.}" "$img_out" >/dev/null 2>&1
    done
    # Write regular files
    find . -type f | while read -r f; do
        debugfs -w -R "write $f ${f#.}" "$img_out" >/dev/null 2>&1
    done
    # Write symlinks
    find . -type l | while read -r lnk; do
        target=$(readlink "$lnk")
        debugfs -w -R "symlink ${lnk#.} $target" "$img_out" >/dev/null 2>&1
    done
    echo "rootfs.img created: $img_out"
    du -h "$img_out" | awk '{print "Size: "$1}'
}

mkfs() {
    info "Cloning busybox source repository $BUSYBOX_REPO_URL -> $BUSYBOX_SRC_DIR"
    clone_repository "$BUSYBOX_REPO_URL" "$BUSYBOX_SRC_DIR"

    if [[ -d "$BUSYBOX_PATCH_DIR" ]]; then
        info "Applying patches..."
        apply_patches "$BUSYBOX_PATCH_DIR" "$BUSYBOX_SRC_DIR"
    fi

    info "Starting to build busybox..."
    mkfs_build_busybox

    info "Packing filesystem..."
    mkfs_pack_fs
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            mkfs_usage
            exit 0
            ;;
        aarch64|riscv64|x86_64)
            MKFS_ARCH="$cmd"
            ;;
        *)
            die "Unknown command: $cmd"
            ;;
    esac

    # Parse the other arguments
    mkfs_parse_args "$@"

    # Call the main function
    mkfs
fi
