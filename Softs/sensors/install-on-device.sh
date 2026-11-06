#!/usr/bin/env bash
# Idempotent on-device setup for the dada sensor stack.
# Runs ON THE PHONE (Debian 13 rootfs), after the CI rootfs was restored.
# It NEVER writes Android partitions. It only creates the /var/lib/hexagonrpc
# skeleton and prints the extraction map for the device-private data tree.
set -euo pipefail

R=/var/lib/hexagonrpc
[[ $EUID -eq 0 ]] || { echo "run as root" >&2; exit 1; }

mkdir -p "$R"/{acdb,dsp/adsp,dsp/cdsp,sensors/config,sensors/state/registry}
touch "$R/sensors/sns_reg.conf"
# The DSP reads socinfo from /sys/devices/soc0 (soc_id=618 on dada).
if [[ ! -e $R/socinfo ]]; then
    ln -s /sys/devices/soc0 "$R/socinfo"
fi

cat <<'MAP'
=== /var/lib/hexagonrpc data map (from docs/sensor-fix.md 验收 B) ===
Populate these from the phone's Android side (adb shell su). These files are
DEVICE-PRIVATE and are intentionally NOT shipped in the CI rootfs image:

  Linux target                     Android source
  -------------------------------  --------------------------------------------
  $R/acdb/                         /vendor/etc/acdbdata           (16 items)
  $R/dsp/adsp, dsp/cdsp            /vendor/dsp                    (needs su)
  $R/sensors/config/               /odm/etc/sensors/config/       (json.lst +
                                    sm8750_*.json) +
                                    /vendor/etc/sensors/config/chre_dynamic_sensors.json
  $R/sensors/state/                /mnt/vendor/persist/sensors/  (registry/,
                                    sns_reg_version, parsed_file_list.csv,
                                    gyro_caldata.txt, sensors_list.txt; needs su)
  $R/sensors/sns_reg.conf          /vendor/etc/sensors/sns_reg_config
  $R/socinfo                       symlink -> /sys/devices/soc0

WARNING: use a WRITABLE Linux COPY of sensors/state. Never mount the Android
persist partition writable (docs/sensor-fix.md: registry is written by the DSP).
MAP

# Verify ADSP firmware is present in the rootfs (installed by the CI build).
[[ -f /lib/firmware/qcom/sm8750/adsp.mdt ]] || {
    echo "ERROR: /lib/firmware/qcom/sm8750/adsp.mdt missing" >&2; exit 1; }
[[ $(find /lib/firmware/qcom/sm8750 -maxdepth 1 -name 'adsp*' | wc -l) -eq 60 ]] || {
    echo "ERROR: expected 60 adsp* firmware files" >&2; exit 1; }

systemctl daemon-reload
systemctl enable --now hexagonrpcd-sensors.service iio-sensor-proxy.service
echo "Run /opt/dada-sensors/bin/verify-on-device.sh to check the stack."
