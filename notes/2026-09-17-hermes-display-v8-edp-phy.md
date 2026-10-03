# Display, 2026-09-17 — the eDP failure is an upstream PHY bug, and the fix is posted but unmerged

Short version: the black screen on entries [3]/[4] is **not** a device-tree problem and **not** a
config problem any more. It is an upstream bug in the **v8 eDP PHY** programming sequence
(`drivers/phy/qualcomm/phy-qcom-edp.c`), Qualcomm posted a two-patch fix for it on 2026-06-22, and
that series is **still sitting in review — it is in no kernel, including the newest linux-next.**
We have now carried it locally and built the module.

## The bug, in upstream's own words

`[PATCH 0/2] phy: qcom: edp: Update v8 programming sequence` — Bjorn Andersson (Qualcomm),
2026-06-22, `<20260622-glymur-edp-phy-v1-0-814b45089ac9@oss.qualcomm.com>`:

> The programming sequences introduced for v8 doesn't work other than for 4-lane 8.1Gbps.
> For 2-lane 5.4Gbps link training fails and for 2.7 and 1.62Gbps PLL lock isn't reached.

> With these changes the v8 PHY has been validated to lock at 1.62, 2.7, 5.4 and 8.1 Gbps, using
> both 2 and 4 lanes. Link training now succeeds on 4-lane 8.1Gbps and 2-lane 5.4Gbps.

That is our failure, exactly. Our panel advertises **HBR2 (5.4 Gbps) as its maximum**, so `msm`
correctly picks HBR2 — the one rate v8 does not do correctly — and link training #2 never converges
(`link training #1 on phy 0 successful` → `#2 ... failed. ret=-110`, 4 lanes, pixel_rate 709633).

Independent confirmation on a *second* A16 (same model): a rate sweep (linux-next next-20260803)
found RBR/HBR fail clock recovery, HBR2 passes CR and fails EQ, **HBR3 trains and the panel lights**,
i.e. the only working rate is the only one upstream says works — and that same report notes the
panel's advertised max (HBR2) cannot carry its own preferred mode at 10 bpc. Reported, not patched:
`glymur eDP PHY (v8): link trains only at HBR3, all lower rates fail`, 2026-08-08.

And the fix was verified on this hardware model by a third party, on top of next-20260819:
`rate=540000, num_lanes=4, bw_code=0x14`, `2880x1800 @ 120Hz, 24bpp` — "panel trained natively".

## Merge status (checked 2026-09-17)

| item | status |
|---|---|
| newest upstream | mainline `7.3-rc3` (2026-09-13); linux-next `next-20260916` (2026-09-16) |
| our pin | `next-20260914` (`7.3.0-rc3-next-20260914`) — two days behind, nothing display-related changed |
| the v8 PHY series | patchwork **`changes-requested`** (series 1114965, v1 of 2026-06-22) — **not merged** |
| `dp_display.c`, `dp_ctrl.c`, `dp_panel.c`, `phy-qcom-qmp-combo.c`, mainline vs our tree | byte-identical — nothing new to pick up |
| the A16 `.dts` upstream vs our pin | one line (`qcom,dmic-sample-rate` 2400000 → 4800000) — nothing display-related |

So: updating the kernel would change nothing for the panel, and the DT is not the lever either — the
board file we boot is upstream's own (it builds to the DTB this machine has been booting), and the
panel node, `aux-bus`, `enable-gpios` (TLMM 18), `VREG_EDP_3P3` and the four `link-frequencies` are
all already correct. **Keep the DT boot (internal input depends on it) and fix the PHY.**

## What we did (2026-09-17)

1. Fetched the series verbatim from the linux-phy list archive and committed it as
   `BRINGUP/patches/0006-…-split-power-on-sequencing-by-phy-version.patch` and
   `BRINGUP/patches/0007-…-v8-power-on-programming-sequence.patch` (507 insertions / 68 deletions
   in one file; patch 0007 applies on top of 0006).
