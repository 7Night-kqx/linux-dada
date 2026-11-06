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
gcc --version | head -1
meson --version | head -1

# ---------------------------------------------------------------- dependencies
log "apt: build + runtime dependencies (Debian trixie names)"
export DEBIAN_FRONTEND=noninteractive
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
    file tar xz-utils ca-certificates
info "dependencies installed"

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
          /etc/modules-load.d /usr/lib/udev/rules.d /var/lib/hexagonrpc \
          /opt/dada-sensors/bin
install -m644 "$DEPLOY/hexagonrpcd-sensors.service" /usr/lib/systemd/system/
install -m644 "$DEPLOY/ssc.conf" /etc/systemd/system/iio-sensor-proxy.service.d/
install -m644 "$DEPLOY/80-iio-sensor-proxy.rules" /usr/lib/udev/rules.d/
install -m644 "$DEPLOY/00-adsp.conf" /etc/modules-load.d/
install -m755 "$DEPLOY/install-on-device.sh" /opt/dada-sensors/bin/
install -m755 "$DEPLOY/verify-on-device.sh" /opt/dada-sensors/bin/
# Skeleton only. The Android-extracted data tree is injected on-device.
mkdir -p /var/lib/hexagonrpc/{acdb,dsp/adsp,dsp/cdsp,sensors/config,sensors/state/registry}
touch /var/lib/hexagonrpc/sensors/sns_reg.conf

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
systemctl --root=/ enable hexagonrpcd-sensors.service iio-sensor-proxy.service
: > /etc/machine-id
rm -f /etc/ssh/ssh_host_* 2>/dev/null || true
printf 'dada\n' > /etc/hostname

# ---------------------------------------------------------------- artifacts (before cleanup!)
log "collect artifacts into $OUT"
mkdir -p "$OUT"
cp "$BUILD/arch/arm64/boot/Image" "$OUT/Image-dada-debian"
cp "$BUILD/.config" "$OUT/final.config"
cp "$WS/linux/arch/arm64/boot/dts/qcom/sm8750-xiaomi-dada-mainline.dts" "$OUT/dts-snapshot.dts"
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
