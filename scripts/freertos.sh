#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/.." && pwd -P)
BUILD_DIR="$(cd "${ROOT_DIR}" && mkdir -p "build" && cd "build" && pwd -P)"

source "$SCRIPT_DIR/utils.sh"

# Repository and directory configuration
FREERTOS_REPO_URL="https://github.com/zephyrproject-rtos/rtos-benchmark.git"
FREERTOS_KERNEL_REPO_URL="https://github.com/FreeRTOS/FreeRTOS-Kernel.git"
FREERTOS_KERNEL_SRC_DIR="${BUILD_DIR}/FreeRTOS-Kernel"
FREERTOS_PATCH_DIR="${ROOT_DIR}/patches/freertos"
FREERTOS_CROSS_COMPILE="${FREERTOS_CROSS_COMPILE:-aarch64-linux-gnu-}"

# Shared source directory (all targets reuse the same clone, patches are re-applied per build)
FREERTOS_SRC_DIR="${BUILD_DIR}/freertos"

# Resolve cross-compiler binary directory
CC_PATH="$(command -v "${FREERTOS_CROSS_COMPILE}gcc" 2>/dev/null || true)"
if [[ -z "$CC_PATH" ]]; then
    die "Cross compiler not found: ${FREERTOS_CROSS_COMPILE}gcc"
fi
CROSS_BIN_DIR="$(dirname "$CC_PATH")"

# Output help information
usage() {
    printf 'Build FreeRTOS rtos-benchmark for supported platforms\n'
    printf '\n'
    printf 'Usage:\n'
    printf '  scripts/freertos.sh <command> [options]\n'
    printf '\n'
    printf 'Commands:\n'
    printf '  qemu                               Build for QEMU (aarch64)\n'
    printf '  phytiumpi                          Build for Phytium Pi\n'
    printf '  orangepi-5-plus                    Build for Orange Pi 5 Plus\n'
    printf '  all                                Build all supported platforms\n'
    printf '  help, -h, --help                   Display this help information\n'
    printf '  test                               Run self-test for fix_cmake_paths
  clean                              Clean build output artifacts\n'
    printf '\n'
    printf 'Environment Variables:\n'
    printf '  FREERTOS_CROSS_COMPILE             Cross compiler prefix (default: aarch64-linux-gnu-)\n'
    printf '\n'
    printf 'Examples:\n'
    printf '  scripts/freertos.sh qemu           # Build for QEMU\n'
    printf '  scripts/freertos.sh all            # Build all platforms\n'
    printf '  scripts/freertos.sh clean          # Clean all\n'
}

# ── Apply a single patch file ────────────────────────────────────────────────

