#!/usr/bin/env bash
# Executed INSIDE the Debian trixie/arm64 chroot.
# Everything here uses the rootfs' own toolchain (native aarch64, no
# CROSS_COMPILE). Layout inside the chroot:
#   /workspace/linux          kernel submodule copy
#   /workspace/Softs          patches + deployment units
#   /workspace/config         sources.json, assertions, firmware manifest
#   /workspace/firmware       runtime firmware -> /lib/firmware/
#   /workspace/tools          mkbootimg.py
#   /ci                       CI scripts (outside /workspace; survives cleanup)
#   /workspace/build-dada-evidence   O= output
#   /mnt/artifacts            host bind-mount; collected before cleanup
set -euo pipefail
source "$(dirname "$0")/common.sh"

# Workflow passes credentials base64-encoded so any characters in the
# password survive shell quoting. Decode here; never echo the values.
if [[ -n ${DADA_USER_B64:-} ]]; then
    DADA_USER=$(printf '%s' "$DADA_USER_B64" | base64 -d)
    export DADA_USER
fi
if [[ -n ${DADA_PASSWORD_B64:-} ]]; then
    DADA_PASSWORD=$(printf '%s' "$DADA_PASSWORD_B64" | base64 -d)
    export DADA_PASSWORD
fi

# Surface the real failing line as a GitHub annotation. The job page only
# shows the bare step exit code and the Actions API is unavailable here.
trap 'rc=$?; printf "::error::chroot-build.sh failed at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

WS=/workspace
SRC=$WS/Softs/sensors-src
PATCHES=$WS/Softs/patches
DEPLOY=$WS/Softs/sensors
CONFIG=$WS/config
BUILD=$WS/build-dada-evidence
OUT=/mnt/artifacts          # outside /workspace; survives chroot-cleanup.sh
JOBS=${JOBS:-$(nproc)}

log "toolchain (native arm64, no CROSS_COMPILE)"
[[ $(uname -m) == aarch64 ]] || die "chroot is not aarch64: $(uname -m)"
# gcc/meson checks come AFTER apt install below: the minbase rootfs has no
# compiler yet, calling them here would fail with exit code 127.

# ---------------------------------------------------------------- dependencies
log "apt: build + runtime dependencies (Debian trixie names)"
export DEBIAN_FRONTEND=noninteractive
# Keep /etc/apt/sources.list AS THE SINGLE SOURCE. mmdebstrap wrote it as a
# one-line entry pointing at the TUNA mirror (from $MIRROR); an earlier
# version also wrote a deb822 file, which made apt warn "Target Packages ...
# is configured multiple times". Drop any extra deb822 source we may have
# created and keep security/updates entries mmdebstrap put in sources.list.d/.
rm -f /etc/apt/sources.list.d/dada-debian.sources
[[ -f /etc/apt/sources.list ]] || die "/etc/apt/sources.list missing (mmdebstrap did not create it)"
apt-get update
apt-get install -y --no-install-recommends \
    gcc make bc bison flex libssl-dev libelf-dev device-tree-compiler \
    python3 python3-dev python3-gi git pkg-config meson ninja-build cmake \
    gettext libglib2.0-dev libgudev-1.0-dev libqmi-glib-dev \
    libprotobuf-c-dev protobuf-c-compiler protobuf-compiler \
    gobject-introspection libgirepository1.0-dev \
    libpolkit-gobject-1-dev polkitd valac libudev-dev libjson-c-dev \
    systemd kmod udev dbus systemd-sysv \
    libsystemd-dev libgirepository-2.0-dev \
    openssh-server sudo adduser passwd \
    qrtr-tools zstd \
    network-manager wpasupplicant iproute2 isc-dhcp-client \
    net-tools iputils-ping wireless-tools rfkill iw \
    vim fastfetch btop systemd-timesyncd tzdata \
    libdrm-dev libwayland-dev wayland-protocols libwayland-egl-backend-dev \
    libx11-dev libxext-dev libxfixes-dev libxcb1-dev libx11-xcb-dev \
    libxcb-dri2-0-dev libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev \
    libxcb-glx0-dev libxcb-shm0-dev libxcb-xfixes0-dev libxcb-keysyms1-dev \
    libxcb-randr0-dev x11proto-gl-dev \
    libxshmfence-dev libxrandr-dev libxdamage-dev \
    libxxf86vm-dev libxrender-dev libexpat1-dev libzstd-dev \
    libglvnd-dev libgbm-dev libvulkan-dev glslang-tools \
    python3-mako python3-ply python3-yaml python3-packaging \
    zlib1g-dev libxml2-dev \
    file tar xz-utils ca-certificates
