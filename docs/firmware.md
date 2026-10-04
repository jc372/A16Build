# Firmware

The kernel package contains **no firmware**. Drivers are in the package; the firmware they ask for is
loaded at boot from `/lib/firmware`, and a file that is missing means that one device does not come
up. The kernel itself always boots, and display, keyboard, disk and suspend do not depend on any of
this.

Ubuntu's `linux-firmware*` packages cover almost everything. This page lists the three groups that
are different on this machine, in the order they matter.

| Group | Needed for | Optional? | Source |
|---|---|---|---|
| glymur DSP images and topology | sound | **required** | your own Windows install — in no package |
| QCC2072 `board-2.bin` | Wi-Fi | required here, but **check first** — a newer firmware package may already carry it | your own Windows install, rebuilt |
| qca Bluetooth patch and NVM | Bluetooth | **optional** — the chip runs without it | Ubuntu ships the patch; extras come from Windows |

None of these files are redistributed here: they are Qualcomm/ASUS proprietary. Everything below
gives the size and sha256 of each one so you can confirm you have the same bytes.
`BRINGUP/tools/extract-windows-a16-firmware.sh` in the repository pulls them out of your own Windows
driver store; it runs on the Windows side.

## 1. Sound — the glymur DSP images and topology (required)

Five files, from the Qualcomm DSP packages (`qcadsp8480`, `qccdsp8480`, `qcasd8480`, `qcacsp*`):

| File | Size | sha256 |
|---|---|---|
| `qcadsp8480.mbn` | 19,867,608 B | `67b4e129d4d60fccd05d85be3754168f46535549a03a3627c598d634e73df49d` |
| `qccdsp8480.mbn` | 3,252,504 B | `acf13d29288d283793f418a36650e8a261eed927d30de109a59cb2210f458794` |
| `adsp_dtbs.elf` | 225,080 B | `7906466c734b2f360d48cf086f80b6e04d84e9b02255c74545aa28d5df1e932c` |
| `cdsp_dtbs.elf` | 69,432 B | `9bee104a48d4aac647287d6c1454df170c1cff7158a2352711fd1e2163ea6d1d` |
| `GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin` | 11,356 B uncompressed | see below |

Destinations:

    /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/qcadsp8480.mbn
    /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/qccdsp8480.mbn
    /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/adsp_dtbs.elf
    /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/cdsp_dtbs.elf
    /lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin

The topology may be copied as it comes or compressed (`.zst`, 941 B, sha256
`d2beccf1642bde81777865700dc58f2555b70a96a3182c49320c9a0fd51698e7`); this kernel decompresses
`.zst` firmware itself, so either name works.

Steps:

1. On Windows (or in WSL), run the extractor and give it an output directory:

        OUT=firmware/from-windows bash BRINGUP/tools/extract-windows-a16-firmware.sh

