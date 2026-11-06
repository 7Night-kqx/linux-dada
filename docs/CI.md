# dada GitHub Actions CI — Debian 13 rootfs + sensor services

> 本文提到的 `docs/sensor-fix.md`、`docs/rootfs-backup-restore.md`、
> `docs/modem-rootfs-restore-2026-11-05.md` 等属外部参考仓库
> `/home/night/AI/dada_kernel/docs/`（用户指定的文档来源），不在本仓库内。

## 架构

单 job、原生 arm64（`ubuntu-24.04-arm`），**一个 chroot 内完成全部构建**：

```
actions/checkout (主仓 + linux submodule)
  └─ mmdebstrap --variant=minbase trixie arm64  → rootfs/
       └─ chroot rootfs:
            apt 装构建依赖
            make O=../build-dada-evidence ARCH=arm64 dada_defconfig
            make ... Image dtbs modules
            make ... INSTALL_MOD_PATH=/ modules_install ; depmod -b /
            顺序 meson 构建 hexagonrpc → libssc → iio-sensor-proxy
            装固件 + systemd unit + udev 规则
            静态校验 + 收集产物到 /mnt/artifacts
            purge 构建工具/源码/对象, 保护运行时库
  └─ tar -czf rootfs-debian13-dada-<release>.tar.gz
  └─ upload-artifact / (tag 时) GitHub Release
```

设计要点：

- **不用交叉编译**：runner 与 chroot 同为 aarch64，命令里只有
  `ARCH=arm64`，没有 `CROSS_COMPILE`（用户确认第 3 点）。
- **不用旧构建脚本**：直接 `make O=../build-dada-evidence ARCH=arm64 ...`
  （用户确认第 2 点），旧 `build-dada-debian-systemd-usb*.sh` 的 11 阶段逻辑
  不进仓；只把它的逐符号断言保留为 `config/config-assertions.txt`。
- **rootfs 即编译环境**：内核、模块、用户态服务全部在目标 rootfs 内用其
  自带 gcc/glibc/meson 构建，天然 ABI 一致，满足 `docs/sensor-fix.md`
  验收 B 的「Debian 13 原生 AArch64 构建」要求。
- **构建后清理**：`chroot-cleanup.sh` 删 `/workspace`（源码/对象）、purge
  构建工具、删 `modules_install` 留下的 `build`/`source` 断链；先根据真实
  `ldd` 结果把运行时库 `apt-mark manual`，避免 `autoremove` 误删 trixie 的
  `t64` 运行时包。
- **固件双来源**（务必区分）：
  - `linux/firmware/`（内核 submodule 内）= `CONFIG_EXTRA_FIRMWARE` 的 14 个
    内建 blob，kbuild 按 `$(srctree)/firmware` 解析（`EXTRA_FIRMWARE_DIR="firmware"`）。
  - 主仓 `firmware/`（727 文件 / 216MB，含 60 个 `adsp*`）= 运行时固件，
    workflow 拷进 `rootfs:/lib/firmware/`。`CONFIG_ATH12K=m` /
    `CONFIG_QCOM_Q6V5_PAS=m` 的固件由此提供。
- **设备私有数据不进镜像**：`/var/lib/hexagonrpc/` 数据树由
  `install-on-device.sh` 在真机从 Android 侧提取；CI 只建空骨架。

## 目录

| 路径 | 作用 |
|---|---|
| `linux/` | git submodule（`7Night-kqx/linux@dada-mainline`），gitlink pin 见 `config/kernel-ref.txt` |
| `config/sources.json` | 3 个用户态仓库的 pinned SHA + patch 映射 |
| `config/config-assertions.txt` | post-olddefconfig 的 28 条逐符号断言 |
| `config/firmware-manifest.txt` | 主仓固件 sha256 清单（730 行） |
| `Softs/patches/*.patch` | 从本地工作区 diff 固化的 dada 专属改动 |
| `Softs/sensors/` | systemd unit、udev 规则、drop-in、modules-load、设备端脚本 |
| `tools/mkbootimg/` | AOSP `mkbootimg.py` + 最小 gki 依赖 |
| `scripts/ci/` | host/chroot 构建脚本 + `dry-run.sh` 静态校验 |
| `.github/workflows/build-dada-debian.yml` | 唯一 workflow（build + 可选 release） |

## 触发

- `workflow_dispatch`（可勾 `publish` 生成 Release）
- `push` 到 `main` / `dev` 且路径命中（`.github/ config/ scripts/
  Softs/patches/ Softs/sensors/ tools/ firmware/ linux`）
- `push` tag `v*` → 额外跑 release job
- PR 到 `dev` → 只跑 build

`concurrency` 按 ref 分组；`permissions: contents: read`，仅 release job 提权。

