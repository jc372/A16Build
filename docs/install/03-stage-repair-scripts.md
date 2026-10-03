# Phase 3 — put the boot-repair scripts on the EFI partition

After Phase 2 the EFI partition holds no Linux payload. Two shell scripts fix that; both have to be
sitting at the root of the EFI partition, where the live session can reach them by mounting it.

| Script in this repository | Put it on the ESP as | Purpose |
|---|---|---|
| `scripts/a16-finish-boot.sh` | `\A16FIX.SH` | stage 1 — GRUB install with `--no-nvram --removable`, `update-grub`, log to the ESP |
| `scripts/a16-stage-esp-boot.sh` | `\A16STAGE2.SH` | stage 2 — diagnostics, plus a boot that needs only the ESP |

## 3.1 Option A — copy them from the live session

The live session can mount the EFI partition, so if you still have the installer running or can boot
it again, this avoids Windows entirely. Find the ESP and copy:

    lsblk -o NAME,SIZE,FSTYPE,PARTTYPENAME      # the EFI System Partition (vfat, ~200-500 MB)
    sudo mkdir -p /mnt/esp
    sudo mount /dev/nvme0n1p1 /mnt/esp         # adjust to your ESP
    sudo cp a16-finish-boot.sh  /mnt/esp/A16FIX.SH
    sudo cp a16-stage-esp-boot.sh /mnt/esp/A16STAGE2.SH
    sync; ls -l /mnt/esp/A16FIX.SH /mnt/esp/A16STAGE2.SH
    sudo umount /mnt/esp

Filenames matter: the scripts expect to be found as `\A16FIX.SH` and `\A16STAGE2.SH`, and the
documentation in them refers to each other by those names.

## 3.2 Option B — copy them from Windows

Booting Windows here means **re-enabling Secure Boot first**; disable it again before you go back to
the live session (standing rule: off for Linux, on for Windows).

The EFI partition is FAT, so Windows can mount it. In an **elevated** PowerShell:

    # which partition is the EFI system partition
    Get-Partition | Where-Object { $_.GptType -eq '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}' }

    # give it a letter, copy, remove the letter again
    mountvol S: /S
    Copy-Item .\A16FIX.SH     S:\A16FIX.SH
    Copy-Item .\A16STAGE2.SH  S:\A16STAGE2.SH
    Get-ChildItem S:\A16*.SH | Select-Object Name,Length
    mountvol S: /D

The original of this step was a small PowerShell helper kept on the Windows side
(`a16-esp-stage2.ps1`); it did exactly the three things above. It is not reproduced here because it
was Windows-specific tooling — the commands above are the equivalent, and they are all that is
needed.

## 3.3 Verify the copy

Both scripts are small text files and the copy has to be complete — a truncated script fails
mid-repair in the live session, where it is awkward to debug:

    # from the live session, after mounting the ESP again
    sha256sum /mnt/esp/A16FIX.SH /mnt/esp/A16STAGE2.SH
    head -5 /mnt/esp/A16STAGE2.SH          # should show the '#!/bin/bash' shebang and the notes

Compare against the copies in this repository:

    sha256sum scripts/a16-finish-boot.sh scripts/a16-stage-esp-boot.sh

Note the size you copy: the recorded stage-2 script was 14 173 bytes. If yours differs, it is a
different revision of the script, which is fine — but compare its notes with what Phase 4 says it
writes, so you are not surprised by the result.

## 3.4 If you edit a script later

Re-copy it to the ESP after every edit, and re-verify with `sha256sum`. The scripts read their
inputs from the machine (partition layout, the installed system), not from themselves, so a stale
copy is the most likely cause of an unexpected result.
