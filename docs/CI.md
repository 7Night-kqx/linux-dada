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
- **`/var/lib/hexagonrpc/` 数据树现在随镜像发布**：从可用的 dada 设备
  （192.168.2.222）整棵提取，压成 `Softs/sensors/data/hexagonrpc.tar.zst`
  （34MB / 1225 条目 / 解包 102MB），CI 在 chroot 里解到 `/var/lib/`。
  没有它 SSC sensor PD 枚举不出任何传感器（`ssccli` 能启动但读不到数）。
  ⚠️ 这是**每台设备私有**的出厂标定 / registry / 高通 DSP 二进制，且仓库为
  **public**：合规风险由用户承担；换设备必须替换成该机自己的副本。
  `install-on-device.sh` 保留提取映射说明，但不再要求手工灌数据。
- **QRTR / ADSP 启动链**：设备验证过的 `qrtr-ns.service`（`qrtr-tools` 包名服务）
  和 `dada-adsp.service`（`modprobe qcom_q6v5_pas` + 起 remoteproc0）已随
  chroot 安装并 enable；缺前者 libssc 找不到 ADSP 上的 SSC 服务，缺后者
  `/dev/fastrpc-adsp-secure` 不出现。

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

- `workflow_dispatch`，参数：
  - `username`：rootfs 里的普通用户名，默认 `dada`
  - `password`：**普通用户与 root 共用**的密码，默认 `123456`
  - `publish`：是否额外生成 Release
- `push` 到 `main` / `dev` 且路径命中（`.github/ config/ scripts/
  Softs/patches/ Softs/sensors/ tools/ firmware/ linux`）——非 dispatch 事件用
  上述默认账号密码
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

## 登录

rootfs 自带 `openssh-server`（开机自启）、普通用户和 root 密码：

| 项 | 值 |
|---|---|
| 普通用户 | `workflow_dispatch` 的 `username`，默认 `dada` |
| 密码 | `password` 参数，默认 `123456`，**普通用户与 root 相同** |
| SSH | `ssh dada@<设备IP>` / `ssh root@<设备IP>`，允许密码登录与 root 登录 |

host key 首次启动生成。**首次登录后立刻 `passwd` 改密码**（默认值写在公开仓里）。
控制台仍是 `console=tty0`；host 轨没有 `/dev/ttyGS0`，WiFi SSH 是主要远程通道。

## 网络（普通 WiFi）

CI 安装 `network-manager wpasupplicant iproute2 isc-dhcp-client net-tools
iputils-ping wireless-tools rfkill iw vim fastfetch btop systemd-timesyncd
tzdata` 并 enable `NetworkManager.service`：

```bash
nmcli device wifi list
nmcli device wifi connect "<SSID>" password "<PSK>"
nmcli device status
ifconfig wlan0          # net-tools
ping 8.8.8.8            # iputils-ping
ip addr                 # iproute2
fastfetch / btop / vim
```

### apt 源与索引

- **单一源**：`/etc/apt/sources.list`（mmdebstrap 生成的 one-line TUNA 条目）。
  旧版额外写了 `/etc/apt/sources.list.d/dada-debian.sources`（deb822，同样
  TUNA），导致 `apt` 每次报 `Target Packages ... is configured multiple
  times`。现构建时删掉该 deb822 文件，只留 `sources.list`。
- **保留包索引**：`chroot-cleanup.sh` 只 `apt-get clean`（清 .deb 缓存），
  **不再 `rm -rf /var/lib/apt/lists/*`**。之前删掉索引后设备直接
  `apt install fastfetch/btop` 会报 `Unable to locate package`。
- **时间/证书**：手机无 RTC 电池，恢复 rootfs 后时钟可能偏差数年，导致
  `apt update` 到清华源 HTTPS 报 `certificate verify failed`（证书未生效/
  已过期，证书本身有效）。现设时区 `Asia/Shanghai` 并 enable
  `systemd-timesyncd.service`，联网后自动对时，apt 即可正常工作。

### SSH 服务

