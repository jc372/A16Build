# Phase 5 — first boot, then bring the machine up

The installed system boots (Phase 4), but it is running the installer's stock kernel and none of the
machine's own pieces are in place. This phase is the on-machine work, in the order it worked.
Per-component detail and verification commands are in `docs/`.

Run everything as root, from a checkout of this repository on the machine, with **Secure Boot
disabled** — it stays disabled for Linux and goes back on for Windows (README, Secure Boot).

## 5.1 Check the firmware's EFI variables

    ls /sys/firmware/efi/efivars/            # 102 entries on this machine first time round
    sudo apt install -y efibootmgr && sudo efibootmgr -v

Worth recording: whether EFI variables work at all in the *installed* system. They did not during
installation, which is why Phase 3/4 exist.

## 5.2 Install the linux-next kernel and the device-tree boot entries

    sudo bash scripts/a16-install-next-kernel.sh
    sudo bash scripts/a16-stage-dt-boot.sh

Two facts decide this step:

- **ACPI mode cannot give internal input.** `ACPI\QCOM0F10` (I2C) and `ACPI\QCOM0F0C` (GPIO) match no
  linux-next driver, so no I2C adapter appears and the firmware I2C-HID devices (`ASUP1207`,
  `QTEC0001`, `QTEC0003`, `MSFT&DEV_0001`) never enumerate. The **device tree** path is what makes
  the internal keyboard, touchpad and touchscreen work.
- **The upstream DTS cannot simply be dropped in.** Qualcomm platforms boot with the *firmware's* DT
  in the UEFI configuration table and the Linux DTB applied on top; GRUB's `devicetree` command
  replaces that tree, so a bare upstream DTB boots with no memory and no console. The bring-up boots
  the **machine's own DTB** with `acpi=off` plus the cleanup flags, and patches that DTB where needed
  (see `docs/boot-options.md`).

Verify: `cat /proc/cmdline` shows `acpi=off`, and the internal keyboard works.

## 5.3 Firmware

    sudo bash scripts/a16-install-firmware.sh          # the four DSP blobs from Phase 0
    sudo bash scripts/a16-bt-setup.sh install          # Bluetooth firmware into /lib/firmware/qca

Verify: the DSPs stop reporting missing firmware in `dmesg`; `BT` firmware files exist in
`/lib/firmware/qca/`.

## 5.4 Wi-Fi board data

    sudo bash scripts/make-a16-qcc2072-board-2.sh --install

The QCC2072 (`17cb:1112`, SUBSYS `E14F105B`) needs a board-data entry for *this machine's* key. The
script rebuilds `board-2.bin` from the vendor package staged in Phase 0 and installs it
(sha256 `314e2d57…`).

Verify:

    journalctl -k -b 0 -o cat | grep -c 'failed to fetch board data'   # 0
    nmcli device status                                                # wlP4p1s0 connected

## 5.5 Bluetooth

    bash scripts/a16-bt-setup.sh status
    sudo bash scripts/a16-bt-arm.sh            # arms the patched device tree

The patched device tree (`firmware/glymur-asus-zenbook-a16-ux3607oa-a16bt.dtb`, change in
`patches/0001`) adds the UART serdev client with its six supply rails and flips the `w-disable2`
polarity that was holding the chip disabled.

Verify: `bluetoothctl show` lists a controller, with its own address.

## 5.6 Display and GPU

Two separate things, in this order — see `docs/gpu-adreno.md` and `docs/display-edp.md`:

1. **The GPU clock controller.** `CONFIG_CLK_GLYMUR_GPUCC` was not set in the kernel this machine
   came with, so `msm` could never bind at all (the GPU supplies a power domain the display path
   needs). Build the module and install it:

       sudo bash scripts/a16-build-gpucc-native.sh --build
       sudo bash scripts/a16-install-gpucc-module.sh <built .ko ...>

   Verify: `msm_dpu` binds, `/sys/class/drm/card1-eDP-1` exists, `/sys/class/backlight` is not empty.

2. **The eDP link rate.** With `msm` bound, the link still failed channel equalisation at 4-lane
   HBR2. `patches/0009` takes the highest rate the device tree allows (HBR3, 8.1 G) instead of the
   highest the panel advertises. `patches/0006`/`0007` are the posted v8 PHY series, carried too.

   Verify in the kernel log:

       link_rate=810000
       using LINK_BW_SET: 0x1e
       link training #2 on phy 0 successful

## 5.7 The rest of the machine

    docs/input.md            keyboard, touchpad, touchscreen, stylus (works)
    docs/power-battery.md    battery, charge control, power key (works)
    docs/wifi.md             Wi-Fi (works), one unreproduced idle observation
    docs/audio.md            speakers: blocked, needs a machine ACPI topology
    docs/suspend.md          suspend: not implemented
    docs/display-outputs.md  external displays: blocked, needs in-review PHY work
