# AxVisor Guest Firmware Repository

English | [中文](README_CN.md)

## Introduction

This repository aggregates every Linux and ArceOS guest image supported by the AxVisor hypervisor together with the scripts and patches required to build them. It offers an end-to-end pipeline that spans source cloning, configuration delivery, artifact collection, and publication, covering local builds, remote SDK invocations, and GitHub Release uploads:

- The utilities under `scripts/` compile Linux and ArceOS images for each board, apply bundled patches, and gather the resulting binaries automatically.
- `build.sh` exposes a single entry point for bulk builds and clean-ups across all supported targets.
- `scripts/release.sh` packages finished images and pushes them to GitHub Release in one command.
- `http_server.py` starts a lightweight HTTP file server rooted at the local image directory, making it easy to share artifacts inside the team or serve them to CI jobs. 

## Supported Boards

The table below lists the hardware boards and QEMU virtual machines currently maintained. Match the rows with the script names and output directories to locate the generated images quickly. Each platform script prepares the cross compiler, replays the built-in patches, downloads upstream sources, and emits both Linux and ArceOS images for testing and release workflows.

| Platform | Target Architecture | Linux Build Method | ArceOS Configuration | Output Directories |
| --- | --- | --- | --- | --- |
| Phytium Pi development board | aarch64 | Clone the official [Phytium Pi OS](https://gitee.com/phytium_embedded/phytium-pi-os) repository to build | Clone https://github.com/arceos-hypervisor/arceos to build | `IMAGES/phytiumpi/linux`, `IMAGES/phytiumpi/arceos` |
| ROC-RK3588-PC development board | aarch64 | Build from the SDK source code in the specific directory of the intranet server `10.3.10.194` | Same as above | `IMAGES/roc-rk3588-pc/linux`, `IMAGES/roc-rk3588-pc/arceos` |
| EVM3588 development board | aarch64 | Build from the SDK source code in the specific directory of the intranet server `10.3.10.194` | Same as above | `IMAGES/evm3588/linux`, `IMAGES/evm3588/arceos` |
| TAC-E400-PLC industrial controller | aarch64 | Pull the `tac-e400-plc` private repository and build | Same as above | `IMAGES/tac-e400-plc/linux`, `IMAGES/tac-e400-plc/arceos` |
| QEMU virtual machine | aarch64 / riscv64 / x86_64 | Clone mainline Linux and cross-compile, use `scripts/mkfs.sh` to generate the root file system | Same as above | `IMAGES/qemu/linux/<arch>`, `IMAGES/qemu/arceos/<arch>` |
| Orange Pi 5 Plus | aarch64 | Clone the [orangepi-build](https://github.com/orangepi-xunlong/orangepi-build) repository to build | Same as above | `IMAGES/orangepi/linux`, `IMAGES/orangepi/arceos` |
| Black Sesame A1000 domain controller | aarch64 | Pull the `bst-a1000` private repository and build | Same as above | `IMAGES/orangepi/linux`, `IMAGES/orangepi/arceos` |

## Build

The build process is coordinated by `build.sh` and `scripts/*.sh`: the former provides a unified entry point, while the latter covers platform-specific commands. Before running a full build, ensure that any existing images you need are backed up to avoid deletion during the `clean` phase.

1. The scripts will clone source code and apply patches as needed. Ensure you have access to the relevant repositories and, for boards requiring remote builds, access to the intranet build machine.
2. For some board SDKs, various patches in `patches` will be applied.
3. Some SDKs require administrator privileges during the build process, which may require manual input or passwordless configuration.

### Prerequisites

Before building, ensure the host machine has at least 30GB of free disk space and stable access to vendor source repositories or intranet SDK services. On Ubuntu 24.04 or a compatible distribution, install the required cross-compilers, kernel utilities, and root file system tools with:

```bash
sudo apt update
sudo apt install \
  flex bison libelf-dev libssl-dev \
  gcc-aarch64-linux-gnu g++-aarch64-linux-gnu \
  gcc-riscv64-linux-gnu g++-riscv64-linux-gnu \
  bc fakeroot coreutils cpio gzip rsync file \
  debootstrap binfmt-support debian-archive-keyring eatmydata \
  python3 python3-venv curl git openssh-client libmpc-dev libgmp-dev \
  lz4 chrpath gawk texinfo chrpath diffstat expect cmake
```

When running scripts in containers or CI, prepare proxies, APT caches, and SSH credentials in advance; otherwise, cloning and remote build steps will fail. For convenience, grant execute permissions to the scripts:

```bash
chmod +x build.sh scripts/*.sh
```

### `build.sh`

Directly executing `build.sh` with the relevant subcommands will clone source code, replay patches, invoke platform scripts to execute builds, and finally collect the built images. The script automatically determines whether to generate the root file system first or update external repositories, avoiding redundant steps.

```bash
./build.sh help                # List all available commands
./build.sh all                 # Build all platforms sequentially (time-consuming)
./build.sh phytiumpi           # Build Phytium Pi Linux + ArceOS
./build.sh roc-rk3568-pc linux # Build only the ROC-RK3588-PC Linux kernel and image
./build.sh qemu-aarch64 all    # Generate QEMU aarch64 Linux + ArceOS + root file system
./build.sh clean               # Clean build caches and images for all platforms
```

During the build, download caches, build logs, and intermediate packages are located in the `build/` directory. Final results are copied to the `IMAGES/` directory, and packaged results are stored in the `release/` directory.

### Platform Scripts

To debug a single platform, execute the corresponding `scripts/<board>.sh` directly for finer-grained commands. Most scripts provide a `help` subcommand, allowing you to query the parameters for Linux, ArceOS, and rootfs tasks, making it easier to integrate into CI:

```bash
scripts/phytiumpi.sh all              # Linux + ArceOS
scripts/phytiumpi.sh linux            # Linux only
scripts/phytiumpi.sh clean            # Clean artifacts

scripts/qemu.sh aarch64 linux         # QEMU aarch64 Linux
scripts/qemu.sh riscv64 all           # riscv64 Linux + ArceOS + root file system
scripts/qemu.sh x86_64 clean          # Clean QEMU x86_64 artifacts

scripts/tac-e400-plc.sh all           # TAC-E400-PLC full build
scripts/evm3588.sh arceos             # ArceOS firmware only
```

For `evm3588.sh` and `roc-rk3568-pc.sh`, the scripts log in to `10.3.10.194` via SSH, execute the vendor-provided SDK build scripts, and download the artifacts. It is recommended to prepare a dedicated read-only account and SSH key for this process, and restrict access through a bastion host if necessary.

If you only need to generate a minimal root file system, execute `scripts/mkfs.sh` to produce `initramfs.cpio.gz` and `rootfs.img` (the QEMU flow automatically calls this script). The script supports parameters such as `--out_dir` and `--guest`, allowing you to customize the output directory and include additional guest files:

```bash
scripts/mkfs.sh aarch64 --out_dir IMAGES/qemu/linux/aarch64
scripts/mkfs.sh aarch64 --guest /path/to/guest/files
```

## Images

All build artifacts are placed in the `IMAGES/<platform>/<os>` directory, where `<os>` is either `linux` or `arceos`. The directory names are consistent with the script output, making it easy to reuse them directly with `scripts/release.sh`, `http_server.py`, and external automation:

| Output Directory | Description | Typical Files / Naming |
| --- | --- | --- |
| `phytiumpi/linux` | Phytium Pi Linux SDK deliverables | `Image`, `fitImage`, `fip-all.bin`, `phytiumpi_firefly.dtb`, etc. |
| `phytiumpi/arceos` | Phytium Pi ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `roc-rk3588-pc/linux` | Firefly SDK generated images | `boot.img`, `MiniLoaderAll.bin`, `parameter.txt`, `rk3568-firefly-roc-pc-se.dtb`, `Image` |
| `roc-rk3588-pc/arceos` | Matching ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `evm3588/linux` | EVM3588 SDK generated images | `boot.img`, `MiniLoaderAll.bin`, `parameter.txt`, `evm3588.dtb`, `Image` |
| `evm3588/arceos` | Matching ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `tac-e400-plc/linux` | PLC Linux kernel and device tree | `Image`, `e2000q-hanwei-board.dtb` |
| `tac-e400-plc/arceos` | Matching ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `qemu/linux/aarch64` | QEMU aarch64 kernel and rootfs | `Image`, `initramfs.cpio.gz`, `rootfs.img` |
| `qemu/linux/riscv64` | QEMU riscv64 kernel and rootfs | `Image`, `initramfs.cpio.gz`, `rootfs.img` |
| `qemu/linux/x86_64` | QEMU x86_64 kernel and rootfs | `bzImage`, `initramfs.cpio.gz`, `rootfs.img` |
| `qemu/arceos/aarch64` | QEMU aarch64 ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `qemu/arceos/riscv64` | QEMU riscv64 ArceOS firmware | `arceos-riscv64-dyn-smp1.bin` |
| `qemu/arceos/x86_64` | QEMU x86_64 ArceOS firmware | `arceos-x86_64-dyn-smp1.bin` |
| `orangepi/linux` | Orange Pi 5 Plus vendor SDK or local builds | `boot.img`, `parameter.txt`, `u-boot.img`, `orangepi5-plus.dtb`, `Image` |
| `orangepi/arceos` | Matching ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |
| `bst-a1000/linux` | Black Sesame A1000 domain controller Linux kernel and device trees | `Image`, `bsta1000b-fada.dtb`, `bsta1000b-fadb.dtb` |
| `bst-a1000/arceos` | Matching ArceOS firmware | `arceos-aarch64-dyn-smp1.bin` |

1. For QEMU images, you can quickly validate them with `run.sh`. The script selects the appropriate QEMU architecture, kernel, and rootfs parameters to boot the VM:

  ```bash
  ./run.sh aarch64 ramfs   # Boot QEMU AArch64 with an initramfs
  ./run.sh riscv64 rootfs  # Boot QEMU RISC-V with an ext4 rootfs
  ```
2. The `IMAGES` directory actually contains only a subset of the images generated by the SDK.

### Packaging and Release

After the images are built, use the packaging and release scripts to organize the artifacts into tarballs and upload them to a remote repository. `scripts/release.sh` reads the directories under `IMAGES/`, generates archives, and can be used with GitHub Release or intranet HTTP services.

#### Package Images

The packaging process traverses each platform directory under `IMAGES/`, generates separate archives for the Linux and ArceOS outputs, and places them in `release/`. To exclude debug images, use `--include` or `--exclude` to filter directories and reduce upload size:

```bash
./build.sh release pack
# Or use the lower-level script:
scripts/release.sh pack --in_dir IMAGES --out_dir release
```

#### GitHub Release

Before publishing to GitHub, set `GITHUB_TOKEN` and confirm the repository has Release write permissions. The script creates or updates the specified tag and uploads the archives in `release/`:

```bash
scripts/release.sh github \
    --token <GITHUB_TOKEN> \
    --repo arceos-hypervisor/axvisor-guest \
    --tag v0.0.10 \
    --dir release
```

The repository also provides `.github/workflows/releases.yml`, which triggers the relevant build and release steps when a tag is pushed or `workflow_dispatch` is executed via the GitHub UI.

### Local Distribution

`http_server.py` can daemonize a lightweight HTTP server rooted at `IMAGES/`, delivering images over the network. The script relies solely on the Python standard library and supports logging, health checks, and PID files, making it suitable for developer machines or CI staging nodes.

#### Startup and Management

```bash
# Serve IMAGES on port 8000 by default
python3 http_server.py start

# Override directory and port
python3 http_server.py start --dir IMAGES --port 9000 --bind 127.0.0.1

# Query status / health
python3 http_server.py status --port 9000

# Restart or stop
python3 http_server.py restart --port 9000
python3 http_server.py stop --port 9000
```

On startup, the script writes the process ID to `IMAGES/.images_http.pid`; the `status`, `restart`, and `stop` commands use this file to locate the service. If the default port is busy, use `--bind` to specify a new address. Common environment variables and parameters:

- `SERVE_DIR`: Override the default root directory (defaults to the repository `IMAGES` folder).
- `--log-file`: Specify the log file (defaults to `IMAGES/.images_http.log`).
- `--timeout`: Health-check timeout in seconds (default: 3).

#### Client Examples

Once the server is up, directory indexing remains enabled, allowing you to browse and download builds directly. When exposing the service on shared networks, pair it with Nginx basic auth or firewall rules to limit access.

```bash
# Download the QEMU aarch64 kernel image
wget http://127.0.0.1:9000/qemu/linux/aarch64/Image

# Download the Phytium ArceOS firmware
curl -O http://127.0.0.1:9000/phytiumpi/arceos/arceos-aarch64-dyn-smp1.bin
``` 

## Contributing

We welcome new platform scripts, improvements to the existing build flows, or documentation updates. During review, we will help align artifact locations and naming conventions where needed. Before submitting a pull request, read the inline script comments, keep shell style consistent, and include the steps required to reproduce your results.

1. FORK -> PR

2. If you have further requirements around the build, release, or distribution workflow, please open an issue so we can discuss them.

## License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.
