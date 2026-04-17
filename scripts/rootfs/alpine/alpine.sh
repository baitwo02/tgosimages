ARCH=${ARCH:-riscv64}
IMG_SIZE=${IMG_SIZE:-1G}

# BASE=https://dl-cdn.alpinelinux.org/alpine
BASE=https://mirrors.cernet.edu.cn/alpine
REL=v3.23
URL=${BASE}/${REL}/releases/${ARCH}

eval $(curl -sS -L ${URL}/latest-releases.yaml | yq -o=shell '.[] | select(.flavor == "alpine-minirootfs")')

function download() {
    echo "Downloading ${file}..."
    echo "Arch: ${arch}"
    echo "Version: ${version}"
    echo "Date: ${date}"
    echo "Time: ${time}"
    echo "Size: $(numfmt --to=iec ${size}) (${size} bytes)"
    echo "SHA256: ${sha256}"
    echo "SHA512: ${sha512}"

    curl -# -L -O ${URL}/${file}

    echo "Verifying ${file}..."
    echo "${sha256}  ${file}" | sha256sum -c -
}

IMG=rootfs-${ARCH}.img

function mkfs() {
    fallocate -v -l ${IMG_SIZE} ${IMG}
    mkfs.ext4 -v -O ^metadata_csum -F ${IMG}
    fsck.ext4 -v -f ${IMG}
}

function extract() {
    mkdir -v -p mnt
    mount -v ${IMG} mnt

    echo "Extracting ${file} to ${IMG}..."
    tar -xzf ${file} -C mnt

    cp -av etc/* mnt/etc

    sed -i "s#https\?://dl-cdn.alpinelinux.org/alpine#${BASE}#g" mnt/etc/apk/repositories

    umount -v mnt
}

function compress() {
    echo "Compressing ${IMG} to ${IMG}.gz..."
    xz -k -f -v ${IMG}
}

# download
# mkfs
# extract
# compress

case $1 in
    download) download ;;
    mkfs) mkfs ;;
    extract) extract ;;
    compress) compress ;;
    all)
        download
        mkfs
        extract
        compress
        ;;
    *)
        echo "Usage: $0 {download|mkfs|extract|compress|all}"
        exit 1
        ;;
esac
