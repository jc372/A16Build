# board-2.bin for the A16's QCC2072 (17cb:1112, SUBSYS E14F105B)

`board-2.bin` (526,972 B, sha256 `314e2d5702bd5431bd7abc6f71c6610f79f79ece50c5f854ccadeaee1bb27b49`)
is the file that makes Wi-Fi work on this machine. Verified on hardware 2026-09-16:
after installing it and booting GRUB entry 2, `ath12k` comes up with zero
`failed to fetch board data` lines, `wlP4p1s0` exists, and the session associates and
scans (57 → 50 APs visible, 29 Mbit/s measured over the radio).

## What was wrong

The part loads its firmware fine and dies one step later, at the board-data key match:

    ath12k_wifi7_pci 0004:01:00.0: chip_id 0x21 chip_family 0x4 board_id 0xff soc_id 0x40292100
    ath12k_wifi7_pci 0004:01:00.0: fw_version 0x100581de ... WLAN.COL.1.0.c2-00277
    failed to fetch board data for bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,
        subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255,variant=UX3407Q from ath12k/QCC2072/hw1.0/board-2.bin
    failed to fetch board data for bus=pci,vendor=17cb,... (same, without ,variant=...)
    qmi failed to load board data file:-2

linux-firmware ships `ath12k/QCC2072/hw1.0/board-2.bin` with four board entries — keys for
`subsystem-device=e15a` (board-id 24) and `17cb:1110` (board-id 12/19/24). **None matches
this machine.** `qmi-board-id=255` means the chip's OTP carried no board id, so such parts
are matched by `subsystem-device` *and* `variant=` instead, and no per-board-id file exists
for them.

## How this file was built

The machine's own Windows WLAN package (`qcwlancol8480`, the package bound to
`PCI\VEN_17CB&DEV_1112&SUBSYS_E14F105B`) ships 25 board images. Its
`bdwlan_qcc2072_1p0_ncm820A.elf` is the one that works here; it is an ELF32/ARM wrapper
whose `.data` is the raw BDF, the same shape linux-firmware ships. Wrapping it under this
machine's key and rebuilding with QCA's own tool produces this file:

    scripts/make-a16-qcc2072-board-2.sh --install          # reproduces + installs it

which is exactly:

    python3 scripts/ath12k-bdencoder -e <installed board-2.bin>      # -> board-2.json + per-key .bin
    # add {"names": [<key>, <key without variant>], "data": "bdwlan_qcc2072_1p0_ncm820A.elf"}
    python3 scripts/ath12k-bdencoder -c board-2.json                 # -> board-2.bin
    install -m 0644 board-2.bin /lib/firmware/ath12k/QCC2072/hw1.0/board-2.bin

The key it carries (both forms, so either request matches):

    bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255
    bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255,variant=UX3407Q

Reproduce or re-check the images with `scripts/a16-wifi-bdf-test.sh`
(`--dry-run` to build only, `--verify` to report the live radio and which candidate is
installed, default to walk the candidate list).

## Provenance and caveats

- The BDF comes from **this machine's own** Windows driver package, not from a sibling
  board; but per-board RF calibration lives in these images, so the claim "correct
  calibration" rests on the radio coming up and associating — which it does. If a Windows
  driver update ships a new package, re-run the extractor and rebuild.
- The candidate was chosen by being the first that worked, not by identifying the board id:
  the other 24 images were never needed. If throughput or band behaviour ever looks wrong,
  the harness can walk them (grouped by inner-BDF hash) — see
  `scripts/ath12k-bdf-from-elf.py`.
- `ath12k-bdencoder` is QCA's tool from
  `qca/qca-swiss-army-knife/tools/scripts/ath12k/ath12k-bdencoder` (vendored in
  `scripts/`, 25,963 B). Installing a rebuilt container means the *plain* `board-2.bin` is
  present, so keep the distro's `board-2.bin.zst` aside (`board-2.bin.zst.a16bak`) — a
  linux-firmware upgrade will bring the broken-for-this-machine file back, and this
  directory exists so it can be reinstalled in one command.
