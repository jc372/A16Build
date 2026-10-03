#!/usr/bin/env python3
"""a16-gpu-param-probe.py -- exercise exactly the ioctl path that oopses the kernel.

Starting GNOME dies in:

    msm_gpu_create_private_vm+0x6c   <- msm_context_vm  <- adreno_get_param
    <- msm_ioctl_get_param           (MSM_GET_PARAM)

because `adreno_get_param()` creates the context's private VM on *any* param query, and on gen8
that goes through a6xx's per-process-pagetable path which is not valid.  This probe is the same
call sequence in one second, with no compositor, no session, nothing else involved -- so it tells
us whether the rebuilt msm.ko fixed the path before anything expensive happens.

Run it on the console (nothing needs root):
    python3 a16-gpu-param-probe.py

Expected with the fix in place:
    FAULTS    -> a number (global counter)
    VA_START  -> EINVAL  "requires per-process pgtables"     <- safe refusal, not a crash
    VA_SIZE   -> EINVAL
"""
import array
import fcntl
import os
import struct
import sys

DRM_IOCTL_MSM_GET_PARAM = 0xC0186440          # _IOWR('d', 0x40, struct drm_msm_param[24])
MSM_PARAM = {"FAULTS": 0x09, "VA_START": 0x0E, "VA_SIZE": 0x0F, "GPU_MODEL": 0x04}
STRUCT = "IIQII"                              # pipe, param, value(u64), len, pad

def probe(fd, name, param):
    buf = array.array("B", struct.pack(STRUCT, 0, param, 0, 0, 0))
    try:
        fcntl.ioctl(fd, DRM_IOCTL_MSM_GET_PARAM, buf, True)
    except OSError as e:
        print("   %-10s -> %s (%s)" % (name, e.strerror, e.errno))
        return
    _, _, value, ln, _ = struct.unpack(STRUCT, buf.tobytes())
    print("   %-10s -> ok, value=0x%x len=%d" % (name, value, ln))

def main():
    node = sys.argv[1] if len(sys.argv) > 1 else "/dev/dri/renderD128"
    if not os.path.exists(node):
        print("FATAL: %s does not exist -- is msm bound?" % node)
        return 1
    print("=== a16 gpu param probe: %s ===" % node)
    print("   (if this prints the three lines below, the private-VM path is safe)")
    fd = os.open(node, os.O_RDWR)
    try:
        probe(fd, "GPU_MODEL", MSM_PARAM["GPU_MODEL"])
        probe(fd, "FAULTS", MSM_PARAM["FAULTS"])
        probe(fd, "VA_START", MSM_PARAM["VA_START"])
        probe(fd, "VA_SIZE", MSM_PARAM["VA_SIZE"])
    finally:
        os.close(fd)
    print("=== survived: no oops. The desktop can be started safely. ===")
    print("    sudo systemctl isolate graphical.target")
    return 0

if __name__ == "__main__":
    sys.exit(main())
