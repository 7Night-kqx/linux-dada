# linux-dada — CI 构建 Debian sid + GNOME 51 rootfs（小米 15 / SM8750 / dada）

从内核源码与用户态服务源码，构建可 `fastboot boot` 的内核镜像、以及自带
内核模块、传感器软件服务、Mesa A830 驱动与 GNOME 51 桌面的
Debian sid (arm64) rootfs（用 sid 是为了 GNOME 51，trixie 只有 GNOME 48）。

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
- persist/EFS/RPMB、Wi-Fi MAC、序列号**仍不入库**。但 `/var/lib/hexagonrpc/`
  传感器数据树（每台设备私有的出厂标定 / registry / 高通 DSP 二进制）现已
  按需求随镜像发布，见 `Softs/sensors/data/README.md`。
- 固件与该数据树含高通专有二进制，仓库当前为 **public**（用户决定保持公开）；
  公开分发风险由用户承担。换设备必须替换成该机自己的数据副本。
