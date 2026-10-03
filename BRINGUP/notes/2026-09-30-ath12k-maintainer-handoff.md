# A16 maintainer handoff — ath12k board data and suspend/PCIe findings

Author: Hermes  
Date: 2026-09-30  
Project: A16Build — ASUS Zenbook A16 UX3607OA / Snapdragon X2 Elite (Glymur)

This note gathers the A16-specific evidence that may help upstream maintainers. The board-data mismatch and suspend/resume failure are separate issues; report them separately.

## Quick links

- Kernel.org ath12k board-data report: [Bug 221984 — QCC2072 board file for ASUS Zenbook A16](https://bugzilla.kernel.org/show_bug.cgi?id=221984)
- Ubuntu Concept 26.10 Snapdragon thread: [main thread](https://discourse.ubuntu.com/t/ubuntu-concept-26-10-snapdragon-edition/88518), [A16 test report, post 8](https://discourse.ubuntu.com/t/ubuntu-concept-26-10-snapdragon-edition/88518/8), [maintainer response, post 10](https://discourse.ubuntu.com/t/ubuntu-concept-26-10-snapdragon-edition/88518/10)
- Project overview: [STATUS.md](../../STATUS.md)
- Wi-Fi guide: [docs/wifi.md](../../docs/wifi.md)
- A16 board-data provenance and reproduction: [board-2 README](../../firmware/ath12k-board-2-qcc2072-e14f/README.md)
- Board-data build/test utility: [a16-wifi-bdf-test.sh](../tools/a16-wifi-bdf-test.sh)
- Suspend/PCIe analysis: [2026-09-22 Wi-Fi suspend ladder, §9](2026-09-22-wifi-suspend-ladder.md#9-why-one-resume-kept-the-radio-and-the-next-did-not-2026-09-22)
- Suspend experiment evidence: [ladder runs](../evidence/2026-09-22-ladder-runs.txt)
- Local ath12k patch series: [patches 0014–0018](../patches/)

## 1. QCC2072 board-data mismatch — best upstream handoff

### Hardware and observed request

- Laptop: ASUS Zenbook A16, model UX3607OA.
- WLAN PCI function: `17cb:1112`, subsystem `105b:e14f`.
- ath12k identifies the device as QCC2072 (`chip_id 0x21`, `chip_family 0x4`, `board_id 0xff`, `soc_id 0x40292100`).
- Firmware build observed: `WLAN.COL.1.0.c2-00277-QCACOLSWPL_V1_TO_SILICONZ-1`.
- The board-data lookup recorded in the project asks for `qmi-chip-id=33,qmi-board-id=255` and includes `variant=UX3407Q`; the request without the variant also fails against the distro board data. The variant string differs from the laptop's UX3607OA model name and is worth clarifying with ath12k/linux-firmware maintainers.

### What works locally

The A16-specific image was made from this laptop's Windows WLAN package, using `bdwlan_qcc2072_1p0_ncm820A.elf`, and wrapped under the A16 key with and without the variant. The resulting file is 526,972 bytes, SHA-256 `314e2d5702bd5431bd7abc6f71c6610f79f79ece50c5f854ccadeaee1bb27b49`. It is installed on this A16 and the WLAN interface probes. The repo documents its provenance and build method in the linked board-2 README.

The local repository also preserves a distro-provided compressed board file captured as `board-2.bin.zst.distro-20260911`. It is a useful baseline candidate, but verify its firmware-package version and contents before describing it as the exact upstream file requested by maintainers. Do not replace the currently working board file merely to make a report: a clean live-USB test or a separately staged, reversible test is safer.

### What the upstream report needs

Kernel.org Bug 221984 is the right thread for the board-data issue. The report's latest recorded maintainer response (2026-09-23) asks for kernel logs with the unmodified upstream `board-2.bin`; the currently running A16 has the custom image installed, so its successful probe log does not satisfy that request. Capture the failing lookup with the stock image before claiming to have supplied the requested reproducer. Do not attach the Windows firmware blob unless its redistribution permission is established; the identifiers, hashes, and logs are the shareable evidence.

The Ubuntu Concept 26.10 thread provides useful corroboration: its A16 tester reported that the system booted but Wi-Fi was missing, and the Concept maintainer pointed to this upstream issue while discussing modem firmware. The same tester filed a separate installer/partitioning bug; that is not the ath12k board-data issue.

### Draft for Bug 221984 — add the stock log before posting

> I have the same WLAN device on an ASUS Zenbook A16 UX3607OA: PCI `17cb:1112`, subsystem `105b:e14f`, identified by ath12k as QCC2072 (`chip_id 0x21`, `board_id 0xff`, `soc_id 0x40292100`). The lookup on this machine includes `qmi-chip-id=33,qmi-board-id=255,variant=UX3407Q`; the variant-less lookup also fails with the distro `board-2.bin`.
>
> A board file from the machine's Windows WLAN package (`bdwlan_qcc2072_1p0_ncm820A.elf`) makes the radio probe when wrapped for subsystem `105b:e14f`. I understand the request for logs with the unmodified upstream board file. I am attaching a fresh boot log from that baseline below, along with the exact kernel and linux-firmware package versions:
>
> `[ATTACH: full ath12k probe log from unmodified board-2.bin; include uname -a and linux-firmware package version]`
>
> Could you clarify why the UX3607OA reports variant `UX3407Q`, and whether the intended upstream contribution is the raw board-data blob through the linux-firmware submission process rather than a locally built `board-2.bin` container? I am not attaching the Windows firmware payload pending license review.

Before posting, replace the bracketed attachment reminder with an actual baseline log. Check it for private SSIDs, MAC addresses, hostnames, serial numbers, and other personal details. Do not claim the archived September 11 distro file is the current upstream image until its provenance/version is verified.

## 2. Suspend/resume and PCIe recovery — separate, preliminary report

`2026-09-22-wifi-suspend-ladder.md` §9 compares two resumes with the keep-MHI-up experiment. One resume has no PCIe recovery messages and Wi-Fi remains associated; the other reports Root Port Link Down, AER recovery failure/no `error_detected` callback, then Root Port reset and ath12k WMI timeouts. That trace suggests the endpoint/link was reset outside ath12k's current recovery path. It is valuable to ath12k and PCIe maintainers as an observed failure sequence, not proof that a driver-side PCIe recovery patch is the complete fix.

The current boot command line includes `pcie_port_pm=off pcie_aspm=off`, but the project does not yet have a complete, repeated suspend/resume result demonstrating that those options make the behavior reliable. Do not report the experiment as a fix. If filing a separate issue, attach both sides of the comparison, kernel logs, boot parameters, and clearly identify which downstream patches were loaded.

## Sharing guidance

1. Start with Bug 221984 and supply the requested unmodified-board-data log once captured.
2. Keep the suspend/PCIe evidence in a separate ath12k/PCIe discussion; label the causal explanation as a hypothesis until the link-preservation test is fully recorded.
3. Share logs and hardware identifiers, not the Windows firmware payload or the whole A16Build repository. Link the project note only as supporting background.
