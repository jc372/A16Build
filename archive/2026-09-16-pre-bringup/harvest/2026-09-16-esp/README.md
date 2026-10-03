# Internal ESP state and the stage-1 repair log (2026-09-16)

Read from Windows with the elevated probe `C:\Users\cates\Downloads\a16-esp-read.ps1`
and `a16-esp-read2.ps1` (full outputs: `a16-esp-read-out.txt`, `a16-esp-read2-out.txt`).
The ESP is disk 0 partition 12, 450 MB FAT32, label `SYSTEM`, UUID `7E07-8CF1`.

## What stage 1 (the live-session repair) actually did

`A16BOOT.LOG` here is the log `scripts/a16-finish-boot.sh` (staged as `\A16FIX.SH`)
wrote onto the ESP; its own timestamps read `Tue Jul 28 12:51` because that live
session had no readable hardware clock (the same reason the July harvest tarball is
stamped `20260728-124912`). Facts from it:

- the installed Ubuntu root is `nvme0n1p17`, ext4, UUID `f8e005e9-414c-4c8e-ad68-d1e9fdc208bc`;
- its `/boot` holds exactly one kernel: `vmlinuz-7.2.0-5-generic` (23,707,016 B,
  dated Aug 18 2026 in the package) plus `initrd.img-7.2.0-5-generic` (57,201,537 B);
  `/boot/grub/grub.cfg` was MISSING before the run;
- `ls /sys/firmware/efi/efivars` is present but shows **0 variables**, and the live
  session has **no `efibootmgr` binary at all** (exit 127), which is why curtin died;
- `grub-install --target=arm64-efi --efi-directory=/boot/efi --bootloader-id=ubuntu
  --no-nvram --recheck` → `Installation finished. No error reported.` (exit 0);
  the `--removable` pass → same (exit 0);
- `update-grub` → `Found linux image: /boot/vmlinuz-7.2.0-5-generic`,
  `Found initrd image: ...`, os-prober found Windows, `done`;
- `\EFI\ubuntu\grub.cfg` (117 B) is the stub grub-install writes:
  `search.fs_uuid f8e005e9-... root` / `set prefix=($root)'/boot/grub'` /
  `configfile $prefix/grub.cfg`; `\EFI\BOOT\` got the same stub plus the removable
  shim/GRUB; `\EFI\ubuntu_snapdragon\` was not touched by it.

So stage 1 succeeded at its own job, and the installed root now carries a generated
`/boot/grub/grub.cfg` for kernel 7.2.0-5-generic.

## Which config the firmware's entries actually make GRUB read

`strings` on the ESP's EFI binaries (copies in `a16esp/` on the Windows side):

| file | bytes | sha256 | embedded config prefix |
|---|---|---|---|
| `EFI\ubuntu\grubaa64.efi` | 2967432 | `e9c439d22305d4962befc73ba0b2dbb6bef0cd7113399765ae9bc302bd3d269f` | `/EFI/ubuntu` |
| `EFI\ubuntu_snapdragon\grubaa64.efi` | 2967432 | same hash (byte-identical) | `/EFI/ubuntu` |
| `EFI\BOOT\grubaa64.efi` (removable) | 2533256 | `cfc15dd8e3794369215790c3e8438a0a5fc16d9aa7c7dcba8cccafd6dac054ab` | `/boot/grub` |
| `EFI\*\shimaa64.efi` | 987440 | `be7fc4a03dfba7b3f900b31f0f1ffd933b8639501816c04959c0c8f014e35422` | — (shim) |

The two `grubaa64.efi` that the firmware's Linux entries run are **byte-identical**,
and their embedded prefix is `/EFI/ubuntu` — so both read `\EFI\ubuntu\grub.cfg`
(the stub, i.e. the installed system's generated config), **not** the config sitting
next to them in `\EFI\ubuntu_snapdragon\`. The hand-written config staged there is
dead code unless a config is also present at the embedded prefix.

Firmware entries (`bcdedit /enum firmware`, order top to bottom):

```
{bootmgr}                            -> \EFI\Microsoft\Boot\bootmgfw.efi      (Windows)
{e478a527-7ff7-11f1-849c-806e6f6e6963} "Ubuntu"        -> \EFI\ubuntu_snapdragon\shimaa64.efi
{6a51310e-5b09-11f1-92ef-be9cacaee250} "Ubuntu Linux"  -> \EFI\ubuntu_snapdragon\grubaa64.efi
{99907c04-b1db-11f1-84ff-806e6f6e6963} "ubuntu (SAMSUNG …)" -> \EFI\ubuntu\shimaa64.efi
```

## Files here

- `A16BOOT.LOG` — stage 1's log as copied to the ESP root (the live session's
  `/tmp` copy is 40 lines longer: it stops at the `=== 11. log ===` marker).
- `efi-ubuntu-grub.cfg` — the 117 B stub GRUB reads (prefix `/EFI/ubuntu`).
- `efi-snapdragon-grub.cfg` — the hand-written 2,883 B config left in
  `\EFI\ubuntu_snapdragon\`, whose first entry searches with `--set=rt` but never
  sets `$root`, and whose third entry names `7.2.0-8-generic`, which is not installed.
- `efi-boot-grub.cfg` — the removable layout's copy of the stub.