`ssh.service` 在真机曾报 `Failed to start ssh.service`：Debian 的 unit 只有
`ExecStartPre=/usr/sbin/sshd -t`，**不会生成 host key**，而旧脚本把 dpkg 装的
`/etc/ssh/ssh_host_*` 全删了 → `sshd -t` 因无 host key 失败。现改为**构建期
`ssh-keygen -A` 生成并保留**，另加 `dada-ssh-keygen.service`（`Before=ssh.service`
+ `ConditionPathExists=!...`）兜底；`10-dada.conf` 显式开
`PermitRootLogin yes` / `PasswordAuthentication yes` / `UsePAM yes`，构建期跑
`sshd -t` 校验。`ssh.service` 自带 `RuntimeDirectory=sshd`，无需手工建 `/run/sshd`。

**基带/modem 暂不纳入，且 MPSS 已禁用**：`modemmanager` 在 Debian 只是
`network-manager` 的 Recommends，构建用 `--no-install-recommends` 所以不会安装；
只有客户端库 `libmm-glib0` 会作为 NM 的硬依赖被带上（纯库，不启动任何服务）。

⚠️ 内核 DTS 默认通过 `dada-mpss-enable.dtsi` 把 `&remoteproc_mpss` 设为
`status = "okay"`，而 rootfs 没有基带许可/远程文件系统。这会让 MPSS 固件启动后
在 Smart Transmit 许可检查（`dog_hal_common`）处 fatal，`remoteproc` 的
crash/recovery 链最终导致整机自动重启（屏幕可见 `crash #1 in modem`、
`ipa ... error -5 ... flow control`）。

因此在 **CI 侧**禁用 MPSS：`chroot-build.sh` 在 `make dtbs` 之前把编译副本
`/workspace/linux/.../dada-mpss-enable.dtsi` 的 `status` 改为 `"disabled"`，
并把改后的 dtsi 收进产物（`dts-dada-mpss-enable.dtsi`）以便复现。
**linux 子模块本身不改**；ADSP（`remoteproc_adsp`，传感器/音频需要）是另一个
PAS 节点，保持 `okay`。`CONFIG_ARM64_BUILTIN_DTB_FORCE=y` 意味着 DTB 编进
Image、外部 dtb 被忽略，所以「只换 dtb」不可行，必须改 DTS 源重编。

蜂窝数据需要 `dada-modem.service` / `tqftpserv` / `rmtfs` / RPMB 许可等一整套，
另立阶段；启用时把上述 CI 覆盖撤掉即可。

## GPU（Adreno 830 用户态驱动）

内核侧 `drm/msm` + GPU/GMU/GPUCC/Adreno SMMU + `gen80000_*` 固件已随 Image
构建（见 [README 内核前置条件](Softs/mesa/README.md)），但 Debian trixie 自带
Mesa 25.0.7 **没有** `0xffff44050001`（A830v1）设备表条目，freedreno/turnip
会拒绝这块 GPU。

CI 从 `config/mesa-ref.txt` pin 的 **Mesa upstream main** 源码（上游 commit
`2061a5ee` 起已含 A830v1 → **无需补丁**）在 chroot 里原生编译：

- `freedreno`（GL/EGL/GBM）+ `turnip`（Vulkan），装到 `/opt/mesa-a830`
- 会话环境写入 `/etc/environment`、`/etc/environment.d/50-mesa-a830.conf`、
  `/etc/profile.d/mesa-a830.sh`、gdm/gdm3 drop-in
- `LD_LIBRARY_PATH` 指向 `/opt/mesa-a830/runtime`（无 RPATH，故需软链汇聚
  `libEGL/libGL/libGLESv2/libgbm/libgallium`）
- 选项集逐项对照 pinned commit 的 `meson.options` 核验过：main 移除了
  `-Dstrip=true`，改用 `meson install --strip`；meson 要求 `>=1.7.0`，trixie
  的 1.7.0-1 刚好满足

设备上验证过的那份也是 `Mesa 26.3.0-devel`（main 分支），路线一致。
验证命令见 [Softs/mesa/README.md](Softs/mesa/README.md)。

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
