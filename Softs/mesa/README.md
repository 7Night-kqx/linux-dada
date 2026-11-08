# mesa-a830 — Adreno 830 (SM8750 / dada) GPU via distro-Mesa binary patch

The kernel side (`drm/msm`, GPU/GMU nodes, `0x44050001` in `a6xx_catalog.c`,
`gen80000_*` firmware) is already built into the CI kernel. What was missing
is the **userspace** driver: distro Mesa's device table has no
`0xffff44050001` (A830v1) entry, so freedreno/turnip refuse the GPU.

## Current approach: patch the DISTRO Mesa (no source build)

An earlier version of this project built Mesa from upstream main into
`/opt/mesa-a830` and injected it via `LD_LIBRARY_PATH`. That mixed two Mesa
ABI versions inside GNOME 51 (which uses Debian sid's Mesa) and crashed the
desktop (`user@<uid>` start/stop loop). It has been REMOVED.

On-device testing (root@192.168.2.222) proved that patching the distro libs
is sufficient:

| check | result |
|---|---|
| `eglinfo -B` (surfaceless/GBM) | `freedreno` / **`Adreno (TM) 830`** / OpenGL 4.6 / GLES 3.2 |
| `vk-probe.py` | enumerates **`Adreno (TM) 830`** (`0x44050001`, vendor 0x5143) |
| desktop | stable, one Mesa, no `LD_LIBRARY_PATH` |

The patch rewrites the single 8-byte fused chip-id entry from
`0xffff44050000` to `0xffff44050001` (`WILDCARD_FUSE_ID | A830v1`) in:

- `/usr/lib/aarch64-linux-gnu/libgallium-*.so`  (GL/EGL/GBM)
- `/usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so` (turnip, from
  `mesa-vulkan-drivers`)

`scan-a830.py` decides `OK` (skip) / `NEEDS` (patch) / `ABSENT`/unknown
(fail loudly). `patch-mesa-binary-a830.sh` refuses to touch the file unless
exactly one known pattern matches. Patched libs are listed in
`/etc/dada-a830-patched-libs`.

⚠️ These `.so` files are owned by dpkg: `apt upgrade` of Mesa overwrites the
patch, and a new Mesa version may change the byte layout (scan then reports
NEEDS/ABSENT instead of guessing). Re-run the patch step after a Mesa upgrade.

## Files

| path | role |
|---|---|
| `scripts/scan-a830.py` | classify a `.so` as OK / NEEDS / NEEDS* / ABSENT (exit code usable in CI) |
| `scripts/patch-mesa-binary-a830.sh` | apply/verify the 8-byte chip-id patch (idempotent, has `--dry-run`) |
| `scripts/vk-probe.py` | enumerate Vulkan physical devices via ctypes (no vulkan-tools needed) |
| `env/` | reference systemd/PAM env snippets from the earlier self-built route (NOT used) |
| `0001-freedreno-add-adreno-830v1-chip-id.patch` | upstream `2061a5ee` source backport for 26.x tarballs (NOT used) |

## Verification (on device)

```bash
python3 /path/to/scan-a830.py /usr/lib/aarch64-linux-gnu/libgallium-*.so \
                              /usr/lib/aarch64-linux-gnu/libvulkan_freedreno.so
eglinfo -B | grep -A2 'OpenGL core profile renderer'
vulkaninfo --summary | head -30
python3 /path/to/vk-probe.py
```

## Kernel prerequisites (already satisfied)

`DRM_MSM=y`, `DRM_MSM_GPU_STATE=y`, `SM_GPUCC_8750=y`, `ARM_SMMU_QCOM=y`,
`PM_OPP`, `PM_DEVFREQ`, `INTERCONNECT_QCOM_SM8750`, DTS `gpu@3d00000` /
`gmu@3d37000` / `adreno_smmu` / `gpu_zap_shader`, and `a6xx_catalog.c`
`0x44050001`. The old `mesa-a830/README.md` in the reference repo claims the
kernel has no GPU nodes — that was true for the 7.3-rc1 tree and is obsolete.
