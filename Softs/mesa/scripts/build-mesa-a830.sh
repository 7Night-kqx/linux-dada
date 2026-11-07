#!/bin/bash
# build-mesa-a830.sh - cross-compile Mesa (freedreno GL + turnip Vulkan) for
# the Xiaomi 15 "dada" (SM8750 / Adreno 830) mainline kernel.
#
# Adapted from xiaobai-Lethe/Y700-elden-linux project/rootfs/build-mesa-a830.sh,
# whose meson option set was validated on the Y700 Gen4 (same SM8750 + A830
# family).  Every path is overridable through the environment.
#
# IMPORTANT: build Mesa 26.1 or newer.  Mesa 26.0 has no real A830 device
# entry (only a "totally fake, just to get cffdump to work" one) and is known
# to wedge the GPU.  26.1/26.2 additionally need patches/0001-*.patch, or
# build from git main which already contains it (commit 2061a5ee).
#
# Usage (inside WSL, from the mesa-a830 directory):
#   MESA_SRC=/path/to/mesa-26.2 bash scripts/build-mesa-a830.sh
#
# Environment:
#   MESA_SRC   Mesa source tree (required)
#   BUILD_DIR  meson build dir        (default: ./build)
#   CROSS_FILE meson cross file       (default: ./scripts/cross-aarch64.ini)
#   PREFIX     install prefix         (default: /opt/mesa-a830)
#   LIBDIR     target libdir          (default: lib/aarch64-linux-gnu; Alpine: lib)
#   JOBS       parallelism            (default: nproc)
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)

MESA_SRC=${MESA_SRC:?set MESA_SRC to the Mesa source tree (>= 26.1)}
BUILD_DIR=${BUILD_DIR:-$PWD/build}
CROSS_FILE=${CROSS_FILE:-$HERE/cross-aarch64.ini}
PREFIX=${PREFIX:-/opt/mesa-a830}
LIBDIR=${LIBDIR:-lib/aarch64-linux-gnu}
JOBS=${JOBS:-$(nproc)}
MESON=${MESON:-$(command -v meson || true)}

[ -n "$MESON" ] || { echo "meson not found (pip install meson ninja)" >&2; exit 1; }
[ -f "$CROSS_FILE" ] || { echo "cross file not found: $CROSS_FILE" >&2; exit 1; }

# Sanity: the chip-id entry must be present in the source tree, otherwise the
# resulting driver will refuse the GPU on dada.
if ! grep -q '0xffff44050001' "$MESA_SRC/src/freedreno/common/freedreno_devices.py"; then
	echo "!! $MESA_SRC has no 0xffff44050001 (A830v1) entry."
	echo "   Either use Mesa >= the commit 2061a5ee (git main), or apply"
	echo "   $HERE/../patches/0001-freedreno-add-adreno-830v1-chip-id.patch"
	echo "   to the source tree first:"
	echo "     git -C \$MESA_SRC apply $HERE/../patches/0001-freedreno-add-adreno-830v1-chip-id.patch"
	exit 1
fi

# pkg-config for the target comes from the cross file's pkg_config_libdir;
# exporting the *_SYSROOT/_LIBDIR/_PATH trio here would also redirect native
# tool lookups, so clear them.
unset PKG_CONFIG_SYSROOT_DIR PKG_CONFIG_LIBDIR PKG_CONFIG_PATH

echo "== meson setup $BUILD_DIR"
rm -rf "$BUILD_DIR"
"$MESON" setup "$BUILD_DIR" "$MESA_SRC" \
	--cross-file "$CROSS_FILE" \
	--prefix "$PREFIX" \
	--libdir "$LIBDIR" \
	--buildtype release \
	-Dstrip=true \
	-Dgallium-drivers=freedreno \
	-Dvulkan-drivers=freedreno \
	-Dplatforms=x11,wayland \
	-Dglx=dri \
	-Degl=enabled \
	-Dgbm=enabled \
	-Dgles1=disabled \
	-Dgles2=enabled \
	-Dopengl=true \
	-Dllvm=disabled \
	-Dshared-llvm=disabled \
	-Dvideo-codecs= \
	-Dgallium-va=disabled \
	-Dvulkan-layers= \
	-Dtools= \
	-Dvalgrind=disabled \
	-Dlibunwind=disabled \
	-Dzstd=enabled \
	-Dxmlconfig=disabled

echo "== building (jobs=$JOBS)"
ninja -C "$BUILD_DIR" -j"$JOBS"

echo "== installing to staging"
rm -rf "$BUILD_DIR/stage"
DESTDIR="$BUILD_DIR/stage" ninja -C "$BUILD_DIR" install >/dev/null

echo "== result"
find "$BUILD_DIR/stage$PREFIX" \( -name '*.so*' -o -name '*.json' \) | head -20
du -sh "$BUILD_DIR/stage$PREFIX"
echo
echo "next: verify the chip id, then install"
echo "  python3 scripts/scan-a830.py $BUILD_DIR/stage$PREFIX/$LIBDIR/libvulkan_freedreno.so"
echo "  R=/mnt/target-rootfs bash scripts/install-mesa-a830.sh"