2. Reverted our own `0005` experiment (the `TXn_TRAN_DRVR_EMP_EN 0x5f` trial) in the build tree —
   the upstream sequence keeps writing `0x01` there, so that experiment really was not the lever.
3. Applied 0006 + 0007 to `~/build/linux-next-1a1de54f7369` and rebuilt **natively** —
   1.9 s incremental, one file:
   `make -C ~/build/linux-next-1a1de54f7369 ARCH=arm64 LOCALVERSION=-next-20260914 -j$(nproc) M=drivers/phy/qualcomm modules KBUILD_MODPOST_WARN=1`
4. Verified the artifact and froze a copy:

```
~/a16-payload/phy-qcom-edp-v8fix.ko   1 285 040 bytes
sha256                                15e0d556e4e988a1b244af167668562e9ee3a6db8a3989867732e700c20152eb
vermagic                              7.3.0-rc3-next-20260914 SMP preempt mod_unload modversions aarch64
module_layout CRC                     0xe6658f7b   (= the running kernel's)
imports with versions                 40
binds                                 of:N*T*Cqcom,glymur-dp-phy
carries                               qcom_edp_prepare_power_on_v8, qcom_edp_ldo_config_v8,
                                      qcom_edp_finish_power_on_v8, qcom_edp_configure_tx_pre_pll_v8_lane
```

The committed patches, applied to the pristine file, reproduce the compiled source byte for byte
(`sha256 2ab845746deaa8613e1381e23a7528abcbf8aa5637c6783c3975e8851b48dc03`).

## Next step, one command

```
sudo bash ~/A16Build/BRINGUP/tools/a16-install-gpucc-module.sh ~/a16-payload/phy-qcom-edp-v8fix.ko
# then reboot and pick [3] (msm + panel enabled), wait ~90 s
```

What each outcome means:

- **Panel lights, 2880x1800 with refresh choices, `/sys/class/backlight/dp_aux_backlight` present** →
  the fix is confirmed on this unit too. Brightness (slider) and refresh-rate control now work;
  the Fn brightness keys still need the EC, which `acpi=off` has no driver for.
- **Still dark, log shows `link training #2 ... failed. ret=-110`** → the PHY sequence was not the
  whole story on this unit; next levers are, in order: the `PUSH_IDLE` guard (`patches/0008`, built
  into `msm.ko`) so a failed enable cannot silently reset the SoC, then forcing HBR3 (the rate the
  other A16 owner proved lights this panel).
- **Backlight device missing but panel lit** → same root cause family; capture
  `~/a16-payload/boots/<newest>/` before anything else (the 45 s snapshot unit runs in every boot).

Reverting is `rm /lib/modules/<ver>/updates/a16/phy-qcom-edp.ko && sudo depmod -a` (entry [2]
blacklists the module anyway, so the working entry is unaffected either way).

## Also worth knowing (same machine, separate upstream reports)

- `drm/msm/dp: skip PUSH_IDLE when the link was never enabled` — 14 lines in `dp_display.c`
  (**not merged**, but `Reviewed-by: Dmitry Baryshkov` on 2026-09-13). On glymur a failed eDP enable
  followed by any disable path makes TrustZone force-stop SOCCP/ADSP and the SoC **resets silently**
  ~50 ms later. Committed here as `patches/0008`; needs `msm.ko` rebuilt to take effect.
- `phy-qcom-qmp-combo: com_aux enable fails on a DP-only instance` — the `gcc_usb3_tert_phy_com_aux_clk
  status stuck at 'off'` line in our own dark-boot logs. That is the **external** DP/HDMI PHY, not the
  panel; a display plugged into HDMI can wedge the session (`msm_dp_aux_transfer` never times out).
  Not merged; a separate thread of work.
- The USB-C/HDMI DP path also wants the in-review `qmp-combo` HPG PLL series (2026-08-28, v3) —
  "DP link training completes successfully on Glymur" once applied.
