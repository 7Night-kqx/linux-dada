#!/usr/bin/env bash
# Build Mesa from pinned upstream main (native aarch64, NO cross compiler),
# then install the A830-capable freedreno/turnip payload into /opt/mesa-a830.
#
# Runs INSIDE the Debian trixie/arm64 chroot, from /ci, with the mesa source
# already cloned at /workspace/Softs/mesa-src by chroot-build.sh.
#
# Mesa main contains the A830v1 chip id (0xffff44050001) since upstream commit
# 2061a5ee, so NO source patch is needed. The sanity check below enforces it.
set -euo pipefail
# common.sh lives in /ci (the CI scripts dir), not next to this script.
if [[ -f /ci/common.sh ]]; then
    source /ci/common.sh
else
    log()  { printf '\n=== %s\n' "$*"; }
    info() { printf '  ok   %s\n' "$*"; }
    warn() { printf '  WARN %s\n' "$*" >&2; printf '::warning::%s\n' "$*"; }
    die()  { printf 'ERROR: %s\n' "$*" >&2; printf '::error::%s\n' "$*"; exit 1; }
fi
trap 'rc=$?; printf "::error::chroot-mesa.sh failed at line %s (exit %s): %s\n" "$LINENO" "$rc" "$BASH_COMMAND" >&2' ERR

MESA_SRC=${MESA_SRC:-/workspace/Softs/mesa-src}
BUILD_DIR=${BUILD_DIR:-/workspace/Softs/mesa-build}
STAGE=${STAGE:-/workspace/Softs/mesa-stage}
# This script is copied to /ci/ before running, so the reference helpers live
# under the staged Softs/mesa tree, NOT next to this file.
MESA_ASSETS=${MESA_ASSETS:-/workspace/Softs/mesa}
PREFIX=/opt/mesa-a830
LIBDIR=lib/aarch64-linux-gnu
JOBS=${JOBS:-$(nproc)}

[[ -f $MESA_SRC/src/freedreno/common/freedreno_devices.py ]] \
    || die "mesa source tree missing: $MESA_SRC"
grep -q '0xffff44050001' "$MESA_SRC/src/freedreno/common/freedreno_devices.py" \
    || die "pinned Mesa has no A830v1 chip id (0xffff44050001) — wrong commit"

log "mesa: native meson setup (freedreno GL + turnip Vulkan)"
rm -rf "$BUILD_DIR" "$STAGE"
meson setup "$BUILD_DIR" "$MESA_SRC" \
    --prefix "$PREFIX" \
    --libdir "$LIBDIR" \
    --buildtype release \
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

log "mesa: ninja (-j$JOBS)"
ninja -C "$BUILD_DIR" -j"$JOBS"

log "mesa: install into /opt/mesa-a830"
# Install DIRECTLY into the running rootfs (no DESTDIR): we are already in the
# target rootfs, and cleanup keeps /opt/mesa-a830.
# `-Dstrip=true` was removed from mesa main (it is a meson core option now),
# so strip at install time instead.
meson install -C "$BUILD_DIR" --strip >/dev/null

# Sanity: both drivers must exist.
[[ -f $PREFIX/$LIBDIR/libvulkan_freedreno.so ]] \
    || die "turnip driver missing after install"
[[ -d $PREFIX/$LIBDIR/dri ]] || die "freedreno DRI drivers missing after install"
TURNIP=$PREFIX/$LIBDIR/libvulkan_freedreno.so

log "mesa: A830 chip-id verification"
# scan-a830.py targets the GL implementation (libgallium-*.so / libgallium*.so),
# where Mesa stores the fused chip-id table. Scan whatever is present; a
# non-OK verdict is a warning, not a build failure (turnip has its own table).
GALLIUM=$(ls "$PREFIX/$LIBDIR"/libgallium-*.so 2>/dev/null | head -1 || true)
if [[ -n $GALLIUM ]]; then
    python3 "$MESA_ASSETS/scripts/scan-a830.py" "$GALLIUM" || \
        warn "scan-a830.py reported non-OK on $(basename "$GALLIUM") (see log)"
else
    warn "no libgallium-*.so found; skipping chip-id scan"
fi

# ---------------------------------------------------------------- runtime env
# Mesa has no RPATH, so GL/EGL/GBM libs must be reachable via LD_LIBRARY_PATH.
install -d "$PREFIX/runtime"
for so in libEGL.so.1 libGL.so.1 libGLESv2.so.2 libgbm.so.1; do
    [[ -e $PREFIX/$LIBDIR/$so ]] && ln -sfn "../$LIBDIR/$so" "$PREFIX/runtime/$so" || true
done
for g in "$PREFIX/$LIBDIR"/libgallium-*.so; do
    [[ -e $g ]] && ln -sfn "../$LIBDIR/$(basename "$g")" "$PREFIX/runtime/$(basename "$g")" || true
done

# GLVND EGL vendor json (mesa normally ships one; fall back if absent).
install -d "$PREFIX/share/glvnd/egl_vendor.d"
if [[ ! -e $PREFIX/share/glvnd/egl_vendor.d/50_mesa.json ]]; then
    cat > "$PREFIX/share/glvnd/egl_vendor.d/50_mesa.json" <<'EOF'
{
    "file_format_version" : "1.0.0",
    "ICD" : {
        "library_path" : "libEGL_mesa.so.0"
    }
}
EOF
fi

# System-wide environment. Write BOTH forms: /etc/environment is what the
# verified device used (PAM pam_env reads it), while /etc/environment.d/ is
# the systemd-native form. Do not clobber PATH in /etc/environment — append.
MESA_ENV=$(cat <<EOF
LD_LIBRARY_PATH="$PREFIX/runtime"
LIBGL_DRIVERS_PATH="$PREFIX/$LIBDIR/dri"
GBM_BACKENDS_PATH="$PREFIX/$LIBDIR/gbm"
__EGL_VENDOR_LIBRARY_FILENAMES="$PREFIX/share/glvnd/egl_vendor.d/50_mesa.json"
VK_DRIVER_FILES="$PREFIX/share/vulkan/icd.d/freedreno_icd.aarch64.json"
EOF
)
grep -v -E '^(LD_LIBRARY_PATH|LIBGL_DRIVERS_PATH|GBM_BACKENDS_PATH|__EGL_VENDOR_LIBRARY_FILENAMES|VK_DRIVER_FILES)=' \
    /etc/environment 2>/dev/null > /tmp/dada-env.tmp || true
printf '%s\n' "$MESA_ENV" >> /tmp/dada-env.tmp
install -m644 /tmp/dada-env.tmp /etc/environment
rm -f /tmp/dada-env.tmp
install -d /etc/environment.d
printf '%s\n' "$MESA_ENV" > /etc/environment.d/50-mesa-a830.conf
install -d /etc/profile.d
cp "$MESA_ASSETS/env/mesa-a830.sh" /etc/profile.d/mesa-a830.sh
chmod 644 /etc/profile.d/mesa-a830.sh
for d in gdm gdm3; do
    install -d "/etc/systemd/system/$d.service.d"
    cp "$MESA_ASSETS/env/50-mesa-a830.conf" \
       "/etc/systemd/system/$d.service.d/50-mesa-a830.conf"
done

# NOTE: /etc/environment is written by install-mesa-a830.sh in the reference
# flow; we use /etc/environment.d/ instead (systemd/PAM on Debian 13 supports
# it) to avoid clobbering PATH and other entries.
info "mesa installed at $PREFIX ($(du -sh "$PREFIX" | cut -f1))"