info "dependencies installed"
log "toolchain versions"
gcc --version | head -1
meson --version | head -1
need gcc; need meson; need ninja; need make; need git; need dtc

# ---------------------------------------------------------------- kernel
log "kernel: make O=../build-dada-evidence ARCH=arm64 dada_defconfig"
cd "$WS/linux"
make O="$BUILD" ARCH=arm64 dada_defconfig
make O="$BUILD" ARCH=arm64 olddefconfig
check_config_assertions "$BUILD/.config" "$CONFIG/config-assertions.txt"
# EXTRA_FIRMWARE_DIR="firmware" resolves to $(srctree)/firmware; assert the
# 14 built-in blobs are present so a missing file fails loudly, not as -ENOENT.
for fw in $(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"$/\1/p' "$BUILD/.config" | tr ' ' '\n'); do
    [[ -s "$WS/linux/firmware/$fw" ]] || die "built-in firmware missing: $fw"
done
info "CONFIG_EXTRA_FIRMWARE blobs present"

# ---------------------------------------------------------------- disable modem (MPSS)
# The board DTS enables the modem via dada-mpss-enable.dtsi, but the CI rootfs
# deliberately has NO modem userspace (no dada-modem/tqftpserv/rmtfs/RPMB
# license/EFS). MPSS then boots, fails its Smart Transmit license check
# (dog_hal_common) and the remoteproc crash/recovery chain eventually reboots
# the phone. Disable the MPSS node in the BUILD COPY of the DTS only: the
# linux submodule is untouched. ADSP (sensors/audio) is a separate PAS node
# and stays enabled.
MPSS_DTSI=$WS/linux/arch/arm64/boot/dts/qcom/dada-mpss-enable.dtsi
[[ -f $MPSS_DTSI ]] || die "mpss dtsi missing: $MPSS_DTSI"
if grep -q 'status = "okay"' "$MPSS_DTSI"; then
    sed -i 's#status = "okay"#status = "disabled"#' "$MPSS_DTSI"
    info "MPSS disabled in build DTS copy (modem userspace not shipped)"
else
    info "MPSS already disabled in build DTS copy"
fi
grep -q 'status = "disabled"' "$MPSS_DTSI" \
    || die "failed to disable MPSS in $MPSS_DTSI"

log "kernel: Image dtbs modules (-j$JOBS)"
make O="$BUILD" ARCH=arm64 -j"$JOBS" Image dtbs modules
KREL=$(cat "$BUILD/include/config/kernel.release")
[[ -n $KREL ]] || die "empty kernel.release"
# LOCALVERSION= keeps the release stable across clean CI runs.
make O="$BUILD" ARCH=arm64 LOCALVERSION= \
     INSTALL_MOD_PATH=/ modules_install
depmod -b / "$KREL"
info "kernel.release=$KREL"

# ---------------------------------------------------------------- sensor stack
log "clone pinned sensor sources (config/sources.json)"
python3 - "$CONFIG/sources.json" "$SRC" <<'PY'
import json, subprocess, sys
cfg, dst = sys.argv[1], sys.argv[2]
for c in json.load(open(cfg))["components"]:
    d = f'{dst}/{c["name"]}'
    subprocess.run(['git', 'clone', '--quiet', c['url'], d], check=True)
    subprocess.run(['git', '-C', d, 'checkout', '--quiet', c['sha']], check=True)
    head = subprocess.check_output(['git', '-C', d, 'rev-parse', 'HEAD'], text=True).strip()
    assert head == c['sha'], (c['name'], head)
    print(f'  ok   {c["name"]} @ {head[:12]}')
PY

log "apply dada patches"
for c in hexagonrpc iio-sensor-proxy; do
    p=$PATCHES/$c-dada.patch
    [[ -f $p ]] || die "patch missing: $p"
    git -C "$SRC/$c" apply --check "$p"
    git -C "$SRC/$c" apply "$p"
    info "applied $c-dada.patch"
done

# Prefix /usr everywhere so libs/units land in standard paths. libssc's
# pkgconfig file is generated into the staging prefix; make the build order
# explicit with PKG_CONFIG_PATH.
export PKG_CONFIG_PATH=/usr/lib/aarch64-linux-gnu/pkgconfig:/usr/lib/pkgconfig:/usr/share/pkgconfig
MESON_COMMON="--prefix=/usr --libdir=lib/aarch64-linux-gnu --buildtype=release"

log "meson: hexagonrpc"
meson setup "$SRC/hexagonrpc/build" "$SRC/hexagonrpc" $MESON_COMMON
ninja -C "$SRC/hexagonrpc/build"
ninja -C "$SRC/hexagonrpc/build" install
# Keep the sensors listener isolated from dada-voice-audiopd's hexagonrpcd -a.
install -d /opt/dada-sensors/bin
mv /usr/bin/hexagonrpcd /opt/dada-sensors/bin/hexagonrpcd
info "hexagonrpcd -> /opt/dada-sensors/bin/"

log "meson: libssc"
meson setup "$SRC/libssc/build" "$SRC/libssc" $MESON_COMMON
ninja -C "$SRC/libssc/build"
ninja -C "$SRC/libssc/build" install
ldconfig

log "meson: iio-sensor-proxy (SSC enabled)"
meson setup "$SRC/iio-sensor-proxy/build" "$SRC/iio-sensor-proxy" $MESON_COMMON \
    -Dssc-support=enabled \
    -Dgtk-tests=false -Dtests=false -Dgtk_doc=false \
    -Dudevrulesdir=/usr/lib/udev/rules.d \
    -Dsystemdsystemunitdir=/usr/lib/systemd/system
ninja -C "$SRC/iio-sensor-proxy/build"
ninja -C "$SRC/iio-sensor-proxy/build" install
ldconfig
info "iio-sensor-proxy + monitor-sensor + ssccli installed"

# Upstream hexagonrpc installs a default sensorspd unit targeting
# /dev/fastrpc-adsp (no -R, User=fastrpc). dada needs the secure node and an
# explicit -R, so remove it to avoid two competing listeners.
rm -f /usr/lib/systemd/system/hexagonrpcd-adsp-sensorspd.service \
      /usr/lib/systemd/system/hexagonrpcd-adsp-rootpd.service \
      /usr/lib/systemd/system/hexagonrpcd-sdsp.service

# ---------------------------------------------------------------- Mesa (A830 GPU)
log "clone pinned Mesa main ($CONFIG/mesa-ref.txt)"
MESA_SHA=$(grep -v '^#' "$CONFIG/mesa-ref.txt" | tr -d '[:space:]')
[[ $MESA_SHA =~ ^[0-9a-f]{40}$ ]] || die "bad Mesa SHA in mesa-ref.txt: $MESA_SHA"
MESA_SRC=$WS/Softs/mesa-src
# Shallow fetch of exactly the pinned commit. A --filter=blob:none clone would
# lazily pull blobs during meson setup (slow / fragile in CI); depth-1 fetch
# by SHA is supported by GitLab and gives a complete tree.
mkdir -p "$MESA_SRC"
git -C "$MESA_SRC" init --quiet
git -C "$MESA_SRC" remote add origin https://gitlab.freedesktop.org/mesa/mesa.git
git -C "$MESA_SRC" fetch --quiet --depth 1 origin "$MESA_SHA"
git -C "$MESA_SRC" checkout --quiet FETCH_HEAD
[[ $(git -C "$MESA_SRC" rev-parse HEAD) == "$MESA_SHA" ]] \
    || die "Mesa HEAD != pinned $MESA_SHA"
grep -q '0xffff44050001' "$MESA_SRC/src/freedreno/common/freedreno_devices.py" \
    || die "pinned Mesa lacks the A830v1 chip id"
info "mesa @ ${MESA_SHA:0:12} (A830v1 chip id present, no patch needed)"

log "build Mesa (freedreno GL + turnip Vulkan, native aarch64)"
MESA_SCRIPTS=$WS/Softs/mesa/scripts
cp "$MESA_SCRIPTS/chroot-mesa.sh" /ci/chroot-mesa.sh
chmod +x /ci/chroot-mesa.sh
# chroot-mesa.sh sources /ci/common.sh and reads scan-a830.py / env from the
# staged Softs/mesa tree, so keep those paths stable.
MESA_SRC="$MESA_SRC" JOBS="$JOBS" bash /ci/chroot-mesa.sh
info "Mesa A830 drivers installed to /opt/mesa-a830"

# ---------------------------------------------------------------- deployment
log "install firmware + deployment units"
install -d /lib/firmware
cp -a "$WS/firmware/." /lib/firmware/
# Drop the backup duplicate tree to keep rootfs.tar.gz small.
rm -rf /lib/firmware/qcom/sm8750/backup-mine
[[ -f /lib/firmware/qcom/sm8750/adsp.mdt ]] || die "adsp.mdt not installed"
[[ $(find /lib/firmware/qcom/sm8750 -maxdepth 1 -name 'adsp*' | wc -l) -eq 60 ]] \
    || die "adsp firmware count != 60 after install"
info "runtime firmware installed (60 adsp files)"

install -d /usr/lib/systemd/system /etc/systemd/system/iio-sensor-proxy.service.d \
          /etc/modules-load.d /usr/lib/udev/rules.d /etc/udev/rules.d \
          /var/lib/hexagonrpc /opt/dada-sensors/bin
install -m644 "$DEPLOY/hexagonrpcd-sensors.service" /usr/lib/systemd/system/
install -m644 "$DEPLOY/ssc.conf" /etc/systemd/system/iio-sensor-proxy.service.d/
# The working device ships the udev rule in /etc/udev/rules.d/; put it there
# too (both paths are scanned, but matching the verified layout avoids doubt).
install -m644 "$DEPLOY/80-iio-sensor-proxy.rules" /usr/lib/udev/rules.d/
install -m644 "$DEPLOY/80-iio-sensor-proxy.rules" /etc/udev/rules.d/
install -m644 "$DEPLOY/00-adsp.conf" /etc/modules-load.d/
# Device-verified services that were missing from the CI image:
#   qrtr-ns     -> QRTR/QMI name service (libssc cannot find ADSP without it)
#   dada-adsp   -> loads qcom_q6v5_pas and starts remoteproc0 (ADSP)
install -m644 "$DEPLOY/qrtr-ns.service" /usr/lib/systemd/system/
install -m644 "$DEPLOY/dada-adsp.service" /etc/systemd/system/
install -m755 "$DEPLOY/install-on-device.sh" /opt/dada-sensors/bin/
install -m755 "$DEPLOY/verify-on-device.sh" /opt/dada-sensors/bin/

# Full /var/lib/hexagonrpc data tree extracted from the working device.
# Without acdb/ dsp/ sensors/config/ sensors/state/ the SSC sensor PD
# cannot enumerate any sensor, even though ssccli itself starts fine.
DATA=$DEPLOY/data/hexagonrpc.tar.zst
[[ -s $DATA ]] || die "sensor data archive missing: $DATA"
tar -I zstd -xf "$DATA" -C /var/lib
[[ -f /var/lib/hexagonrpc/sensors/config/json.lst ]] || die "json.lst missing after unpack"
[[ -f /var/lib/hexagonrpc/sensors/sns_reg.conf ]]   || die "sns_reg.conf missing after unpack"
[[ -d /var/lib/hexagonrpc/sensors/state/registry ]] || die "registry missing after unpack"
info "hexagonrpc data tree installed ($(find /var/lib/hexagonrpc -type f | wc -l) files)"

# Verify the shipped udev rules carry all three SSC tags (patch correctness).
for tag in ssc-light ssc-accel ssc-compass; do
    grep -q "$tag" /usr/lib/udev/rules.d/80-iio-sensor-proxy.rules \
        || die "udev rules missing $tag"
done
info "deployment units installed"

# ---------------------------------------------------------------- verify (build-time only)
log "static verification"
for b in /opt/dada-sensors/bin/hexagonrpcd /usr/bin/ssccli \
         /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor; do
    [[ -x $b ]] || die "missing executable: $b"
    file "$b" | grep -q 'ARM aarch64' || die "not aarch64 ELF: $b"
done
ldd /opt/dada-sensors/bin/hexagonrpcd | grep -q 'not found' && die "hexagonrpcd unresolved libs"
ldd /usr/libexec/iio-sensor-proxy   | grep -q 'not found' && die "iio-sensor-proxy unresolved libs"
systemd-analyze verify /usr/lib/systemd/system/hexagonrpcd-sensors.service \
                       /usr/lib/systemd/system/iio-sensor-proxy.service 2>&1 | tee "$OUT/systemd-verify.log" || true
[[ -f /lib/modules/$KREL/modules.dep ]] || die "depmod did not produce modules.dep"
# hexagonrpc upstream unit tests (including the dada registry test)
meson test -C "$SRC/hexagonrpc/build" --print-errorlogs || warn "hexagonrpc tests failed (non-fatal)"
info "static verification passed"

# Enable, never start, inside the build chroot.
systemctl --root=/ enable NetworkManager.service \
                         qrtr-ns.service dada-adsp.service \
                         hexagonrpcd-sensors.service iio-sensor-proxy.service \
                         ssh.service systemd-timesyncd.service
: > /etc/machine-id
printf 'dada\n' > /etc/hostname

# ---------------------------------------------------------------- timezone / clock
# The phone has no battery-backed RTC, so after restoring the rootfs the clock
# can be years off. That makes apt's HTTPS to the TUNA mirror fail with
# "certificate verify failed" (cert not yet valid / expired). Ship Shanghai
# timezone + systemd-timesyncd so the clock is corrected automatically at
# boot. apt update then works once the network is up.
log "timezone: Asia/Shanghai + systemd-timesyncd"
printf 'Asia/Shanghai\n' > /etc/timezone
rm -f /etc/localtime
ln -s /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
[[ -f /usr/share/zoneinfo/Asia/Shanghai ]] || die "tzdata missing Asia/Shanghai"
info "timezone set to Asia/Shanghai"

# ---------------------------------------------------------------- ssh host keys
# Debian's ssh.service only runs `sshd -t` (config check) before starting
# sshd; it does NOT generate host keys. Deleting them (as an earlier version
# of this script did) makes `sshd -t` fail with "no hostkeys available" and
# ssh.service fails to start on the device. Generate them at build time and
# KEEP them so sshd can start on first boot.
log "ssh: generate host keys + validate sshd config"
ssh-keygen -A
[[ -f /etc/ssh/ssh_host_ed25519_key ]] || die "ssh host key generation failed"
# Also install a small first-boot keygen unit as a belt-and-braces guard: if
# the image is ever re-keyed or the keys are removed, regenerate before sshd.
install -d /usr/lib/systemd/system
cat > /usr/lib/systemd/system/dada-ssh-keygen.service <<'EOF'
[Unit]
Description=Regenerate SSH host keys if missing
Before=ssh.service
ConditionPathExists=!/etc/ssh/ssh_host_ed25519_key

[Service]
Type=oneshot
ExecStart=/usr/bin/ssh-keygen -A
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
systemctl --root=/ enable dada-ssh-keygen.service

# ---------------------------------------------------------------- accounts
# mmdebstrap minbase leaves root LOCKED and creates no normal user, so the
# shipped rootfs was otherwise impossible to log into. Both the normal user
# and root get the password supplied by the workflow dispatch inputs.
DADA_USER=${DADA_USER:-dada}
DADA_PASSWORD=${DADA_PASSWORD:-123456}
log "accounts: create '$DADA_USER', set password for user + root"
# Never echo the password into the build log. Create only groups that a
# minbase + the packages above are known to provide; useradd fails outright
# if any -G group is missing.
for g in sudo adm dialout audio video input systemd-journal; do
    getent group "$g" >/dev/null 2>&1 || groupadd "$g" 2>/dev/null || true
done
if ! id "$DADA_USER" >/dev/null 2>&1; then
    useradd -m -s /bin/bash -G sudo,adm,dialout,audio,video,input,systemd-journal "$DADA_USER"
fi
printf '%s:%s\n' "$DADA_USER" "$DADA_PASSWORD" | chpasswd
printf 'root:%s\n'        "$DADA_PASSWORD" | chpasswd
# Allow password-based SSH for root (WiFi SSH is the only remote channel now
# that the gadget serial console is gone); the user can harden this later.
mkdir -p /etc/ssh/sshd_config.d
cat > /etc/ssh/sshd_config.d/10-dada.conf <<'EOF'
PermitRootLogin yes
PasswordAuthentication yes
KbdInteractiveAuthentication no
UsePAM yes
EOF
# Validate the effective config now. This is exactly what ssh.service runs
# (ExecStartPre=/usr/sbin/sshd -t); if it fails here it will fail on the phone.
# sshd needs /run/sshd for privilege separation; systemd-tmpfiles normally
# creates it at boot, create it here so the check (and first boot) works.
install -d -m 0755 /run/sshd
/usr/sbin/sshd -t || die "sshd -t failed (ssh.service would not start)"
info "accounts configured (user='$DADA_USER', root password synced); sshd -t OK"

# ---------------------------------------------------------------- artifacts (before cleanup!)
log "collect artifacts into $OUT"
mkdir -p "$OUT"
cp "$BUILD/arch/arm64/boot/Image" "$OUT/Image-dada-debian"
cp "$BUILD/.config" "$OUT/final.config"
cp "$WS/linux/arch/arm64/boot/dts/qcom/sm8750-xiaomi-dada-mainline.dts" "$OUT/dts-snapshot.dts"
# Record the CI-side MPSS override so the produced DTB is reproducible.
cp "$WS/linux/arch/arm64/boot/dts/qcom/dada-mpss-enable.dtsi" \
   "$OUT/dts-dada-mpss-enable.dtsi"
find "$BUILD/arch/arm64/boot/dts/qcom" -name 'sm8750-xiaomi-dada-mainline.dtb' \
     -exec cp {} "$OUT/" \;
printf '%s\n' "$KREL" > "$OUT/kernel.release"
# boot.img for `fastboot boot` (header v4 / 4096, same as the verified local build)
python3 "$WS/tools/mkbootimg/mkbootimg.py" \
    --header_version 4 --pagesize 4096 \
    --kernel "$BUILD/arch/arm64/boot/Image" \
    --cmdline "console=tty0 root=/dev/sda36 rw rootwait" \
    --output "$OUT/boot-dada-debian-test.img"
sha256sum "$OUT"/* > "$OUT/SHA256SUMS"
info "artifacts collected"
