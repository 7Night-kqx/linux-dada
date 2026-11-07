#!/bin/bash
# install-mesa-a830.sh - install the cross-built Mesa into a target root and
# point the session at it.
#
# Adapted from xiaobai-Lethe/Y700-elden-linux project/rootfs/install-mesa-a830.sh.
# Only the Mesa payload is copied: the build also stages libarchive/libxml2 and
# the bsdtar/xmllint helpers pulled in as meson subprojects, which would shadow
# the distro copies if they landed in the runtime library path.
#
# Usage:
#   STAGE=<build>/stage/opt/mesa-a830 R=/mnt/rootfs bash scripts/install-mesa-a830.sh [--alpine]
#
# Options:
#   --alpine   also write /etc/profile.d/mesa-a830.sh (openrc / busybox users;
#              Alpine has no systemd, so the systemd drop-ins are still written
#              but harmless)
#
# Environment:
#   STAGE   staged install prefix          (default: ./build/stage/opt/mesa-a830)
#   R       target rootfs mount point      (default: /)
#   LIBDIR  target libdir                  (default: lib/aarch64-linux-gnu)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
STAGE=${STAGE:-$PWD/build/stage/opt/mesa-a830}
R=${R:-/}
LIBDIR=${LIBDIR:-lib/aarch64-linux-gnu}
PREFIX=$R/opt/mesa-a830

alpine=0
[ "${1:-}" = "--alpine" ] && alpine=1

[ -d "$STAGE" ] || { echo "staging prefix not found: $STAGE" >&2; exit 1; }
[ -d "$R" ] || { echo "target root not found: $R" >&2; exit 1; }

echo "== installing payload into $PREFIX"
rm -rf "$PREFIX"
install -d "$PREFIX/$LIBDIR/dri" "$PREFIX/$LIBDIR/gbm" \
	"$PREFIX/share/vulkan/icd.d" "$PREFIX/share/glvnd/egl_vendor.d" \
	"$PREFIX/runtime"

# libgallium carries the actual GL/EGL implementation in modern Mesa.
cp -a "$STAGE/$LIBDIR"/libEGL.so* "$PREFIX/$LIBDIR/" 2>/dev/null || true
cp -a "$STAGE/$LIBDIR"/libGL.so* "$PREFIX/$LIBDIR/" 2>/dev/null || true
cp -a "$STAGE/$LIBDIR"/libGLESv2.so* "$PREFIX/$LIBDIR/" 2>/dev/null || true
cp -a "$STAGE/$LIBDIR"/libgbm.so* "$PREFIX/$LIBDIR/" 2>/dev/null || true
cp -a "$STAGE/$LIBDIR"/libgallium-*.so "$PREFIX/$LIBDIR/" 2>/dev/null || true
cp -a "$STAGE/$LIBDIR"/libvulkan_freedreno.so "$PREFIX/$LIBDIR/" 2>/dev/null || true
[ -d "$STAGE/$LIBDIR/dri" ] && cp -a "$STAGE/$LIBDIR/dri/." "$PREFIX/$LIBDIR/dri/"
[ -d "$STAGE/$LIBDIR/gbm" ] && cp -a "$STAGE/$LIBDIR/gbm/." "$PREFIX/$LIBDIR/gbm/"
[ -d "$STAGE/share/vulkan/icd.d" ] && cp -a "$STAGE/share/vulkan/icd.d/." "$PREFIX/share/vulkan/icd.d/"
[ -d "$STAGE/share/glvnd/egl_vendor.d" ] && \
	cp -a "$STAGE/share/glvnd/egl_vendor.d/." "$PREFIX/share/glvnd/egl_vendor.d/"

# Mesa is built without an RPATH, so everything the GL/EGL/GBM libraries pull
# in has to be reachable through LD_LIBRARY_PATH - libgallium included.
for so in libEGL.so.1 libGL.so.1 libGLESv2.so.2 libgbm.so.1; do
	[ -e "$PREFIX/$LIBDIR/$so" ] && ln -sfn "../$LIBDIR/$so" "$PREFIX/runtime/$so"
done
for g in "$PREFIX/$LIBDIR"/libgallium-*.so; do
	[ -e "$g" ] && ln -sfn "../$LIBDIR/$(basename "$g")" "$PREFIX/runtime/$(basename "$g")"
done

echo "== egl vendor json"
if [ ! -e "$PREFIX/share/glvnd/egl_vendor.d/50_mesa.json" ]; then
	cat > "$PREFIX/share/glvnd/egl_vendor.d/50_mesa.json" <<EOF
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "/opt/mesa-a830/$LIBDIR/libEGL.so.1"
    }
}
EOF
fi

echo "== session environment ($R/etc/environment)"
cat > "$R/etc/environment" <<EOF
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LD_LIBRARY_PATH="/opt/mesa-a830/runtime"
LIBGL_DRIVERS_PATH="/opt/mesa-a830/$LIBDIR/dri"
GBM_BACKENDS_PATH="/opt/mesa-a830/$LIBDIR/gbm"
__EGL_VENDOR_LIBRARY_FILENAMES="/opt/mesa-a830/share/glvnd/egl_vendor.d/50_mesa.json"
VK_DRIVER_FILES="/opt/mesa-a830/share/vulkan/icd.d/freedreno_icd.aarch64.json"
EOF

if [ "$alpine" -eq 1 ]; then
	echo "== Alpine profile.d snippet"
	install -d -m 755 "$R/etc/profile.d"
	cp "$HERE/../env/mesa-a830.sh" "$R/etc/profile.d/mesa-a830.sh"
	chmod 644 "$R/etc/profile.d/mesa-a830.sh"
fi

echo "== systemd/gdm drop-in"
install -d -m 755 "$R/etc/systemd/system/gdm.service.d" \
	"$R/etc/systemd/system/gdm3.service.d"
for d in gdm gdm3; do
	cp "$HERE/../env/50-mesa-a830.conf" "$R/etc/systemd/system/$d.service.d/50-mesa-a830.conf"
done

echo "== result"
du -sh "$PREFIX"
ls "$PREFIX/$LIBDIR/" | head
echo
echo "verify on the device:"
echo "  python3 scripts/scan-a830.py /opt/mesa-a830/$LIBDIR/libvulkan_freedreno.so"
echo "  python3 scripts/vk-probe.py"
