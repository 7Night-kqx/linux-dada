# mesa-a830 — Adreno 830 (SM8750 / dada) userspace drivers

The kernel side (`drm/msm`, GPU/GMU nodes, `0x44050001` in `a6xx_catalog.c`,
`gen80000_*` firmware) is already built into the CI kernel. What was missing
is the **userspace** driver: Debian trixie ships Mesa 25.0.7, whose device
table has no `0xffff44050001` (A830v1) entry, so freedreno/turnip refuse the
GPU.

## What CI does

`chroot-build.sh` clones Mesa from `config/mesa-ref.txt` (pinned upstream
**main**, which contains the A830v1 chip id since upstream commit `2061a5ee`,
2026-08-19 → **no source patch needed**) and runs
[`scripts/chroot-mesa.sh`](scripts/chroot-mesa.sh):

- native aarch64 meson build (no cross compiler, no `--cross-file`)
- `-Dgallium-drivers=freedreno -Dvulkan-drivers=freedreno`
- `-Dplatforms=x11,wayland -Dglx=dri -Degl=enabled -Dgbm=enabled`
- `-Dllvm=disabled -Dxmlconfig=disabled` … (full set in the script, checked
  against the pinned commit's `meson.options` — note `-Dstrip=true` was
  removed in main, we strip at `meson install --strip` instead)
- installs to `/opt/mesa-a830` (kept by `chroot-cleanup.sh`)
- writes `/etc/environment`, `/etc/environment.d/50-mesa-a830.conf`,
  `/etc/profile.d/mesa-a830.sh` and gdm/gdm3 drop-ins so sessions pick up
  `LD_LIBRARY_PATH`, `LIBGL_DRIVERS_PATH`, `GBM_BACKENDS_PATH`,
  `__EGL_VENDOR_LIBRARY_FILENAMES`, `VK_DRIVER_FILES`

The working device (root@192.168.2.222) runs the same layout with
`Mesa 26.3.0-devel`, i.e. this main-branch route is the one already proven
on hardware.

## Verification (on device)

```bash
cat /etc/environment | grep mesa-a830
ls /opt/mesa-a830/lib/aarch64-linux-gnu/libvulkan_freedreno.so
python3 /opt/.../scan-a830.py /opt/mesa-a830/lib/aarch64-linux-gnu/libgallium-*.so
python3 .../vk-probe.py                  # expect: Adreno (TM) 830
ls -l /dev/dri/                          # card0 + renderD128
vulkaninfo --summary 2>/dev/null | head  # if vulkan-tools installed
```

## Files

| path | role |
|---|---|
| `scripts/chroot-mesa.sh` | **CI entry point** — native build + install + env |
| `scripts/scan-a830.py`, `vk-probe.py` | build-time / on-device verification |
| `env/` | systemd drop-in, `/etc/environment` snippet, profile.d snippet |
| `scripts/build-mesa-a830.sh` | reference *cross*-compile flow (from the old repo), NOT used by CI |
| `scripts/install-mesa-a830.sh` | reference staged-install flow (NOT used; CI installs directly) |
| `scripts/patch-mesa-binary-a830.sh` | binary patch for distro Mesa 26.1/26.2 (NOT used) |
| `0001-freedreno-add-adreno-830v1-chip-id.patch` | upstream `2061a5ee` backport for 26.1/26.2 tarballs (NOT used — main already has it) |

The last four are kept as documentation/fallback for the "build a 26.x
tarball" or "patch distro .so" routes.

## Kernel prerequisites (already satisfied)

`DRM_MSM=y`, `DRM_MSM_GPU_STATE=y`, `SM_GPUCC_8750=y`,
`ARM_SMMU_QCOM=y`, `PM_OPP`, `PM_DEVFREQ`, `INTERCONNECT_QCOM_SM8750`,
DTS `gpu@3d00000` / `gmu@3d37000` / `adreno_smmu` / `gpu_zap_shader`,
and `a6xx_catalog.c` `0x44050001`. The old `mesa-a830/README.md` in the
reference repo claims the kernel has no GPU nodes — that was true for the
7.3-rc1 tree and is now obsolete.
