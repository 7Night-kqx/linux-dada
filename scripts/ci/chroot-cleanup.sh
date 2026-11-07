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

# Surface the real failing line as a GitHub annotation (the Actions API is
# blocked here, so the job page otherwise only shows a bare exit code).
trap 'rc=$?; printf "::error::chroot-cleanup.sh failed at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

export DEBIAN_FRONTEND=noninteractive

log "pin runtime libraries (protect from autoremove)"
# Derive the owning packages from the ACTUAL ldd output, so Debian trixie's
# t64 renames (libglib2.0-0t64, libpolkit-gobject-1-0t64, ...) cannot slip
# through a hardcoded grep list.
# NOTE: every command substitution below is guarded with `|| true`. Under
# `set -o pipefail`, a single ldd/dpkg -S miss (exit 1) would otherwise abort
# the whole cleanup -- this was the run-8 failure at line 29.
RUNTIME_LIBS=$( { for b in /opt/dada-sensors/bin/hexagonrpcd /usr/bin/ssccli \
                           /usr/libexec/iio-sensor-proxy /usr/bin/monitor-sensor; do
                      ldd "$b" 2>/dev/null || true
                  done; } | awk '/=> \// {print $3}' | sort -u ) || true
RUNTIME_PKGS=$( { for lib in $RUNTIME_LIBS; do
                      dpkg -S "$lib" 2>/dev/null || true
                  done; } | cut -d: -f1 | tr ',' '\n' \
                      | sed 's/[[:space:]]//g' | sort -u ) || true
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
# apt-mark manual exits 1 on a single unknown package and would abort the
# whole purge under set -e. Mark each package independently, logging misses.
pinned=0
for p in $RUNTIME_PKGS; do
    if apt-mark manual "$p" >/dev/null 2>&1; then
        pinned=$((pinned+1))
    else
        warn "runtime package not found for pinning: $p"
    fi
done
info "pinned $pinned runtime packages"

log "remove build toolchain files (keep dpkg packages)"
# DO NOT `apt-get purge/autoremove` here. The meson-installed sensor binaries
# link against libqmi-glib / libglib / libgudev / libprotobuf-c runtime libs;
# purging the -dev packages makes apt consider those runtime libs orphaned and
# removes them, which broke /usr/bin/ssccli on run 9. Removing the toolchain
# FILES directly is deterministic and keeps every runtime lib intact.
rm -f /usr/bin/gcc* /usr/bin/*-gcc* /usr/bin/g++* /usr/bin/cc \
      /usr/bin/make /usr/bin/bc /usr/bin/bison /usr/bin/flex \
      /usr/bin/meson /usr/bin/ninja /usr/bin/cmake /usr/bin/pkg-config \
      /usr/bin/valac /usr/bin/protoc /usr/bin/protoc-gen-c \
      /usr/bin/dtc /usr/bin/git /usr/bin/gettext* 2>/dev/null || true
# Headers and static archives are build-time artifacts, not runtime deps.
rm -rf /usr/include /usr/lib/aarch64-linux-gnu/*.a \
       /usr/lib/aarch64-linux-gnu/pkgconfig /usr/share/pkgconfig \
       /usr/lib/python3*/site-packages 2>/dev/null || true
# apt-get clean drops the downloaded .deb cache but KEEP /var/lib/apt/lists
# (the package index). Removing the index made `apt install <pkg>` on the
# device fail with "Unable to locate package" until the user ran apt update
# first. Keeping it makes the rootfs usable out of the box.
apt-get clean

log "remove build sources, objects, caches"
# Never leave the workflow-supplied plaintext password behind.
rm -f /ci/dada-account.env
rm -rf /workspace /opt/dada-sensors/bin/../src /usr/src /root/.cache /tmp/*
# modules_install leaves symlinks into /workspace/linux; they are dead after
# /workspace removal and would confuse depmod on the device.
rm -f /lib/modules/*/build /lib/modules/*/source
rm -f /lib/modules/*/modules.devname~ /lib/modules/*/*.bak 2>/dev/null || true
# Stale generated unit symlinks pointing at removed upstream services.
systemctl --root=/ disable hexagonrpcd-adsp-sensorspd.service 2>/dev/null || true
rm -f /etc/systemd/system/multi-user.target.wants/hexagonrpcd-adsp-*.service

log "post-cleanup runtime check"
# `ls | head` trips set -o pipefail (SIGPIPE) when there are multiple module
# dirs; use a pure shell glob instead.
KREL=""
for d in /lib/modules/*; do [[ -d $d ]] && { KREL=${d##*/}; break; }; done
[[ -n $KREL ]] || die "no /lib/modules/<release> directory"
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
