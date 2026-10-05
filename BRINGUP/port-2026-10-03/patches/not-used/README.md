# Patches deliberately not applied

Anything in this directory is NOT part of the port. It is kept because it was tried, and
because the reason it was dropped is worth not re-deriving.

## 0003-dp-panel-hbr3.patch -- retired by test

Forced HBR3 link rate on the internal panel. The panel comes up without it, so it was
retired rather than carried. Keeping it would be carrying a change nothing needs.

## 0009-dp-external-rate-and-failed-enable-guard.patch -- split, and half of it is carried

This file holds two changes. **The `dp_display.c` half is in the built kernel** and is now
carried as `0009-dp-failed-enable-guard` in the port's set — the proof run in
`../../evidence/2026-10-05-patch-set-proof.txt` found it there while the set claimed the
whole file was unused. Only the `dp_panel.c` half stays here: it collides with `0012`,
because both edit `drivers/gpu/drm/msm/dp/dp_panel.c` around the same region (0009 aims at
~line 196, 0012 inserts the `a16_dp_cap_external_rate` parameter at ~187-199). So it can
only be applied before `0012`, or not at all, and the external monitor works with `0012`
alone.

Ordering matters even for the patches that ARE carried: see readme section 2 for the order
the verified set is applied in.

## The verified set is whatever is in patches/ itself

`build.sh` applies `patches/[0-9]*/*.patch` from the repository root, so the numbered
folders in `../../../../patches/` ARE the port's patch set — nothing here can drift out of
sync with what gets built.
