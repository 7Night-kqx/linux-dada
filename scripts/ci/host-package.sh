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

## Login
- Normal user: the \`username\` workflow_dispatch input (default **dada**)
- Password: the \`password\` input (default **123456**), applied to BOTH the
  normal user and root.
- SSH: openssh-server is installed and enabled; password auth and root login
  are allowed so WiFi SSH is usable (the gadget serial console is gone on the
  USB host track). Host keys are generated at BUILD time (ssh-keygen -A) and
  kept, so \`sshd -t\` passes and ssh.service starts on first boot. A
  dada-ssh-keygen.service guard regenerates them if ever missing.
- **Change the password after first boot**: \`passwd\` and \`passwd root\`.
  Dispatch the workflow with your own values instead of the defaults.
- Network CLI tools: \`ifconfig\` (net-tools), \`ping\` (iputils-ping),
  \`ip\` (iproute2), \`iw\`, \`rfkill\`, \`nmcli\` are all installed, plus
  \`vim\`, \`fastfetch\`, \`btop\`.
- apt uses a single source (\`/etc/apt/sources.list\`, TUNA mirror) and the
  package index is kept, so \`apt install\` works out of the box.
- Timezone \`Asia/Shanghai\` + \`systemd-timesyncd\` keep the clock correct
  (the phone has no RTC battery; a wrong clock breaks apt's HTTPS cert
  validation). Run \`apt update\` after WiFi is connected if the clock was
  just synced.

## WiFi
- \`network-manager\` + \`wpa_supplicant\` + \`iproute2\` + \`iw\`/\`rfkill\` are
  installed and NetworkManager.service is enabled.
- \`nmcli device wifi list\` / \`nmcli device wifi connect "<SSID>" password "<PSK>"\`.
- ModemManager is NOT installed (only its client library comes in as an NM
  dependency); cellular/modem bring-up is out of scope for this build.

## GPU (Adreno 830)
- Mesa is built from pinned upstream main (already contains the A830v1 chip
  id, no patch needed): freedreno GL/EGL/GBM + turnip Vulkan, installed to
  \`/opt/mesa-a830\`. Debian's own Mesa 25.x cannot drive this GPU.
- Session env is set in \`/etc/environment\`, \`/etc/environment.d/\`,
  \`/etc/profile.d/mesa-a830.sh\` and gdm drop-ins, so desktop sessions pick
  up \`LD_LIBRARY_PATH\` / \`VK_DRIVER_FILES\` automatically.
- Verify: \`ls /dev/dri/\` (card0 + renderD128), and
  \`VK_DRIVER_FILES=/opt/mesa-a830/share/vulkan/icd.d/freedreno_icd.aarch64.json vulkaninfo\`.
- Kernel side (drm/msm + GPU/GMU DT + gen80000 firmware) is already in the
  Image.

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
