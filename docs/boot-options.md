# Boot options — the ways this machine can be brought up

Two independent choices decide how the machine behaves at boot. Both are made with **kernel
command-line options** in the GRUB menu, so nothing needs reinstalling to switch and either can be
selected at boot.

    A. display driver     : firmware framebuffer   |  built display driver (msm)
    B. device tree        : stock DTB              |  BT-enabled DTB

They are independent: any combination works.

## A. Display driver

### A1 — firmware framebuffer

The display stack is not loaded, so the panel is driven by the firmware's framebuffer:

    module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20

Result: a picture at one fixed 2880x1800 mode. Not available in this mode: brightness control
(`/sys/class/backlight` is empty), any refresh-rate choice, a GPU device. This is also what a
stock Ubuntu install does on this machine — not because it is configured this way, but because `msm`
has no ACPI match, so under ACPI nothing claims the panel and the kernel falls back to `simpledrm`.

### A2 — built display driver

Add none of the blacklist, i.e. the same command line **without** `module_blacklist=...`, and make
sure our modules are installed ([build.md](build.md)):

    /lib/modules/$(uname -r)/updates/a16/msm.ko
    /lib/modules/$(uname -r)/updates/a16/phy-qcom-edp.ko
    /lib/modules/$(uname -r)/updates/a16-clk-qcom/gpucc-glymur.ko

In addition to A1: real modesetting (2880x1800 at 120 Hz and 60 Hz), a working backlight
(`dp_aux_backlight`), a GPU device (`/dev/dri/renderD128`), and the possibility of external outputs
later. Details and the one driver fix it needs: [display-edp.md](display-edp.md).

## B. Device tree: Bluetooth

The stock DTB leaves the BT serdev client and the `W_DISABLE2#` polarity wrong, so BT does not come
up. A patched DTB fixes both (see [bluetooth.md](bluetooth.md)).

    BRINGUP/tools/a16-bt-arm.sh              # arm the patched DTB over both stock DTB paths
    BRINGUP/tools/a16-bt-setup.sh status     # which DTB is live
    BRINGUP/tools/a16-bt-arm.sh --revert     # back to the stock DTB

BT works with either display option: the DTB and the display choice do not interact.

## Making the two selections

**The menu is written in four places** on the ESP — `/boot/efi/a16boot/grub.cfg`,
`/boot/efi/EFI/Boot/grub.cfg`, `/boot/efi/EFI/ubuntu/grub.cfg`,
`/boot/efi/EFI/ubuntu_snapdragon/grub.cfg` — and the firmware boots one of the `/EFI` ones, so a
change that edits only one file appears to do nothing. `BRINGUP/tools/a16-drm-debug-entry.sh` edits
**all four** idempotently, keeps per-file backups, and can add or remove a set of parameters:

    # add/replace a set of parameters on the entry that has no blacklist (= built display driver)
    sudo A16_PARAMS="drm.debug=0x1ff consoleblank=0" bash BRINGUP/tools/a16-drm-debug-entry.sh arm
    sudo bash BRINGUP/tools/a16-drm-debug-entry.sh remove inline      # strip the recorded set
    sudo bash BRINGUP/tools/a16-bt-setup.sh status                    # sanity-check the DTB

`arm` is self-correcting: it removes a stray parameter row and then puts the parameters where they
belong, so it is safe to run repeatedly.

## Parameters that are for debugging, not for daily use

- `drm.debug=0x1ff` — ~15 000 extra DRM log lines per boot. Invaluable for a display problem,
  pointless afterwards.
- `systemd.unit=multi-user.target` — boots to a text console instead of the desktop. This is what
  makes the text console available when the desktop is not working.
- `consoleblank=0` — the text console does not blank. It only affects the text console.

To take the machine from "display debugging" to "daily use" without rebooting into a debug
configuration:

    sudo bash ~/a16.sh daily      # or: BRINGUP/tools/a16-gpu-fix.sh daily

## Telling which option a past boot used

    journalctl -k -b -1 -o cat | grep -m1 'Command line' | grep -o 'module_blacklist=[^ ]*'
    journalctl -k -b -1 -o cat | grep -oE 'simpledrmdrmfb|msmdrmfb' | head -1

`msmdrmfb` means the built display driver was in use; `simpledrmdrmfb` means the firmware
framebuffer. No `module_blacklist=` in the command line means the built driver was allowed.
