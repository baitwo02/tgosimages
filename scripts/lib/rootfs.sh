#!/bin/bash

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    echo "This is a library, should be sourced, not executed." >&2
    exit 1
fi

rootfs_build_one() {
    local rootfs_builder="$1"
    local rootfs_script="${SCRIPT_DIR}/../rootfs/${rootfs_builder}.sh"
    local guest_dir="${ROOTFS_STAGE_DIR}/guest"

    [[ -n "${ROOTFS_ARCH:-}" ]] || die "ROOTFS_ARCH is not set"

    if [[ ! -f "${rootfs_script}" ]]; then
        die "Root filesystem script does not exist: ${rootfs_script}"
    fi

    mkdir -p "${ROOTFS_IMAGES_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    info "Creating root filesystem: ${rootfs_script} -> ${ROOTFS_IMAGES_DIR:-${ROOT_DIR}/IMAGES/rootfs}"

    case "${rootfs_builder}" in
        busybox|alpine|debian)
            [[ -d "${guest_dir}" ]] || die "Guest staging directory not found: ${guest_dir}"
            bash "${rootfs_script}" "${ROOTFS_ARCH}" --out_dir "${ROOTFS_IMAGES_DIR:-${ROOT_DIR}/IMAGES/rootfs}" --guest "${guest_dir}"
            ;;
        "")
            return 0
            ;;
        *)
            die "Unsupported rootfs builder: ${rootfs_builder} (supported: busybox, alpine, debian)"
            ;;
    esac

    success "Root filesystem creation completed"
}

rootfs_ensure_stage_dir() {
    if [[ -n "${ROOTFS_STAGE_DIR:-}" ]]; then
        return 0
    fi

    local stage_prefix="${ROOTFS_STAGE_PREFIX:-rootfs-stage}"
    ROOTFS_STAGE_DIR="$(mktemp -d "${BUILD_DIR}/${stage_prefix}.XXXXXX")"
}

rootfs_stage_payload() {
    local relative_dir="$1"
    local source_dir="$2"
    local payload_dir

    [[ -d "${source_dir}" ]] || die "Payload source directory not found: ${source_dir}"

    rootfs_ensure_stage_dir
    payload_dir="${ROOTFS_STAGE_DIR}/${relative_dir}"
    rm -rf "${payload_dir}"
    mkdir -p "${payload_dir}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${source_dir}/" "${payload_dir}/"
    else
        cp -a "${source_dir}/." "${payload_dir}/"
    fi
}

rootfs_stage_guest_tree() {
    local stage_dir="$1"
    local source_dir="$2"
    local guest_dir

    [[ -d "${stage_dir}" ]] || die "Guest stage directory not found: ${stage_dir}"
    [[ -d "${source_dir}" ]] || die "Guest payload source directory not found: ${source_dir}"

    guest_dir="${stage_dir}/guest"
    rm -rf "${guest_dir}"
    mkdir -p "${guest_dir}"

    if command -v rsync >/dev/null 2>&1; then
        rsync -a "${source_dir}/" "${guest_dir}/"
    else
        cp -a "${source_dir}/." "${guest_dir}/"
    fi
}

