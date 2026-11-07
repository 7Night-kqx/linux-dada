#!/usr/bin/env bash
# Idempotent on-device setup for the dada sensor stack.
# Runs ON THE PHONE (Debian 13 rootfs), after the CI rootfs was restored.
# The /var/lib/hexagonrpc data tree is now shipped IN the CI rootfs image
# (extracted from the working device), so this script only fixes up the
# runtime-only symlink and (re)starts the services.
set -euo pipefail

R=/var/lib/hexagonrpc
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

# socinfo must point at the RUNNING kernel's sysfs, so it cannot be baked into
# the image as a real directory. Keep it a symlink (idempotent).
if [[ -e $R/socinfo && ! -L $R/socinfo ]]; then
    rm -rf "$R/socinfo"
fi
if [[ ! -L $R/socinfo ]]; then
    ln -s /sys/devices/soc0 "$R/socinfo"
fi

# Sanity-check the shipped data tree. If any of these are missing the SSC
# sensor PD will enumerate nothing, even though ssccli starts.
for p in sensors/config/json.lst sensors/sns_reg.conf \
         sensors/state/sns_reg_version acdb dsp/adsp dsp/cdsp; do
    [[ -e $R/$p ]] || { echo "ERROR: missing $R/$p (rootfs data tree incomplete)" >&2; exit 1; }
done
echo "  ok   hexagonrpc data tree: $(find "$R" -type f | wc -l) files"

# ADSP firmware is installed into /lib/firmware by the CI build.
[[ -f /lib/firmware/qcom/sm8750/adsp.mdt ]] || {
    echo "ERROR: /lib/firmware/qcom/sm8750/adsp.mdt missing" >&2; exit 1; }
[[ $(find /lib/firmware/qcom/sm8750 -maxdepth 1 -name 'adsp*' | wc -l) -eq 60 ]] || {
    echo "ERROR: expected 60 adsp* firmware files" >&2; exit 1; }

# The data tree is DEVICE-PRIVATE per-unit calibration from one dada unit.
# If this image is used on a different phone, re-extract from that unit's
# Android side (see docs/sensor-fix.md 验收 B) and replace $R.
cat <<'NOTE'
NOTE: /var/lib/hexagonrpc contains per-device factory calibration /
      registry data extracted from ONE dada unit. On a different device,
      replace it with that unit's own copy:
        acdb/            <- /vendor/etc/acdbdata
        dsp/             <- /vendor/dsp
        sensors/config/  <- /odm/etc/sensors/config + chre_dynamic_sensors.json
        sensors/state/   <- /mnt/vendor/persist/sensors  (writable Linux COPY)
        sns_reg.conf     <- /vendor/etc/sensors/sns_reg_config
      Never mount the Android persist partition writable.
NOTE

systemctl daemon-reload
systemctl enable --now qrtr-ns.service dada-adsp.service \
                       hexagonrpcd-sensors.service iio-sensor-proxy.service
echo "Run /opt/dada-sensors/bin/verify-on-device.sh to check the stack."
