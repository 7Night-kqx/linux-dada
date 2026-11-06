#!/usr/bin/env bash
# Executed INSIDE the chroot, AFTER artifacts were collected.
# Removes build-time code and generated objects while preserving every
# runtime library the sensor binaries link against.
#
# CRITICAL: meson used `ninja install` (not dpkg), so dpkg does NOT know about
# the installed binaries' runtime deps. A naive `apt-get autoremove` would
# delete libglib/libgudev/libqmi/libprotobuf-c/... and break the services.
# We therefore mark those runtime libs as manually installed FIRST, then
# purge an explicit build-tool list (no --auto-remove on the purge call).
set -euo pipefail
source "$(dirname "$0")/common.sh"

export DEBIAN_FRONTEND=noninteractive

log "pin runtime libraries (protect from autoremove)"
# Derive the owning packages from the ACTUAL ldd output, so Debian trixie's
# t64 renames (libglib2.0-0t64, libpolkit-gobject-1-0t64, ...) cannot slip
# through a hardcoded grep list.
RUNTIME_LIBS=$(for b in /opt/dada-sensors/bin/hexagonrpcd /usr/bin/ssccli \
                        /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor; do
                  ldd "$b" 2>/dev/null || true
               done | awk '/=> \// {print $3}' | sort -u)
RUNTIME_PKGS=$(for lib in $RUNTIME_LIBS; do dpkg -S "$lib" 2>/dev/null | cut -d: -f1; done \
               | tr ',' '\n' | sed 's/[[:space:]]//g' | sort -u)
# Always keep the init/service plumbing regardless of ldd output.
RUNTIME_PKGS="$RUNTIME_PKGS
systemd
systemd-sysv
udev
dbus
kmod
libc6
libgcc-s1"
RUNTIME_PKGS=$(echo "$RUNTIME_PKGS" | sed '/^$/d' | sort -u | tr '\n' ' ')
# shellcheck disable=SC2086
apt-mark manual $RUNTIME_PKGS
info "pinned $(echo $RUNTIME_PKGS | wc -w) runtime packages"

log "purge build tools (explicit list, no --auto-remove)"
# shellcheck disable=SC2086
apt-get purge -y \
    gcc make bc bison flex libssl-dev libelf-dev device-tree-compiler \
    meson ninja-build cmake pkg-config gettext git \
    python3-dev libglib2.0-dev libgudev-1.0-dev libqmi-glib-dev \
    libprotobuf-c-dev protobuf-c-compiler protobuf-compiler \
    gobject-introspection libgirepository1.0-dev libgirepository-2.0-dev \
    libpolkit-gobject-1-dev valac libudev-dev libsystemd-dev \
    libjson-c-dev python3-gi 2>/dev/null || true
apt-get autoremove -y || true
apt-get clean
rm -rf /var/lib/apt/lists/*

log "remove build sources, objects, caches"
rm -rf /workspace /opt/dada-sensors/bin/../src /usr/src /root/.cache /tmp/*
# modules_install leaves symlinks into /workspace/linux; they are dead after
# /workspace removal and would confuse depmod on the device.
rm -f /lib/modules/*/build /lib/modules/*/source
rm -f /lib/modules/*/modules.devname~ /lib/modules/*/*.bak 2>/dev/null || true
# Stale generated unit symlinks pointing at removed upstream services.
systemctl --root=/ disable hexagonrpcd-adsp-sensorspd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-*.service

log "post-cleanup runtime check"
KREL=$(ls -1 /lib/modules | head -1)
for b in /opt/dada-sensors/bin/hexagonrpcd /usr/bin/ssccli \
         /usr/libexec/iio-sensor-proxy; do
    [[ -x $b ]] || die "runtime binary removed: $b"
    if ldd "$b" 2>/dev/null | grep -q 'not found'; then
        die "unresolved runtime libs after cleanup: $b"
    fi
done
[[ -f /lib/firmware/qcom/sm8750/adsp.mdt ]] || die "runtime firmware removed"
[[ -f /lib/modules/$KREL/modules.dep ]] || die "modules.dep removed"
info "runtime preserved, build artifacts removed"
