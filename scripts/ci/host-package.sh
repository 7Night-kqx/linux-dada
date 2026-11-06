#!/usr/bin/env bash
# Runs on the arm64 runner (host side), AFTER chroot-cleanup.sh.
# Unmounts bind mounts, packages the cleaned rootfs, writes provenance.
set -euo pipefail
source "$(dirname "$0")/common.sh"

REPO=${REPO:-$(git rev-parse --show-toplevel)}
ROOTFS=${ROOTFS:-$REPO/rootfs}
OUT=${OUT:-$REPO/out}
WS=$ROOTFS/workspace

log "unmount chroot pseudo filesystems"
# /mnt/artifacts is bind-mounted to $REPO/out-stage (see host-prepare.sh),
# so artifacts written by chroot-build.sh survive removal of /workspace.
sudo umount "$ROOTFS/mnt/artifacts" 2>/dev/null || true
sudo umount "$ROOTFS/dev/pts" 2>/dev/null || true
for d in dev proc sys; do sudo umount "$ROOTFS/$d" 2>/dev/null || true; done

mkdir -p "$OUT"
cp -a "$REPO/out-stage/." "$OUT/"

log "package rootfs (cleaned)"
[[ -f "$ROOTFS/bin/bash" ]] || die "rootfs has no /bin/bash"
[[ ! -e "$ROOTFS/workspace" ]] || die "/workspace survived cleanup"
[[ ! -e "$ROOTFS/usr/bin/gcc" ]] || die "gcc survived cleanup"
KREL=$(cat "$OUT/kernel.release" 2>/dev/null || echo unknown)
TARBALL=rootfs-debian13-dada-$KREL.tar.gz
# Trailing "." is mandatory (docs/rootfs-backup-restore.md: "tar: empty archive").
sudo tar --numeric-owner -czf "$OUT/$TARBALL" -C "$ROOTFS" \
    --exclude='./proc/*' --exclude='./sys/*' --exclude='./dev/*' \
    --exclude='./run/*' --exclude='./tmp/*' --exclude='./mnt/*' \
    --exclude='./workspace/*' --exclude='./ci/*' \
    --exclude='./etc/resolv.conf' .
info "packaged $TARBALL ($(du -h "$OUT/$TARBALL" | cut -f1))"

log "provenance.json"
KERNEL_SHA=$(git -C "$REPO/linux" rev-parse HEAD)
PIN_SHA=$(grep -v '^#' "$REPO/config/kernel-ref.txt" | tr -d '[:space:]')
[[ $KERNEL_SHA == "$PIN_SHA" ]] || die "linux submodule HEAD != config/kernel-ref.txt"
SOURCES_SHA=$(sha256_of "$REPO/config/sources.json")
FW_SHA=$(sha256_of "$REPO/config/firmware-manifest.txt")
PATCH_SHA=$(cat "$REPO"/Softs/patches/*.patch | sha256sum | cut -d' ' -f1)
DTS_SHA=$(sha256_of "$REPO/linux/arch/arm64/boot/dts/qcom/sm8750-xiaomi-dada-mainline.dts")
DEFCONFIG_SHA=$(sha256_of "$REPO/linux/arch/arm64/configs/dada_defconfig")
python3 - "$OUT/provenance.json" <<PY
import json, hashlib, os, sys
out = sys.argv[1]
def sha(p):
    try:
        return hashlib.sha256(open(p,'rb').read()).hexdigest()
    except FileNotFoundError:
        return None
d = {
  "kernel_repo": "7Night-kqx/linux",
  "kernel_sha": "$KERNEL_SHA",
  "kernel_release": "$KREL",
  "defconfig_sha256": "$DEFCONFIG_SHA",
  "dts_sha256": "$DTS_SHA",
  "sources_json_sha256": "$SOURCES_SHA",
  "patches_sha256": "$PATCH_SHA",
  "firmware_manifest_sha256": "$FW_SHA",
  "final_config_sha256": sha(os.path.join("$OUT", "final.config")),
  "artifacts": {n: sha(os.path.join("$OUT", n)) for n in sorted(os.listdir("$OUT"))
                if os.path.isfile(os.path.join("$OUT", n)) and n != "SHA256SUMS"},
}
json.dump(d, open(out, "w"), indent=2, sort_keys=True)
PY
info "provenance written"

( cd "$OUT" && sha256sum * > SHA256SUMS )

log "RELEASE_NOTES.md"
cat > "$OUT/RELEASE_NOTES.md" <<EOF
# dada Debian build $KREL

Native aarch64 build. Kernel, modules and userspace sensor services were all
built INSIDE the shipped rootfs via chroot; build-time code and objects were
purged before packaging.

## Artifacts
- \`Image-dada-debian\` — kernel image (built-in DTB, ARM64_BUILTIN_DTB_FORCE)
- \`boot-dada-debian-test.img\` — \`fastboot boot\` verification image
- \`final.config\` / \`dts-snapshot.dts\` — reproducibility inputs
- \`rootfs-debian13-dada-$KREL.tar.gz\` — cleaned Debian 13 trixie rootfs
- \`provenance.json\` / \`SHA256SUMS\` — SHA pins and hashes

## Provenance
- kernel: \`7Night-kqx/linux@$KERNEL_SHA\`
- kernel release: \`$KREL\`
- sensor sources: see \`config/sources.json\` (3 pinned SHAs + 2 patches)

## Install (NEVER \`fastboot flash\`)
1. Restore the rootfs tar to /dev/sda36 as root with busybox/GNU tar:
   \`tar --numeric-owner -xzpPf rootfs-*.tar.gz -C /mnt/sda36\` after excluding
   proc/sys/dev/run/tmp/mnt; the trailing \`.\` in the archive matters.
2. \`fastboot boot boot-dada-debian-test.img\` — temporary, no partition writes.
3. On the device: \`/opt/dada-sensors/bin/install-on-device.sh\` prints the
   Android extraction map for the device-private /var/lib/hexagonrpc data tree,
   then \`/opt/dada-sensors/bin/verify-on-device.sh\`.

HasAmbientLight is not an acceptance criterion (ALS still needs display-state
injection per the sensor bring-up notes). Gyro is read via
\`ssccli --sensor gyroscope\`.
EOF
( cd "$OUT" && sha256sum * > SHA256SUMS )

log "final artifacts"
ls -lh "$OUT"