## 产物（`out/`，Artifact 保留 14 天）

| 文件 | 说明 |
|---|---|
| `Image-dada-debian` | 内核镜像（内置 DTB） |
| `boot-dada-debian-test.img` | `fastboot boot` 验证用 |
| `final.config` / `dts-snapshot.dts` | 可复现输入 |
| `kernel.release` | 与 `/lib/modules/<release>` 一致 |
| `rootfs-debian13-dada-<release>.tar.gz` | 清理后的 rootfs |
| `SHA256SUMS` / `provenance.json` / `RELEASE_NOTES.md` | 校验与来源 |

`provenance.json` 记录内核 SHA、3 个 Softs SHA、patch/config/DTS/固件清单的
sha256 —— 延续 `docs/modem-rootfs-restore-2026-11-05.md` §1「模块必须与 Image
同一次构建」的可追溯要求。

## 当前状态（CI 已跑通）

仓库 `7Night-kqx/linux-dada`（**public**，用户决定保持公开；内含高通专有
固件，公开分发风险由用户承担）。首次成功的完整 run 产出内核镜像、模块、
rootfs.tar.gz 与传感器服务包。

- 内核子模块 `7Night-kqx/linux@dada-mainline` 的 gitlink 与
  `config/kernel-ref.txt` 必须一致；改内核后**先把该 commit push 到内核仓**，
  再更新主仓 gitlink 与 pin，否则 CI 的 submodule fetch 找不到 SHA。
- `bash scripts/ci/dry-run.sh` 做本地静态校验（不需要 root / arm64）。
- 已完成：`a2994ff9f` 把 43 条 bring-up `bootargs` 收敛为顶层 `/chosen` 唯一
  一条；`bcfc9a69b` 把 USB-C 从 gadget 切到 **host 轨**（见下）。

### USB-C 角色：host（可接外设）

`bcfc9a69b` 之前构建的是 gadget 轨（`USB_DWC3_GADGET=y` +
`dr_mode="peripheral"`），USB-C 只能当 CDC ACM 串口，**接不了 U 盘/键鼠/ hub**。
现为 host 轨，三者必须一致：

| 位置 | 值 |
|---|---|
| `dada_defconfig` | `USB_DWC3_HOST=y`，gadget 全套 `is not set`，xHCI/STORAGE/UAS/HID 全 `=y` 内建 |
| `sm8750-xiaomi-dada-mainline.dts` `&usb` | `dr_mode = "host"` |
| `config/config-assertions.txt` | 逐符号断言锁死上述角色，防止回归 |

`DWC3 Mode Selection` 是 Kconfig `choice`，HOST/GADGET 互斥；sm8750.dtsi 无
独立 XHCI 节点，`dwc3/host.c` 创建的 `xhci-hcd` 平台设备由 `xhci-plat` 绑定，
故 `USB_XHCI_HCD` / `USB_XHCI_PLATFORM` 必须同时开，否则插外设完全无反应
且不报错。host 侧驱动改为 `=y` 内建，避免依赖 udev/modprobe 时序。

需要 USB gadget 控制台（黑屏抓 dmesg）时，需另起一条 usbdebug 轨，把以上
三处整体反向切换，不能用本镜像。

## 上机验收（照 `docs/sensor-fix.md` 验收 B）

```bash
# 只用 fastboot boot，绝不 flash / 不写分区
fastboot boot boot-dada-debian-test.img
# rootfs tar 恢复到 /dev/sda36（见 docs/rootfs-backup-restore.md，末尾 "." 不能少）
/opt/dada-sensors/bin/install-on-device.sh
/opt/dada-sensors/bin/verify-on-device.sh
```

判据：`hexagonrpcd-sensors` + `iio-sensor-proxy` 双 active、
`HasAccelerometer=true`、`ssccli --sensor accelerometer/gyroscope` 出数。
`HasAmbientLight` **不**列为通过项（「2026-09-28 light 根因更正」后仍未解决）。

## 已知风险 / 未覆盖

- CI 内只做 `ldd` / `systemd-analyze verify` / hexagonrpc 单测；D-Bus 属性与
  传感器读数必须真机验证（`verify-on-device.sh`）。
- `systemd-analyze verify` 在 minbase 中可能对 D-Bus/polkit 报 warning，
  当前以 `|| true` 记录日志、不阻断构建。
- 主仓 `firmware/qcom/sm8750/backup-mine/` 是 modem 固件重复副本（~100MB），
  `chroot-build.sh` 装进 rootfs 后删除，仅留在仓库里。
- libssc 的 `mocking/` 测试桩依赖 qrtr submodule，但 `ninja install` 不构建它；
  若未来开启 libssc 测试需补 `mocking/qrtr`。
