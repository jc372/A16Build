# Session apps, and what "something is open" looks like on this image (2026-10-03)

Everything below was read off the live machine while the apps were actually running — every form in
the table was a guess that was wrong until it was tested. `BRINGUP/tools/a16-session-apps.sh`
(`bash ~/a16.sh apps …`) is the tool that consumes this.

## How a running app appears

| app family | unit (all in the **user** manager) | id → desktop entry |
|---|---|---|
| native, launched by the session | `app-gnome-<desktop-id>-<pid>.scope` | `<desktop-id>`, e.g. `org.gnome.Nautilus` |
| native, newer form | `app-<desktop-id>@<token>.service` | `<desktop-id>` |
| D-Bus activated (the terminal!) | `app-dbus\x2d:1.NN\x2d<bus-name>.slice`, with `dbus-:1.NN-<bus>@0.service` inside | **the bus name is the desktop id**, e.g. `org.gnome.Ptyxis` |
| snap | `snap.<snap>.<app>-<uuid>.scope` — **dash**-separated UUID, not the `<snap>.<app>.<hash>` I assumed | `<snap>_<app>`, the exported name, e.g. `firefox_firefox` |

Facts that cost time, recorded so they are not re-learned:

- **Snap app scopes live in the *user* manager here**, not the system one (the system manager has only
  `init.scope` and the session scopes). Seen: `snap.firefox.firefox-9bb5bb7b-323a-4f83-bb07-57a0b6da9de4.scope`.
- `snap-<name>-<rev>.mount` units are **mounts, not apps** — the query is narrowed to `.service`/`.scope`.
- **`org.gnome.Shell.Introspect.GetWindows` returns `AccessDenied`** ("GetWindows is not allowed"),
  so GNOME's own window list is not a usable source. Units are the only source available.
- The filter is **a real desktop entry that does not set `NoDisplay=true`/`Hidden=true`**, searched in
  `~/.local/share/applications`, `/usr/local/share/applications`, `/usr/share/applications`,
  `/var/lib/snapd/desktop/applications`, the flatpak exports and `${XDG_DATA_DIRS}/applications`.
  That one rule drops `org.a11y.atspi.Registry`, `org.freedesktop.FileManager1`,
  `org.gnome.OnlineAccounts`, `org.gnome.Identity`, `org.gnome.NautilusPreviewer`,
  `org.gnome.Evolution-alarm-notify`, `update-notifier` and `snapd-desktop-integration` with **no
  blocklist**, while keeping `org.gnome.Ptyxis` and `firefox_firefox`.
