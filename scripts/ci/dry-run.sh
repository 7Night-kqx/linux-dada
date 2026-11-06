#!/usr/bin/env bash
# Local validation WITHOUT running the full chroot build (which needs root,
# mmdebstrap and a native arm64 machine). Verifies every static input the
# GitHub Actions job relies on.
set -euo pipefail
source "$(dirname "$0")/common.sh"

REPO=${REPO:-$(git rev-parse --show-toplevel)}
cd "$REPO"

log "1. shell syntax"
for s in scripts/ci/*.sh Softs/sensors/*.sh; do bash -n "$s"; done
info "all shell scripts parse"

log "2. YAML / JSON syntax"
python3 - <<'PY'
import json, sys
json.load(open('config/sources.json'))
print('  ok   config/sources.json')
try:
    import yaml
    yaml.safe_load(open('.github/workflows/build-dada-debian.yml'))
    print('  ok   .github/workflows/build-dada-debian.yml')
except ImportError:
    print('  WARN PyYAML not installed; workflow YAML not parsed')
PY

log "3. pinned SHAs"
K=$(git -C linux rev-parse HEAD)
P=$(grep -v '^#' config/kernel-ref.txt | tr -d '[:space:]')
[[ $K == "$P" ]] || die "linux HEAD $K != pinned $P"
info "linux @ $K"
python3 - <<'PY'
import json, os, re, subprocess
for c in json.load(open('config/sources.json'))['components']:
    sha = c['sha']
    assert re.fullmatch(r'[0-9a-f]{40}', sha), (c['name'], 'bad sha', sha)
    d = f"Softs/sensors-src/{c['name']}"
    # The local working copies are gitignored; CI clones them from sources.json
    # at build time, so a clean checkout legitimately has no such directory.
    if os.path.isdir(os.path.join(d, '.git')):
        h = subprocess.check_output(['git','-C',d,'rev-parse','HEAD'], text=True).strip()
        assert h == sha, (c['name'], h, sha)
        print(f"  ok   {c['name']} @ {h[:12]} (pinned, local copy matches)")
    else:
        print(f"  ok   {c['name']} @ {sha[:12]} (pinned; CI will clone)")
PY

log "4. patches apply cleanly to pinned sources (reverse-check)"
# Only possible when the local working copies exist (they are gitignored).
# In CI the patches are applied forward to freshly cloned pinned sources by
# chroot-build.sh instead.
for c in hexagonrpc iio-sensor-proxy; do
    if [[ -d "Softs/sensors-src/$c/.git" ]]; then
        git -C "Softs/sensors-src/$c" apply --check -R "$REPO/Softs/patches/$c-dada.patch"
        info "$c-dada.patch (reverse-check on local copy)"
    else
        info "$c-dada.patch (local copy absent; CI applies forward to pinned clone)"
    fi
done

log "5. defconfig assertions (against dada_defconfig as a proxy for .config)"
# config-assertions.txt is checked post-olddefconfig in CI; here we just
# confirm the symbols exist in the seed with the expected value where feasible.
while IFS= read -r line; do
    line=${line%%#*}
    line=${line#"${line%%[![:space:]]*}"}; line=${line%"${line##*[![:space:]]}"}
    [[ -z $line ]] && continue
    sym=${line%%=*}; want=${line#*=}
    case "$want" in
      n) grep -q "^# CONFIG_${sym} is not set" linux/arch/arm64/configs/dada_defconfig \
           || warn "$sym expected unset in defconfig" ;;
      *) grep -q "^CONFIG_${sym}=${want}$" linux/arch/arm64/configs/dada_defconfig \
           || warn "$sym=$want not literally in defconfig (olddefconfig may add it)" ;;
    esac
done < config/config-assertions.txt
info "assertion list parsed"

log "6. built-in EXTRA_FIRMWARE blobs"
n=0
for f in $(sed -n 's/^CONFIG_EXTRA_FIRMWARE="\(.*\)"$/\1/p' \
           linux/arch/arm64/configs/dada_defconfig | tr ' ' '\n'); do
    [[ -s "linux/firmware/$f" ]] || die "missing built-in firmware: $f"
    n=$((n+1))
done
info "$n EXTRA_FIRMWARE blobs present in linux/firmware"

log "7. main-repo runtime firmware"
[[ $(find firmware/qcom/sm8750 -maxdepth 1 -name 'adsp*' | wc -l) -eq 60 ]] || die "adsp count != 60"
[[ -f firmware/qcom/sm8750/adsp.mdt && -f firmware/qcom/sm8750/adsp_dtb.mdt ]] || die "mdt missing"
[[ -f firmware/ath12k/WCN7850/hw2.0/amss.bin ]] || die "ath12k fw missing"
python3 - <<'PY'
import hashlib, pathlib
bad = []
for line in open('config/firmware-manifest.txt'):
    line = line.strip()
    if not line or line.startswith('#'): continue
    h, rel = line.split(None, 1)
    p = pathlib.Path('firmware') / rel
    if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != h:
        bad.append(rel)
assert not bad, f'manifest mismatch: {bad[:5]}'
print(f'  ok   firmware manifest verified')
PY

log "8. deployment units + mkbootimg import"
for f in Softs/sensors/hexagonrpcd-sensors.service Softs/sensors/ssc.conf \
         Softs/sensors/00-adsp.conf Softs/sensors/80-iio-sensor-proxy.rules \
         Softs/sensors/install-on-device.sh Softs/sensors/verify-on-device.sh; do
    [[ -s $f ]] || die "missing: $f"
done
grep -q 'ssc-accel' Softs/sensors/80-iio-sensor-proxy.rules || die "udev rules unpatched"
PYTHONPATH=tools/mkbootimg python3 -c 'import mkbootimg' || die "mkbootimg.py import failed"
info "deployment units + mkbootimg OK"

log "DRY-RUN PASS"
