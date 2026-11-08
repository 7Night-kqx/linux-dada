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
SUITE=${SUITE:-sid}
MIRROR=${MIRROR:-https://mirrors.tuna.tsinghua.edu.cn/debian}

need mmdebstrap
[[ -f $REPO/.gitmodules ]] || die ".gitmodules missing"
[[ -d $REPO/linux/.git || -f $REPO/linux/.git ]] || die "linux submodule not checked out (use actions/checkout submodules: recursive)"
[[ -d $REPO/firmware/qcom/sm8750 ]] || die "main-repo firmware/ missing"

# 1. official Debian minimal rootfs (native arm64, no qemu, no cross compiler)
log "mmdebstrap --variant=minbase ($SUITE / arm64)"
sudo rm -rf "$ROOTFS"
# mmdebstrap's internal apt exits 25 on dependency/mirror failures. Capture
# full output to a log and, when it fails, print the tail so the Actions log
# shows the real apt error instead of just "exit code 25".
MM_LOG=$REPO/out-stage/mmdebstrap.log
sudo mkdir -p "$REPO/out-stage"
# On an Ubuntu runner the host apt does NOT trust Debian's archive key, so
# mmdebstrap's internal apt fails to verify sid/InRelease and exits 25.
# --keyring points the build-time apt at the Debian keyring installed by the
# workflow; --include=debian-archive-keyring puts that key INTO the generated
# rootfs so chroot apt (used later to install build deps) can verify too.
MM_ARGS=(--architectures=arm64 --variant=minbase
         --include=ca-certificates,debian-archive-keyring)
KEYRING=/usr/share/keyrings/debian-archive-keyring.gpg
if [[ -f $KEYRING ]]; then MM_ARGS+=(--keyring "$KEYRING"); fi
if [[ ${DADA_MMDEBSTRAP_DEBUG:-0} == 1 ]]; then MM_ARGS+=(--debug); fi
log "mmdebstrap args: ${MM_ARGS[*]} $SUITE $ROOTFS $MIRROR"
set +e
sudo mmdebstrap "${MM_ARGS[@]}" "$SUITE" "$ROOTFS" "$MIRROR" 2>&1 | sudo tee "$MM_LOG"
MM_RC=${PIPESTATUS[0]}
set -e
if [[ $MM_RC -ne 0 ]]; then
    echo "ERROR: mmdebstrap exited $MM_RC; last 80 lines:" >&2
    tail -80 "$MM_LOG" >&2
    exit "$MM_RC"
fi
[[ -f $ROOTFS/bin/bash ]] || die "mmdebstrap produced no /bin/bash"
info "mmdebstrap ok ($(find "$ROOTFS" -type f | wc -l) files)"

# 2. staging — everything under /workspace is removed by chroot-cleanup.sh
log "stage build inputs into $WS"
sudo mkdir -p "$WS/build-dada-evidence" "$REPO/out-stage" "$ROOTFS/mnt/artifacts"
sudo cp -a "$REPO/linux" "$WS/linux"
sudo cp -a "$REPO/config" "$WS/config"
sudo cp -a "$REPO/firmware" "$WS/firmware"
sudo cp -a "$REPO/tools" "$WS/tools"
# Softs: patches, sensor deployment units and the Mesa binary-patch scripts
# are needed in the chroot. sensors-src is a LOCAL REFERENCE — CI clones the
# pinned sensor SHAs at build time, so that dir must not pre-exist.
# (No Mesa source checkout is needed anymore: we patch the distro libs.)
sudo install -d "$WS/Softs/patches" "$WS/Softs/sensors" "$WS/Softs/sensors-src"
sudo cp -a "$REPO/Softs/patches/." "$WS/Softs/patches/"
sudo cp -a "$REPO/Softs/sensors/." "$WS/Softs/sensors/"
sudo cp -a "$REPO/Softs/mesa" "$WS/Softs/mesa"
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
