# Audio — WSA884x speakers

**State: not working, and blocked on upstream work rather than on anything we can patch locally.**

## The hardware

| | |
|---|---|
| Speakers | Qualcomm WSA884x amplifiers over SoundWire |
| SoC audio | LPASS (Audio DSP), `qcom-apm` / `q6apm` / `q6prm`, plus the LPASS macro codecs (`snd_soc_lpass_*`) |
| Machine binding | none — there is no machine driver or ACPI/DT description for *this* laptop |

## Current state

The kernel has the pieces as modules and loads them, but nothing describes how they are wired
together on this board, so the DSP never comes up and the SoundWire codecs are never instantiated:

    qcom-apm gprsvc:service:2:1: CMD timeout for [1001021] opcode
    qcom_pmic_glink / q6apm: present, no machine driver to bind them

There is no sound card: `aplay -l` lists nothing, and `/proc/asound/cards` is empty.

## What is needed

A machine description that ties together the SoundWire links, the WSA884x amplifiers and the LPASS
macros for this board — on Qualcomm laptops that is usually an **ACPI machine driver** (a new
`acpi_match_table` entry plus the topology), because these machines ship with ACPI tables rather
than a device tree for the audio side. That is upstream work: it is the same shape as the existing
`x1e80100` machine drivers, extended for Glymur, and it is not something this repository can produce
by patching a config or rebuilding a module.

## Evidence we already have

- `notes/2026-09-16-hermes-audio-state.md` — the state dump from the machine
- `BRINGUP/NEXT-STEPS.md` item 3 — the plan and its size ("blocked, upstream, biggest single win")

## Verify

    aplay -l
    cat /proc/asound/cards
    journalctl -k -b 0 -o cat | grep -iE 'q6apm|apm|soundwire|wsa884x|lpass' | tail

## Bluetooth audio (a different path)

Bluetooth *audio* is a userspace matter (BlueZ + PipeWire) and does work as far as the transport is
concerned, once both ends are paired. This page is about the internal speakers.

---

## The three steps that actually produced sound (2026-10-03, working)

Recorded from the message that supplied it. This is the first configuration on this machine
that has produced audio, and it is much simpler than the bring-up path that preceded it.

1. **Run the latest Debian `qcom-firmware-extractor`.** It pulls the ADSP and related blobs out
   of the Windows install into `/lib/firmware/qcom/glymur/` (plus `ASUSTeK/UX3607OA/` with
   `qcadsp8480.mbn`, `qccdsp8480.mbn`, `adsp_dtbs.elf`, `cdsp_dtbs.elf`).

2. **Run the second script it comes with**, then **copy the topology by hand** to
   `/lib/firmware/qcom/glymur/GLYMUR-ASUS-Zenbook-A16-UX3607OA-tplg.bin`. The manual copy is
   not optional in practice: the machine driver requests that exact name and will not find
   anything named otherwise.

3. **Take the UCM profile for this machine from Konrad Dybcio's branch**, not from the generic
   Qualcomm profile and not from another project's tweak tree:

   ```bash
   git clone https://github.com/quic-kdybcio/alsa-ucm-conf --branch=topic/zenbooka16
   cd alsa-ucm-conf/ucm2/Qualcomm/glymur
   sudo cp *.conf /usr/share/alsa/ucm2/Qualcomm/glymur/
   ```

### Why the earlier attempts failed

- The profiles shipped by `alsa-ucm-conf` for `Qualcomm/glymur` are the **X1E80100 reference**
  (`GLYMUR-CRD`), not this laptop. They import, but they do not match this card's PCM layout.
- Installing a profile from another project's tweak tree (`GLYMUR-A16.conf` obtained elsewhere)
  did not produce sound either.
- The card is matched on its ALSA id `GLYMURASUSZenbo` (short) while the driver name is
  `GLYMUR-ASUS-Zenbook-A16-UX3607O`, so any profile has to be reachable under both.

### What the machine had to be right for this to work

- SoundWire enumerates **four WSA8845 amplifiers** (`sdw:1:0:0217:0204:00:{0,1}`,
  `sdw:4:0:0217:0204:00:{0,1}`) and two masters (`sdw-master-1-0`, `sdw-master-4-0`).
- The ADSP remoteproc is running and PDR delivered `msm/adsp/audio_pd`.
- The card exposes `MultiMedia2 Playback`; before any profile is applied it fails with
  `ASoC: no backend DAIs enabled for MultiMedia2 Playback`, and playback opens fail `-22`.

**Do not install a `wsa-mix-boost.service` or a saved `asound.state` from a tweak tree.** One
such service pushes all four WSA mix digital volumes to 90 (+6 dB) pre-amplifier, which is a
speaker-damage risk and is not needed for audio to work. The working enable sequence runs the
codec digital volumes at 81/77 (about 0 dB).
