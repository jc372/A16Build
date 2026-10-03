# Battery, charge control and the power key

**State: working, and nothing here was ever broken.** No patches or module builds.

## What is present

| | |
|---|---|
| Fuel gauge | via `pmic_glink` / `qcom_battmgr`, on the SPMI PMIC |
| Charge control | conservation mode, reported through the same path |
| Power key | `pm8941_pwrkey` / `qcom_pon` |

Observed values on this machine: conservation mode set to 75–80 %, charge ~81.8 %, health 95 %,
42 cycles, pack temperature ~30 °C.

## The `capacity` attribute that is absent by design

An early reading of this component concluded "the battery gauge is silent" because
`/sys/class/power_supply/*/capacity` did not exist for the X1E80100-class property set that this
machine's `qcom,glymur-pmic-glink` driver advertises. That was wrong, and the correction is the
useful part: **a missing sysfs file is not a broken subsystem.** `upower` derives the percentage
from the properties that *are* exposed, and it was already showing it:

    upower -i /org/freedesktop/UPower/devices/battery_*      # percentage present


## Verify

    upower -i $(upower -e | grep battery) | head -20
    ls /sys/class/power_supply/
    cat /sys/class/power_supply/*/status /sys/class/power_supply/*/capacity 2>/dev/null

`BRINGUP/tools/a16-power-watch.sh` samples the gauge over time and writes a log, which is what to
run if charge behaviour ever looks wrong.

## The power key

Works, and is what makes a wedged machine recoverable without pulling the battery: a short press
shuts down cleanly, a long press cuts power.
