# 0002-dts-ec-node

Konrad Dybcio's patch **3/3** from `[PATCH v3 0/3] Asus Zenbook A16/A14
(UX3607OA/UX3407NA) EC driver`, 2026-09-23. Copied in verbatim, mail headers and all,
so the file is exactly what he posted rather than our re-typing of it.

Adds the embedded controller node to the board DTS: `embedded-controller@76` on
`&i2c9`, compatible `asus,zenbook-a16-ux3607oa-ec`, interrupt on `tlmm 66`,
`ec_int_n_default` pinctrl, `wakeup-source`.

## Result

Live in the running kernel. `/proc/device-tree` carries the node with its compatible,
and the controller answers on the bus:

    i2c 9-0076   -> driver asus-glymur-ec
    i2c 9-005b      EC subdevice
    hwmon4          name=asus_glymur_ec
    led             /sys/class/leds/asus::kbd_backlight

Verified that this patch produces the built tree's DTS byte for byte, so replacing our
own version of the node with his changed nothing that was already tested.

## Evidence

`../asus-zenbook-a16-a14-ec-v3/evidence/FINAL-RESULT.txt` — machine, bindings, readings, and the
suspend/resume exchange with its timings.