apply_single_patch() {
    local patch_file="$1"
    local src_dir="$2"
    local exclude_pattern="${3:-}"

    if [[ ! -f "$patch_file" ]]; then
        die "Patch file not found: $patch_file"
    fi

    local stamp_dir="${src_dir}/.patch_stamps"
    local base
    base=$(basename "$patch_file")
    local stamp="${stamp_dir}/${base}.applied"

    mkdir -p "$stamp_dir"
    if [[ -f "$stamp" ]]; then
        info "[SKIP] $base (stamp exists)"
        return 0
    fi

    pushd "$src_dir" >/dev/null

    local applied=0
    local exclude_args=()
    if [[ -n "$exclude_pattern" ]]; then
        exclude_args=(--exclude "$exclude_pattern")
    fi

    # Try git apply
    if git apply --check "${exclude_args[@]}" "$patch_file" >/dev/null 2>&1; then
        if git apply "${exclude_args[@]}" "$patch_file" >>"${LOG_FILE}" 2>&1; then
            applied=1
            echo > "$stamp"
            info "[APPLY] $base (git apply)"
        fi
    elif [[ ${#exclude_args[@]} -eq 0 ]] && git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
        info "[SKIP] $base (already applied)"
        echo > "$stamp"
        applied=1
    fi

    # Try git apply --3way for conflicting patches
    if [[ $applied -eq 0 ]] && git apply --3way "${exclude_args[@]}" "$patch_file" >>"${LOG_FILE}" 2>&1; then
        applied=1
        echo > "$stamp"
        info "[APPLY] $base (git apply --3way)"
    fi

    # Fallback to patch command
    if [[ $applied -eq 0 ]]; then
        for plevel in 1 0; do
            if patch -p${plevel} --dry-run < "$patch_file" >/dev/null 2>&1; then
                if patch -p${plevel} < "$patch_file" >>"${LOG_FILE}" 2>&1; then
                    applied=1
                    echo > "$stamp"
                    info "[APPLY] $base (patch -p${plevel})"
                    break
                fi
            fi
        done
    fi

    popd >/dev/null

    if [[ $applied -eq 0 ]]; then
        die "Cannot apply patch: $base"
    fi
}

# ── Clone and patch ──────────────────────────────────────────────────────────

prepare_source() {
    info "Cloning rtos-benchmark source repository $FREERTOS_REPO_URL -> $FREERTOS_SRC_DIR"
    clone_repository "$FREERTOS_REPO_URL" "$FREERTOS_SRC_DIR"

    info "Cloning FreeRTOS-Kernel source repository $FREERTOS_KERNEL_REPO_URL -> $FREERTOS_KERNEL_SRC_DIR"
    clone_repository "$FREERTOS_KERNEL_REPO_URL" "$FREERTOS_KERNEL_SRC_DIR"
}

# Restore shared source to clean state and ensure it's cloned
prepare_target_source() {
    prepare_source

    # Restore source to clean state before patching (remove previous patches/build artifacts)
    if [[ -d "${FREERTOS_SRC_DIR}/.git" ]]; then
        info "Restoring source to clean state"
        pushd "${FREERTOS_SRC_DIR}" >/dev/null
        git checkout -- . 2>>"${LOG_FILE}" || true
        git clean -fd 2>>"${LOG_FILE}" || true
        rm -rf .patch_stamps build-* */build
        popd >/dev/null
    fi
}

# ── Freestanding libc support ────────────────────────────────────────────────

ensure_freestanding_libc_support() {
    local support_dir="${FREERTOS_SRC_DIR}/src/freertos_aarch64_guest"
    local support_file="${support_dir}/freestanding_libc.c"

    mkdir -p "$support_dir"

    cat > "$support_file" <<'EOF'
#include <stddef.h>

void *memcpy(void *dst, const void *src, size_t n)
{
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;

    for (size_t i = 0; i < n; i++) {
        d[i] = s[i];
    }

    return dst;
}

void *memset(void *dst, int c, size_t n)
{
    unsigned char *d = (unsigned char *)dst;

    for (size_t i = 0; i < n; i++) {
        d[i] = (unsigned char)c;
    }

    return dst;
}

int memcmp(const void *lhs, const void *rhs, size_t n)
{
    const unsigned char *a = (const unsigned char *)lhs;
    const unsigned char *b = (const unsigned char *)rhs;

    for (size_t i = 0; i < n; i++) {
        if (a[i] != b[i]) {
            return (int)a[i] - (int)b[i];
        }
    }

    return 0;
}

size_t strlen(const char *s)
{
    size_t len = 0;

    while (s[len] != '\0') {
        len++;
    }

    return len;
}

size_t __strnlen(const char *s, size_t maxlen)
{
    size_t len = 0;

    while (len < maxlen && s[len] != '\0') {
        len++;
    }

    return len;
}

int strcmp(const char *lhs, const char *rhs)
{
    while (*lhs != '\0' && *lhs == *rhs) {
        lhs++;
        rhs++;
    }

    return (int)(unsigned char)*lhs - (int)(unsigned char)*rhs;
}

int strncmp(const char *lhs, const char *rhs, size_t n)
{
    for (size_t i = 0; i < n; i++) {
        if (lhs[i] != rhs[i] || lhs[i] == '\0' || rhs[i] == '\0') {
            return (int)(unsigned char)lhs[i] - (int)(unsigned char)rhs[i];
        }
    }

    return 0;
}

char *strchr(const char *s, int c)
{
    unsigned char needle = (unsigned char)c;

    for (;; s++) {
        if ((unsigned char)*s == needle) {
            return (char *)s;
        }
        if (*s == '\0') {
            return NULL;
        }
    }
}

char *strrchr(const char *s, int c)
{
    const char *last = NULL;
    unsigned char needle = (unsigned char)c;

    for (;; s++) {
        if ((unsigned char)*s == needle) {
            last = s;
        }
        if (*s == '\0') {
            return (char *)last;
        }
    }
}

char *strstr(const char *haystack, const char *needle)
{
    size_t needle_len;

    if (*needle == '\0') {
        return (char *)haystack;
    }

    needle_len = strlen(needle);
    while (*haystack != '\0') {
        if (*haystack == *needle && strncmp(haystack, needle, needle_len) == 0) {
            return (char *)haystack;
        }
        haystack++;
    }

    return NULL;
}

__attribute__((noreturn))
void __assert_fail(const char *assertion, const char *file,
                   unsigned int line, const char *function)
{
    (void)assertion;
    (void)file;
    (void)line;
    (void)function;

    for (;;) {
    }
}
EOF
}

# ── Fix hardcoded paths in cmake toolchain files ─────────────────────────────

fix_cmake_paths() {
    local cmake_file="$1"
    if [[ ! -f "$cmake_file" ]]; then
        die "CMake toolchain file not found: $cmake_file"
    fi

    info "Fixing hardcoded paths in $cmake_file"
    sed -i \
        -e "s|/code/rtos/FreeRTOS-Kernel|${FREERTOS_KERNEL_SRC_DIR}|g" \
        -e "s|set(AARCH64_GCC_DIR \".*\"|set(AARCH64_GCC_DIR \"${CROSS_BIN_DIR}\"|g" \
        -e "s|aarch64-zephyr-elf-gcc|${FREERTOS_CROSS_COMPILE}gcc|g" \
        -e "s|aarch64-zephyr-elf-objcopy|${FREERTOS_CROSS_COMPILE}objcopy|g" \
        -e "/--specs=nano\.specs/d" \
        -e "/--specs=nosys\.specs/d" \
        -e 's/-nostartfiles/-nostartfiles -nostdlib/' \
        "$cmake_file"

    ensure_freestanding_libc_support

    sed -i '/# Pull minimal string functions from libc for fdt.c/,+2d' "$cmake_file"

    if ! grep -q "add_compile_definitions(NDEBUG)" "$cmake_file"; then
        sed -i '/^add_executable/i add_compile_definitions(NDEBUG)\n' "$cmake_file"
    fi

    sed -i '/freestanding_libc\.c/d' "$cmake_file"

    if ! grep -q 'src/freertos_aarch64_guest/bench_porting_layer_freertos.c' "$cmake_file"; then
        die "Expected guest FreeRTOS source list not found in $cmake_file"
    fi

    if ! grep -q "freestanding_libc.c" "$cmake_file"; then
        sed -i '/src\/freertos_aarch64_guest\/bench_porting_layer_freertos.c/a\    src/freertos_aarch64_guest/freestanding_libc.c' "$cmake_file"
    fi

    if ! grep -q '^target_link_libraries(app PRIVATE gcc)$' "$cmake_file"; then
        sed -i '/^add_custom_command/i target_link_libraries(app PRIVATE gcc)\n' "$cmake_file"
    fi

    # Fix bench_api.h: add FREERTOS_AARCH64_GUEST/QEMU guard before the FREERTOS guard
    # so it includes the aarch64 guest porting layer instead of the MCU-based one
    local bench_api_h="${FREERTOS_SRC_DIR}/h/bench_api.h"
    if [[ -f "$bench_api_h" ]] && ! grep -q "FREERTOS_AARCH64_GUEST\|FREERTOS_AARCH64_QEMU" "$bench_api_h"; then
        info "Fixing bench_api.h: adding aarch64 guest porting layer guard"
        sed -i '/#ifdef FREERTOS/i\
#if defined(FREERTOS_AARCH64_GUEST) || defined(FREERTOS_AARCH64_QEMU)\
#include "../src/freertos_aarch64_guest/bench_porting_layer_freertos.h"\
#elif defined(FREERTOS)' "$bench_api_h"
        # Close the elif: replace #endif with #endif // FREERTOS, and add extra #endif
        sed -i 's|^#endif /\* FREERTOS \*/$|#endif /* FREERTOS */\n#endif /* FREERTOS_AARCH64 */|' "$bench_api_h"
        sed -i 's|^#endif /\*FREERTOS\*/$|#endif /*FREERTOS*/\n#endif /* FREERTOS_AARCH64 */|' "$bench_api_h"
    fi
}

# ── CMake build (shared by qemu and phytiumpi) ───────────────────────────────

build_cmake() {
    local rtos_name="$1"      # e.g. freertos_aarch64_qemu
    local cmake_file="$2"     # e.g. src/freertos_aarch64_qemu/freertos_aarch64_qemu.cmake
    local bin_name="$3"       # e.g. freertos-aarch64-qemu.bin
    local out_name="$4"       # e.g. freertos-qemu
    local images_dir="$5"     # e.g. IMAGES/qemu/freertos

    # Fix hardcoded paths in the platform cmake file
    info "Fixing cmake paths: $cmake_file"
    fix_cmake_paths "${FREERTOS_SRC_DIR}/${cmake_file}"

    # Add the platform RTOS name to AVAILABLE_RTOSES in top-level CMakeLists.txt (idempotent)
    if ! grep -q "${rtos_name}" "${FREERTOS_SRC_DIR}/CMakeLists.txt"; then
        sed -i "s|    freertos)|    freertos\n    ${rtos_name})|" \
            "${FREERTOS_SRC_DIR}/CMakeLists.txt"
    fi

    local build_dir="${FREERTOS_SRC_DIR}/build-${rtos_name}"
    mkdir -p "$build_dir"
    pushd "$build_dir" >/dev/null

    info "Configuring CMake with -DRTOS=${rtos_name}"
    cmake -DRTOS="${rtos_name}" "${FREERTOS_SRC_DIR}"

    info "Building ${rtos_name}"
    make -j"$(nproc)"

    popd >/dev/null

    local bin_path="${build_dir}/${bin_name}"
    if [[ ! -f "$bin_path" ]]; then
        die "Build output not found: $bin_path"
    fi

    mkdir -p "$images_dir"
    cp -f "$bin_path" "${images_dir}/${out_name}"
    success "Image saved: ${images_dir}/${out_name}"
}

# ── QEMU ─────────────────────────────────────────────────────────────────────

qemu() {
    if [[ "$#" -gt 0 && "$1" == "clean" ]]; then
        info "Cleaning QEMU FreeRTOS build artifacts"
        rm -rf "${FREERTOS_SRC_DIR}/build-freertos_aarch64_qemu"
        rm -rf "${ROOT_DIR}/IMAGES/qemu/freertos"
        return
    fi

    prepare_target_source

    info "Applying patch: rtos-benchmark-qemu-a53.patch"
    apply_single_patch "${FREERTOS_PATCH_DIR}/rtos-benchmark-qemu-a53.patch" "$FREERTOS_SRC_DIR"

    build_cmake \
        "freertos_aarch64_qemu" \
        "src/freertos_aarch64_qemu/freertos_aarch64_qemu.cmake" \
        "freertos-aarch64-qemu.bin" \
        "freertos-qemu" \
        "${ROOT_DIR}/IMAGES/qemu/freertos"
}

# ── Phytium Pi ───────────────────────────────────────────────────────────────

phytiumpi() {
    if [[ "$#" -gt 0 && "$1" == "clean" ]]; then
        info "Cleaning PhytiumPi FreeRTOS build artifacts"
        rm -rf "${FREERTOS_SRC_DIR}/build-freertos_aarch64_guest"
        rm -rf "${ROOT_DIR}/IMAGES/phytiumpi/freertos"
        return
    fi

    prepare_target_source

    info "Applying patch: rtos-benchmark-phytiumpi.patch"
    apply_single_patch "${FREERTOS_PATCH_DIR}/rtos-benchmark-phytiumpi.patch" "$FREERTOS_SRC_DIR"

    build_cmake \
        "freertos_aarch64_guest" \
        "src/freertos_aarch64_guest/freertos_aarch64_guest.cmake" \
        "freertos-aarch64-guest.bin" \
        "freertos-phytiumpi" \
        "${ROOT_DIR}/IMAGES/phytiumpi/freertos"
}

# ── Orange Pi ────────────────────────────────────────────────────────────────

orangepi-5-plus() {
    if [[ "$#" -gt 0 && "$1" == "clean" ]]; then
        info "Cleaning OrangePi FreeRTOS build artifacts"
        rm -rf "${FREERTOS_SRC_DIR}/src/freertos_aarch64_orangepi/build"
        rm -rf "${ROOT_DIR}/IMAGES/orangepi/freertos"
        return
    fi

    prepare_target_source

    info "Applying patch: rtos-benchmark-orangepi.patch"
    apply_single_patch "${FREERTOS_PATCH_DIR}/rtos-benchmark-orangepi.patch" "$FREERTOS_SRC_DIR"

    local orangepi_src="${FREERTOS_SRC_DIR}/src/freertos_aarch64_orangepi"
    local build_sh="${orangepi_src}/build.sh"
    if [[ ! -f "$build_sh" ]]; then
        die "Build script not found: $build_sh"
    fi

    info "Building Orange Pi FreeRTOS via build.sh"
    FREERTOS_KERNEL_PATH="$FREERTOS_KERNEL_SRC_DIR" \
    CROSS_COMPILE="$FREERTOS_CROSS_COMPILE" \
    bash "$build_sh"

    local bin_path="${orangepi_src}/build/freertos_aarch64_orangepi.bin"
    if [[ ! -f "$bin_path" ]]; then
        die "Build output not found: $bin_path"
    fi

    local images_dir="${ROOT_DIR}/IMAGES/orangepi/freertos"
    mkdir -p "$images_dir"
    cp -f "$bin_path" "${images_dir}/freertos-orangepi"
    success "Image saved: ${images_dir}/freertos-orangepi"
}

# ── Self-test ────────────────────────────────────────────────────────────────

selftest() {
    info "Running self-test for fix_cmake_paths"

    local tmpdir
    tmpdir=$(mktemp -d)
    trap 'rm -rf "${tmpdir}"' RETURN

    local saved_log_file="${LOG_FILE}"
    export LOG_FILE="${tmpdir}/test.log"

    mkdir -p "${tmpdir}/src/h" "${tmpdir}/src/src/freertos_aarch64_guest"

    cat > "${tmpdir}/src/h/bench_api.h" <<'EOF'
#ifdef FREERTOS
#include "../src/freertos/bench_porting_layer_freertos.h"
#endif /* FREERTOS */
EOF

    cat > "${tmpdir}/toolchain.cmake" <<'EOF'
set(AARCH64_GCC_DIR "/code/toolchain")
set(CMAKE_EXE_LINKER_FLAGS "${CMAKE_EXE_LINKER_FLAGS} -nostartfiles")

add_executable(app
    src/freertos_aarch64_guest/bench_porting_layer_freertos.c
)
target_link_libraries(app PRIVATE gcc)
add_custom_command(TARGET app POST_BUILD COMMAND true)
EOF

    local saved_src_dir="${FREERTOS_SRC_DIR}"
    local saved_kernel_dir="${FREERTOS_KERNEL_SRC_DIR}"
    local saved_cross_compile="${FREERTOS_CROSS_COMPILE}"
    local saved_cross_bin_dir="${CROSS_BIN_DIR}"

    FREERTOS_SRC_DIR="${tmpdir}/src"
    FREERTOS_KERNEL_SRC_DIR="/tmp/freertos-kernel"
    FREERTOS_CROSS_COMPILE="aarch64-linux-gnu-"
    CROSS_BIN_DIR="$(dirname "$(command -v aarch64-linux-gnu-gcc)")"

    fix_cmake_paths "${tmpdir}/toolchain.cmake"

    local ok=1
    if ! grep -q 'src/freertos_aarch64_guest/freestanding_libc.c' "${tmpdir}/toolchain.cmake"; then
        echo "FAIL: expected freestanding libc source to be injected" >&2
        ok=0
    fi
    if grep -q 'libc_string_objs' "${tmpdir}/toolchain.cmake"; then
        echo "FAIL: unexpected libc_string_objs glob remains in cmake file" >&2
        ok=0
    fi
    if ! grep -q 'add_compile_definitions(NDEBUG)' "${tmpdir}/toolchain.cmake"; then
        echo "FAIL: expected NDEBUG compile definition to be injected" >&2
        ok=0
    fi
    if [[ ! -f "${tmpdir}/src/src/freertos_aarch64_guest/freestanding_libc.c" ]]; then
        echo "FAIL: expected freestanding_libc.c to be generated" >&2
        ok=0
    fi

    FREERTOS_SRC_DIR="${saved_src_dir}"
    FREERTOS_KERNEL_SRC_DIR="${saved_kernel_dir}"
    FREERTOS_CROSS_COMPILE="${saved_cross_compile}"
    CROSS_BIN_DIR="${saved_cross_bin_dir}"
    export LOG_FILE="${saved_log_file}"

    if [[ $ok -eq 1 ]]; then
        success "All self-tests passed"
    else
        die "Self-test failed"
    fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    cmd="${1:-}"
    shift || true
    case "$cmd" in
        ""|-h|--help|help)
            usage
            exit 0
            ;;
        qemu)
            qemu "$@"
            ;;
        phytiumpi)
            phytiumpi "$@"
            ;;
        orangepi-5-plus)
            orangepi-5-plus "$@"
            ;;
        all)
            qemu "$@"
            phytiumpi "$@"
            orangepi-5-plus "$@"
            ;;
        clean)
            rm -rf "${FREERTOS_SRC_DIR}"
            qemu "clean"
            phytiumpi "clean"
            orangepi-5-plus "clean"
            ;;
        *)
            die "Unknown command: $cmd (supported: qemu, phytiumpi, orangepi-5-plus, all, clean)"
            ;;
    esac
fi
