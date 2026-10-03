# Input — keyboard, touchpad, touchscreen, stylus

**State: working.** Nothing to patch; this is also why the machine is usable even when the display
is not (input does not depend on the display stack at all).

## The devices

    N: Name="gpio-keys"
    N: Name="Asus Keyboard"                     # internal keyboard, via the ASUS HID glue
    N: Name="hid-over-i2c 093A:3012 Mouse"      # touchpad
    N: Name="hid-over-i2c 093A:3012 Touchpad"
    N: Name="hid-over-i2c 04F3:4645"            # touchscreen (plus its Stylus entry)

All of it is I2C-HID or USB-HID, so it works identically whichever display option is in use
([boot-options.md](boot-options.md)).

## Verify

    grep -E '^N: Name=' /proc/bus/input/devices
    ls /dev/input/by-path/ | head

## Function keys

The machine boots with `acpi=off`, so the embedded controller has no driver and none of the
EC-mediated function keys exist as input devices:

    grep -l KEY_BRIGHTNESS /sys/class/input/*/device/capabilities/* 2>/dev/null   # empty

That is why brightness has to be set from the desktop (the slider writes through
`/sys/class/backlight/dp_aux_backlight`, see [display-edp.md](display-edp.md)) rather than with
Fn keys. An EC driver binding under these conditions would be the fix; it is ACPI work and not
started.

## Related

Suspend and resume would have to keep this input path alive; see [suspend.md](suspend.md).
