# The session-manager trap: a black screen *after* login is not a display problem

Date: 2026-10-03. Machine: A16 (Zenbook A16 UX3607OA, glymur/X2E). Cost: most of a morning,
plus a long detour through GRUB entries, module builds and kdump that were all innocent.

## The symptom, exactly

  * The GRUB menu shows, the kernel boots, the console text scrolls, the **greeter appears**.
  * You log in: the screen goes **grey**, then **black**. No desktop. Sometimes a `systemctl
    restart gdm` gets you in, which makes it look like a display or modeset problem.
  * SSH still works, so the machine looks "up but headless".

## The mechanism

`systemd --user` is **per user**, not per session. We initially blamed an SSH login; live evidence on 2026-10-03 found the persistent trigger: `loginctl show-user jc` reports `Linger=yes`, `/var/lib/systemd/linger/jc` exists, and the `manager` session plus `user@1000.service` start at boot before the GDM greeter. That deliberately pre-starts the same user manager without a graphical seat, so GNOME can attach to a manager that predates its login. An SSH session for jc before graphical login can create the same conflict even after lingering is disabled.

The GDM/greeter journal signature is:

    gnome-shell: Will monitor session c<N>    <- greeter session
    gnome-shell: Failed to start gdm-authd verification ... PAM service gdm-authd was not found

Those lines appear in the greeter session; in the captured boot the actual user session later came up as session 3. Treat them as a clue, not alone as proof the user session failed. The decisive persistent precondition is the seat-less jc manager that starts before the greeter.

**Permanent policy:** disable linger for jc using `sudo bash ~/a16.sh gdmfix`. This removes the boot-time manager without killing the live desktop; take effect on the next normal shutdown/boot. The user manager and enabled `hermes-gateway.service` then start with jc's first login instead of before it. Log in locally before opening an SSH session as jc. The script logs and verifies `Linger=no` and that the linger marker is absent; it deliberately does not restart GDM.

`systemd --user` is **per user**, not per session. If a session for that user already exists
before the graphical login — an **SSH login**, which is exactly how you reach the machine to
debug it — its user manager is already running, seat-less and without the graphical session's
DRM access. GNOME's login then attaches to *that* manager, and everything the graphical session
needs fails inside it:

    systemd[2219]: Failed to start org.gnome.Shell@ubuntu.service - GNOME Shell.
    gnome-shell[12672]: Failed to start gdm-authd verification for user:
        GDBus.Error:org.gnome.DisplayManager.SessionWorker.Error.ServiceUnavailable
    gnome-shell[12892]: Unset XDG_SESSION_ID ... Asking logind directly
    gnome-shell[12892]: Will monitor session c3          <- c3 = the GREETER's session, not ours

GDM tears the login down, the shell exits with the wrong session, and you get grey → black. Then
you SSH in again to fix it, which **recreates the exact state that breaks the login**. That loop is
the whole bug, and it is why "the same issue" survived every reboot, every module change and every
GRUB entry in between.

Evidence that nailed it: `ps -o pid,lstart,cmd -p 2219` → `systemd --user`, started 08:37:23, i.e.
*by an SSH login*; the failures above carried the `systemd[2219]` prefix rather than the login's
own manager; and `loginctl list-sessions` showed the jc sessions with **no wayland session for the
graphical login** at all.

## The signature — recognise it in 30 seconds

Run these three before touching anything display-related:

    loginctl list-sessions                # is there a jc session with no seat? where is the wayland one?
    pgrep -a -u jc systemd                # how many user managers, and when did they start?
    journalctl -b | grep -E "org.gnome.Shell@|gdm-authd|XDG_SESSION_ID|Will monitor session"

If you see `Failed to start org.gnome.Shell@ubuntu.service`, `gdm-authd ... ServiceUnavailable`,
or `Will monitor session c<N>` (the greeter's session), it is **this trap** — not the display, not
the DRM module, not the GRUB entry, not the kernel command line.

## The rules (locked in)

1. **A session that exists before the graphical login breaks the graphical login.** Before logging
   in at the greeter, end every other session for that user — including the SSH connection.
2. **Never reach into the user session from the system context.** No
   `runuser -u jc -- env XDG_RUNTIME_DIR=/run/user/1000 DBUS_SESSION_BUS_ADDRESS=... busctl --user ...`
   from a root/system service: it creates and leaves behind exactly the orphan session state this
   bug is made of. The display hook's rung 1 did that, and `A16_ALWAYS=1` made it run on every
   resume — keep the hook at `conditional` (`sudo bash ~/a16.sh display hook conditional`) or
   remove it.
3. **"The login screen appears" proves only the greeter.** The greeter and the session are
   different stages: a greeter that paints and a session that dies looks exactly like a display
   failure and is not one. Check the greeter's session (`c<N>`) and the user's sessions separately.
4. **Check the unit names before concluding.** On this image the display manager is
   **`gdm3.service`** (`/etc/systemd/system/display-manager.service -> /lib/systemd/system/gdm3.service`);
   `systemctl is-active gdm` reports on the wrong unit and will mislead you.
5. **`drm.debug` and driver builds are innocent in this class.** They were chased for hours here;
   the greeter paints fine with `drm.debug=0x1fe`, and the failure was never in the DRM path.

## First aid (the two commands that resolved it)

    sudo systemctl start gdm3      # greeter back on the panel
    sudo chvt 1                    # if the panel is dark with the greeter running

then end the non-greeter jc sessions (`loginctl terminate-session <id>`, including the SSH one)
and log in at the panel. With no pre-existing user manager, the login creates its own, gets the
seat, and the shell comes up.

## Follow-up

`a16-display-outputs.sh` should refuse `display hook always` unless `A16_I_KNOW=1` is set (the same
guard the risky rungs elsewhere use), so the aggressive mode cannot be re-armed by a future session
that has not read this file.