2. Copy the five files to the destinations above, then confirm:

        sha256sum /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/*.mbn \
                  /lib/firmware/qcom/glymur/ASUSTeK/UX3607OA/*dtbs.elf \
                  /lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin*

3. Install the ALSA UCM profile and the WirePlumber rule — [audio.md](audio.md) has the four steps.

Without this group: no sound card at all (`Dummy Output`).

## 2. Wi-Fi — the QCC2072 board file (required here, but check first)

`ath12k` will not bring the radio up unless it finds a board file carrying this machine's key:

    bus=pci,vendor=17cb,device=1112,subsystem-vendor=105b,subsystem-device=e14f,qmi-chip-id=33,qmi-board-id=255,variant=UX3407Q

Ubuntu's `linux-firmware-qualcomm-wireless` ships `ath12k/QCC2072/hw1.0/board-2.bin` with keys for
other boards only (subsystem `e15a`/`1110`, board ids e12/e19/e24), so the driver logs
`failed to fetch board data for bus=pci,...subsystem-device=e14f,qmi-board-id=255,variant=UX3407Q`
and the interface never appears. Upstream tracking: [kernel.org bug 221984](https://bugzilla.kernel.org/show_bug.cgi?id=221984).

**Check first** — a newer firmware package may have added the key, in which case there is nothing to
do and Wi-Fi may or may not need any of this:

    python3 ath12k-bdencoder -e /lib/firmware/ath12k/QCC2072/hw1.0/board-2.bin | grep -i e14f

If that prints nothing, build the board file from your own Windows WLAN package (the
`qcwlancol8480` package bound to `VEN_17CB&DEV_1112&SUBSYS_E14F105B`; it ships 25 `bdwlan.*`
images, one per board):

    OUT=firmware/from-windows bash BRINGUP/tools/extract-windows-a16-firmware.sh
    A16_BOARD_SRC=firmware/from-windows/wlan/qcwlancol8480.inf_arm64_* \
        sudo bash make-a16-qcc2072-board-2.sh --install

Result: `board-2.bin`, 526,972 B, sha256
`314e2d5702bd5431bd7abc6f71c6610f79f79ece50c5f854ccadeaee1bb27b49`. The script backs up whatever is
there first and restores it if no candidate works. Which image is correct cannot be proven by the
file merely loading — per-board RF calibration lives in these images; see
[the provenance note](../retired/firmware/ath12k-board-2-qcc2072-e14f/README.md).

Without this group: Wi-Fi may or may not work. It works if your firmware package carries the key
above; it does not if it only carries the other boards' keys, which is the case on this machine's
distro packages as of `linux-firmware 20260915.git1522c78a`.

## 3. Bluetooth — the patch and NVM files (optional)

The radio uses `/lib/firmware/qca/hmtbtfw20.tlv` (patch) with an `hmtnv20.b*` NVM blob chosen by the
chip's ROM version. Ubuntu already ships both, compressed, so a stock install needs nothing here:

| File | Size | sha256 | In Ubuntu? |
|---|---|---|---|
| `hmtbtfw20.tlv` | 280,764 B | `7ee3f2b968d0616b67676a67e7c7e9de1e3fd0e4d4f96c5cc364650280563ad5` | yes (`linux-firmware-qualcomm-wireless`, as `.zst`) |
| `hmtnv20.b10f` | 9,656 B | `3af0e8c65c3f119a2380820a24af4979d5affc2751a22170ecd9f318e25e77ff` | yes |
| `hmtnv20.b112` | 9,656 B | `6cc9e4609bde5cba32460ecd691ed39bcf2de14d6ae59e501c9c9fc637c54b4b` | yes |
| `hmtnv20.b105` | 9,656 B | `57c3cf985ff407606db950574daf639ca9f279bdd37675acccd7ad1d980761ef` | no |
| `hmtnv20.b3b` | 9,656 B | `f0b2bd0050d1b8d935c9fad533352a9fbccccb47fafbd191d2044a8caacc4b7c` | no |

This machine has all five uncompressed in `/lib/firmware/qca/`, which is a superset of what the
packages provide. Without any of them Bluetooth still works: the chip runs from its ROM firmware, and
the driver logs `-2` for the absent rampatch `qca/hmtbtfw11.tlv`, which is missing here either way.
[bluetooth.md](bluetooth.md) has the detail.

## Not covered here

- **3D GPU** — the Adreno firmware is vendor-only and is not installed on this machine
  (`gpu-video`: `qcdxkmsuc8480.mbn`, `qcdxkmbase8480_*.bin`, `qcvss8480.mbn`). Whether the current
  `GMU firmware initialization timed out` is caused by that, or is a kernel-side issue, is untested.
- **Camera** — the vendor images exist in the driver store, but the device tree path for the sensor
  is not in place and there is no page for it yet.
- **Wireless regulatory database** — `regulatory.db` is not ours; it belongs to the `wireless-regdb`
  package. Removing it costs you nothing but the country-specific channel rules.

## Verifying what actually loaded

    ls /sys/class/remoteproc/remoteproc*/state          # adsp and cdsp: running
    cat /proc/asound/card0/id                           # a card id, not "Dummy"
    nmcli -t -f DEVICE,TYPE,STATE device | grep wifi    # connected
    bluetoothctl show | grep Controller                 # a controller

Firmware is requested once per boot; the kernel does not re-read a file it has already loaded, so
replacing a blob takes effect on the next boot, not immediately.