rootfs_package_os() {
    local os_name="$1"
    local source_dir="$2"

    [[ ${#ROOTFS_BUILDERS[@]} -gt 0 ]] || return 0

    rootfs_stage_payload "${os_name}" "${source_dir}"
}

rootfs_finalize_builders() {
    [[ ${#ROOTFS_BUILDERS[@]} -gt 0 ]] || return 0
    [[ -n "${ROOTFS_STAGE_DIR:-}" && -d "${ROOTFS_STAGE_DIR}" ]] || {
        warn "No guest payload was staged for rootfs generation"
        return 0
    }

    local rootfs_builder
    for rootfs_builder in "${ROOTFS_BUILDERS[@]}"; do
        rootfs_build_one "${rootfs_builder}"
    done
}

rootfs_clean_generated_outputs() {
    local output_dir="${ROOTFS_IMAGES_DIR:-${ROOT_DIR}/IMAGES/rootfs}"
    local rootfs_builder

    [[ -n "${ROOTFS_ARCH:-}" ]] || die "ROOTFS_ARCH is not set"
    [[ ${#ROOTFS_BUILDERS[@]} -gt 0 ]] || return 0

    for rootfs_builder in "${ROOTFS_BUILDERS[@]}"; do
        case "${rootfs_builder}" in
            busybox)
                rm -f "${output_dir}/initramfs-${ROOTFS_ARCH}-busybox.cpio.gz"
                rm -f "${output_dir}/rootfs-${ROOTFS_ARCH}-busybox.img"
                ;;
            alpine)
                rm -f "${output_dir}/rootfs-${ROOTFS_ARCH}-alpine.img"
                ;;
            debian)
                rm -f "${output_dir}/rootfs-${ROOTFS_ARCH}-debian.img"
                ;;
            *)
                die "Unsupported rootfs builder: ${rootfs_builder} (supported: busybox, alpine, debian)"
                ;;
        esac
    done
}

rootfs_parse_build_args() {
    BUILD_ARGS=()
    ROOTFS_BUILDERS=()

    local builder
    local seen
    local -A rootfs_seen=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --rootfs)
                [[ $# -ge 2 ]] || die "--rootfs requires a value"
                IFS=',' read -r -a seen <<< "$2"
                for builder in "${seen[@]}"; do
                    [[ -n "${builder}" ]] || continue
                    case "${builder}" in
                        busybox|alpine|debian)
                            [[ -n "${rootfs_seen[${builder}]:-}" ]] && continue
                            rootfs_seen["${builder}"]=1
                            ROOTFS_BUILDERS+=("${builder}")
                            ;;
                        *)
                            die "Unsupported rootfs builder: ${builder} (supported: busybox, alpine, debian)"
                            ;;
                    esac
                done
                shift 2
                ;;
            *)
                BUILD_ARGS+=("$1")
                shift
                ;;
        esac
    done
}

rootfs_apply_default_builders() {
    local target="${1:-}"

    [[ ${#ROOTFS_BUILDERS[@]} -gt 0 ]] && return 0

    case "${target}" in
        clean|help|-h|--help|"")
            return 0
            ;;
    esac

    ROOTFS_BUILDERS=(busybox alpine debian)
}

rootfs_prepare_target() {
    local rootfs_target="$1"

    [[ -n "${rootfs_target}" ]] || die "rootfs target is empty"
    mkdir -p "$(dirname "${rootfs_target}")"
    rm -f "${rootfs_target}"
}

rootfs_publish_target() {
    local source_path="$1"
    local target_path="$2"

    [[ -f "${source_path}" ]] || return 1
    rootfs_prepare_target "${target_path}"
    cp -f "${source_path}" "${target_path}"
}

_rootfs_detect_fs_type() {
    local target="$1"
    local fs_type=""

    fs_type="$(blkid -o value -s TYPE "${target}" 2>/dev/null || true)"
    if [[ -n "${fs_type}" ]]; then
        printf '%s\n' "${fs_type}"
        return 0
    fi

    if command -v file >/dev/null 2>&1; then
        file -b "${target}" 2>/dev/null | awk '
            /ext2 filesystem/ { print "ext2"; exit }
            /ext3 filesystem/ { print "ext3"; exit }
            /ext4 filesystem/ { print "ext4"; exit }
        '
    fi
}

_rootfs_inject_tree_via_debugfs() {
    local image_path="$1"
    local source_dir="$2"
    local abs_source
    local rel_path
    local target_path
    local link_target

    command -v debugfs >/dev/null 2>&1 || {
        warn "debugfs not found, cannot inject into ext filesystem image: ${image_path}"
        return 1
    }

    abs_source="$(cd "${source_dir}" && pwd -P)"
    pushd "${abs_source}" >/dev/null

    while IFS= read -r rel_path; do
        [[ "${rel_path}" == "." ]] && continue
        target_path="/${rel_path#./}"
        debugfs -w -R "mkdir ${target_path}" "${image_path}" >/dev/null 2>&1 || true
    done < <(find . -type d | sort)

    while IFS= read -r rel_path; do
        target_path="/${rel_path#./}"
        debugfs -w -R "rm ${target_path}" "${image_path}" >/dev/null 2>&1 || true
        debugfs -w -R "write ${abs_source}/${rel_path#./} ${target_path}" "${image_path}" >/dev/null || {
            popd >/dev/null
            return 1
        }
    done < <(find . -type f | sort)

    while IFS= read -r rel_path; do
        target_path="/${rel_path#./}"
        link_target="$(readlink "${rel_path}")"
        debugfs -w -R "rm ${target_path}" "${image_path}" >/dev/null 2>&1 || true
        debugfs -w -R "symlink ${target_path} ${link_target}" "${image_path}" >/dev/null || {
            popd >/dev/null
            return 1
        }
    done < <(find . -type l | sort)

    popd >/dev/null
}

_rootfs_inject_tree_via_loop_mount() {
    local image_path="$1"
    local source_dir="$2"
    local loop_dev=""
    local mount_dir=""
    local root_partition=""
    local status=0

    command -v losetup >/dev/null 2>&1 || return 1
    command -v lsblk >/dev/null 2>&1 || return 1
    command -v mount >/dev/null 2>&1 || return 1

    if [[ "${EUID}" -ne 0 ]]; then
        warn "Loop-mount injection requires root privileges: ${image_path}"
        return 1
    fi

    loop_dev="$(losetup --find --show --partscan "${image_path}")" || return 1
    mount_dir="$(mktemp -d "${BUILD_DIR}/rootfs-mount.XXXXXX")"

    root_partition="$(
        lsblk -lnbo NAME,FSTYPE,SIZE "${loop_dev}" 2>/dev/null \
            | awk '$2 ~ /^ext[234]$/ { print $1, $3 }' \
            | sort -k2 -nr \
            | head -n1 \
            | awk '{ print $1 }'
    )"

    if [[ -z "${root_partition}" ]]; then
        warn "No ext filesystem partition found in disk image: ${image_path}"
        status=1
    elif ! mount "${root_partition}" "${mount_dir}"; then
        warn "Failed to mount rootfs partition ${root_partition} from ${image_path}"
        status=1
    else
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" "${mount_dir}/" || status=1
        else
            cp -a "${source_dir}/." "${mount_dir}/" || status=1
        fi
        sync
        umount "${mount_dir}" || status=1
    fi

    losetup -d "${loop_dev}" >/dev/null 2>&1 || true
    rm -rf "${mount_dir}"
    return "${status}"
}

rootfs_inject_guest_stage() {
    local rootfs_target="$1"
    local source_dir="$2"
    local fs_type=""

    [[ -d "${source_dir}" ]] || {
        warn "Guest source directory not found, skipping rootfs injection: ${source_dir}"
        return 0
    }

    if [[ -z "${rootfs_target}" ]]; then
        warn "No rootfs target found, skipping /guest injection"
        return 0
    fi

    if [[ -d "${rootfs_target}" ]]; then
        info "Injecting guest payload into rootfs directory: ${rootfs_target}"
        mkdir -p "${rootfs_target}/guest"
        if command -v rsync >/dev/null 2>&1; then
            rsync -a "${source_dir}/" "${rootfs_target}/guest/"
        else
            cp -a "${source_dir}/." "${rootfs_target}/guest/"
        fi
        return 0
    fi

    if [[ ! -f "${rootfs_target}" ]]; then
        warn "Rootfs target does not exist, skipping /guest injection: ${rootfs_target}"
        return 0
    fi

    fs_type="$(_rootfs_detect_fs_type "${rootfs_target}")"
    if [[ "${fs_type}" =~ ^ext[234]$ ]]; then
        info "Injecting guest payload into ext filesystem image: ${rootfs_target}"
        local stage_dir
        stage_dir="$(mktemp -d "${BUILD_DIR}/rootfs-inject.XXXXXX")"
        rootfs_stage_guest_tree "${stage_dir}" "${source_dir}"
        _rootfs_inject_tree_via_debugfs "${rootfs_target}" "${stage_dir}" || {
            rm -rf "${stage_dir}"
            die "Failed to inject guest payload into ext filesystem image: ${rootfs_target}"
        }
        rm -rf "${stage_dir}"
        return 0
    fi

    info "Attempting to inject guest payload into disk image: ${rootfs_target}"
    local stage_dir
    stage_dir="$(mktemp -d "${BUILD_DIR}/rootfs-inject.XXXXXX")"
    rootfs_stage_guest_tree "${stage_dir}" "${source_dir}"
    _rootfs_inject_tree_via_loop_mount "${rootfs_target}" "${stage_dir}" || {
        rm -rf "${stage_dir}"
        die "Failed to inject guest payload into disk image: ${rootfs_target}"
    }
    rm -rf "${stage_dir}"
}
