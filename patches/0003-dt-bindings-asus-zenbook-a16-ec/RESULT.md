# 0003-dt-bindings-asus-zenbook-a16-ec

Konrad Dybcio's patch **1/3** of the same series. Verbatim, as posted.

Creates `Documentation/devicetree/bindings/embedded-controller/asus,zenbook-a16-ux3607oa-ec.yaml`.

It is documentation, so it changes nothing in the built kernel — it is here because it
is one third of the series, and a `Tested-by` on a series should mean the series was
applied, not two thirds of it.

## Result

Nothing to record on hardware.

## Evidence

None needed. If the series is submitted again it is worth running
`make dt_binding_check DT_SCHEMA_FILES=...` to confirm the binding still validates, which
has not been done here.
