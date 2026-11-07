#!/usr/bin/env python3
"""scan-a830.py - report which Adreno 830 chip-id entry a Mesa binary carries.

Mainline DRM (msm) reports the GPU as  (fuse << 32) | chip_id  through
MSM_PARAM_CHIP_ID.  For Xiaomi 15 "dada" (SM8750) that is
    0x0000ffff44050001   (fuse/speedbin unknown -> 0xffff wildcard)
    0x00xx44050001       (fuse/speedbin 0xbe/0xdd/0xe8/0xf2 -> xx = that value)
Both are matched by the single device-table entry 0x0000ffff44050001, whose
bits 47..32 are Mesa's WILDCARD_FUSE_ID (see freedreno_dev_info.c).

This tool tells you, without running anything, whether a prebuilt library is
usable on dada:

    OK        -> carries 0xffff44050001            (turnip/freedreno will match)
    NEEDS     -> carries 0xffff44050000            (26.1/26.2 layout, binary-patchable)
    NEEDS*    -> carries 0x44050000 (KGSL/26.0)    (binary-patchable, but 26.0
                                                    lacks real A830 GPU info)
    ABSENT    -> no A830 entry at all              (wrong driver / old Mesa)

Derived from xiaobai-Lethe/Y700-elden-linux project/rootfs/scan-a830.py.

Usage:
    scan-a830.py FILE.so [FILE.so ...]     # files or directories
"""
import os
import sys

TARGET = "0x0000ffff44050001  A830v1 (dada target)"
WILD_261 = "0x0000ffff44050000  A830   (26.1/26.2)"
KGSL_260 = "0x0000000044050000  A830   (26.0/KGSL fake)"
SANITY = "0x0000ffff44070041  X2-85  (sanity: another A8xx)"

PATTERNS = {
    TARGET: bytes.fromhex("01000544ffff0000"),
    WILD_261: bytes.fromhex("00000544ffff0000"),
    KGSL_260: bytes.fromhex("0000054400000000"),
    SANITY: bytes.fromhex("41000744ffff0000"),
}


def scan_file(path):
    try:
        with open(path, "rb") as fh:
            data = fh.read()
    except OSError as err:
        print(f"{path}: {err}")
        return "ERROR"

    print(f"== {path} ({len(data)} bytes)")
    counts = {}
    for name, pat in PATTERNS.items():
        hits, start = [], 0
        while True:
            i = data.find(pat, start)
            if i < 0:
                break
            hits.append(i)
            start = i + 1
        counts[name] = len(hits)
        if name in (TARGET, WILD_261, KGSL_260):
            print(f"   {name}: {len(hits)} {[hex(h) for h in hits[:6]]}")

    if counts[TARGET] == 1:
        verdict = "OK       turnip/freedreno will match dada's GPU"
    elif counts[TARGET] == 0 and counts[WILD_261] == 1:
        verdict = "NEEDS    patch with scripts/patch-mesa-binary-a830.sh (26.1/26.2)"
    elif counts[TARGET] == 0 and counts[KGSL_260] == 1:
        verdict = "NEEDS*   patchable (26.0 layout) but 26.0 lacks real A830 info - prefer 26.1+"
    elif counts[TARGET] > 1:
        verdict = "SUSPECT  multiple target entries - check the library"
    else:
        verdict = "ABSENT   no A830 entry: not a freedreno library, or Mesa is too old"
    print(f"   -> {verdict}")
    return verdict.split()[0]


def iter_paths(argv):
    for arg in argv:
        if os.path.isdir(arg):
            for root, _dirs, files in os.walk(arg):
                for name in sorted(files):
                    if ".so" in name:
                        yield os.path.join(root, name)
        else:
            yield arg


def main():
    if len(sys.argv) < 2:
        sys.exit(__doc__.strip())
    verdicts = {}
    for path in iter_paths(sys.argv[1:]):
        v = scan_file(path)
        verdicts[v] = verdicts.get(v, 0) + 1
    print("\n== summary:", ", ".join(f"{k}={v}" for k, v in sorted(verdicts.items())))
    # exit 0 only when every scanned file is usable as-is
    sys.exit(0 if set(verdicts) <= {"OK"} else 1)


if __name__ == "__main__":
    main()
