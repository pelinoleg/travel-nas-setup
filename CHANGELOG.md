# Changelog

Significant changes to travel-nas-setup. Newest first.

## Unreleased

- Power-aware governor switching: NetworkManager hook detects home/field WiFi and
  toggles CPU governor + heavy Docker apps. Configurable via
  `/etc/travel-nas/power-mode.conf`.
- Telegram bot listener: `/status`, `/backup`, `/logs`, `/reboot`, `/shutdown`
  commands via long-polling. Auth by `TG_CHAT_ID`.
- microSD wear monitoring: reads `/sys/block/mmcblk0/device/life_time`, alerts
  via Telegram at >70 %.
- Status LED helper: photo-backup blinks the Pi power LED during sync,
  solid green when done, fast blink on error.
- Backup verification: photo-backup writes to `<name>.incomplete` and renames
  on success; orphan incompletes >24 h old are reported in daily summary.
- First-boot wizard: `travel-nas-setup` helper command + motd hint after a
  clean PiOS install.
- Refactored `setup.sh` into `lib/common.sh` + `modules/NN-*.sh`.

## 2026-05-27 — dashboard polish

- Fixed Network card SSID overlapping IP — explicit positioning below IP,
  cards heightened by 6–8 px.
- Added desktop shortcuts: **Travel-NAS Setup** (re-fetches latest installer
  from GitHub), **T7 Files**, **Edit Services**.
- Added **Exit to desktop** button in Menu and matching
  **Travel-NAS Dashboard** desktop shortcut for round-trip.
- T7 mount: interactive whiptail disk picker + ext4 format wizard for fresh
  installs (auto-detects existing label `t7` on re-runs).
- Restored Photoview install, switched mount to `/mnt/t7:/t7:ro` so the UI
  can browse any folder under T7.
- Added YT-Archiver install block (`/var/lib/casaos/apps/ytarchiver/`),
  backend port 8000 dropped from compose to avoid conflict with Photoview.
- `/etc/travel-nas/services.conf` is now user-owned so editing without sudo
  works.
- `/mnt/t7` and all subdirs chowned to install user; `rsync --chown=oleg:oleg`
  in photo-backup and nas-backup so new files inherit user ownership.
- Menu grouped into NAS / INFO / SYSTEM sections with coloured dividers.
- New dashboard pages:
  - **NAS status** — per-module size, last run, ok/warn/fail dot
  - **Today** — daily-summary preview with Pi 5 throttle/under-voltage flag
  - **Services** — list from `/etc/travel-nas/services.conf` with `{host}`
    and `{ip}` substitution
- Hourly `nas-backup-status.timer` and 10-minute `daily-summary-refresh.timer`
  keep JSONs warm for the dashboard.
- Card backgrounds tinted (green for active backup, orange for AP mode) so
  state changes are obvious.
- Fixed rsync `\r` progress writer (was only catching the final 100 % line).
- pcmanfm auto-mount popup disabled — was stealing focus from the kiosk
  when an SD card was inserted.
- Auto-sleep honesty note: on MHS35 (`fb_ili9486`) backlight is hardwired to
  5 V, dashboard blanks the picture but the LED stays on. Software fallback
  via `/sys/class/backlight/*/bl_power` + `xset dpms` is in place for boards
  that support it.

## 2026-05-26 — initial dashboard + watchdog hardening

- Disk-watchdog: tolerate `-d sat` SMART failure on USB-bridged T7 by
  caching the working `-d` flag in `/var/lib/travel-nas/smart-type.txt`.
- zram: skipped if PiOS' built-in zram service already running.

## Earlier — bootstrap

- Photo-backup via udev + rsync + Telegram. flock-protected. Auto-umount on
  finish. T7-UUID guard so it never copies onto itself.
- restore-pi-config.sh — pulls latest config snapshot from T7 onto a fresh
  microSD.
- /mnt/ path convention (not /media/), devmon ignore-list for T7, Samba
  mountpoint check.
- Initial Pi 5 + Samsung T7 setup with whiptail menu, modular components.
