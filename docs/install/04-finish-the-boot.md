# Phase 4 — finish the boot, in two stages from the live session

Boot the Ubuntu daily again (the same stick), open a terminal, and run the two stages in order. Both
work on the *installed* system by mounting it; neither needs the installer.

    findmnt -no SOURCE,UUID,FSTYPE /           # the installed root
    findmnt -no SOURCE,UUID,FSTYPE /boot/efi   # the ESP
    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME,LABEL

Use the installed root where the commands below say `/dev/nvme0n1p12`: the number in the original
run is not the number today, and mounting the ESP in its place silently gives a repair that does
nothing.

## 4.1 Stage 1 — `A16FIX.SH`: install GRUB into the installed system

    sudo mount /dev/nvme0n1p12 /mnt      # <- the INSTALLED ROOT, confirm it first
    sudo bash /mnt/A16FIX.SH

What it does:

- mounts the installed root read-only first and prints what it found;
- runs `grub-install --no-nvram --removable` for the installed system — `--no-nvram` is the point:
  this machine has no EFI variables to write, so the bootloader must be installed as a removable
  fallback (`\EFI\BOOT\BOOTAA64.EFI`) instead of as a firmware boot entry;
- generates `/boot/grub/grub.cfg` (`update-grub`), which finds the installed kernel;
- tries `efibootmgr` only if EFI variables actually work;
- writes its log to the root of the EFI partition as `A16BOOT.LOG`.

It writes only to the EFI partition (`\EFI\ubuntu`, `\EFI\BOOT\BOOTAA64.EFI`) and to the installed
root (`/boot/grub/grub.cfg`, and an initramfs if one is missing).

**Check it:** mount the ESP from Windows or from the live session and read `A16BOOT.LOG`. Two
`grub-install` passes exiting 0 and a "Found linux image" line from `update-grub` mean it worked.

## 4.2 Why stage 2 is needed

After stage 1 the panel shows the installed system's own menu — and **every entry fails**:

    you need to load the kernel first

GRUB on this machine cannot read the kernel out of the installed root filesystem (the error the
operator sees is from the `initrd` line, which runs after the `linux` line has already failed). That
is a dead end for a menu that depends on reading `/boot` from the root filesystem, so stage 2 takes
the root filesystem out of the picture entirely.

## 4.3 Stage 2 — `A16STAGE2.SH`: stage a boot that needs only the EFI partition

    sudo mount /dev/nvme0n1p12 /mnt      # <- again, the installed root
    sudo bash /mnt/A16STAGE2.SH

It writes, all on the ESP and all readable from Windows afterwards:

    A16DIAG2.TXT     kernel file format and size, /boot listing, GRUB module presence
                     (gzio/ext2/linux/...), ext4 features, fstab, /etc/default/grub
    P17-GRUB.CFG     the installed system's generated menu, kept for reference
    A16STAGE2.LOG    the run's own log
    A16ESP-BACKUP/   the three configs that were on the ESP before the run

and it stages a complete boot payload on the ESP:

    \a16boot\        the kernel, the initrd, and the installed system's arm64-efi GRUB module
                     directory, so nothing has to be read from ext4

with a four-entry menu written to **every** location a GRUB on this ESP reads a config from:

    \EFI\ubuntu\grub.cfg              (the embedded prefix both firmware Linux entries use)
    \EFI\ubuntu_snapdragon\grub.cfg
    \EFI\BOOT\grub.cfg
    \boot\grub\grub.cfg

    0  installed Ubuntu, kernel + initrd from the ESP   (no ext4 involved)
    1  installed Ubuntu, its own generated menu         (keeps the normal path working)
    2  diagnostics: prefix, cmdpath, staged payload, module checks (sleeps 90 s)
    3  Windows Boot Manager

Writing the menu to all four locations is the fix for a trap: the firmware boots a config from one of
the `\EFI` directories, not from a single file you might assume. Editing only one of them appears to
change nothing.

## 4.4 Boot the installed system

**Secure Boot off** (standing rule); it stays off for the installed Linux because the kernel and its
modules are unsigned.

    sudo umount /mnt     # if still mounted
    sudo reboot

Press **Esc** at power-on for the boot options, pick the Linux entry, and choose menu entry **0**. The
installed Ubuntu boots. If it fails, choose entry 2 (diagnostics) — it sleeps for 90 seconds so the
panel can be photographed — and entry 1 to compare with the normal path.

## 4.5 After this point

- The installed system now boots on its own, through the ESP payload staged in `\a16boot\`.
- **Re-copy a script to the ESP after every edit** (Phase 3), then verify with `sha256sum`.
- The next work — kernel, firmware, Wi-Fi, Bluetooth, display — happens in the installed system:
  Phase 5.
