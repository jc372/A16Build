# A16Build — ASUS Zenbook A16 (UX3607OA) on Linux

Turn a Windows-only Zenbook A16 into a working **Ubuntu + linux-next** machine. Follow the
steps in order. You do not need a second computer.

---

## What you need

| | |
|---|---|
| **USB-A hub** | The machine has no USB-A ports. The hub must have one, and the keyboard, mouse and stick plug into it. |
| **Wired keyboard** | Whether the internal keyboard and touchpad work in the live session depends on the kernel the nightly ships — see step 3. Have one available. |
| **Wired mouse** | Same reason. |
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

> **What works in the live session depends on the kernel the nightly ships.** The internal
> keyboard, touchpad and touchscreen need a device-tree boot with `acpi=off`; the support for
> that is now **in linux-next**, so a recent enough nightly should give you working internal
> input by itself. Earlier nightlies needed a remastered image carrying the A16 device tree, and
> a plain one booted ACPI with no internal input at all.
>
> Try the plain nightly. If the internal keyboard and touchpad work, the wired ones are not
> needed. Keep them connected until you know.
>
> The image is a moving target: the same instructions can behave differently a month later. If
> internal input works, note the nightly's date.


1. Write the **latest Ubuntu nightly arm64 image** to a USB stick. Use a nightly: released
   images do not carry the support this machine needs. If you use Rufus, choose **DD image mode**,
   and **check the checksum**.

2. **Secure Boot off first** (**F2** at power-on → firmware setup), and put the stick **on the
   hub**, not in a USB-C port: a USB-C device is not seen during the install.

3. Start the machine with the stick in, pressing **Esc** at power-on for the **boot options** and
   picking the stick.
4. Install **alongside Windows**, onto the unallocated space from step 1. Let it use the
   existing EFI partition. Do not erase the disk.

5. **Set the clock.** This machine has no clock Linux can read, so a live session starts with
   the wrong date, and Ubuntu's package indices have a `Valid-Until` that a wrong date breaks.
   Either plug in ethernet (it sets the clock by itself) or set the date and time by hand
   before updating anything.

Once Ubuntu is installed, **the Ubuntu installer will fail if you run it again** for a repair
or reinstall. Ubuntu will not start until the EFI work in **Step 4** is done, and the Ubuntu
installer is not the tool for it — Windows is.

---

## Step 4 — Make Ubuntu start (EFI work, from Windows)

A fresh install on this machine does not start: the firmware has no boot entry it can use and
no EFI variable Linux can write, so Ubuntu installs and then boots to nothing. The fix is done here, from Windows, and it has to
happen before anything else can run on the Linux side.

The short version is below; [the full page](docs/efi-on-windows.md) covers mounting, what
is on the partition, the repair scripts, and what to check when nothing starts.

1. **Secure Boot: off for Linux, on for Windows — every time you switch.**
   **F2** at power-on opens **firmware setup** — that is where Secure Boot is set.
   **Esc** at power-on shows the **boot options** — that is where you pick the stick, or pick
   which entry to start. Two different menus; do not confuse them.

2. **Mount the EFI partition.** Command Prompt, as Administrator, either:

   ```
   mountvol S: /s
   ```

   or with `diskpart`: `list volume`, `select volume N` (the ~100–300 MB FAT32 volume with no
   letter), `assign letter=S`, `exit`.

   Check you picked the right one: `S:\` should contain `EFI\` and nothing recognisable as
   Windows or Ubuntu itself.

3. **Edit the menu** — `S:\EFI\ubuntu_snapdragon\grub.cfg`. Copy an entry that already works
   and change the three filenames:

   ```
   menuentry "[10] A16: next <release>" {
       if [ -f /boot/vmlinuz-<release> ]; then
           linux /boot/vmlinuz-<release> root=UUID=<your-root-uuid> ro acpi=off console=tty0 loglevel=7
           devicetree /boot/glymur-a16-<release>.dtb
           initrd /boot/initrd.img-<release>
       fi
   }
   ```

   Leave `root=UUID=` and `acpi=off` alone — `acpi=off` is not optional on this machine. Keep
   titles unique: a duplicate title can boot a kernel you have replaced.

4. **Save, keep a copy, and start the machine.** If the entry does nothing when picked, the
   kernel file it names is missing — mount the partition again and check the filenames.

Do the same edit later for the kernel you build in step 5: it is the same file, one more entry.
Once the machine runs, `/boot/efi` is that same partition, so that one can be done from Linux.

## Step 5 — Build and install the kernel

Plug the stick into the new install and run, from the stick's directory:

```bash
bash a16-port.sh --verify     # applies the patches to a scratch copy and checks every hash
sudo bash a16-port.sh         # same again, then builds and installs beside the existing kernels
```

`--verify` builds nothing. Run it first: it will tell you in about a minute whether the payload
on your stick is the one this port was tested against.

The build takes a while (a full kernel). Everything it does is logged to `~/a16-port/`.

**One thing needs the network after all:** the build toolchain — `build-essential`, `gawk`, `flex`,
`bison`, `bc`, `kmod`, `rsync`. If the installed system does not already have them, `a16-port.sh`
will say so and they have to come from `apt`. A desktop install does not include them, so keep the
ethernet (or another connection) available for that one step, or install them before you go
offline. The *snapshot* needs no network — that is on the stick.

---

## Step 6 — Start it up

Choose the new kernel from the boot menu. **Check the display first** — if the panel comes up,
you have the whole thing: internal display, external monitor, Bluetooth, and Wi-Fi, which works
from here on without a cable.

To add another kernel later, edit the same menu file — from Linux via `/boot/efi`, or from
Windows as in step 4.

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
