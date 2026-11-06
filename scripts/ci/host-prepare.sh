#!/usr/bin/env bash
# Runs on the arm64 GitHub runner (host side), BEFORE entering the chroot.
#  1. build the official Debian minimal rootfs with mmdebstrap --variant=minbase
#  2. stage source trees / patches / firmware / tools into rootfs/workspace
#  3. bind-mount the pseudo filesystems needed by chroot (apt, depmod, meson)
set -euo pipefail
source "$(dirname "$0")/common.sh"

REPO=${REPO:-$(git rev-parse --show-toplevel)}
ROOTFS=${ROOTFS:-$REPO/rootfs}
WS=$ROOTFS/workspace
SUITE=${SUITE:-trixie}
MIRROR=${MIRROR:-https://deb.debian.org/debian}

need mmdebstrap
[[ -f $REPO/.gitmodules ]] || die ".gitmodules missing"
[[ -d $REPO/linux/.git || -f $REPO/linux/.git ]] || die "linux submodule not checked out (use actions/checkout submodules: recursive)"
[[ -d $REPO/firmware/qcom/sm8750 ]] || die "main-repo firmware/ missing"

# 1. official Debian minimal rootfs (native arm64, no qemu, no cross compiler)
log "mmdebstrap --variant=minbase ($SUITE / arm64)"
sudo rm -rf "$ROOTFS"
sudo mmdebstrap \
    --architectures=arm64 \
    --variant=minbase \
    --include=ca-certificates \
    "$SUITE" "$ROOTFS" "$MIRROR"
[[ -f $ROOTFS/bin/bash ]] || die "mmdebstrap produced no /bin/bash"

# 2. staging — everything under /workspace is removed by chroot-cleanup.sh
log "stage build inputs into $WS"
sudo mkdir -p "$WS/build-dada-evidence" "$REPO/out-stage" "$ROOTFS/mnt/artifacts"
sudo cp -a "$REPO/linux" "$WS/linux"
sudo cp -a "$REPO/config" "$WS/config"
sudo cp -a "$REPO/firmware" "$WS/firmware"
sudo cp -a "$REPO/tools" "$WS/tools"
# Softs: only patches + deployment units are needed in the chroot. The
# sensors-src checkouts are LOCAL REFERENCES — CI re-clones pinned SHAs from
# config/sources.json into $WS/Softs/sensors-src, so it must not exist yet.
sudo install -d "$WS/Softs/patches" "$WS/Softs/sensors" "$WS/Softs/sensors-src"
sudo cp -a "$REPO/Softs/patches/." "$WS/Softs/patches/"
sudo cp -a "$REPO/Softs/sensors/." "$WS/Softs/sensors/"
# CI scripts live at /ci (OUTSIDE /workspace) so chroot-cleanup.sh can delete
# /workspace wholesale without removing the script that is currently running.
sudo install -d "$ROOTFS/ci"
sudo cp -a "$REPO/scripts/ci/." "$ROOTFS/ci/"

# Firmware integrity: 60 adsp files + the 9 ath12k runtime files must exist.
[[ $(find "$WS/firmware/qcom/sm8750" -maxdepth 1 -name 'adsp*' | wc -l) -eq 60 ]] \
    || die "expected 60 adsp* firmware files"
[[ -f $WS/firmware/qcom/sm8750/adsp.mdt && -f $WS/firmware/qcom/sm8750/adsp_dtb.mdt ]] \
    || die "adsp.mdt / adsp_dtb.mdt missing"
[[ -f $WS/firmware/ath12k/WCN7850/hw2.0/amss.bin ]] \
    || die "ath12k runtime firmware missing"
info "firmware staged ($(find "$WS/firmware" -type f | wc -l) files)"

# 3. bind mounts (host side; torn down by host-package.sh)
log "bind mounts for chroot"
sudo cp /etc/resolv.conf "$ROOTFS/etc/resolv.conf"
for d in dev proc sys; do
    sudo mkdir -p "$ROOTFS/$d"
    sudo mount --bind "/$d" "$ROOTFS/$d"
done
sudo mkdir -p "$ROOTFS/dev/pts"
sudo mount -t devpts devpts "$ROOTFS/dev/pts" || true
# Artifacts are written to /mnt/artifacts (outside /workspace) so they
# survive chroot-cleanup.sh removing /workspace entirely.
sudo mount --bind "$REPO/out-stage" "$ROOTFS/mnt/artifacts"
info "chroot environment ready"
