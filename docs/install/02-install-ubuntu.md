# Phase 2 — install Ubuntu (and expect the boot failure at the end)

## 2.1 Boot the stick

**Secure Boot must be disabled** for this media and for the installed Linux; see the README's Secure
Boot section.

With the **USB-A dock** connected (keyboard, mouse, Ethernet) and the installer on a **USB stick or
the SD card** — not on a USB-C device; those ports do not work until Phase 5.

Press **Esc** at power-on for the boot options, pick the stick, then the normal entry. The internal
keyboard and touchpad work
in this live session: the image carries the A16 device tree and boots it with `acpi=off`.

The wired keyboard and mouse are what you type with: the internal keyboard, touchpad and
touchscreen need the device-tree boot with `acpi=off`, and a stock installer media boots ACPI. If you
get no input at all, boot the diagnostics entry instead and read the panel; the cause is documented
in `docs/input.md` (`ACPI\QCOM0F10`/`QCOM0F0C` match no driver).

## 2.2 Set the clock before anything else

This machine has no RTC as far as Linux is concerned: a live session starts with a wrong date, and
Ubuntu's package indices carry a `Valid-Until`. Both "too old" and "too new" break the installer.

    sudo timedatectl set-ntp false
    sudo date -s '2026-09-16 10:30:00'     # today's real date, not a date in the past
    date

The bundled daily's indices expire 2026-09-22, so a clock beyond that fails for the opposite reason.
Connecting a network and letting NTP sync is equivalent — and it is the easier route if the Wi-Fi
firmware is already in the image (it is: Phase 1 adds it).

## 2.3 Run the installer

    ubuntu-desktop-bootstrap

Install to the internal disk as usual (the daily's guided flow). The only thing to be careful about
is **not overwriting the Windows installation** — this machine keeps Windows, and the firmware boot
menu keeps offering it (see Phase 4, menu entry 3).

## 2.4 The failure you should expect at the end

The installer aborts at its last step, `install-grub`, with:

    efibootmgr: EFI variables are not supported on this system.

`curthooks` runs `efibootmgr -v` inside the target chroot; on this machine that exits 2, and the
whole step fails **before anything is written to the EFI partition**. The result:

- the installed root filesystem is complete and correct;
- the EFI partition has no Linux payload and no GRUB entry was created;
- the firmware has no Linux boot entry — the machine still boots Windows.

This is not a mistake in your procedure and reinstalling will not change it. The boot is finished in
Phase 3 and 4.

## 2.5 Check before you leave the live session

    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME   # identify the installed root and the ESP
    sudo mount <installed-root> /mnt && ls /mnt/boot   # the installed kernel is present
    sudo umount /mnt

If you can, copy the two repair scripts onto the EFI partition now (Phase 3) — it saves the trip to
Windows entirely.

## 2.6 The live session's harvest hook

The live session's `65a16-live-root` hook (installed in Phase 1) is what made a session without
input interrogable: it can place a collector in the live root so the machine reports its own state
to a volume you can read later. `scripts/a16-harvest.sh` is that collector — it writes ACPI tables,
`/proc/iomem`, device lists and `dmesg` to a FAT volume, and prints a short summary to the panel.
Useful when the panel is the only output you have.
