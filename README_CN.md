# AxVisor 客户机固件仓库

[English](README.md) | 中文

## 简介

本仓库集中收录 AxVisor 虚拟化管理程序支持的 Linux 与 ArceOS 客户机镜像，以及生成这些镜像的全部脚本和补丁。仓库提供从源码克隆、配置下发到产物归档的完整流水线，涵盖本地构建、远程 SDK 触发与 GitHub Release 发布：

- `scripts/` 目录下的脚本自动化完成各开发板的 Linux 与 ArceOS 镜像编译、补丁应用与产物收集；
- `build.sh` 提供单入口的批量构建和清理能力；
- `scripts/release.sh` 支持将镜像一键打包并推送到 GitHub Release；
- `http_server.py` 可为本地镜像目录启动轻量的 HTTP 分发服务，方便团队内部共享与 CI 下载。 

## 开发板支持

下表列出了目前维护的硬件开发板和 QEMU 虚拟机目标，可直接对照脚本名称和输出目录定位镜像。每个平台的脚本都会准备交叉编译器、回放内置补丁并下载依赖源码，生成 Linux 与 ArceOS 两类镜像供测试和发版使用。

| 平台 | 目标架构 | Linux 构建方式 | ArceOS 配置 | 输出目录 |
| --- | --- | --- | --- | --- |
| Phytium Pi 开发板 | aarch64 | 直接克隆官方 [Phytium Pi OS](https://gitee.com/phytium_embedded/phytium-pi-os) 源码来构建 | 直接克隆 https://github.com/arceos-hypervisor/arceos 来构建 | `IMAGES/phytiumpi/linux`、`IMAGES/phytiumpi/arceos` |
| ROC-RK3588-PC 开发板 | aarch64 | 通过内网 `10.3.10.194` 服务器的特定目录下 SDK 源码构建 | 同上 | `IMAGES/roc-rk3588-pc/linux`、`IMAGES/roc-rk3588-pc/arceos` |
| EVM3588 开发板 | aarch64 | 通过内网 `10.3.10.194` 服务器的特定目录下 SDK 源码构建 | 同上 | `IMAGES/evm3588/linux`、`IMAGES/evm3588/arceos` |
| TAC-E400-PLC 工业控制器 | aarch64 | 拉取 `tac-e400-plc` 私有仓库后构建 | 同上 | `IMAGES/tac-e400-plc/linux`、`IMAGES/tac-e400-plc/arceos` |
| QEMU 虚拟机 | aarch64 / riscv64 / x86_64 | 克隆主线 Linux 并交叉编译，配合 `scripts/mkfs.sh` 生成根文件系统 | 同上 | `IMAGES/qemu/linux/<arch>`、`IMAGES/qemu/arceos/<arch>` |
| 香橙派 5 Plus | aarch64 | 直接克隆 [orangepi-build](https://github.com/orangepi-xunlong/orangepi-build) 源码来构建 | 同上 | `IMAGES/orangepi/linux`、`IMAGES/orangepi/arceos` |
| 黑芝麻 A1000 域控制器 | aarch64 | 拉取 `bst-a1000` 私有仓库后构建 | 同上 | `IMAGES/orangepi/linux`、`IMAGES/orangepi/arceos` |

## 构建

构建流程由 `build.sh` 与 `scripts/*.sh` 协同完成：前者负责统一入口，后者覆盖各平台的具体命令。执行全量任务前，请确认已有镜像是否需要备份，避免 `clean` 阶段删除仍在使用的文件。

1. 脚本会按需克隆源代码与应用补丁，请确保具备相应仓库访问权限以及（对需要远程构建的开发板）可访问内网构建机
2. 对于某些开发板 SDK，会应用 `patches` 中的各种补丁
3. 部分 SDK 在构建时要求管理员权限，需要手动输入或者配置为免输入密码

### 环境准备

执行构建前请保证宿主机剩余磁盘空间不少于 30GB，并能稳定访问各厂商的源码仓库或内网 SDK 服务。建议在 Ubuntu 24.04 或兼容发行版上执行以下命令，安装交叉编译器、内核工具链以及根文件系统生成必需的软件包：

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

若在容器或 CI 中运行脚本，需提前准备好代理、APT 缓存和 SSH 凭据，否则克隆和远程构建步骤会失败。为方便执行，建议赋予各个脚本执行权限：

```bash
chmod +x build.sh scripts/*.sh
```

### `build.sh`

直接执行 `build.sh` 相关子命令将克隆源码、回放补丁、调用平台脚本执行构建，并最终收集构建镜像打。脚本会自动判断是否需要先生成根文件系统或更新外部仓库，避免重复执行相同的步骤。

```bash
./build.sh help                # 查看所有可用命令
./build.sh all                 # 依次构建所有平台（耗时较长）
./build.sh phytiumpi           # 构建飞腾派 Linux + ArceOS
./build.sh roc-rk3568-pc linux # 仅构建 ROC-RK3588-PC Linux 内核及镜像
./build.sh qemu-aarch64 all    # 生成 QEMU aarch64 的 Linux+ArceOS+根文件系统
./build.sh clean               # 清理各平台的构建缓存与镜像
```

在构建时产生的下载缓存、编译日志和中间包位于 `build/` 目录中，最终结果会统一复制到 `IMAGES/` 目录中，打包结果位于 `release/` 目录中。

### 平台脚本

如需单独调试某个平台，可直接执行对应的 `scripts/<board>.sh` 获取更细粒度的命令。大部分脚本提供 `help` 子命令，你可以查询 Linux、ArceOS、rootfs 等子任务的参数，方便集成到 CI：

```bash
scripts/phytiumpi.sh all              # Linux + ArceOS
scripts/phytiumpi.sh linux            # 仅 Linux
scripts/phytiumpi.sh clean            # 清理产物

scripts/qemu.sh aarch64 linux         # QEMU aarch64 Linux
scripts/qemu.sh riscv64 all           # riscv64 Linux + ArceOS + 根文件系统
scripts/qemu.sh x86_64 clean          # 清理 QEMU x86_64 产物

scripts/tac-e400-plc.sh all           # TAC-E400-PLC 全量构建
scripts/evm3588.sh arceos             # 仅 ArceOS 固件
```

对于 `evm3588.sh` 与 `roc-rk3568-pc.sh` 会通过 SSH 登录 `10.3.10.194`，执行厂商提供的 SDK 构建脚本并下载产物。建议为该流程准备只读权限的专用账号和 SSH key，必要时通过跳板机限制访问源。

若只需生成最小根文件系统，可单独执行 `scripts/mkfs.sh` 产出 `initramfs.cpio.gz` 和 `rootfs.img`（QEMU 流程会自动调用该脚本）。脚本支持 `--out_dir`、`--guest` 等参数，可按需自定义输出目录或添加额外的 guest 文件：

```bash
scripts/mkfs.sh aarch64 --out_dir IMAGES/qemu/linux/aarch64
scripts/mkfs.sh aarch64 --guest /path/to/guest/files
```

## 镜像

所有构建产物会统一放到 `IMAGES/<platform>/<os>` 目录中，其中 `<os>` 取值为 `linux` 或 `arceos`。目录命名与脚本输出保持一致，便于 `scripts/release.sh`、`http_server.py` 以及外部自动化流程直接复用：

| 输出目录 | 内容说明 | 典型文件 / 命名规则 |
| --- | --- | --- |
| `phytiumpi/linux` | 飞腾派 Linux SDK 产物 | `Image`、`fitImage`、`fip-all.bin`、`phytiumpi_firefly.dtb` 等 |
| `phytiumpi/arceos` | 飞腾派 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `roc-rk3588-pc/linux` | Firefly SDK 生成的镜像 | `boot.img`、`MiniLoaderAll.bin`、`parameter.txt`、`rk3568-firefly-roc-pc-se.dtb`、`Image` |
| `roc-rk3588-pc/arceos` | 对应 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `evm3588/linux` | EVM3588 SDK 生成的镜像 | `boot.img`、`MiniLoaderAll.bin`、`parameter.txt`、`evm3588.dtb`、`Image` |
| `evm3588/arceos` | 对应 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `tac-e400-plc/linux` | PLC Linux 内核与设备树 | `Image`、`e2000q-hanwei-board.dtb` |
| `tac-e400-plc/arceos` | 对应 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `qemu/linux/aarch64` | QEMU aarch64 内核与根文件系统 | `Image`、`initramfs.cpio.gz`、`rootfs.img` |
| `qemu/linux/riscv64` | QEMU riscv64 内核与根文件系统 | `Image`、`initramfs.cpio.gz`、`rootfs.img` |
| `qemu/linux/x86_64` | QEMU x86_64 内核与根文件系统 | `bzImage`、`initramfs.cpio.gz`、`rootfs.img` |
| `qemu/arceos/aarch64` | QEMU aarch64 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `qemu/arceos/riscv64` | QEMU riscv64 ArceOS 固件 | `arceos-riscv64-dyn-smp1.bin` |
| `qemu/arceos/x86_64` | QEMU x86_64 ArceOS 固件 | `arceos-x86_64-dyn-smp1.bin` |
| `orangepi/linux` | Orange Pi 5 Plus 厂商 SDK 或本地构建 | `boot.img`、`parameter.txt`、`u-boot.img`、`orangepi5-plus.dtb`、`Image` |
| `orangepi/arceos` | 对应 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |
| `bst-a1000/linux` | 黑芝麻 A1000 域控制 Linux 源码构建 |  `Image`、`bsta1000b-fada.dtb`、`bsta1000b-fadb.dtb` |
| `bst-a1000/arceos` | 对应 ArceOS 固件 | `arceos-aarch64-dyn-smp1.bin` |

1. 对于 QEMU 镜像，可执行 `run.sh` 来进行快速验证，脚本会选择对应的 QEMU 架构、内核和 rootfs 参数启动虚拟机：

  ```bash
  ./run.sh aarch64 ramfs   # 使用 initramfs 启动 QEMU AArch64
  ./run.sh riscv64 rootfs  # 使用 ext4 rootfs 启动 QEMU RISC-V
  ```
2. `IMAGES` 目录中实际仅仅包含了 SDK 生成的镜像的部分镜像

### 打包与发布

当镜像构建完毕后，可通过打包与发布脚本将产物整理为 tarball，并根据标签上传到远端仓库。`scripts/release.sh` 会读取 `IMAGES/` 下的目录生成归档文件，随后可与 GitHub Release 或内网 HTTP 服务配套使用。

#### 打包镜像

打包流程会遍历 `IMAGES/` 下的每个平台目录，为 linux 与 arceos 产物各生成一个压缩包并存放在 `release/`。如需剔除调试镜像，可通过 `--include` 或 `--exclude` 过滤目录，降低上传体积：

```bash
./build.sh release pack
# 或使用底层脚本：
scripts/release.sh pack --in_dir IMAGES --out_dir release
```

#### Github Release

执行 GitHub 发布前需设置 `GITHUB_TOKEN` 并确认当前仓库具备 Release 写权限。脚本会根据指定 Tag 创建或更新 Release，并把 `release/` 中的压缩包依次上传：

```bash
scripts/release.sh github \
    --token <GITHUB_TOKEN> \
    --repo arceos-hypervisor/axvisor-guest \
    --tag v0.0.10 \
    --dir release
```

仓库也提供了 `.github/workflows/releases.yml`，当提交代码中打 Tag 时或在 Github 网页上手动执行 `workflow_dispatch` 时执行相关构建并自动发布到 Release 页面。

### 本地分发

`http_server.py` 可在后台以守护进程方式托管 `IMAGES/` 目录，通过 HTTP 提供镜像下载。脚本仅依赖 Python 标准库，额外支持日志输出、健康检查和 PID 文件，适用于开发机或 CI 节点的临时分发：

#### 启动与管理

```bash
# 在默认 8000 端口、服务 IMAGES 目录
python3 http_server.py start

# 自定义端口与目录
python3 http_server.py start --dir IMAGES --port 9000 --bind 127.0.0.1

# 查看状态 / 健康检查
python3 http_server.py status --port 9000

# 重启或停止
python3 http_server.py restart --port 9000
python3 http_server.py stop --port 9000
```

启动时会在 `IMAGES/.images_http.pid` 写入进程号，`status`、`restart`、`stop` 都基于此定位服务；如果端口被占用，可通过 `--bind` 指定新地址。常用环境变量与参数：

- `SERVE_DIR`：覆盖默认服务目录（默认为仓库根目录下的 `IMAGES`）。
- `--log-file`：指定日志文件（默认写入 `IMAGES/.images_http.log`）。
- `--timeout`：健康检查超时时间，默认 3 秒。

#### 客户端示例

服务启动后会开放目录索引，可直接浏览镜像文件并下载，便于在测试机上快速拉取所需版本。部署在共享网络时，可以结合 Nginx Basic Auth 或防火墙白名单限制访问范围。

```bash
# 下载 QEMU aarch64 的内核镜像
wget http://127.0.0.1:9000/qemu/linux/aarch64/Image

# 下载 Phytium ArceOS 固件
curl -O http://127.0.0.1:9000/phytiumpi/arceos/arceos-aarch64-dyn-smp1.bin
``` 

## 贡献

欢迎提交新的平台脚本、改进现有构建流程或完善文档示例，我们会在 Review 中协助对齐输出目录与命名规范。提交 Pull Request 前请阅读脚本内的注释，保持 Shell 风格一致并附上可复现实验步骤。

1. FORK -> PR

2. 如对构建流程、发布策略或镜像分发有进一步需求，欢迎在仓库 Issue 中反馈。

## 许可证

本项目基于 MIT 许可证授权 - 详见 [LICENSE](LICENSE) 文件。
