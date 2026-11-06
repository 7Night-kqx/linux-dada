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

## 首次上 CI 前的准备（阶段 0）

1. GitHub 建 **private** 主仓 `linux-dada`（固件含高通专有二进制，勿公开）。
   单文件最大 46.3MB < GitHub 100MB 硬限，无需 LFS。
2. `git submodule add -b dada-mainline --depth 1
   https://github.com/7Night-kqx/linux.git linux`，checkout
   `a2994ff9fca18d64991a155fd9b30557c64b4e57` 后 `git add linux` 固定 gitlink。
   内核仓是 shallow（现 17 commit），CI 用 `submodules: recursive` + `fetch-depth: 1`。
   **该 commit 只存在于本地内核仓，必须先 push 到 `7Night-kqx/linux` 的
   `dada-mainline` 分支，否则 CI 的 submodule fetch 会拿到不存在的 SHA。**
3. 运行 `bash scripts/ci/dry-run.sh` 做本地静态校验（不需要 root / arm64）。
4. **DTS 清理（已完成）**：`a2994ff9f` 把 43 条 bring-up `bootargs` 收敛为
   顶层 `/chosen` 里唯一一条（usbhost 轨、`console=tty0`、重复与
   `rdinit`/`dada_*`/`panel_*`/`maxcpus` 残留全清）。已用 `make dtbs` 验证
   可编译，且反解 DTB 与清理前除 `/chosen` 和 `model` 外逐字节一致。
5. 首次实跑确认 trixie 的 gcc 能编过 7.3-rc5、`meson ≥1.4`（libssc 要求）、
   `libgirepository-2.0-dev` / `libpolkit-gobject-1-dev` 等包名在 trixie 存在。

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
