# AxVisor ivshmem IVC SDK 设计说明

本文档介绍本目录中 IVC SDK 的设计结构、数据流和使用边界。SDK 的目标是让 Linux、Zephyr 等客户机用户程序用统一的消息接口访问 AxVisor 暴露的 ivshmem 共享内存设备，而不需要业务代码直接处理 PCI BAR、doorbell、ring 布局和请求匹配。

## 总体分层

当前实现的分层如下：

```text
业务应用
  |
  v
ivc_sdk              面向业务的稳定 API
  |
  v
ivc_client           消息收发、请求/回复、pending table
  |
  v
ivc_demo             图像描述符、控制命令等示例业务消息封装
  |
  v
ivc_ring             双向 ring、BAR2 共享内存布局、data allocator
  |
  v
ivc_platform         Linux/Zephyr 平台适配，映射 BAR0/BAR2，触发 doorbell
  |
  v
AxVisor ivshmem vPCI 设备
```

业务程序通常只需要包含 `ivc_sdk.h`。除非要扩展底层协议或移植到新平台，否则不应直接依赖 `ivc_ring.h`、BAR 地址、PCI vendor/device 或 doorbell 寄存器。

## 目录和职责

```text
common/include/
  ivc_sdk.h          业务侧主入口，提供图像、控制命令、回复匹配等 API
  ivc_client.h       通用消息客户端，管理 seq/reply_to 和 pending table
  ivc_demo.h         当前示例业务消息的打包、解析和执行辅助函数
  ivc_ring.h         共享内存 ring、endpoint、data allocator 接口
  ivc_msg.h          wire format，定义消息头、payload、共享内存头部结构

common/src/
  ivc_sdk.c          面向业务的 API 实现
  ivc_client.c       请求/回复、收发等待、pending table 实现
  ivc_demo.c         image/control/error/heartbeat payload 实现
  ivc_ring.c         BAR2 布局初始化、ring 收发、data alloc/free/read/write

linux/
  init.cpp           Linux 示例业务程序
  src/ivc_platform.c Linux 平台适配，扫描 PCI 设备并 mmap BAR0/BAR2

zephyr/
  src/main.cpp       Zephyr 示例业务程序
  src/ivc_platform.c Zephyr 平台适配，映射固定 BAR 地址并处理中断/轮询

tests/
  *.c                可在 host 上运行的协议、ring、pending、image descriptor 测试
```

## 共享内存布局

AxVisor 通过 ivshmem vPCI 设备向两个客户机暴露同一块 BAR2 共享内存。SDK 在 BAR2 内部划分出固定元数据、两个方向的 ring 和可分配数据区：

```text
BAR2
  |
  +-- ivc_shared_header
  |
  +-- Zephyr -> Linux ring header
  +-- Zephyr -> Linux ring data
  |
  +-- Linux -> Zephyr ring header
  +-- Linux -> Zephyr ring data
  |
  +-- data allocator region
        |
        +-- ivc_data_block_header + payload
        +-- ivc_data_block_header + payload
        +-- ...
```

两个 ring 分别服务一个通信方向，因此 Zephyr 和 Linux 可以同时向对端发送消息。ring 中保存消息头和小 payload；大数据例如图像帧放在 data allocator region，ring 里只发送 `data_offset` 和 `data_len` 这样的描述符。

当前 BAR2 推荐配置为 16 MiB。扣除 shared header、两个 64 KiB ring 和 allocator 元数据后，单次连续 payload 可以覆盖 10 MiB 级别的图像吞吐测试。

## 消息格式

所有 ring 消息都带 `ivc_msg_header`：

```text
magic/version/header_len  协议识别和版本检查
msg_type                  消息类型
flags                     NEEDS_REPLY / IS_REPLY
seq                       本端发送序号
reply_to                  如果是回复，指向原请求 seq
payload_len/checksum      payload 长度和校验
timestamp_ns              发送时间戳
```

当前定义的主要业务消息包括：

```text
IVC_MSG_IMAGE_FRAME       图像帧或图像描述符
IVC_MSG_CONTROL_CMD       控制命令
IVC_MSG_CONTROL_DONE      控制执行成功
IVC_MSG_CONTROL_FAILED    控制执行失败
IVC_MSG_ERROR             错误消息
IVC_MSG_HEARTBEAT         心跳消息
```

`seq` 和 `reply_to` 用来建立请求和回复的对应关系。例如 Zephyr 连续发送十帧图像，Linux 返回十条控制命令或处理结果时，每条回复都可以通过 `reply_to` 找回对应的原始请求。

## 数据生命周期

大 payload 的生命周期由 SDK 显式管理：

