# A16Build — ASUS Zenbook A16 (UX3607OA) on Linux

Turn a Windows-only Zenbook A16 into a working **Ubuntu + linux-next** machine. Follow the
steps in order. You do not need a second computer.

> **[Hermes](https://hermes-agent.nousresearch.com), and a good model, are your friend — I used
> ChatGPT 6 and DeepSeek.**
> **Especially when working through issues.**

> **Status: the from-scratch route is untested.** Everything here was worked out on this machine
> *after* it already had Ubuntu and the build toolchain installed. The patch set, the build, and
> the kernel that comes out of it are verified on the hardware — the path that starts from a clean
> install, including `a16-port.sh`, the toolchain pool and the USB payload, has **not** been run
> end to end. Treat a first attempt as a rehearsal, and run `a16-port.sh --verify` before building:
> it exists to catch payload problems before anything is compiled.

---

## Two ways to get there

| | |
|---|---|
| **Just want the kernel?** | Download the prebuilt **`.deb`** from [Releases](../../releases/latest). It is arm64, built for this machine on `7.3.0-rc5-next-20261002`, and installs with `dpkg -i`. You still need Ubuntu on the machine (steps 1–4), and you still add the boot entry yourself. |
| **Build it yourself** | Follow the steps below. Everything you need to build the same kernel from source travels on a USB stick, and the patches are in [`BRINGUP/port-2026-10-03/patches/`](BRINGUP/port-2026-10-03/patches/). |

Both routes end at the same place. The `.deb` is the same kernel this repository builds — the
patches, the manifest and the hashes are here so you can check that.

---

## What you need

| | |
|---|---|
| **USB-A hub or dock** | The machine has both USB-A and USB-C, but **on this version the USB-C ports cannot be used** — so the keyboard, mouse, ethernet and any USB stick go through the machine's **USB-A port**, via a hub or dock when you need more than one. |
| **Wired keyboard** | Whether the internal keyboard and touchpad work in the live session depends on the kernel the nightly ships — see step 3. Have one available. |
| **Wired mouse** | Same reason. |
| **USB stick or SD card, 8 GB+** | For the installer image — either works. A second one if you want the payload on its own media. |
| **Ethernet, or another connection** | Needed **during the install** to set the clock (step 3), and **after it** for the build toolchain — unless you carry the toolchain pool on the stick (step 2). Wi-Fi only works once the new kernel is running. |

Windows stays installed throughout. Do not erase it.

---

## Step 1 — In Windows, before anything else

1. **Shrink the Windows partition** from Windows (Disk Management) to leave unallocated space
   for Ubuntu. Leave the space unformatted. If anything has to happen first — BitLocker, for
   instance — Windows says so when you try.
2. **Download linux-next onto the USB stick.** Open PowerShell and run:

```powershell
$u = "https://git.kernel.org/pub/scm/linux/kernel/git/next/linux-next.git/snapshot/linux-next-next-20261002.tar.gz"
Invoke-WebRequest -Uri $u -OutFile "E:\linux-next-7.3.0-rc5-next-20261002.tar.gz"   # E: = your stick
Get-FileHash "E:\linux-next-7.3.0-rc5-next-20261002.tar.gz" -Algorithm SHA256
```

That is 261 MB. Carrying it on the stick saves downloading it on the installed machine — but it
is not the only thing the build needs. The toolchain (`build-essential`, `gawk`, `flex`, `bison`,
`bc`, `kmod`, `rsync`) comes from `apt`, which needs a network once — **unless you also carry the
toolchain pool** described in step 2.

---

## Step 2 — Put the payload on the same stick

Copy these four things from this repository to the root of the stick, next to the tarball. The
fifth is optional and explained underneath:

| Copy this | From |
|---|---|
| `a16-port.sh` | [`BRINGUP/port-2026-10-03/a16-port.sh`](BRINGUP/port-2026-10-03/a16-port.sh) |
| `patches/` (whole directory) | [`BRINGUP/port-2026-10-03/patches/`](BRINGUP/port-2026-10-03/patches/) |
| `config-seed` | [`BRINGUP/port-2026-10-03/config-seed`](BRINGUP/port-2026-10-03/config-seed) |
| `MANIFEST.sha256` | [`BRINGUP/port-2026-10-03/MANIFEST.sha256`](BRINGUP/port-2026-10-03/MANIFEST.sha256) |
| `a16-pool/` — *optional, see below* | the build toolchain packages, so step 5 needs no network |

If the hash from step 1 does not match the snapshot line in `MANIFEST.sha256`, **stop**. (If
that line still starts with `#`, no hash has been recorded yet; `a16-port.sh` will tell you so
rather than pretending it checked.)

Your stick now holds everything needed to build the kernel.

### Optional: the build toolchain, so nothing needs the network

The build needs `build-essential gawk flex bison bc kmod rsync`, and a desktop install does not
have them. Carrying them on the stick removes the last network requirement. Generate the pool on
a machine with the **same architecture (arm64) and the same Ubuntu release**, WSL included:

```bash
sudo apt-get install --download-only --reinstall -y \
     -o Dir::Cache::archives=/mnt/e/a16-pool \
     build-essential gawk flex bison bc kmod rsync
```

Copy `a16-pool/` to the stick. `a16-port.sh` installs from it when it is there — as a temporary
local repository if `dpkg-scanpackages` exists, otherwise by installing the files directly — and
only falls back to `apt` when it is not.



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


1. Write the **latest Ubuntu nightly arm64 image** to a USB stick **or the machine's SD card** —
   either works. Use a nightly: released
   images do not carry the support this machine needs. If you use Rufus, choose **DD image mode**,
   and **check the checksum**.

2. **Secure Boot off first** (**F2** at power-on → firmware setup). Any USB device goes in the
   machine's **USB-A** port (through the hub for more than one) — USB-C cannot be used on this
   version, so a stick in a USB-C port is not seen. The SD card is unaffected and uses the
   machine's own slot.

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
   ```
   menuentry "[10] A16: next <release>" {
       if [ -f /boot/vmlinuz-<release> ]; then
           linux /boot/vmlinuz-<release> root=UUID=<your-root-uuid> ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7
           devicetree /boot/glymur-a16-<release>.dtb
           initrd /boot/initrd.img-<release>
       fi
   }
   ```

   Leave `root=UUID=` alone, and keep all four of `acpi=off`, `clk_ignore_unused`,
   `pd_ignore_unused`, `regulator_ignore_unused` — they are not optional on this machine. Keep
   titles unique: a duplicate title can boot a kernel you have replaced.

   All three files in that entry must exist. `vmlinuz` and the `.dtb` come with the kernel;
   **the `initrd` does not** — see the box below.

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

The entry for a kernel you install or build goes into the menu with one command:

```bash
bash BRINGUP/tools/a16-grub-entry.sh check      # show the entry it would add, change nothing
sudo bash BRINGUP/tools/a16-grub-entry.sh add   # add it, with a backup of the menu first
```

It writes the entry with **your** root UUID, insists on the four kernel options this machine needs,
builds the initramfs if that kernel has none, and refuses to add a duplicate. Remove an entry again
with `... a16-grub-entry.sh remove <version>`, and drop entries whose kernel is gone with
`sudo bash BRINGUP/tools/a16-grub-prune.sh --apply`.

`--verify` builds nothing. Run it first: it will tell you in about a minute whether the payload
on your stick is the one this port was tested against.

The build takes a while (a full kernel). Everything it does is logged to `~/a16-port/`.

**The build toolchain is the only thing that may still need the network** — `build-essential`,
`gawk`, `flex`, `bison`, `bc`, `kmod`, `rsync`. If you carried `a16-pool/` on the stick (step 2),
`a16-port.sh` installs from it and needs nothing. Otherwise it says what is missing and you
install it with `apt`. The *snapshot* never needs the network — that is on the stick.

---

### If you installed the `.deb`

`dpkg -i` puts the kernel, its modules and the device tree in place, and its postinst builds the
initramfs. If yours is an older download, or `update-initramfs` is not installed, make it by hand —
a missing initramfs is the single most common reason the machine will not start:

```bash
sudo update-initramfs -c -k 7.3.0-rc5-next-20261002-ec1
```

Then add the boot entry from step 4, naming `/boot/glymur-a16-7.3.0-rc5-next-20261002-ec1.dtb`.

Firmware is a separate matter: Wi-Fi and Bluetooth come from the standard `linux-firmware`
package, but **audio needs the ADSP images and the topology out of your Windows install**, plus a
UCM profile. See [docs/audio.md](docs/audio.md) — without it the machine runs silently.

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
| External monitor (USB-C and HDMI) | Internal speakers -- **needs firmware from your own Windows install**, which this repo cannot ship; see [docs/audio.md](docs/audio.md) | |
| Bluetooth | Dock USB / ethernet after a suspend |
| Wi-Fi | |
| Suspend power draw (2.4 W while asleep -- PCIe L2; see [docs/suspend-power.md](docs/suspend-power.md)) | |
| Internal speakers (with the audio profile — see [docs/audio.md](docs/audio.md)) | |
| Suspend and resume, with the fans spinning down | |

---

## More detail

| | |
|---|---|
| [`docs/from-the-beginning.md`](docs/from-the-beginning.md) | The same journey with the reasoning: why each step, the full patch table, the verification story |
| [`docs/install/`](docs/install/) | The install steps in full, including the traps |
| [`docs/efi-on-windows.md`](docs/efi-on-windows.md) | Editing the boot menu and the EFI partition from Windows |
| [`BRINGUP/port-2026-10-03/readme.md`](BRINGUP/port-2026-10-03/readme.md) | The decision record: what was tried, what was dropped, and why |
