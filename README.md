# linux-dada — CI 构建 Debian 13 rootfs（小米 15 / SM8750 / dada）

从内核源码与用户态服务源码，构建可 `fastboot boot` 的内核镜像、以及自带
内核模块与传感器软件服务的 Debian 13 (trixie/arm64) 最小 rootfs。

本项目**不含内核源码**：`linux/` 是 `7Night-kqx/linux@dada-mainline` 的
git submodule（pin 见 `config/kernel-ref.txt`）。用户态传感器相关程序与
部署件在 `Softs/`，运行时固件在 `firmware/`。

## 快速开始

```bash
# 静态校验（无需 root / arm64 机器）
bash scripts/ci/dry-run.sh

# 完整构建（需要原生 arm64 + sudo + mmdebstrap；GitHub Actions 自动跑）
bash scripts/ci/host-prepare.sh
sudo chroot rootfs /bin/bash -lc 'cd /ci && ./chroot-build.sh'
sudo chroot rootfs /bin/bash -lc 'cd /ci && ./chroot-cleanup.sh'
bash scripts/ci/host-package.sh
```

CI 全流程与目录说明见 [docs/CI.md](docs/CI.md)。

## 安全边界

- 只用 `fastboot boot` 临时启动，**绝不 `fastboot flash`**、不写/擦/激活分区。
- 设备私有数据（`/var/lib/hexagonrpc` 数据树、persist/EFS、MAC、序列号）
  不进仓库、不进镜像，由 `Softs/sensors/install-on-device.sh` 在真机注入。
- 固件含高通专有二进制，仓库应保持 **private**。
