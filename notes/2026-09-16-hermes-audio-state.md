# 2026-09-16 — audio state on the A16: what is ruled out, what is left

Author: Hermes
Date: 2026-09-16
Project: A16Build (ASUS Zenbook A16 UX3607OA, Snapdragon X2 Elite, Glymur)

## Measured state (GRUB entry 2, kernel 7.3.0-rc3-next-20260914, live reloads)

The card is created by the reference topology renamed to the machine's name
(`/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin.zst` ←
`GLYMUR-CRD-tplg.bin.zst`). Card 0 has `MultiMedia1 Playback` + `MultiMedia2 Playback`,
the session offers a real sink, the ALSA stream reaches `RUNNING` — and **nothing consumes
it**: `hw_ptr` stays 0 while `appl_ptr` parks at the buffer depth, which is why playback
blocks and only a single "crack" (the amps powering up) is audible. Muting the sink makes
video play again; that is the interim workaround, not a fix.

## Ruled out, with evidence

1. **Missing providers.** In the current boot the LPI pinctrl (`qcom-sm8650-lpass-lpi-pinctrl`
   @7760000), both SoundWire masters, both WSA macros and the q6prm clock service
   (`6800000.remoteproc:glink-edge:gpr:service@2:clock-controller`) are all bound, and
   `journalctl -k -b 0 | grep 'deferred probe pending'` is **empty**. The ADSP is running.
2. **The amplifiers.** All four WSA884x are enumerated: `sdw:1:0:0217:0204:00:0/1` and
   `sdw:4:0:0217:0204:00:0/1`, driver `wsa884x-codec`, same rails (`regulator.24/26`).
3. **Not a channel-count / graph-width problem.** The CRD graph is already the minimal,
   single-playback-path shape: `stream0 → device105.codec_dma_rx1` (+ `device110.codec_dma_tx1`
   capture), 11,320 B decompressed. The Dell-XPS-13-9345 and Lenovo-Yoga-Slim7x graphs have
   the *identical* shape. Only `X1E80100-Romulus` is wide (4 streams, two codec-DMA pairs,
   display ports 104/129/130). So "make it stereo" is not a lever — it already is.
4. **Cross-SoC topologies do not work on this DSP.** Romulus, Dell-XPS-13-9345 and
   Yoga-Slim7x all fail in the same way, at *trigger*:
   `qcom-apm … DSP returned error[1001002] 1` → `Failed to start APM port 105` →
   `ASoC error (-22) at soc_dai_trigger() on WSA_CODEC_DMA_RX_0`. Only the glymur CRD graph
   is accepted (it starts the port and then never consumes).
5. **Device tree / GPIO description.** `wsa-swr-active-state` (clk gpio10 / data gpio11) and
   `wsa2-swr-active-state` (clk gpio15 / data gpio16) are distinct and correctly named; the
   two amp-group reset lines are two separate 1-line gpiochips (13 and 16), both released.
   The two SoundWire controllers are described symmetrically (`qcom,soundwire-v3.1.0`, same
   port tables). No DT-level fault found.

## What is actually broken

The **second** amp bus is dead from boot, before anything plays:

    6ca0000.soundwire: qcom_swrm_irq_handler: SWR bus clsh detected
    6ca0000.soundwire: qcom_swrm_irq_handler: SWR unknown interrupt value: 2048
    6ca0000.soundwire: swrm_wait_for_wr_fifo_avail err write overflow   (repeats)
    wsa884x-codec sdw:4:0:0217:0204:00:0: ASoC error (-61) [ENODATA] on resume
    later: "Parity error detected" on both master-4 amps; their status becomes Alert

Master 1 (`6c80000.soundwire`, its amps `Attached`) is clean. A bus clash + a slave left in
Alert is a hardware/firmware-level fault (or a driver bug in the second instance), not
something a topology or a DTB property can paper over: with the graph driving both paths,
the codec DMA never runs and the DSP consumes nothing.

## Windows firmware: what it can and cannot give us

The extracted package (`firmware/windows-driverstore-2026-09-16/`) carries the machine's
audio *resources*, but **no Linux topology** — a grep for the `CoSA` container magic over all
87 MiB returns nothing:

    adsp/qcacsp_crd8480…/acdb_cal.acdb       524,502 B  magic "ACDB"  <- the calibration DB
    adsp/qcacsp_crd8480…/ADCMResources.bin     3,426 B  magic "AeoB"
    adsp/qcacsp_crd8480…/workspaceFile.qwsp  721,216 B
    adsp/qcadc8480…/ADC1.bin                  12,648 B  magic "AeoB"
    adsp/qcaucd_ext_crd8480…/ACDResources.bin  5,477 B
    adsp/qcascd_ext_crd8480…/ASCDResources.bin 5,265 B
    adsp/qcasd8480…/AudioResourceConstraints_8480.xml   (Windows ACX endpoint constraints)

The missing `*-tplg.bin` is a Linux-only Audioreach artifact that *embeds* that ACDB
calibration; it is generated from it with Qualcomm's Audioreach tooling, which the package
does not ship. So the real fix for native audio is either
(a) obtaining/building this machine's own topology around `acdb_cal.acdb`, or
(b) upstream linux-firmware gaining `qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin`
(checked 2026-09-16 against the linux-firmware tip `e2898686`: `qcom/glymur/` still has only
the CRD topology).
Until one of those exists, this is upstream work, not a setting to find.

## Tools left in place

- `scripts/a16-audio-graph-test.sh` — `tplg crd|romulus|xps|yoga|<path>`, `reload`, `probe`,
  or any sequence of those in one invocation; the probe's verdict distinguishes "the stream
  never opened" (DSP/bus refused it) from "RUNNING with hw_ptr frozen".
- The reference topology file is restored with `tplg crd` followed by `reload`; keep
  `…-tplg.bin.zst.a16bak` as the rollback.
