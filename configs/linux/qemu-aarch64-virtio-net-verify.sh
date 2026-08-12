#!/bin/sh
set -eu

peer=${1:-192.0.2.2}
port=${2:-4242}
payload=zephyr-linux-virtio-net

ip link set eth0 up
ip addr replace 192.0.2.1/24 dev eth0

reply=$(printf '%s\n' "${payload}" | nc -w 5 "${peer}" "${port}")
if [ "${reply}" != "${payload}" ]; then
    echo "LINUX_ZEPHYR_VIRTIO_NET_FAIL unexpected echo: ${reply}" >&2
    exit 1
fi

bytes=$(dd if=/dev/zero bs=1024 count=64 2>/dev/null | nc -w 5 "${peer}" "${port}" | wc -c)
if [ "${bytes}" -ne 65536 ]; then
    echo "LINUX_ZEPHYR_VIRTIO_NET_FAIL expected=65536 actual=${bytes}" >&2
    exit 1
fi

echo "LINUX_ZEPHYR_VIRTIO_NET_PASS bytes=${bytes} peer=${peer}:${port}"
