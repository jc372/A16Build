# Retired: the ath12k resume patch set (2026-10-03)

Moved here: 0014, 0015, 0016, 0017, 0018 (ath12k), 0021 (ath12k power-cycle),
and a16-install-ath12k-resume-fix.sh.

Why: these existed to keep Wi-Fi alive across suspend/resume on the older kernel.
On linux-next next-20261002 the suspend path runs without them, and this machine does
not enter a real low-power state anyway (see below), so they have no justification left.
None of them is in any build of the current port.

Measured on -edp1-bt2, 2026-10-03:

    16:57:47  PM: suspend entry (s2idle)
    16:59:04  Freezing user space processes ... completed
    16:59:04  PM: suspend exit

s2idle runs and thaws cleanly, but the fans keep running and the keyboard stays lit --
the SoC never enters its low-power state. /sys/power/mem_sleep shows "[s2idle] deep";
deep is offered but not selected. So the reported "suspend is fixed in linux-next" is not
confirmed on this machine: the software path works, the silicon transition does not happen.

Side effect worth remembering: a16-install-ath12k-resume-fix.sh wrote
    /etc/modprobe.d/a16-ath12k.conf -> options ath12k a16_skip_global_reset_on_resume=Y
which upstream ath12k does not understand ("unknown parameter ... ignored"). That file was
removed separately. Do not re-run the installer unless the patched ath12k comes back.

To un-retire: the patches are unmodified; moving them back and re-testing each against its
own symptom is the same procedure as any other patch in this directory.
