# scripts 目录分类说明

本文按职责将 `scripts/` 下的脚本整理为两类：

1. 构建 OS 的脚本
2. 构建 rootfs 的脚本

另外，目录中还有一部分脚本并不直接构建 OS 或 rootfs，而是负责打包、通用函数或辅助构建。为了避免混淆，这些脚本也单独列出。

## 一、构建 OS 的脚本

这类脚本的主要职责是拉取源码、打补丁、调用上游构建系统，并把内核、固件或系统镜像复制到 `IMAGES/`。

| 脚本 | 主要职责 | 说明 |
| --- | --- | --- |
| `phytiumpi.sh` | 平台 OS 入口 | 构建 `linux`、`arceos`、`rtthread`、`zephyr`、`freertos` |
| `roc-rk3568-pc.sh` | 平台 OS 入口 | 构建 `linux`、`arceos`、`rtthread`，Linux 通过远端 SDK 机器构建 |
| `evm3588.sh` | 平台 OS 入口 | 构建 `linux`、`arceos`，Linux 通过远端 SDK 机器构建 |
| `tac-e400-plc.sh` | 平台 OS 入口 | 构建 `linux`、`arceos` |
| `orangepi-5-plus.sh` | 平台 OS 入口 | 构建 `linux`、`arceos`、`zephyr`、`freertos` |
| `rdk-s100p.sh` | 平台 OS 入口 | 平台级 OS 构建脚本 |
| `bst-a1000.sh` | 平台 OS 入口 | 平台级 OS 构建脚本 |
| `qemu.sh` | QEMU 总入口 | 构建 `linux`、`arceos`、`nimbos`、`zephyr`、`freertos`；其中 `linux`/`arceos` 还会顺带调用 rootfs 生成 |
| `arceos.sh` | 通用 OS 构建器 | 提供 ArceOS 的公共构建逻辑，被多个平台脚本复用 |
| `zephyr.sh` | 通用 OS 构建器 | 提供 Zephyr guest 的公共构建逻辑 |
| `freertos.sh` | 通用 OS 构建器 | 提供 FreeRTOS guest 的公共构建逻辑 |
| `rtthread.sh` | 通用 OS 构建器 | 提供 RT-Thread 的公共构建逻辑 |
| `nimbos.sh` | 通用 OS 构建器，兼具 rootfs 产出 | 主要职责仍是构建 NimbOS，但构建完成后会额外生成 `rootfs.img` |
| `build-u-boot-orangepi5.sh.sh` | OS 构建辅助脚本 | 归属于 Orange Pi 的引导链路构建，属于 OS 侧辅助 |

### 这一类脚本的共同特征

- 典型行为是 `git clone`、`apply_patches`、`make`、`scons`、`west build`、`cargo/make` 等。
- 输出通常是内核、固件、`bin`、`Image`、`dtb`、`boot.img`、`u-boot` 之类产物。
- 产物目录通常落在 `IMAGES/<platform>/<os>`。

## 二、构建 rootfs 的脚本

这类脚本的主要职责是生成文件系统内容或文件系统镜像，比如 `initramfs.cpio.gz`、`rootfs.img`、ext4 镜像等。

| 脚本 | 主要职责 | 说明 |
| --- | --- | --- |
| `mkfs.sh` | 通用 rootfs 生成器 | 基于 BusyBox 生成最小 rootfs，可输出 `initramfs.cpio.gz` 和 `rootfs.img` |
| `alpine/alpine.sh` | Alpine rootfs 生成器 | 下载 Alpine minirootfs，制作 ext4 rootfs 镜像 |
| `nimbos.sh` | NimbOS 专用 rootfs 生成 | 在构建 NimbOS 后额外调用 `create_nimbos_disk_image` 生成 `rootfs.img` |
| `qemu.sh` | rootfs 调度入口 | 自己不直接制作 rootfs，但会在 `linux`/`arceos` 流程中调用 `mkfs.sh` |

### rootfs 相关调用关系

- `qemu.sh` -> `mkfs.sh`
  - 用于 QEMU 的 `linux` 和 `arceos` 流程。
- `nimbos.sh` -> `create_nimbos_disk_image`
  - 为 NimbOS 单独生成磁盘镜像。
- `alpine/alpine.sh`
  - 独立维护 Alpine rootfs 下载、解包、写入镜像流程。

## 三、不属于上面两类的脚本

这部分脚本不直接负责“构建 OS”或“构建 rootfs”，但属于构建体系的重要配套。

| 脚本 | 类型 | 说明 |
| --- | --- | --- |
| `utils.sh` | 公共函数库 | 提供日志、拉仓库、打补丁、切换版本等能力 |
| `release.sh` | 打包/发布 | 将 `IMAGES/` 中的产物打包并上传 GitHub Release |

## 四、建议的理解方式

如果只看职责，`scripts/` 可以进一步理解成下面三层：

- 平台入口层
  - `phytiumpi.sh`、`qemu.sh`、`orangepi-5-plus.sh`、`evm3588.sh` 等
- 通用 OS 构建层
  - `arceos.sh`、`zephyr.sh`、`freertos.sh`、`rtthread.sh`、`nimbos.sh`
- rootfs 构建层
  - `mkfs.sh`、`alpine/alpine.sh`

其中最容易混淆的是两点：

- `qemu.sh` 主要属于 OS 入口脚本，但它会主动串联 `mkfs.sh`，所以同时具备 rootfs 调度职责。
- `nimbos.sh` 主要属于 OS 构建脚本，但内部也会额外生成 `rootfs.img`，属于“OS + rootfs”混合型脚本。

## 五、建议后的归档结果

如果后续还想继续整理目录结构，建议按下面的心智模型维护：

- `scripts/platform/`
  - 放平台入口脚本，例如 `phytiumpi.sh`、`qemu.sh`
- `scripts/os/`
  - 放通用 OS 构建器，例如 `arceos.sh`、`zephyr.sh`
- `scripts/rootfs/`
  - 放 `mkfs.sh`、`alpine/alpine.sh`
- `scripts/lib/`
  - 放 `utils.sh`
- `scripts/tools/`
  - 放发布打包脚本和其他构建辅助工具

当前仓库还没有真的按这个结构迁移文件；本文只是给出职责上的整理结果，便于后续继续重构。
