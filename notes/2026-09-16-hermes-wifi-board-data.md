# 2026-09-16 — the A16's Wi-Fi board data (QCC2072 / 17cb:1112)

Author: Hermes
Date: 2026-09-16
Project: A16Build (ASUS Zenbook A16 UX3607OA, Snapdragon X2 Elite, Glymur)

## What was wrong

The Wi-Fi part is not unsupported and its firmware was never missing. `ath12k` binds,
powers the device, loads `ath12k/QCC2072/hw1.0/firmware-2.bin`, reports
`fw_version 0x100581de … WLAN.COL.1.0.c2-00277`, and then dies at the **board-data key
match**:

    failed to fetch board data for bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,
        subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255,variant=UX3407Q
    failed to fetch board data for … (same, without ,variant=)
    qmi failed to load board data file:-2

The distro's `board-2.bin` carries four keys (subsystem `e15a` board-id 24; `17cb:1110`
board-id 12/19/24). Ours is absent. `qmi-board-id=255` is not a real id — the chip's OTP
carried none — so the driver matches on `subsystem-device` plus `variant=`, and the vendor
package has no `.eff` image for it.

## What fixed it

The machine's own Windows WLAN package (`qcwlancol8480`, the package bound to
`PCI\VEN_17CB&DEV_1112&SUBSYS_E14F105B`) ships 25 board images. `bdwlan_qcc2072_1p0_ncm820A.elf`
— an ELF32/ARM wrapper whose `.data` is the raw BDF, the same shape linux-firmware ships —
wrapped under this machine's key with QCA's `ath12k-bdencoder` and rebuilt:

    board-2.bin  526,972 B  sha256 314e2d5702bd5431bd7abc6f71c6610f79f79ece50c5f854ccadeaee1bb27b49

Committed in `firmware/ath12k-board-2-qcc2072-e14f/` with the pristine distro container
next to it; `scripts/make-a16-qcc2072-board-2.sh` rebuilds it and checks that hash.

## Verified on hardware (GRUB entry 2, 2026-09-16 15:2x)

- `journalctl -k -b 0 | grep -c 'failed to fetch board data'` → **0**
- `wlP4p1s0` exists, `phy0` registered, `rfkill` unblocked
- scan: 57 then 50 APs visible; 29 Mbit/s measured over the radio with the source address
  bound to the Wi-Fi interface; LAN gateway reachable over Wi-Fi (PING 3/3)

## Not a board-data problem (still open)

- The connection profile picks the **weakest** BSSID of the AP: `22:36:26:d8:29:23` on
  6295 MHz at ~44%, `tx bitrate 17.2 Mbit/s`, RSSI −77 dBm, while the same AP's 5 GHz
  (`58:D8:12:08:90:D9`, 5805 MHz) and 2.4 GHz (`58:D8:12:08:90:D8`, 2462 MHz) BSSIDs report
  100%. Also `Power save: on`, and gateway pings over Wi-Fi run 32–77 ms.
  Fix to try: `nmcli con modify hn 802-11-wireless.band a` + `wifi.powersave 2` (and a fixed
  `802-11-wireless.bssid` if it keeps hopping).
- While the Ethernet dongle is connected it holds the default route (metric 100), so Wi-Fi
  carries nothing: expected, not a fault. Unplug and re-test.
- The earlier plan text ("the Wi-Fi gap is at least partly device-tree because the A16 DTS
  has no `pci17cb,1112` node") is **wrong in practice**: PCI enumeration brings the part up
  on this DT boot without any DT node, and no `pci17cb` node exists in the live tree.

## Lessons worth keeping

- `board-2.bin` is QCA's container (`QCA-ATH12K-BOARD` magic, name→data entries), edited
  only through `ath12k-bdencoder -e/-c`. A hand-written IE walker parses garbage and
  "proves" a healthy file is corrupt.
- Verify a rebuild by **re-extracting it** and grepping for the key; the build's stdout
  only proves the tool ran.
- The vendor `bdwlan*.elf` files are wrappers: extract the `_binary_*_bin_start/_end` range
  (mapping the symbol vaddr through its section) to compare two of them as board data. Group
  candidates by that inner hash, not by filename — `e01/e02/e06/e07/e08/e09` are one image,
  `e0f…e14` another, `e15/e17/e18` another.
- `modprobe -r ath12k` alone cannot unload this driver set: `ath12k_wifi7(_pci)` holds the
  core. Unload the dependents by name, and do not decide "still in use" with
  `lsmod | grep '^ath12k'` — that also matches `ath12k_wifi7`. A reboot is a legitimate way
  to test an installed board file (that is how this one was proven).
- `--verify`-style checks beat prose: netdev present, board-fetch failure count 0, sha256 of
  the installed file matched against the builds the harness kept.
