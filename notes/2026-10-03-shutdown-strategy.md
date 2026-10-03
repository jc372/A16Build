# Shutdown strategy: a power cycle instead of suspend (2026-10-03)

Chosen by the operator after two days of suspend/resume work: **stop chasing sleep/wake**. This
platform boots in under 20 seconds, so a power cycle is cheaper than the fight.

    lid closed   -> poweroff
    power button -> poweroff

Both are logind policy (`/etc/systemd/logind.conf.d/50-a16-lid.conf`, written by
`BRINGUP/tools/a16-power-policy.sh`):

    HandleLidSwitch=poweroff
    HandleLidSwitchExternalPower=poweroff
    HandleLidSwitchDocked=poweroff
    HandlePowerKey=poweroff

`HandlePowerKey=poweroff` is logind's own default and was already in force; the earlier `ignore`
(added for the suspend tests — a power key that only woke the machine) **must not be left in place**,
which is exactly what `power apply` rewrites. `power revert` restores lid=suspend if wanted.

Run it as: `sudo bash ~/a16.sh power apply|status|revert`.

## Why a shutdown is the right answer here

- The shutdown path is *clean*: systemd stops the session, so app state is saved on the way out.
- Nothing in the policy depends on the fragile parts: no MHI/QRTR resume (`-110`), no radio loss on
  the first resume, no `deep` one-way trip, no PCI wakeup arming.
- The failure that cost the most time was never the panel: it was the *session* (see
  `notes/2026-10-03-session-manager-trap.md`). Suspending only ever created more chances to hit it.

## "Have GNOME reopen apps like Mac does" — what is actually available

There is **no session restore on this stack**: `org.gnome.SessionManager` in this gnome-session has
no `auto-save-session` key (checked on the machine: "No such key"), and GNOME's session-saving (the
X11 session-manager protocol) does not apply to Wayland sessions anyway.

What does work today, with no extra tooling:

- apps that save their own state: Firefox/Chrome tabs, GNOME Text Editor tabs, Files windows;
- GNOME's "Startup Applications" (`gnome-session-properties`) for a fixed set you always want.

The Mac-like "reopen what was open" needs a small tool of our own, and it is now built:
`BRINGUP/tools/a16-session-apps.sh` (`a16-session-apps save|list|restore|install|uninstall|status`).

- **Shutdown hook**: a *user* unit (`a16-session-apps-save.service`, `WantedBy=graphical-session.target`,
  **`After=app.slice`**) queries the running apps on the way down — logout, reboot, or the new
  lid/power-button poweroff. The ordering *is* the mechanism: systemd stops units in reverse start
  order, so starting after `app.slice` means our snapshot is taken **before** the session's apps are
  killed, which is what makes a plain "query at shutdown" reliable. A 60 s timer is written but
  **not enabled** (`install --with-timer` only): it is a fallback for the case where a teardown still
  beats the hook, and the log line "nothing running -- kept the previous list" is how you know.
- **Startup after login**: an XDG autostart entry (`a16-restore-session.desktop`) runs `restore` 10 s
  after login and reopens the apps, skipping any that are already running.
- **How apps are found**: gnome-shell's per-app units (`app-gnome-<id>-<pid>.scope`), filtered to ids
  that have a desktop entry that does *not* set `NoDisplay=true`/`Hidden=true`. That one rule is what
  separates the operator's apps from session plumbing (`org.gnome.Evolution-alarm-notify`,
  `update-notifier`, `snap-userd-autostart`), with no hardcoded list.
- An empty snapshot never overwrites a good list (a teardown race cannot wipe it); `save --force`
  overrides when every app really was closed.

The tool is independent of the power policy above: it works with any way of shutting down.

## Login recovery, one line

The black screens have two causes, both non-display (the panel reports `connected`/`enabled`
throughout):

1. **Orphan user manager** — a `systemd --user` for `jc` started by an SSH login (no seat) before the
   graphical login. GNOME reuses it and the graphical session dies inside it. Rule: do not sit in an
   SSH session as `jc` while logging in at the greeter.
2. **Inactive greeter session / panel on the wrong VT** — a running compositor whose session is not
   the seat's active one paints nothing; the panel can also simply be showing tty3 instead of the
   greeter's tty1.

`sudo bash ~/a16.sh login` handles both in one go: ends the seat-less `jc` sessions, restarts `gdm3`,
activates the greeter's session and switches the panel to its VT. If the screen is still dark, entry
[1] (firmware framebuffer) always gives a visible console.
