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
