# Hardware harvests

Raw self-reports from the A16, produced by the `A16_HARVEST=1` live image
(`a16-harvest` collector + timer in the live root) and pulled off the machine's
internal ESP with `a16-read-log.ps1`. The tarball is the primary evidence for
everything in `STATUS.md` / `PLANS/PLAN-002` that claims a hardware fact;
`PLAN-002` has the analysis, this directory keeps the bytes.

## 2026-09-16 — first real harvest (ACPI diagnostic console entry)

- File: `a16-harvest-20260728-124912.tar.gz` (146,051 B)
- Written: ~90 s after the live kernel started (systemd timer `OnBootSec=90`),
  boot window 08:04–08:18 EDT.
- **The date in the name is wrong**: in the live session no hardware clock can be
  read (`probe of rtc-efi.0 with driver rtc-efi returned 19`,
  `acpi-tad ACPI000E:00: hctosys: unable to read the hardware clock`), so the
  collector stamped a stale date. Date the content by the kernel string
  (`7.3.0-rc3-next-20260914`, built 2026-09-15).
- Boot: default GRUB entry (index 2) — ACPI diagnostic console, `acpi=force
  console=tty0 earlycon=efifb keep_bootcon`, `module_blacklist=msm`.
- Memory headline: the firmware gives an ACPI boot 31.604 GiB of `System RAM`
  and parks exactly 16.00 GiB at `0x8800000000-0x8bffffffff` as `reserved`
  (544–600 GiB, the window Canonical's GRUB `cutmem` targets). 31.60 + 16.00 =
  47.60 GiB = Windows' `TotalPhysicalMemory` (47.62 GiB): 48 GiB installed,
  one third held back from Linux in this boot mode. Net unreserved RAM after
  firmware carveouts: 26.57 GiB.
- Input: unchanged — no I2C adapters, no HID, no GPIO controllers, only the ACPI
  `Lid Switch`. `MemTotal` was not captured by this build (the collector's
  memory section read a `/var/log/dmesg` that Ubuntu live does not have); the
  collector now reads `/proc/meminfo` and ships `data/meminfo.txt`.

Extract with `tar xzf <file>`; the interesting members are `data/summary.txt`
(console report), `data/iomem.txt`, `data/dmesg.txt`, `data/meminfo.txt`,
`data/fdt`/`firmware.dtb`, `data/acpi-tables/`.
