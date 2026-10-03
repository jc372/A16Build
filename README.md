# A16Build — ASUS Zenbook A16 (UX3607OA) on Linux

Turn a Windows-only Zenbook A16 into a working **Ubuntu + linux-next** machine. Follow the
steps in order. You do not need a second computer.

---

## What you need

| | |
|---|---|
| **USB-A hub** | The machine has no USB-A ports. The hub must have one, and the keyboard, mouse and stick plug into it. |
| **Wired keyboard** | The internal keyboard does not work during the install. |
| **Wired mouse** | Same. |
| **USB stick, 8 GB+** | The installer image, plus a second one if you want the payload on its own stick. |
| **Ethernet (optional)** | Only for the clock — see step 3. The kernel build itself needs no network. |

Windows stays installed throughout. Do not erase it.

---

## Step 1 — In Windows, before anything else

1. **Turn BitLocker off** and wait for it to finish decrypting.
2. **Shrink the Windows partition** from Windows (Disk Management) to leave unallocated space
   for Ubuntu. Leave the space unformatted.
3. **Download linux-next onto the USB stick.** Open PowerShell and run:

```powershell
$u = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-next-next-20261002.tar.gz"
Invoke-WebRequest -Uri $u -OutFile "E:\linux-next-7.3.0-rc5-next-20261002.tar.gz"   # E: = your stick
Get-FileHash "E:\linux-next-7.3.0-rc5-next-20261002.tar.gz" -Algorithm SHA256
```

That is 261 MB. Fetching it here is what lets the whole build happen with **no network at
all** on the installed machine — which matters, because Wi-Fi only works after this kernel
is running.

---

## Step 2 — Put the payload on the same stick

Copy these four things from this repository to the root of the stick, next to the tarball:

| Copy this | From |
|---|---|
| `a16-port.sh` | [`BRINGUP/port-2026-10-03/a16-port.sh`](BRINGUP/port-2026-10-03/a16-port.sh) |
| `patches/` (whole directory) | [`BRINGUP/port-2026-10-03/patches/`](BRINGUP/port-2026-10-03/patches/) |
| `config-seed` | [`BRINGUP/port-2026-10-03/config-seed`](BRINGUP/port-2026-10-03/config-seed) |
| `MANIFEST.sha256` | [`BRINGUP/port-2026-10-03/MANIFEST.sha256`](BRINGUP/port-2026-10-03/MANIFEST.sha256) |

If the hash from step 1 does not match the snapshot line in `MANIFEST.sha256`, **stop**. (If
that line still starts with `#`, no hash has been recorded yet; `a16-port.sh` will tell you so
rather than pretending it checked.)

Your stick now holds everything needed to build the kernel.

---

## Step 3 — Install Ubuntu

1. Write the **latest Ubuntu nightly arm64 image** to a USB stick and start the machine from it.
   Use a nightly: released images do not carry the support this machine needs.
2. Install **alongside Windows**, onto the unallocated space from step 1. Let it use the
   existing EFI partition. Do not erase the disk.
3. **Set the clock.** This machine has no clock Linux can read, so a live session starts with
   the wrong date, and Ubuntu's package indices have a `Valid-Until` that a wrong date breaks.
   Either plug in ethernet (it sets the clock by itself) or set the date and time by hand
   before updating anything.

Once Ubuntu is installed, **the Ubuntu installer will fail if you run it again** for a repair
or reinstall. Firmware, BIOS and boot-menu changes are done from Windows instead —
**[step-by-step for the EFI partition and the boot menu](docs/efi-on-windows.md)**, including the
Secure Boot rule (off for Linux, back on for Windows, every time).

---

## Step 4 — Build and install the kernel

Plug the stick into the new install and run, from the stick's directory:

```bash
bash a16-port.sh --verify     # applies the patches to a scratch copy and checks every hash
sudo bash a16-port.sh         # same again, then builds and installs beside the existing kernels
```

`--verify` builds nothing. Run it first: it will tell you in about a minute whether the payload
on your stick is the one this port was tested against.

The build takes a while (a full kernel). Everything it does is logged to `~/a16-port/`.

---

## Step 5 — Start it up

Choose the new kernel from the boot menu. **Check the display first** — if the panel comes up,
you have the whole thing: internal display, external monitor, Bluetooth, and Wi-Fi, which works
from here on without a cable.

The boot menu is edited from Windows if you ever need to change it.

---

## What works, and what does not

| Working | Not working |
|---|---|
| Internal panel (2880x1800) | 3D GPU — software rendering only, upstream issue |
| External monitor (USB-C and HDMI) | Internal speakers |
| Bluetooth | Dock USB / ethernet after a suspend |
| Wi-Fi | |
| Suspend and resume, with the fans spinning down | |

---

## More detail

| | |
|---|---|
| [`docs/from-the-beginning.md`](docs/from-the-beginning.md) | The same journey with the reasoning: why each step, the full patch table, the verification story |
| [`docs/install/`](docs/install/) | The install steps in full, including the traps |
| [`docs/efi-on-windows.md`](docs/efi-on-windows.md) | Editing the boot menu and the EFI partition from Windows |
| [`BRINGUP/port-2026-10-03/readme.md`](BRINGUP/port-2026-10-03/readme.md) | The decision record: what was tried, what was dropped, and why |
