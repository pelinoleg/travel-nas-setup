# Travel-NAS Setup — Project context for Claude

Travel-NAS на Raspberry Pi 5 (или Pi 4) + Samsung T7 Shield 4TB SSD. Делает: фото-бэкапы с SD-карт в дороге, синхронизация с домашним NAS, мелкий медиа-сервер на месте. Управление: 3.5″ touch-дашборд + Telegram-бот.

## Где смотреть подробности

| Документ | Что внутри |
|---|---|
| [README.md](README.md) | Quick-start, таблица компонентов, hardware |
| [CONTEXT.md](CONTEXT.md) | Детальная архитектура (что устроено как) |
| [CHANGELOG.md](CHANGELOG.md) | История изменений |
| [docs/NAS-BACKUP.md](docs/NAS-BACKUP.md) | rsync modules vs paths, EXCLUDES, troubleshooting |
| [docs/TAILSCALE.md](docs/TAILSCALE.md) | VPN setup + flow |
| [docs/UPDATE.md](docs/UPDATE.md) | `travel-nas-update` fast vs `--full` |
| [docs/VERIFY.md](docs/VERIFY.md) | Bit-rot scrub design |
| [docs/V2-WEB-DASHBOARD.md](docs/V2-WEB-DASHBOARD.md) | План перехода на web+Chromium kiosk (DSI 800×480) — отложено до приезда нового экрана |
| [docs/V2-WEB-UI-LAYOUT.md](docs/V2-WEB-UI-LAYOUT.md) | Визуальный язык V2 — layout patterns, page mockups, design tokens, ambient mode |

## Структура

```
setup.sh                    Orchestrator. Whiptail-меню, парсит args, source-ит модули по DO_* флагам.
lib/common.sh               Shared helpers (log/warn/err/info, mark_ok/mark_fail, fetch_*, write_systemd_unit).
modules/NN-name.sh          Каждый компонент — отдельный модуль. Активируется через DO_NAME=1 (whiptail или --all).
scripts/*.{sh,py}           Раннтайм-код, деплоится в /usr/local/bin/. Список в travel-nas-update.sh:SCRIPTS.
conf-examples/*.example     Шаблоны конфигов. Деплоятся в /etc/travel-nas/ при первом запуске модуля.
desktop/                    .desktop ярлыки для LXDE.
docs/                       Long-form документация.
```

Модули запускаются строго по порядку (`01-update` → `22-verify`). Каждый модуль проверяет `[[ -n "${DO_FOO:-}" ]] || return 0` и сам пропускает уже-установленное.

## Три команды управления

| Команда | Когда |
|---|---|
| `travel-nas-setup` | Перезапустить whiptail-wizard (добавить/переустановить компонент, реинсталл sudoers, …). Качает свежий `setup.sh` из репо. |
| `travel-nas-update` | **Быстро (~30 сек)** — только наши `.sh`/`.py` из GitHub в `/usr/local/bin/`. Рестартит tg-listener/dashboard. Sync sudoers. НЕ трогает apt/Docker/конфиги. |
| `travel-nas-update --full` | **Полное (~5-15 мин)** — то же + `apt upgrade` + `docker compose pull && up -d` всех CasaOS-апсов. |

Любые правки в репо → `git push` → на Pi `travel-nas-update`. Всё подтянется.

## Рабочий цикл с пользователем

1. Пиши скрипт/правку → коммит в репо
2. `ssh oleg@<host>.local` (sshpass через env `SSHPASS=hammett`) — пароль `hammett`. Hostname задаёт юзер в Pi Imager при прошивке — НЕ хардкодь `pi.local` в коде.
3. `sudo -S /usr/local/bin/travel-nas-update` тянет с GitHub
4. После изменений в `REQUIRED_CMDS` (sudoers list) нужен **второй прогон** — sudoers sync прогоняется уже из нового кода

## Ключевые пути на устройстве

| Путь | Что |
|---|---|
| `/etc/travel-nas/*.conf` | Конфиги (НИКОГДА не трогаются update-скриптом) |
| `/mnt/t7/` | T7 SSD, ext4, label `t7`, UUID в fstab. `usb-imports/`, `nas-backup/`, `_logs/`, `pi-config-backups/` |
| `/var/lib/travel-nas/` | Долгое state (sleep-timeout, power-mode-pref, *.status.json, verify manifest pointer) |
| `/var/run/travel-nas/` | Tmpfs runtime (backup-progress.json, screenshot.png, screenshot-req) |
| `/usr/local/bin/` | Все наши скрипты |
| `/usr/lib/systemd/system-shutdown/zzz-sysrq-fallback` | Hard-fallback при shutdown (Pi 5 USB-SSD hang) |

## Hardware gotchas

