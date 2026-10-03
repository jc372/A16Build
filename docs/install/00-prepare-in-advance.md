# Phase 0 — Windows: everything you can do before touching Linux

Nothing here needs Linux. Doing it all first is what avoids round trips later: the firmware is on
the Windows side of this machine, and two of the three things that go wrong during installation are
easier to prepare now than to fix later.

## 0.0 Before you start

**Secure Boot:** disable it now, and re-enable it whenever you boot Windows. Standing rule for the
whole procedure — see the Secure Boot section in the README.

## 0.1 Hardware to have ready before you start flashing

- a **USB-A dock or hub**, plugged into the machine's USB-A port, carrying a **wired keyboard**, a
  **wired mouse** and **Ethernet**;
- install media: a **USB stick**, or the machine's **SD card**;
- and *not* the USB-C ports: those are not usable for the initial install (their support arrives
  later, in Phase 5) — see `docs/display-outputs.md`.

The internal keyboard and touchpad do not work during a stock install (they need the device-tree
boot with `acpi=off`), which is why the wired keyboard and mouse matter.

## 0.2 What this step produces

    A stick or folder containing:
      - the Ubuntu ARM64 desktop daily ISO (checksum verified)
      - the four Qualcomm DSP firmware blobs, from this machine's Windows DriverStore
      - the vendor Wi-Fi package for the QCC2072 (source for the board data)
      - the vendor Bluetooth package (hmtbtfw20.tlv, hmtnv20.b*)
      - scripts/a16-finish-boot.sh   and   scripts/a16-stage-esp-boot.sh   (Phase 3 and 4)
      - Rufus 4.14
    And, on this machine: WSL with an Ubuntu distribution and the build packages.

## 0.3 Downloads

- **Ubuntu ARM64 desktop daily.** The one used here is the 26.10 ("stonking") desktop daily; it
  boots on this machine and its live session has working internal input. Any later daily of the same
  series should behave the same, but check the checksum — a half-copied ISO wasted a flashing round
  in the past.

      # Windows
      Get-FileHash .\<image>.iso -Algorithm SHA256

- **Rufus 4.14.** Flash in **DD image mode** with **Secure Boot off**. Rufus logs to
  `%USERPROFILE%\Downloads\Rufus\rufus.log` and that log is the only record of which image was
  actually written.

- **The ASUS Qualcomm BSP is optional and does not help.** `V1.312.4500.0`
  (sha256 `E8F2389AC5D4DFD30A1A8481EC3C1E282F24BAEA2898414351D0B6EB1FA8A0B3`) contains `RSCP.bin`,
  `soccpr.jsn`, an INF and a catalog. Its INF says the SoCCP firmware is copied from the device's
  SPI-NOR at the factory, and it contains no `soccp.mbn` or `soccp_dtb.mbn`. Do not rename
  `RSCP.bin` to fill the gap; it is not the same image.

## 0.4 Firmware from this machine's Windows install

Search the Windows **DriverStore** for the filenames the kernel asks for, and copy them out of the
signed driver directories:

    C:\Windows\System32\DriverStore\FileRepository\...

| Blob | Comes from | Destination |
|---|---|---|
| `qcadsp8480.mbn`, `adsp_dtbs.elf` | the signed ADSP driver directory | `firmware/qcom/glymur/ASUSTeK/UX3607OA/` |
| `qccdsp8480.mbn`, `cdsp_dtbs.elf` | the signed CDSP driver directory | `firmware/qcom/glymur/ASUSTeK/UX3607OA/` |

`scripts/a16-install-firmware.sh` copies those into `/lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/`
on the installed system.

**Wi-Fi:** the QCC2072 here is `17cb:1112` with SUBSYS `E14F105B`. The vendor package contains the
board files; they are rebuilt into a `board-2.bin` for this machine's exact key with
`scripts/make-a16-qcc2072-board-2.sh` (which needs QCA's `bdencoder`). Copy the vendor package out;
the script turns it into something the driver accepts. See `docs/wifi.md`.

**Bluetooth:** copy `hmtbtfw20.tlv` and the `hmtnv20.b*` files out of the vendor Bluetooth package;
`scripts/a16-bt-setup.sh install` places them in `/lib/firmware/qca/`.

## 0.5 Record these facts while in Windows

- The device → driver → package inventory of the DriverStore. This is what identified the Wi-Fi part
  and its board-data package, and it is the only place those blobs exist.
- The Wi-Fi adapter's firmware version and the Bluetooth module's version, for comparison after the
  Linux side is up.

## 0.6 WSL and the build tools

    # Windows
    wsl --install -d Ubuntu

    # inside WSL
    sudo apt-get update
    sudo apt-get install -y xorriso mtools cpio rpm zstd xz-utils curl \
         coreutils findutils gzip grep sed gawk tar \
         bc bison flex openssl libelf-dev libdw-dev gcc make dtc ccache \
         python3 perl git pipx
    pipx install b4        # only if you will apply a mailing-list series by hand

`scripts/run-wsl-build.sh` installs this set itself for Ubuntu/Debian, Fedora and openSUSE hosts; the
list is in its `BUILD_PACKAGES` block. On an x86-64 WSL host it also wants `qemu-user-static` for the
arm64 toolchain; on this machine WSL is arm64, so it is natively arm64.

## 0.7 Check before you go on

    wsl -l -v                                  # Ubuntu present, version 2
    # inside WSL, from a checkout of this repository:
    scripts/run-wsl-build.sh --help
    ls config/                                 # the kernel build inputs
    ls scripts/a16-finish-boot.sh scripts/a16-stage-esp-boot.sh
