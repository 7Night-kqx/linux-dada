# /etc/profile.d/mesa-a830.sh - login-shell equivalent of the systemd drop-in,
# for openrc / busybox systems (Alpine, postmarketOS, ...).
# Alpine uses lib/, Debian/Ubuntu use lib/aarch64-linux-gnu.
_mesa_a830_libdir=/opt/mesa-a830/lib
[ -d /opt/mesa-a830/lib/aarch64-linux-gnu ] && _mesa_a830_libdir=/opt/mesa-a830/lib/aarch64-linux-gnu

export LD_LIBRARY_PATH="/opt/mesa-a830/runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LIBGL_DRIVERS_PATH="$_mesa_a830_libdir/dri"
export GBM_BACKENDS_PATH="$_mesa_a830_libdir/gbm"
export __EGL_VENDOR_LIBRARY_FILENAMES="/opt/mesa-a830/share/glvnd/egl_vendor.d/50_mesa.json"
export VK_DRIVER_FILES="/opt/mesa-a830/share/vulkan/icd.d/freedreno_icd.aarch64.json"

unset _mesa_a830_libdir
