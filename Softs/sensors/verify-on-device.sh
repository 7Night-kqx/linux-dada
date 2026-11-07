#!/usr/bin/env bash
# On-device acceptance for docs/sensor-fix.md 验收 B.
# Run ON THE PHONE after install-on-device.sh and a `fastboot boot` of the
# CI kernel. Read-only except for systemctl status / busctl / ssccli sampling.
set -uo pipefail

fail=0
check() { if eval "$2" >/dev/null 2>&1; then printf '  ok   %s\n' "$1"; else printf '  FAIL %s\n' "$1"; fail=1; fi; }

echo "=== services ==="
systemctl status --no-pager qrtr-ns dada-adsp hexagonrpcd-sensors iio-sensor-proxy 2>&1 | sed 's/^/  /'
check "qrtr-ns active"              'systemctl is-active --quiet qrtr-ns'
check "dada-adsp active"            'systemctl is-active --quiet dada-adsp'
check "hexagonrpcd-sensors active"  'systemctl is-active --quiet hexagonrpcd-sensors'
check "iio-sensor-proxy active"     'systemctl is-active --quiet iio-sensor-proxy'

echo "=== WiFi / NetworkManager ==="
check "nmcli present"           'command -v nmcli'
check "NetworkManager active"   'systemctl is-active --quiet NetworkManager'
check "wlan interface present"  'ls /sys/class/net | grep -q "^wlan"'
if command -v nmcli >/dev/null 2>&1; then
    nmcli -t -f DEVICE,TYPE,STATE device 2>/dev/null | sed 's/^/  /'
fi

echo "=== hexagonrpc data tree ==="
printf '  files: %s\n' "$(find /var/lib/hexagonrpc -type f 2>/dev/null | wc -l)"
check "json.lst present"        'test -f /var/lib/hexagonrpc/sensors/config/json.lst'
check "registry present"        'test -d /var/lib/hexagonrpc/sensors/state/registry'
check "socinfo symlink"         'test -L /var/lib/hexagonrpc/socinfo'

echo "=== ADSP / QRTR / fastrpc ==="
check "fastrpc-adsp-secure present" 'test -e /dev/fastrpc-adsp-secure'
dmesg | grep -Ei 'remoteproc|adsp|fastrpc|qrtr' | tail -30 | sed 's/^/  /'

echo "=== D-Bus (net.hadess.SensorProxy) ==="
for p in HasAccelerometer HasAmbientLight HasCompass; do
    v=$(busctl --system get-property net.hadess.SensorProxy \
        /net/hadess/SensorProxy net.hadess.SensorProxy "$p" 2>/dev/null || echo '<err>')
    printf '  %-22s %s\n' "$p" "$v"
done
# Acceptance B criterion: HasAccelerometer must be true.
busctl --system get-property net.hadess.SensorProxy /net/hadess/SensorProxy \
    net.hadess.SensorProxy HasAccelerometer 2>/dev/null | grep -q 'true' \
    && echo "  ok   HasAccelerometer=true" \
    || { echo "  FAIL HasAccelerometer not true"; fail=1; }
# NOTE: HasAmbientLight is NOT an acceptance criterion: docs/sensor-fix.md
# "2026-09-28 light 根因更正" shows ALS still needs display-state injection.

echo "=== libssc direct sampling (gyro has no desktop-level channel) ==="
echo "  ssccli --sensor accelerometer (Z ~ 9.8 m/s^2):"
ssccli --sensor accelerometer 2>&1 | head -8 | sed 's/^/  /'
echo "  ssccli --sensor gyroscope (idle noise, jumps when rotated):"
ssccli --sensor gyroscope 2>&1 | head -8 | sed 's/^/  /'

echo "=== result ==="
[[ $fail -eq 0 ]] && echo "PASS" || echo "FAIL (see items above)"
exit "$fail"
