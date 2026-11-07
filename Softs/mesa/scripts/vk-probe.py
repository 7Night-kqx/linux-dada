#!/usr/bin/env python3
"""vk-probe.py - enumerate Vulkan physical devices through the loader.

Lets you check whether turnip recognises the Adreno 830 on dada without
installing vulkan-tools.  Run it *inside the target rootfs*, with the Mesa
790-a830 environment already applied (see ../env/).

    OK:                "physical devices: 1" + a device named like "Adreno (TM) 830"
    NOT MATCHED:       "physical devices: 0" (or vkCreateInstance error)
                       -> the chip id does not match the device table;
                          run ../scripts/scan-a830.py on libvulkan_freedreno.so

Derived from xiaobai-Lethe/Y700-elden-linux project/rootfs/vk-probe.py.
"""
import ctypes
import ctypes.util
import sys


class AppInfo(ctypes.Structure):
    _fields_ = [
        ("sType", ctypes.c_int), ("pNext", ctypes.c_void_p),
        ("pApplicationName", ctypes.c_char_p), ("applicationVersion", ctypes.c_uint32),
        ("pEngineName", ctypes.c_char_p), ("engineVersion", ctypes.c_uint32),
        ("apiVersion", ctypes.c_uint32),
    ]


class InstInfo(ctypes.Structure):
    _fields_ = [
        ("sType", ctypes.c_int), ("pNext", ctypes.c_void_p), ("flags", ctypes.c_uint32),
        ("pApplicationInfo", ctypes.POINTER(AppInfo)),
        ("enabledLayerCount", ctypes.c_uint32), ("ppEnabledLayerNames", ctypes.c_void_p),
        ("enabledExtensionCount", ctypes.c_uint32), ("ppEnabledExtensionNames", ctypes.c_void_p),
    ]


class Limits(ctypes.Structure):
    _fields_ = [("pad", ctypes.c_uint8 * 504)]


class Sparse(ctypes.Structure):
    _fields_ = [("pad", ctypes.c_uint32 * 8)]


class Props(ctypes.Structure):
    _fields_ = [
        ("apiVersion", ctypes.c_uint32), ("driverVersion", ctypes.c_uint32),
        ("vendorID", ctypes.c_uint32), ("deviceID", ctypes.c_uint32),
        ("deviceType", ctypes.c_uint32), ("deviceName", ctypes.c_char * 256),
        ("pipelineCacheUUID", ctypes.c_uint8 * 16),
        ("limits", Limits), ("sparseProperties", Sparse),
    ]


TYPES = {0: "OTHER", 1: "INTEGRATED_GPU", 2: "DISCRETE_GPU", 3: "VIRTUAL_GPU", 4: "CPU"}


def main():
    name = ctypes.util.find_library("vulkan") or "libvulkan.so.1"
    try:
        vk = ctypes.CDLL(name)
    except OSError as err:
        sys.exit(f"cannot load {name}: {err}")

    # VK_MAKE_VERSION(1, 1, 0) as the application API version
    app = AppInfo(0, None, b"vk-probe", 1, b"none", 1, (1 << 22) | (1 << 12))
    info = InstInfo(1, None, 0, ctypes.pointer(app), 0, None, 0, None)
    inst = ctypes.c_void_p()

    rc = vk.vkCreateInstance(ctypes.byref(info), None, ctypes.byref(inst))
    if rc != 0:
        sys.exit(f"vkCreateInstance failed: {rc}")

    count = ctypes.c_uint32(0)
    # VK_SUCCESS == 0, VK_INCOMPLETE == 5
    rc = vk.vkEnumeratePhysicalDevices(inst, ctypes.byref(count), None)
    if rc not in (0, 5):
        sys.exit(f"vkEnumeratePhysicalDevices failed: {rc}")
    if count.value == 0:
        sys.exit("no Vulkan device -- turnip did not claim the GPU "
                 "(run scan-a830.py on libvulkan_freedreno.so)")
    print(f"physical devices: {count.value}")

    devs = (ctypes.c_void_p * count.value)()
    vk.vkEnumeratePhysicalDevices(inst, ctypes.byref(count), devs)
    for d in devs:
        p = Props()
        vk.vkGetPhysicalDeviceProperties(ctypes.c_void_p(d), ctypes.byref(p))
        api, drv = p.apiVersion, p.driverVersion
        print(f"  name   : {p.deviceName.decode(errors='replace').rstrip(chr(0))}")
        print(f"  type   : {TYPES.get(p.deviceType, p.deviceType)}")
        print(f"  vendor : 0x{p.vendorID:04x}  device: 0x{p.deviceID:04x}")
        print(f"  api    : {api >> 22}.{(api >> 12) & 0x3ff}.{api & 0xfff}")
        print(f"  driver : {drv >> 22}.{(drv >> 12) & 0x3ff}.{drv & 0xfff}")


if __name__ == "__main__":
    main()
