# The EFI partition and the boot menu, from Windows

Read this when you need to change **what the machine boots**. On this hardware that work is
done from Windows, and there are two reasons why:

1. **The machine has no EFI variables that Linux can write.** So the bootloader is installed as
   a *removable fallback* — `\EFI\BOOT\BOOTAA64.EFI` — instead of as a firmware boot entry, and
   the menu the firmware shows comes from a **file on the EFI partition**, not from firmware
   settings.
2. **Once Ubuntu is installed, the Ubuntu installer fails** if you run it again. It is not a
   repair tool here. Windows is.

---

## The standing Secure Boot rule

**Do this at every switch between the two systems.** It is not a one-off.

| Booting | Secure Boot |
|---|---|
| Windows | **On** |
| Ubuntu, the installer, or any of the sticks | **Off** |

Reach it by pressing **F2** at power-on for firmware setup. **Esc** shows the boot
options. If Linux will not start, check this first.

---

## Mounting the EFI partition in Windows

Open a Command Prompt **as Administrator**.

**Option A — `diskpart`** (use this if `mountvol` gives you grief):

```
diskpart
  list volume
  select volume N        :: N = the FAT32 volume, ~100-300 MB, no drive letter
  assign letter=S
  exit
```

**Option B — `mountvol`:**

```
mountvol S: /s
```

`S:` is then the EFI System Partition. **Check before you write anything:** it should contain
`EFI\`, and nothing you recognise as Windows or Ubuntu itself. If you picked the wrong volume
you are about to edit the wrong filesystem.

From WSL, the same partition appears under `/mnt/s` once mounted, which is usually more
comfortable for editing text files.

---

## What is on it

| Path | What it is |
|---|---|
| `\EFI\BOOT\BOOTAA64.EFI` | The bootloader as a removable fallback. This is what runs when the machine has no usable boot entry |
| `\EFI\ubuntu\` | What the installer put there |
| `\EFI\ubuntu_snapdragon\grub.cfg` | **The boot menu.** This is the file you edit to add, remove or relabel entries |
| `\A16BOOT.LOG` | Written by the boot-repair script. Read this first if a repair did not work |

---

## Adding a boot entry for a new kernel

An entry is a block in `grub.cfg` shaped like this:

```
menuentry "A16: linux-next 7.3.0-rc5-next-20261002-t1" {
    if [ -f /boot/vmlinuz-7.3.0-rc5-next-20261002-t1 ]; then
        linux /boot/vmlinuz-7.3.0-rc5-next-20261002-t1 root=UUID=<your-root-uuid> ro acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused console=tty0 keep_bootcon loglevel=7
        devicetree /boot/glymur-a16-7.3.0-rc5-next-20261002-t1.dtb
        initrd /boot/initrd.img-7.3.0-rc5-next-20261002-t1
    fi
}
```

Copy an entry that already works and change the three filenames. Substitute your own
`root=UUID=`, and keep **all four** kernel options -- `acpi=off` is not optional on this machine,
and without `clk_ignore_unused`, `pd_ignore_unused` and `regulator_ignore_unused` the display and
the PHYs do not come up:

    acpi=off clk_ignore_unused pd_ignore_unused regulator_ignore_unused


### Finding your root UUID, and the filenames to use

The entry names files by path and the root by UUID, so both must match your install. Get them from
a live session -- the installer's "Try Ubuntu" works, and so does booting the stick:

    lsblk -f                       # the ext4 partition's UUID is the one you want
    sudo blkid | grep ext4
    ls /boot/vmlinuz-* /boot/initrd.img-* /boot/glymur-a16-*.dtb

The `.deb` installs `/boot/glymur-a16-<version>.dtb`; a kernel built with `a16-port.sh` may install
a differently named device tree, so read the name off `/boot` rather than assuming it.

**Keep the entry valid or the machine will not boot it.** Two rules that have bitten here:

- The `if [ -f ... ]` guard means a missing kernel file makes the entry silently do nothing:
  pressing it just returns you to the menu.
- Do not leave **two entries with the same title**. They accumulate every time a kernel is
  installed, and picking the older duplicate boots a kernel you have since replaced.

Editing from Windows, save the file as plain text and keep a copy.

---

## Before you leave the live session (saves the Windows trip)

If you can, copy the repair scripts onto the EFI partition **while you are still in the
installer's live session** — from there the ESP is already mounted, and it avoids needing
Windows at all:

```
ls /boot/efi/          # the ESP
# copy A16FIX.SH and the stage-esp script here, then
sync
```

If you cannot, no matter: mount the partition in Windows as above and put them there.

---

## If the machine will not start

1. **Press Esc at power-on** and look at what the firmware offers. If your entry is there and
   does nothing, the kernel file it names is missing — mount the ESP and check the filenames.
2. If nothing appears at all, the removable fallback `\EFI\BOOT\BOOTAA64.EFI` is what the
   firmware is looking for. That file must exist.
3. Read `A16BOOT.LOG` on the ESP: it records what the repair script did and what it found.
4. The boot menu is drawn by the firmware, not by Linux. If the machine reaches the menu, it is
   not bricked — there is always a way back.
