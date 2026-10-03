# archive/2026-09-16-pre-bringup — the era before the machine could be worked on in place

Nothing here is current. It is kept because it is how the machine was *reached*, because some of
its data are still cited, and because a broken machine is recovered with these tools.

**What changed.** Until 2026-09-16 ~11:00 EDT, every step had to travel: build an ISO on WSL or
the Tumbleweed VM, flash a stick, boot the stick, collect evidence (photos, tarballs written to
the ESP), analyse it in another session. After the Ubuntu install on the internal disk started
booting on its own *and* Hermes was installed onto it, work could happen directly on the hardware
— the era documented in `../../BRINGUP/`.

## Index

### `scripts/` — the old-approach tooling

| Script | What it did |
|---|---|
| `run-wsl-build.sh`, `build.sh`, `package.sh`, `audit-config.sh`, `apply-series.sh` | The WSL/VM kernel build: unpack the pinned linux-next tree, apply the mailing-list series exactly once, build with the A16 config, audit the config, package the bundle. |
| `make-ubuntu-desktop-usb-iso.sh`, `make-ubuntu-daily-baseline.sh` | Replace the kernel payload in an official Ubuntu ARM64 desktop/daily live ISO (and reproduce the baseline byte-for-byte). |
| `make-opensuse-tumbleweed-usb-iso.sh`, `make-opensuse-tumbleweed-baseline.sh`, `make-fedora-xfce-usb-image.sh` | The same for Tumbleweed ARM64 and a Fedora Xfce raw image. |
| `a16-stage-esp-boot.sh` | Stage 2 of the bootloader repair: hand-written GRUB configs on the ESP, kernel+initrd+modules on the FAT volume, a diagnostics entry. It also recorded the finding that the hand-written ESP config was never read. |
| `a16-finish-boot.sh` | Finish the bootloader step curtin's `curthooks` died on (`efibootmgr: EFI variables unsupported`). |
| `a16-harvest.sh` | The live-session collector: write a tarball of ACPI tables, `/proc/iomem`, device lists and `dmesg` to a sink (the ESP), self-reporting, no keyboard needed. |
| `make-a16-dtb-memory.sh` | The DT-memory experiment: bake the harvested `System RAM` ranges into a DTB so the DT path would have memory at all. Superseded — the machine's own vendor DTB carries the memory map, which is what the bring-up boots. |

### `PLANS/`

`PLAN-001-a16-tumbleweed-build.md`, `PLAN-002-ubuntu-linux-next-fresh-build.md` (+ its README) —
the plan/history documents of the ISO era. PLAN-002 still holds facts the bring-up relies on
(the memory map: 20 `System RAM` ranges, 16 GiB reserved at `0x8800000000`, 48 GiB installed,
one third withheld in ACPI mode; and the boot/console path findings).

### `harvest/`

`2026-09-16/` (the first real hardware harvest: ACPI tables, `/proc/iomem`, device lists, dmesg)
and `2026-09-16-esp/`, with its README. These are the source of the ACPI device facts quoted in
the bring-up: `ACPI\QCOM0F10` (I2C), `ACPI\QCOM0F0C` (GPIO), `ACPI\QCOM0F6B` (Bluetooth UART
transport), and the I2C-HID children `ASUP1207`, `QTEC0001`, `QTEC0003`, `MSFT&DEV_0001`.

### `config/`

The kernel build inputs of the pinned tree: `ubuntu-generic-arm64.config`, `a16-required.config`,
`build-overrides.config`, `build.env`, `series.env`. Needed to reproduce the bundle the bring-up
installs — the pin is linux-next `3d08ff75a47a3e7e2ab45a3bcab6723b4d906422`
(`7.2.0-rc7-next-20260810`) per `AGENTS.md`.

### `README-pre-bringup.md`

The repository's front page from the ISO era.

## Why not deleted

`git log --follow` reaches every file here, the ISO builders are the recovery path for a machine
that will not boot Linux at all, and the harvest is the only copy of the ACPI tables that were
read before the DT path made ACPI unnecessary.
