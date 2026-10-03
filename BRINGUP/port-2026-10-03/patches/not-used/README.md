# Patches deliberately not applied

Anything in this directory is NOT part of the port. It is kept because it was tried, and
because the reason it was dropped is worth not re-deriving.

## 0003-dp-panel-hbr3.patch -- retired by test

Forced HBR3 link rate on the internal panel. The panel comes up without it, so it was
retired rather than carried. Keeping it would be carrying a change nothing needs.

## 0009-dp-external-rate-and-failed-enable-guard.patch -- conflicts with 0012

Both edit drivers/gpu/drm/msm/dp/dp_panel.c around the same region (0009 aims at ~line 196,
0012 inserts the a16_dp_cap_external_rate parameter at ~187-199). So 0009 can only be applied
before 0012, or not at all -- and the external monitor works with 0012 alone, so it is not
at all.

Ordering matters even for the patches that ARE carried: see readme section 2 for the order
the verified set is applied in.

## The verified set is whatever is in patches/ itself

build.sh applies patches/*.patch by glob, so this directory listing IS the port's patch set.
Nothing here can drift out of sync with what gets built.
