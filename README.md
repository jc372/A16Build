# A16Build — from the beginning

How to take a stock **ASUS Zenbook A16 (UX3607OA)** from "Windows only" to a working
**linux-next** install, on one machine, without a second computer.

---

## 0. At a glance

| # | Section | What it does | Blocking? |
|---|---------|--------------|-----------|
| 1 | [Hardware setup](#1-hardware-setup) | The hub, and why it is not optional | Yes — you cannot install without it |
| 2 | [Windows: partition the drive](#2-windows-partition-the-drive) | Makes room; BitLocker off first | Yes |
| 3 | [Ubuntu nightly install](#3-ubuntu-nightly-install) | The base OS, onto the free space | Yes |
| 4 | [Windows EFI updates](#4-windows-efi-updates) | Firmware/boot updates, done from Windows | Ongoing — see note |
| 5 | [linux-next retrieval](#5-linux-next-retrieval) | The kernel source this project builds | Yes |
| 6 | [The patch set](#6-the-patch-set) | 11 patches, and what each one buys | Yes |
| 7 | [Build and install](#7-build-and-install) | `build.sh`, install beside, pick at the menu | Yes |
| 8 | [What works, what does not](#8-what-works-what-does-not) | Honest current state | — |
| 9 | [Install steps](docs/install/) | The detailed Windows→Ubuntu steps, step by step | — |
| 10 | [Retired: out-of-tree drivers](docs/RETIRED-out-of-tree-drivers.md) | Why the old module overlay is gone | — |
| 11 | [retired/](retired/) | Driver-era files, kept referable and unused | — |

---

## 1. Hardware setup

**You need a hub, and it has to have a USB-A port.** The A16 has no USB-A, and a plain
USB-C dongle will not do: the machine's USB-A-side support is part of what you are bringing
up, and having real USB-A ports on the hub is what makes the install keyboard-and-mouse
possible.

Until the Wi-Fi section below is satisfied, the hub must also provide:

| Needed | Why |
|--------|-----|
| **Wired keyboard** | The internal keyboard is not available in the installer or a fresh linux-next boot |
| **Wired mouse** | Same — internal touchpad is a HID-over-I2C device that needs the same bring-up |
| **Wired ethernet** | **Wi-Fi does not work until you are running the latest linux-next with the board data.** This is the whole reason for the wired requirement |

So the working arrangement is: hub → USB-A keyboard, USB-A mouse, USB-A/USB-C ethernet, and
the machine powered from its own supply.

> **Wi-Fi note.** Wi-Fi is the last thing to come up, not the first. Plan for a wired
> connection through the entire install, and keep it until you have booted the linux-next
> kernel from section 5 with the patches from section 6. Only then is wireless on the table.

---

## 2. Windows: partition the drive

Do this from Windows, before Ubuntu exists on the machine.

1. **Turn BitLocker off** and let it finish decrypting. Resizing an encrypted volume is how
   you lose the Windows install.
2. Shrink the Windows volume from Windows itself (Disk Management, or `diskpart`) to leave
   unallocated space for Ubuntu. Windows shrink is the reliable path; the Linux side is not
   the one to make room.
3. Leave the unallocated space **unformatted**. The Ubuntu installer will use it.

The EFI system partition is the part that matters later — see section 4.

---

## 3. Ubuntu nightly install

*Write the latest nightly Ubuntu image to a USB stick and install to the space from section 2.*

The daily/nightly image matters: the stock released images do not carry the arm64 support
this machine needs to boot usefully.

- Write the image to the stick, boot the A16 from it (the hub gets you keyboard, mouse and
  network during the installer).
- Install onto the unallocated space, **alongside** Windows — do not let it erase the disk.
- Let it use the existing EFI system partition.

**Known trap:** once Ubuntu is installed, **the Ubuntu installer will fail** if you try to
run it again for a reinstall or repair. Anything that needs the installer a second time is
done from Windows instead — see below.

---

## 4. Windows EFI updates

**Expect to keep doing EFI and firmware updates from Windows.** With Ubuntu already
installed, the installer path fails, so firmware updates, the EFI system partition, and the
GRUB boot config are maintained from the Windows side.

Practical consequences for this project:

| Thing | Where it is edited | Note |
|-------|-------------------|------|
| Firmware / BIOS | Windows | `UX3607OA.312` is the version this project was developed against |
| EFI system partition | Windows | The `grub.cfg` the boot menu comes from lives here |
| Boot entries | Windows, unless the machine is already booted | Entries are edited by the install tooling once Ubuntu is up |

Record the boot menu state before changing anything, and keep a copy of the EFI config: the
menu entries are the only way back if a kernel comes up with no display.

---

## 5. linux-next retrieval

This project tracks **linux-next**, not a released kernel. The tree we build is:

| | |
|---|---|
| **Release** | `7.3.0-rc5-next-20261002` |
| **Source** | `https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-next-next-20261002.tar.gz` |
| **Size** | ~261 MB tarball, ~1.8 GB extracted |

Get the snapshot (the tarball is the practical route — no clone of the full history), extract
it, and keep **the pristine extraction** somewhere permanent. It is the reference copy used
to check whether a change is already upstream, and to restore a file when a patch has been
half-applied. Deleting it costs a 261 MB download at the worst moment.

linux-next is a moving target: a patch that applies cleanly today may not tomorrow, which is
why the port pins the release above and records the patch set below.

---

## 6. The patch set

**The rule this project runs on: carry a change only if this kernel is missing it.** Test
each patch against a *pristine* extraction, never against a tree that already has patches in
it (that reports your own work back to you as "already upstream").

Eleven patches, in the order they apply:

| Patch | Area | What it buys | Why it is still needed |
|-------|------|--------------|------------------------|
| `0001-phy-qcom-edp-v8-sequence` | PHY | eDP v8 power-on sequence | Panel bring-up path |
| `0002-dts-ec-node` | DT | EC node at i2c `9-0076` | Pairs with `0004` |
| `0004-ec-driver` | driver | `asus-glymur-ec` (fans, temps, kbd backlight, wakeup) | Fans keep running through suspend without it |
| `0005-dts-bt-serdev-node` | DT | Bluetooth serdev node | `hci0` does not exist |
| `0006-dts-bt-enable-gpio` | DT | `bt-enable-gpios` on TLMM 116, ACTIVE_HIGH | Radio never powers up |
| `0007-xhci-plat-a16-skip-unsuspended-hcd` | USB | Do not fail system suspend when the HCD is left unsuspended | **Without it, every suspend aborts** (`error -22`) |
| `0008-qmp-combo-glymur-v5` | PHY | Combo PHY init tables for Glymur | Panel **and** external display |
| `0010-qmp-v8-refresh-pcs-drive-on-training` | PHY | PCS drive-level refresh at training | Link training |
| `0011-msm-dp-lttpr-segment-training` | DRM | LTTPR segment scoping | External display training |
| `0012-dp-external-rate-cap` | DRM | Cap the external DP rate | External displays at the right rate |
| `0013-dpu-drop-stuck-flush` | DRM | Drop the stuck flush after a vblank timeout | Prevents the frozen-desktop failure when an external link fails |

**Deliberately not applied** — kept in `BRINGUP/port-2026-10-03/patches/not-used/` with the reasons:

| Patch | Why not |
|-------|---------|
| `0003-dp-panel-hbr3` | Retired by test: the panel comes up without it |
| `0009-dp-external-rate-and-failed-enable-guard` | Conflicts with `0012` (same region of `dp_panel.c`) and is not needed with it |

**No out-of-tree drivers.** Earlier work loaded a set of hand-built modules (an overlay of
`ath12k`, `msm`, the PHY drivers, `gpucc-glymur`) beside a stock kernel. On this linux-next
that is gone: everything the machine needs is in-tree, and the build produces it. The only
hold-out is the 3D GPU, which is an upstream `GMU firmware initialization timed out` and has
no local patch.

---

## 7. Build and install

```
BRINGUP/port-2026-10-03/build.sh      # applies patches/*.patch and builds
BRINGUP/port-2026-10-03/patches/      # the patch set -- this directory IS the set
BRINGUP/port-2026-10-03/readme.md     # the decision record: what was tried, what was dropped
BRINGUP/tools/a16-install-stock-next.sh   # install the built kernel beside the existing ones
```

`build.sh` applies `patches/*.patch` by glob, so **the directory listing is the patch set** —
nothing can drift out of sync with what builds. The installer adds a menu entry and installs
beside the existing kernels; it refuses to overwrite the running kernel.

Two rules learned the hard way:

- **Never `make clean` the tree you are working on.** Reclaim disk by deleting *other* build
  trees. One build per tree, one log per run: a shared log makes failures unreadable.
- **`gawk`, `flex` and `bison` are required**, or the build dies at the last link step.

---

## 8. What works, what does not

Verified on `7.3.0-rc5-next-20261002` with the eleven patches above:

| Component | State |
|-----------|-------|
| Internal panel (2880x1800) | **Works** |
| External monitor | **Works** (USB-C DP and HDMI) |
| Bluetooth | **Works** |
| Wi-Fi | **Works** with the machine's board data; reliability across suspend is not established |
| Suspend / resume | **Works** — measured by frozen monotonic time, not by the fans |
| Fans on suspend | **Spin down**, via the EC driver |
| EC (fans, temps, keyboard backlight, wakeup) | **Works**, bound at i2c `9-0076` |
| 3D GPU | **Does not work** — upstream `GMU firmware initialization timed out`; software rendering only |
| Internal speakers | **Silent** |
| Dock USB/ethernet after resume | Open |

**How to read "did it suspend":** use `CLOCK_BOOTTIME - CLOCK_MONOTONIC` — it grows only
while suspended. Do **not** judge it by the fans or the keyboard backlight: both are EC
outputs, and with no EC driver they say nothing about whether the SoC slept. That mistake
cost a night.