1. 发送方调用 `ivc_sdk_send_image()`。
2. SDK 从 BAR2 data region 分配一块共享内存。
3. SDK 将图像数据写入该共享内存块。
4. SDK 通过 ring 发送 `ivc_image_desc`，其中包含 `data_offset` 和 `data_len`。
5. 接收方调用 `ivc_sdk_recv_image()` 解析描述符。
6. 接收方调用 `ivc_sdk_read_image()` 读取图像内容。
7. 接收方处理完成后调用 `ivc_sdk_release_image()` 释放共享内存块。

释放是长期通信必须遵守的步骤。如果只读不释放，data region 会逐步耗尽，后续大 payload 分配会返回 `IVC_ERR_NO_SPACE`。

## 请求和回复匹配

`ivc_client` 提供 pending table，用来记录本端已经发出、等待对端回复的请求。发送请求时，SDK 会保存：

```text
seq
user_data
created_at_ms
timeout_ms
state
```

收到回复消息后，业务程序调用 `ivc_sdk_complete_reply()`。SDK 根据 `reply_to` 查找 pending entry，并把匹配到的记录返回给业务层。业务层可以用 `user_data` 保存图像 ID、业务任务 ID 或回调索引。

这个机制解决的是“十条请求对应十条回复”的问题。协议层保证消息有关联字段，业务层决定每个请求完成后如何更新自己的状态机。

## Doorbell 和等待模型

发送消息后，SDK 会通过 platform backend 触发 doorbell，通知对端有新消息。接收侧等待路径由平台适配层提供：

```text
Linux:   mmap BAR0/BAR2，写 BAR0 doorbell，等待中断或 fallback polling
Zephyr:  映射 BAR0/BAR2，处理中断或 fallback polling
```

业务程序不应该直接写 BAR0。它只调用 `ivc_sdk_send_*()` 和 `ivc_sdk_recv()`，由 SDK 间接触发通知和等待。

## 面向业务的 API

业务侧主入口是：

```c
#include "ivc_sdk.h"
```

初始化默认连接：

```c
struct ivc_sdk sdk = {0};

ivc_sdk_open_default(&sdk, IVC_PEER_LINUX);
ivc_sdk_open_default(&sdk, IVC_PEER_ZEPHYR);
```

发送图像：

```c
struct ivc_sdk_image image = {
    .image_id = image_id,
    .width = width,
    .height = height,
    .pixel_format = IVC_PIXEL_FORMAT_GRAY8,
    .data = image_data,
    .data_len = image_len,
};

ivc_sdk_send_image(&sdk, &image, now_ms, timeout_ms, &seq);
```

接收并释放图像：

```c
ivc_sdk_recv(&sdk, &msg, timeout_ms);
ivc_sdk_recv_image(&msg, &image);
ivc_sdk_read_image(&sdk, &image, local_buf, local_buf_size);
ivc_sdk_release_image(&sdk, &image);
```

发送控制命令：

```c
struct ivc_sdk_control control = {
    .command = IVC_CMD_SET_EXPOSURE,
    .target_id = image_id,
    .args = args,
    .arg_len = args_len,
};

ivc_sdk_send_control(&sdk, &control, reply_to, now_ms, timeout_ms, &seq);
```

回复控制执行结果：

```c
ivc_sdk_reply_control_result(&sdk, &request_msg, command, IVC_CONTROL_OK,
                             target_id, &seq);
```

## C 和 C++ 兼容性

SDK 对外暴露 C ABI，头文件中使用 `extern "C"` 保护，因此 C 和 C++ 用户程序都可以直接使用：

```cpp
#include "ivc_sdk.h"
```

C++ 业务程序可以在更上层封装 RAII 类，但底层链接仍使用当前 C SDK。当前 Linux 和 Zephyr 示例入口都是 C++，这也验证了 C++ 用户态 demo 的使用方式。

## 扩展方式

如果要增加新的业务消息，推荐按下面方式扩展：

1. 在 `ivc_msg.h` 中增加新的 `ivc_msg_type` 和 payload 结构。
2. 在 `ivc_demo.h/.c` 或新的业务封装文件中实现 make/parse 函数。
3. 在 `ivc_sdk.h/.c` 中提供面向业务的简洁 API。
4. 业务程序继续只 include `ivc_sdk.h`。

如果要移植到新 OS 或新运行环境，优先新增对应的 `ivc_platform.c`，实现设备发现、BAR 映射、doorbell 和等待函数。`common` 目录中的协议和 SDK 核心不应因为平台变化而修改。

## 设计边界

当前 SDK 负责：

```text
共享内存布局初始化和绑定
双向 ring 收发
大 payload 分配、读取和释放
消息校验
请求/回复匹配
图像描述符和控制命令封装
doorbell 通知的抽象调用
```

当前 SDK 不负责：

```text
图像算法处理
业务状态机
命令优先级和取消策略
复杂 QoS
跨多个 peer 的路由
标准 Linux ivshmem/uio 用户态生态封装
```

这些能力可以在 SDK 之上继续构建。当前设计刻意把底层共享内存通信和业务策略分开，避免业务 demo 反向污染协议层。
