#!/usr/bin/env python3
"""Check the matched AArch64 image pair without mounting the rootfs."""

import argparse
import hashlib
from pathlib import Path
import subprocess
import tempfile
import tomllib

ROOT = Path(__file__).resolve().parents[2]


def require(condition, message):
    if not condition:
        raise SystemExit(message)


def sha256(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def check(image, kernel):
    require(image.is_file(), f"Missing rootfs: {image}")
    require(kernel.is_file(), f"Missing kernel: {kernel}")
    with tempfile.TemporaryDirectory(prefix="standard-aarch64-content-") as tmp:
        def extract(guest_path):
            output = Path(tmp) / Path(guest_path).name
            subprocess.run(
                ["debugfs", "-R", f"dump {guest_path} {output}", str(image)],
                check=True, capture_output=True,
            )
            # debugfs can return success even when the guest path is missing.
            require(output.is_file() and output.stat().st_size > 0,
                    f"Missing rootfs asset: {guest_path}")
            return output

        manifest = tomllib.loads(
            extract("/opt/axvisor/ivc/manifest.toml").read_text()
        )
        require(manifest["schema_version"] == 1, "Unexpected manifest schema")
        require(manifest["arch"] == "aarch64", "Unexpected manifest architecture")
        require(manifest["protocol"] == "ivc-message-v1", "Unexpected IVC protocol")
        require(sha256(kernel) == manifest["kernel_sha256"], "Kernel hash mismatch")
        require(sha256(extract("/guest/linux/linux-qemu")) == sha256(kernel),
                "Rootfs and QEMU kernels differ")

        modules = (
            ("uio", "uio_sha256", "uio_vermagic"),
            ("axvisor", "axvisor_ko_sha256", "axvisor_vermagic"),
            ("uio_ivshmem", "uio_ivshmem_sha256", "uio_ivshmem_vermagic"),
        )
        for name, hash_key, vermagic_key in modules:
            module = extract(f"/opt/axvisor/ivc/lib/modules/{name}.ko")
            require(sha256(module) == manifest[hash_key], f"{name}: hash mismatch")
            header = subprocess.check_output(["readelf", "-h", str(module)], text=True)
            require("AArch64" in header, f"{name}: not an AArch64 module")
            modinfo = subprocess.check_output(
                ["readelf", "--string-dump=.modinfo", str(module)], text=True,
            )
            values = [line.split("vermagic=", 1)[1].strip()
                      for line in modinfo.splitlines() if "vermagic=" in line]
            require(len(values) == 1, f"{name}: missing or ambiguous vermagic")
            require(values[0] == manifest[vermagic_key].strip(),
                    f"{name}: manifest vermagic mismatch")
            require(values[0] == manifest["uio_vermagic"].strip(),
                    f"{name}: vermagic differs from uio.ko")
            require(values[0].split()[0] == manifest["kernel_release"],
                    f"{name}: kernel release mismatch")
            if name == "uio_ivshmem":
                require("depends=uio" in modinfo, "ivshmem: missing UIO dependency")
                require("alias=pci:v00001AF4d00001110" in modinfo,
                        "ivshmem: missing expected PCI alias")

        for name in ("publish", "subscribe"):
            demo = extract(f"/opt/axvisor/ivc/bin/ivc-{name}")
            require(sha256(demo) == manifest[f"ivc_{name}_sha256"],
                    f"IVC {name}: hash mismatch")
        extract("/usr/bin/lspci")
        require(sha256(ROOT / "modules/uio_ivshmem/uio_ivshmem.c")
                == manifest["uio_ivshmem_source_sha256"],
                "ivshmem source hash differs from this checkout")
    print("Standard AArch64 image content checks passed.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path,
                        default=ROOT / "IMAGES/rootfs/rootfs-aarch64-alpine.img")
    parser.add_argument("--kernel", type=Path,
                        default=ROOT / "IMAGES/qemu-aarch64/linux/linux-qemu")
    args = parser.parse_args()
    check(args.image, args.kernel)
