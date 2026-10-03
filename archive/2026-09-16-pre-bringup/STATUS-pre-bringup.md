# A16Build — STATUS.md

> The pick-up file: any agent reads this + AGENTS.md, then PLANS/.
> Update after any work on this project.

**As of:** 2026-09-16 (15:4x) · **Last updated by:** Hermes

## Features / current state
- Tumbleweed build — PLAN-001 (working path: ACPI, 48-bit VA/PA, deferred
  MSM DRM)
- Ubuntu linux-next fresh build — PLAN-002:
  - `…-ubuntucfg.iso` boots its two ACPI entries on the A16 (the graphics
    variant is much faster than the diagnostic console one; the DTB entries
    stay dead). No internal keyboard/touchpad, so the session cannot be driven
    by hand.
  - New: `…-live-media-harvest.iso` — every boot self-reports (panel summary +
    tarball of ACPI tables, `/proc/iomem`, device lists, `dmesg`), so no typing
    is needed to get data off the machine.
- Log coordination loop — added (issue #3, cron watcher, registry)
- **Wi-Fi works on the A16** (2026-09-16): `ath12k` binds the QCC2072 and loads its firmware,
  and the missing piece was the board-data key — a rebuilt `board-2.bin` carrying this
  machine's own vendor image is committed in `firmware/ath12k-board-2-qcc2072-e14f/`.
  Evidence and the remaining (non-board-data) tuning: "In flight" and
  `notes/2026-09-16-hermes-wifi-board-data.md`.

## In flight
- **Sound: blocked upstream, measured (2026-09-16).** Card + four WSA884x amps up, no
  deferred probes, stream reaches RUNNING and the DSP consumes nothing; cross-SoC topologies
  are rejected identically (`Failed to start APM port 105` / `ASoC error (-22)`), and the
  second amp bus (`6ca0000.soundwire`) reports `SWR bus clsh detected` at boot. Windows
  firmware has no Linux topology (only `acdb_cal.acdb`), so the fix is a machine topology
  built around that ACDB or an upstream one. Full evidence and what is ruled out:
  `notes/2026-09-16-hermes-audio-state.md`. Interim workaround: mute the sink, video plays.
- **Windows-side firmware is extracted and published** (`f8514c8`,
  `firmware/windows-driverstore-2026-09-16/`, 326 files / 87 MiB,
  `sha256sum -c` 327 OK, tooling `scripts/extract-windows-a16-firmware.sh`), so the
  installed system gets it with `git pull`. A 30 MB zip (`c85357f3…`) sits in
  `/home/jc/a16-export/` and hash-verified in `C:\Users\cates\Downloads\` for the
  stick route. With it, a correction worth acting on: the A16's Wi-Fi is a
  **FastConnect C7700 / NCM820A (`PCI\VEN_17CB&DEV_1112`, package `qcwlancol8480`)**,
  **not** the WCN7850 the plans assumed — that package is staged in the DriverStore
  and bound to nothing present. linux-next's `ath12k` already claims `0x1112`
  (`QCC2072_DEVICE_ID`) and wants `QCC2072/hw1.0`, and the A16 DTS has **no Wi-Fi
  node** (the CRD boards use `pci17cb,1107`), so the Wi-Fi gap is at least partly
  **Resolved 2026-09-16: the gap was the board-data key only, not the device tree** (PCI
  enumeration brings the part up on the DT boot; no `pci17cb` node is needed). The rebuilt
  `board-2.bin` (526,972 B, sha256 `314e2d57…`) wraps this machine's own vendor image
  `bdwlan_qcc2072_1p0_ncm820A.elf` under `…subsystem-device=e14f,qmi-chip-id=33,
  qmi-board-id=255[,variant=UX3407Q]`, and is committed in
  `firmware/ath12k-board-2-qcc2072-e14f/` with the pristine distro container,
  `scripts/make-a16-qcc2072-board-2.sh` (reproduces the same hash) and
  `scripts/a16-wifi-bdf-test.sh` (candidate harness: `--dry-run`, `--verify`). Verified on
  hardware: 0 `failed to fetch board data` lines, `wlP4p1s0` up, scans + associates,
  29 Mbit/s measured. Remaining and *not* board-data: the profile picks the AP's weakest
  6 GHz BSSID (−77 dBm, 17 Mbit/s TX) instead of its 100% 5 GHz/2.4 GHz ones, powersave is
  on, and the Ethernet dongle holds the default route while connected.
  Notes: `notes/2026-09-16-hermes-wifi-board-data.md`.
- **The A16 boots Linux from the internal disk and now runs Hermes on the machine
  itself** (installed 26.10 daily session, `apt update && apt upgrade` done). That
  ends the photo/ESP-tarball round trip: `dmesg`, `/sys` and the ACPI tables can be
  read live. Export payload + exact install/import commands: PLAN-002, "The agent
  moves onto the A16". Still missing there: Wi-Fi (`ath12k`), sound, internal
  keyboard + touchpad; network is a USB-C dock / Ethernet dongle. Open question the
  installed session can answer: does `/sys/firmware/efi/efivars` exist at all
  (`sudo efibootmgr -v`) — the fact curtin died on and the July harvest discarded.
- The harvest works. `…-harvest3.iso` booted the default ACPI diagnostic console
  entry on 2026-09-16, the timer fired ~90 s in and wrote
  `a16-harvest-20260728-124912.tar.gz` (146,051 B; stale name — the live session
  has no readable hardware clock) to the internal ESP. Raw data + notes:
  `harvest/2026-09-16/`. Analysis in PLAN-002, "First real hardware harvest".
- Next hardware test: `…-live-media-dtmem.iso` — the DTB diagnostic console
  entry as the default (index 0), carrying a DT with the harvested RAM ranges
  baked in (`a16-memory-acpi.dtb`, 35 net ranges / 26.57 GiB) so the DT path
  finally has memory. If it boots, the DT path is the route to the internal
  keyboard/touchpad (ACPI mode cannot reach them at all).
  - Memory answer from the harvest: 20 `System RAM` ranges = 31.604 GiB total,
    5.04 GiB carved out inside them (net 26.57 GiB), plus exactly 16.00 GiB
    reserved at `0x8800000000-0x8bffffffff`. 31.60 + 16.00 ≈ 47.60 GiB =
    Windows' 47.62 GiB: 48 GiB installed, one third withheld in ACPI mode.
  - Collector gap fixed for the next build: it now reads `/proc/meminfo`
    (MemTotal/MemAvailable) and ships `data/meminfo.txt`; the old code read a
    `/var/log/dmesg` that live Ubuntu does not have.
  - Its DT entries now carry the upstream X1E-style zero-sized
    `memory@80000000` placeholder, so they double as a test of whether the
    firmware/loader fills the memory size in.
- Then pick the route to keyboard/touchpad: bake the harvested `System RAM`
  ranges into the DT with `scripts/make-a16-dtb-memory.sh ranges …` plus
  `DTB_OVERRIDE=<patched dtb>` (no kernel rebuild), or install `dtbloader` in
  the internal ESP (the A16 is already in its device database) and use the
  `firmware/loader-provided DT` entry.

## Known issues / blocks
- **Input cannot work in ACPI mode.** The firmware describes I2C controllers as
  `ACPI\QCOM0F10` and the GPIO controller as `ACPI\QCOM0F0C`; linux-next matches
  neither (`i2c-qcom-geni` knows only `QCOM0220`/`QCOM0411`, nothing claims
  `QCOM0F0C`), so no I2C adapter is created and the four firmware I2C-HID
  children (`ASUP1207`, `QTEC0001`, `QTEC0003`, `MSFT&DEV_0001`) never
  enumerate. Driver work, not a build knob.
- **The DTB entries can never boot as built.** The DT shipped for this machine
  (and every x1e/glymur SoC dtsi) has no `/memory` node by design: Qualcomm
  platforms boot DT by having the *firmware's* DT — memory map plus reserved
  carveouts — installed in the UEFI configuration table, with the Linux DTB
  applied on top (`dtbloader`). GRUB's `devicetree` command replaces that tree,
  so the kernel gets no RAM and dies before any console exists: no output at
  all, even with `earlycon=efifb`, exactly as observed.
- Keyboard/touchpad are only reachable through the DT path — Qualcomm's own A16
  series lists keyboard, touchpad and lid switch as working there. The pending
  `HID: asus` patch for keyboard `0B05:4B42` is needed for the Fn/media keys
  only; typing should work without it.
- **No console before DRM** (the old "black screen, no output" root cause) is
  solved: `DIAGNOSTIC_CONSOLE=earlycon=efifb`, proven on hardware.
- **Hook placement in the initramfs.** An initramfs-tools phase executes only
  what its `ORDER` file sources, and a casper boot never runs `local-bottom`
  (casper replaces `mountroot()`, so `local_bottom()` is unreachable). Live-root
  hooks therefore belong in `scripts/casper-bottom` *and* must be listed in that
  phase's `ORDER`. A hook in the wrong phase fails silently: the image boots
  normally and reports nothing — the failure mode that produced the first
  "harvest image that harvests nothing".
- **Never trust a `/mnt/c` copy of an ISO.** Copy with
  `/mnt/c/Users/cates/Downloads/a16-copy.ps1` (robocopy `/J` over
  `\\wsl.localhost`) and verify with `a16-verify.ps1`; two images were already
  corrupted at identical sizes.
- Full analysis: `PLANS/PLAN-002-ubuntu-linux-next-fresh-build.md`.

## Live truth
- Repo: PLANS/ (this repo)
- Execution: A16 installed session (Ubuntu 26.10 daily, kernel `7.2.0-5-generic`)
  — **now also runs Hermes on the machine**; VM tw-a16 (Tumbleweed), WSL
  /home/jc/A16Build
- Export payload for the stick (built+verified in WSL): `/home/jc/a16-export/payload/`
  — `hermes-backup-a16.zip.gpg`, `a16build.bundle`,
  `zenbook-a16-7.3.0-rc3-next-20260914.tar.zst`, `a16-triage.sh`, `sha256sums.txt`
- A16 firmware facts, read-only from the machine's own Windows install:
  `/mnt/c/Users/cates/Downloads/a16-acpi/` (`acpi-devices.csv`, `tables/DSDT…bin`).
  Helpers: `a16-acpi-dump.ps1`, `a16-acpi-tables.ps1`, `a16-read-log.ps1`.
  The device→driver→package inventory this extraction was based on is now committed
  with the payload (`firmware/windows-driverstore-2026-09-16/host-inventory/`), so the
  mapping can be re-derived without another Windows session. `scripts/a16-triage.sh`
  (previously only in the export payload) is committed and now probes the Wi-Fi part
  properly: every `17cb` device + bound driver + `modinfo ath12k`, both
  `ath12k/QCC2072/hw1.0` and `WCN7850/hw2.0` firmware directories, and the `17cb`
  device count in its panel summary.
- The extracted Windows firmware for the Linux side:
  `firmware/windows-driverstore-2026-09-16/` (in-repo, `git pull`) and the same tree
  zipped as `a16-windows-firmware-2026-09-16.zip` (30 MB, `c85357f3…`) in
  `/home/jc/a16-export/` + `C:\Users\cates\Downloads\`.
- QEMU (rootless, no KVM): `~/qemu-rootless/root`, helpers in `.diag/qemu-smoke-*.sh`