- **Pi 5 shutdown hang с USB-SSD** — `dtoverlay=usb_max_current_enable=1` (только Pi 5) + fast-shutdown.sh с pre-umount T7 + sysrq fallback hook. Без этого `systemctl poweroff` залипает на «Reached target system power off» навсегда.
- **MHS35 SPI display** — резистивный, 320×480 portrait. Touch матрица отдельная (ADS7846). `dtoverlay=mhs35:rotate=N` меняет экран — НО touch калибровка **не подхватывается** автоматически. Используй `screen-rotate.sh {0|90|180|180|flip}` — он пишет правильную `Calibration` под выбранный rotation (значения из goodtft/LCD-show, по одной матрице на угол).
- **MHS35 backlight всегда вкл** — BL прибит к 5V напрямую, программно не выключить. Поэтому auto-sleep заливает экран чёрным (set_backlight + screen.fill) — пиксели гаснут, но подсветка нет.
- **Pi 4 vs Pi 5** — оба поддерживаются. Pi 4 ~2× дольше работа от powerbank, обычно без shutdown hang. Conditional флаги в модулях (`PI_MODEL`-check в 04-t7-mount, не везде).

## Software gotchas / patterns

- **rsync modules vs paths** — на Synology/UGREEN бэкап идёт через rsync daemon модули (`oleg@host::module/`), **не** через ssh-fs paths. Subpaths внутри модуля можно (`module/Photos/`), `/volume1/...` — нет (rsync daemon отвергает абсолютные пути с `/`). См. docs/NAS-BACKUP.md таблицу.
- **EXCLUDES** в `nas-backup.conf` — `@eaDir/ #recycle/ .DS_Store node_modules/ .cache/ ...`. Эти Synology-thumbnails и cache могут отъедать **5-15% размера на больших библиотеках** — поэтому простой `du`-сравнение T7 vs NAS даёт false-warning «not fully copied». **Авторитетный сигнал — rsync exit-code** (parsed из логов в `nas-backup-status.py`), не размерное сравнение.
- **systemd-run для длинных операций** — `nas-backup.sh` сам себя re-exec'ит как transient unit `nas-backup-runtime` чтобы переживать рестарт dashboard'а / SSH-сессии. Output идёт в `journalctl -u nas-backup-runtime`, не в stdout — НЕ ищи output в /tmp/*.out если вызвал напрямую.
- **Cached pattern в dashboard** — все «дорогие» source-of-truth (governor, temp, disk, status JSONs) обернуты в `Cached(fn, ttl)`. `.invalidate()` после действий, которые изменяют source. Иначе UI отстаёт на TTL.
- **screenshot-req file-IPC** — tg-listener'/`/screenshot`/ кладёт `touch /var/run/travel-nas/screenshot-req`, dashboard в main loop'е каждый кадр проверяет файл, сохраняет PNG и удаляет флаг. PNG читается tg-listener'ом.
- **Sudoers — два места** — `modules/19-display.sh` (шаблон при install) И `scripts/travel-nas-update.sh:REQUIRED_CMDS` (sync на каждом update). Добавляешь новый sudo-вызов — пиши в оба. После добавления нужен **двойной прогон** update (первый ставит новый скрипт, второй сам с собой sync'ает sudoers).
- **page Back всегда слева, action справа** — соглашение для всех страниц дашборда. На странице с Refresh: `Back ← | → Refresh`. На confirm: `Cancel ← | → Confirm`.

## Telegram bot — командный обзор

```
/help /start            Список всех команд
/status /today          Снапшот (uptime, CPU, T7, throttle)
/screenshot /screen     PNG дашборда
/sleep [N|never]        Auto-sleep timeout
/services /configs      URL'ы / конфиги
/nas /backup [dry|diff] NAS backup
/docker [audit]         Docker управление
/update [full]          travel-nas-update
/power [auto|normal|saver] CPU governor
/tailscale /ts          VPN статус + peers
/verify [run]           Bit-rot scrub
/rotate /flip [flip]    MHS35 rotation (0°↔180°)
/reboot /shutdown /yes  Питание (yes confirm)
/logs [N]               Tail логов
```

## Конвенции для правок

- Комменты в коде — **только если "почему" не очевидно из кода**. WHAT покрывается понятными именами; WHY — единственная причина писать коммент.
- Русский в комментах OK (проект-личный, mixed RU/EN — match существующий стиль файла).
- Не добавляй обёртки/feature-flags «на потом» — нужно сейчас, пишешь сейчас.
- При правке существующего модуля — проверь не сломал ли idempotency (повторный запуск setup должен пройти чисто).
- При добавлении нового sudo-вызова — сразу в `19-display.sh` И в `travel-nas-update.sh:REQUIRED_CMDS`.
- Sleep/Back-кнопка/conf-format и др. UI-конвенции — см. CONTEXT.md разделы «UI/UX» и «Сетевые фиксы».

## Git workflow

- Все правки → main (single-dev проект)
- Один коммит = одна логическая единица
- Сообщение коммита: первая строка ≤ 70 char, тело объясняет WHY, в конце `Co-Authored-By: Claude` если ассистент писал
- После push — на Pi `travel-nas-update`
