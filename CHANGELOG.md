# Changelog

Significant changes to travel-nas-setup. Newest first.

## 2026-05-28 — power-mode v2, flat menu, screenshot, NAS source size

### Dashboard

- **Flat menu** — одна страница с тремя секциями (NAS / INFO / SYSTEM+power)
  вместо hub + 3 sub-страниц. Power buttons (Normal/Saver/Auto) переехали в
  SYSTEM для частого доступа.
- **Top strip** — слева `up Xh Ym` вместо hostname, справа
  `power: [A·]<mode> <freq>GHz <W>W`. `A·` префикс синим — индикатор что
  система сама управляет режимом (pref=auto).
- **Storage card** — `Path.is_mount()` проверка перед `df` (раньше показывал
  цифры root-раздела при размонтированном T7). При not-mounted — большое
  красное `NOT MOUNTED`. % перенесён с левого края бара на правую сторону
  (не сливается с заливкой).
- **Last NAS backup card** (новая) — агрегатные данные: total local/source/%
  + статус (worst-of всех модулей). Без привязки к конкретной папке.
- **NAS status page** — формат `local / source` для каждого модуля. Жёлтым
  если local < 95% source + подпись `not fully copied`. Кнопка Refresh
  опционально дёргает `rsync --dry-run --stats` к NAS чтобы получить source
  size без полного backup'а. Новый статус `partial` — backup был прерван
  (нет rsync --stats блока в логе), показывается жёлтым.
- **Run/Stop NAS backup** — одна контекстная кнопка. Когда
  `nas-backup-runtime.service` active → красный Stop. Иначе зелёный Run.
- **AP card** — `comitup-NNN` (SSID) + `http://10.41.0.1:8080` (comitup-web
  на нестандартном порту чтобы не конфликтить с CasaOS-gateway :80).
### nas-backup

- **Self-reexec через systemd-run** — `nas-backup.sh --run/--dry-run/--diff`
  переоборачивает себя в transient unit `nas-backup-runtime` с собственным
  cgroup'ом. Backup переживает рестарт дашборда или SSH-сессии (раньше
  cgroup parent убивал rsync вместе с собой).
- **Stop через systemctl** — `systemctl stop nas-backup-runtime` чисто
  останавливает весь cgroup (rsync + sshpass + progress-writer).
- **Bash trap cleanup** — progress JSON удаляется при любом exit'е
  (SIGTERM, INT). Дашборд видит отсутствие файла → карточка прогресса
  пропадает.

### power-mode v2

- Три режима вместо двух: `normal` / `saver` / `auto`. Pref-файл
  `/var/lib/travel-nas/power-mode-pref` хранит выбор юзера. Auto-tick
  (от таймера, NetworkManager) учитывает pref: ручные `normal`/`saver`
  не перезаписываются.
- **Минутный тик** — новый `power-mode-tick.timer` каждые 60 секунд. Раньше
  только `system-monitor.timer` дёргал power-mode каждые 5 мин — короткие
  температурные пики Pi 5 успевали остыть между тиками.
- Расширенное логирование: каждое решение auto-tick'а пишется в
  `/mnt/t7/_logs/power-mode.log` с причиной (cooled/still-hot/throttled-bit).
- `power-mode.sh status` показывает pref + applied + текущую температуру +
  что бы auto выбрал сейчас и почему.

### AP / comitup

- `/etc/comitup.conf web_port: 8080` — comitup-web на 8080 вместо 80,
  больше не конфликтует с CasaOS-gateway.
- SSID на дашборде поправлен (`comitup-NNN` вместо `pi-XXXX` — comitup
  использует не hostname).

### Telegram

- **`/screenshot` `/screen`** — PNG-снимок текущего экрана дашборда.
  Файловый IPC: tg-listener touch'ит `/var/run/travel-nas/screenshot-req`,
  дашборд сохраняет pygame surface, tg-listener шлёт через sendPhoto
  (multipart/form-data, stdlib only).
- `/power auto` — включить авто-режим (раньше `auto` = "пересчитать
  сейчас", теперь = "система сама выбирает").
- `/status` показывает `pref=auto applied=saver` (или просто `saver` если
  ручной).
- `/help` обновлён под все актуальные команды.

### travel-nas-update.sh

- **systemd-run для restart dashboard** — раньше `nohup &` гасился
  SSH-сессией если update запущен через SSH. Теперь `systemd-run
  --unit=travel-nas-display-runtime` — transient unit переживает что
  угодно.
- Sync дисспетчера `/etc/NetworkManager/dispatcher.d/99-travel-nas-power`
  чтобы старая копия не дёргала `power-mode.sh auto` (= сбрасывала pref).
- **Self-heal desktop-иконок** — если `~/Desktop/Travel-NAS-*.desktop`
  отсутствуют (пропали после переустановки), пересоздаёт + pcmanfm
  reconfigure.

### modules/20-desktop.sh

- `mkdir -p ~/Desktop` перед попыткой положить ярлыки (раньше выходил с
  ошибкой если папка ещё не была создана xdg-user-dirs).
- `pcmanfm --reconfigure` после создания — рабочий стол подхватывает без
  релогина.

### modules/11b-power-mode.sh

- Дополнительно создаёт `power-mode-tick.{service,timer}` (минутный тик).

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
