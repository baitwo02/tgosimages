#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd -P)
ROOT_DIR=$(cd "${SCRIPT_DIR}/../.." && pwd -P)
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

if command -v llvm-objcopy >/dev/null 2>&1; then
    OBJCOPY=llvm-objcopy
elif command -v rust-objcopy >/dev/null 2>&1; then
    OBJCOPY=rust-objcopy
else
    printf 'ArceOS artifact smoke test requires llvm-objcopy or rust-objcopy.\n' >&2
    exit 1
fi

SRC_DIR="${TMP_DIR}/tgoskits"
IMAGE_DIR="${TMP_DIR}/images"
FAKE_BIN_DIR="${TMP_DIR}/fake-bin"
PACKAGE="arceos-ivc-publisher"
FRESH_ELF="${SRC_DIR}/target/aarch64-unknown-linux-musl/release/${PACKAGE}"
STALE_BIN="${SRC_DIR}/target/aarch64-unknown-none-softfloat/release/${PACKAGE}.bin"

mkdir -p \
    "${SRC_DIR}" \
    "$(dirname "${FRESH_ELF}")" \
    "$(dirname "${STALE_BIN}")" \
    "${IMAGE_DIR}" \
    "${FAKE_BIN_DIR}"
cp /bin/true "${FRESH_ELF}"
printf 'stale ArceOS artifact\n' > "${STALE_BIN}"
cat > "${TMP_DIR}/build.toml" <<'EOF'
features = ["arceos"]
log = "Warn"
EOF
cat > "${FAKE_BIN_DIR}/cargo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '[axbuild] cargo build elf=%s\n' "${FAKE_ARCEOS_ELF}"
printf '[axbuild] cargo build artifact_dir=%s\n' "$(dirname "${FAKE_ARCEOS_ELF}")"
EOF
chmod +x "${FAKE_BIN_DIR}/cargo"

git -C "${SRC_DIR}" init -q
printf 'target/\n' > "${SRC_DIR}/.gitignore"
git -C "${SRC_DIR}" config user.name 'tgosimages test'
git -C "${SRC_DIR}" config user.email 'tgosimages@example.invalid'
git -C "${SRC_DIR}" add .gitignore
git -C "${SRC_DIR}" commit --allow-empty -q -m 'test source'
ARCEOS_REF="$(git -C "${SRC_DIR}" rev-parse HEAD)"

PATH="${FAKE_BIN_DIR}:${PATH}" \
FAKE_ARCEOS_ELF="${FRESH_ELF}" \
ARCEOS_SKIP_CHECKOUT=1 \
ARCEOS_REF="${ARCEOS_REF}" \
ARCEOS_SRC_DIR="${SRC_DIR}" \
LOG_CREATE_DEFAULT_FILE=0 \
    bash "${ROOT_DIR}/scripts/os/arceos.sh" \
        aarch64-dyn \
        --images-dir "${IMAGE_DIR}" \
        --image-name "${PACKAGE}.bin" \
        --package "${PACKAGE}" \
        --target aarch64-unknown-none-softfloat \
        --config "${TMP_DIR}/build.toml"

"${OBJCOPY}" --binary-architecture=aarch64 -O binary \
    "${FRESH_ELF}" "${TMP_DIR}/expected.bin"
cmp "${TMP_DIR}/expected.bin" "${IMAGE_DIR}/${PACKAGE}.bin"

printf 'ArceOS artifact smoke test passed.\n'