- The snapshot stores the **desktop id** (the desktop file's basename), which is exactly what
  `gtk-launch <id>` wants on restore.
- **Shutdown ordering is the mechanism, not a timer**: the hook unit is `After=app.slice`, so it is
  stopped *before* the session's apps are killed and the plain "query at shutdown" sees them.

Verified live at the time of writing: `apps list` → `firefox_firefox` + `org.gnome.Ptyxis`, with
firefox and the terminal open.

## Login recovery (unchanged from the trap note, repeated here because it is what a black screen means)

Two non-display causes, both ending in a black screen with the panel reporting `connected`/`enabled`:

1. **Orphan user manager** — a `systemd --user` for `jc` started by an SSH login (no seat) before the
   graphical login; GNOME reuses it and the graphical session dies inside it
   (`Failed to start org.gnome.Shell@ubuntu.service`, `gdm-authd … ServiceUnavailable`).
   Rule: do not sit in an SSH session as `jc` while logging in at the greeter.
2. **Inactive greeter session / panel on the wrong VT** — a running compositor whose session is not
   the seat's active one paints nothing (`c2 … tty1 Active=no` while the panel showed `tty3`).

One line for either: `sudo bash ~/a16.sh login` (ends the seat-less `jc` sessions, restarts `gdm3`,
activates the greeter's session, switches the panel to its VT).

## Next steps (operator's list, 2026-10-03)

**1. Fix the trap permanently** — a `pam_exec` *session* hook in gdm's PAM stack. Available here:
`/etc/pam.d/gdm-password`, `gdm-autologin`, `gdm-launch-environment`, `gdm-authd` absent,
`pam_exec.so` present. Design: `session optional pam_exec.so <sweep>` placed **before** the
`@include common-session` that pulls in `pam_systemd`, guarded on `PAM_USER=jc`, running the same
sweep as `login`. `optional` means a broken or missing script can never block a login. Must be built
with a backup of every file it touches and a test login before it is relied on.

**2. Clean up the git** — inventory at the time of writing: `main` (clean, in sync), plus the older
`bringup-2026-09-16` (tip `8b75b68`) and `feature/tumbleweed-a16-live-iso` (tip `db8fa1f`), and the
`archive/2026-09-16-pre-bringup/` tree. Decide what is history worth keeping vs. noise; the run of
small fix commits from this session (`91e651c`, `5f9aee2`, `ad35a1b`, `06ee8e3`, `bf56a40`, `1b8c5a6`,
`af553ff`) is squashed-able if the operator wants a tidier log.

**3. Clean up the boot entries** — the menu as the machine actually has it (read from
`/boot/efi/EFI/ubuntu_snapdragon/grub.cfg`, `GRUB_DEFAULT=3`; the `[N]` are part of the titles):

| title | contents (verified) | fate |
|---|---|---|
| `[0]` installed Ubuntu 7.2 staged on the … | the original install | **REMOVE** — superseded |
| `[1]` 7.2 + glymur DTB, internal input | blacklist + modprobe.blacklist | **REMOVE** — superseded by [2] |
| `[2]` next 7.3 + glymur DTB, panel left … | blacklist, panel via the firmware framebuffer | **KEEP — this is THE failsafe, the entry the operator uses when [3] fails.** Directions: an earlier revision of this note said to drop it; that was wrong. |
| `[3]` next 7.3 + glymur DTB, full display attempt | `drm.debug`, no blacklist | **KEEP** — the entry in daily use |
| `[4]` next 7.3 + DTB, msm enabled but panel PHY unmanaged | blacklist | **REMOVE** — superseded by [3] |
| `[8]` 7.3 + glymur DTB + Bluetooth serial (two entries, same label) | blacklist | **REMOVE** — belongs to the `feature/tumbleweed-a16-live-iso` work; confirm before deleting |

All the blacklist entries share one set:
`module_blacklist=msm,dispcc_glymur,gpucc_glymur,videocc_glymur,phy_qcom_edp,panel_samsung_atna33xc20`
(plus `modprobe.blacklist=msm`); `[3]` is the only one that does not blacklist.

**Add one more: a command-line-only entry**, built on **[2]'s** proven set (not [1]'s — [2] is the
one known to give a visible screen and a working keyboard here):

```
[2]'s blacklist set, unchanged          # panel via the firmware framebuffer: a visible console
systemd.unit=multi-user.target          # no GNOME, no gdm: a plain interactive console
# ath12k is NOT blacklisted, and NetworkManager starts in multi-user.target, so Wi-Fi comes up too
```

**REQUESTED 2026-10-03 (later the same session): "clean up the grub entries."** This lifts the
earlier deferral — *"do not touch the boot menu for efi, though it needs to be cleaned up later"* —
and the cleanup has **not been run yet**: it is the operator's line, and nothing in a Hermes session
has root.

    sudo bash ~/a16.sh grub plan      # read-only: the current menu and every change it would make
    sudo bash ~/a16.sh grub apply     # timestamped backup -> generate -> grub-script-check -> install

What `apply` does: drops `[0]`, `[1]`, `[4]` and both `[8]` blocks; keeps `[2]` (failsafe) and `[3]`
(in use) — and, because a kernel-args scan cannot see them, **`[5]` (stock Ubuntu path), `[6]`
(diagnostics) and `[7]` Windows Boot Manager stay in place** ([7] stays regardless); adds `[9]`
(command line only: `[2]` + `systemd.unit=multi-user.target`, whose display-only blacklist keeps
keyboard/touchpad/USB/ath12k, so Wi-Fi comes up). `set default` is rewritten **by title** to keep
landing on `[3]`; the old index-based `default=3` would have followed the pruning onto a different
entry. Verified end to end against a scratch copy (`grub-script-check` PASS) before this request.

ESP baseline for comparison and rollback (before any run):
sha256 `9fd7d5f51802f2f95085e50b6ed1e46df228babcffe58557f28b8c5784ea320b`, 10 menuentries,
`set default=3`. `sudo bash ~/a16.sh grub restore <backup>` undoes it, and every write is preceded by
a timestamped backup in `/boot/efi/EFI/ubuntu_snapdragon/`.

`power apply`/`revert` are the only other boot-time writers in this session.
