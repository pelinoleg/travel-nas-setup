# Travel-NAS Setup

Infrastructure-as-Code для travel-NAS на Raspberry Pi 5 **или Pi 4** + USB SSD (Samsung T7 Shield по умолчанию). Whiptail-меню с компонентами, поддержка повторного запуска. Всё переустанавливается одной командой.

## Быстрый старт

### Свежая установка (на чистой PiOS)

```bash
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/setup.sh -o setup.sh && bash setup.sh
```

Откроется whiptail-меню → отметь компоненты → Enter. После завершения доступны команды:

| Команда | Когда использовать |
|---|---|
| `travel-nas-setup` | Перезапустить wizard (добавить компонент, переустановить, поменять конфиг). Скачивает свежий `setup.sh`, бежит whiptail, спрашивает что делать. |
| **`travel-nas-update`** | **Быстро (~30 сек) — только скрипты из репо.** Тянет `.sh`/`.py` из GitHub в `/usr/local/bin/`, перезапускает `tg-listener` и dashboard. Конфиги, systemd-units, sudoers (создание) — НЕ трогает. |
| **`travel-nas-update --full`** | **Полное (~5-15 мин)** — то же + `apt upgrade` (включая kernel/tailscale) + `docker compose pull && up -d` по всем `/opt/stacks` стекам. Печатает варнинг если нужен reboot. См. [docs/UPDATE.md](docs/UPDATE.md). |

### Обновление после правок (когда поменял что-то в репо и хочешь применить на Pi)

```bash
travel-nas-update
```

Или одной строкой если команды ещё нет (бутстрап):

```bash
sudo curl -fsSL "https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/scripts/travel-nas-update.sh?$(date +%s)" -o /usr/local/bin/travel-nas-update && sudo chmod +x /usr/local/bin/travel-nas-update && travel-nas-update
```

### Предусловия для установки

1. Прошил microSD через **Raspberry Pi Imager** (PiOS Desktop Trixie 64-bit)
2. В Imager → Advanced settings: **задал уникальный hostname** (если у тебя несколько travel-NAS — `pi-tn1`, `pi-tn2`, чтобы mDNS не конфликтовал), SSH on, WiFi, пользователь
3. Загрузился, SSH'нулся → `ssh oleg@<твой-hostname>.local`

## Компоненты

| Компонент | Назначение |
|---|---|
| 📦 **UPDATE** | `apt update && upgrade` (на свежем PiOS долго — ~5-10 мин) |
| 🛠 **UTILS** | htop, ncdu, smartmontools, exiftool, wmctrl и т.д. |
| 💾 **STORAGE_MOUNT** | Wizard: показывает подключённые диски (размер/ФС/метка), даёт выбрать. Уже ext4 и здоров → использует как есть (данные целы); чужой/пустой → формат в ext4 с запросом имени. Свой диск опознаётся по файлу-маркеру (любой label, переживает переустановку OS) |
| 📱 **TG_NOTIFY** | Telegram-уведомления (helper script) |
| 📁 **SAMBA** | SMB-шара `smb://<host>.local/travel-nas` (open guest) |
| 📷 **PHOTO_BACKUP** | udev + rsync — автокопирование USB/SD при подключении |
| 🏠 **NAS_BACKUP** | Бэкап с домашнего NAS (rsync daemon) — вручную или опц. авто по расписанию (тихо skip когда NAS недоступен) |
| 🐕 **WATCHDOG** | Мониторинг T7 (mount/SMART/temp/space) каждые 5 мин |
| 💻 **SYS_MONITOR** | CPU temp / throttling / RAM / microSD wear каждые 5 мин |
| 🔌 **POWER_MODE** | Авто-переключение CPU governor + Docker apps под условия питания |
| 📲 **TG_LISTENER** | Двусторонний Telegram-бот: `/status /backup /logs /reboot` |
| 📊 **DAILY_SUM** | Вечерний отчёт в Telegram (21:00) + JSON refresh каждые 10 мин |
| 💾 **LOG2RAM** | Логи в RAM — микро-SD живёт дольше |
| 🗜 **ZRAM** | Сжатый swap (zstd) |
| 📡 **COMITUP** | Полевой WiFi AP-режим |
| 🐳 **DOCKER** | Docker engine (apt-репо) — основа для всех стеков |
| 📦 **DOCKGE** | Dockge — web-UI для docker-compose стеков (`:5001`, стеки в `/opt/stacks`) |
| 🖼 **PHOTOVIEW** | Photo-галерея (Docker, после DOCKER, путь `/storage/*` в UI, `:8000`) |
| 📺 **YTARCHIVER** | YouTube archiver (Docker, после DOCKER, UI на `:8081`) |
| 🔄 **SYNCTHING** | P2P-синхронизация папок (`:8384`, данные `/mnt/storage/sync`) |
| 📂 **FILEBROWSER** | Файл-менеджер + редактор конфигов (`:8082`, диск + `/etc/travel-nas`, пароль из `filebrowser.conf`) |
| 📋 **DOZZLE** | Live-логи всех Docker-контейнеров в вебе (`:8083`, stateless) |
| 🩺 **SCRUTINY** | SMART-здоровье диска T7 — температура, износ, bad sectors (`:8084`) |
| 🎵 **NAVIDROME** | Стриминг музыки (Subsonic API), библиотека `/mnt/storage/media/Music` (`:4533`) |
| 🖥 **DISPLAY** | MHS35 3.5" сенсорный + Python dashboard в X-kiosk |
| 💻 **DESKTOP** | Ярлыки на рабочий стол: Dashboard, Update, Calibrate Touch |
| 🔐 **TAILSCALE** | Zero-config VPN — доступ к Pi из любой сети мира + SSH без ключей. См. [docs/TAILSCALE.md](docs/TAILSCALE.md) |
| 🔍 **VERIFY** | Ежемесячный sha256 scrub T7 — ловит bit-rot, bad-sector'а, I/O ошибки. См. [docs/VERIFY.md](docs/VERIFY.md) |
| 🌡 **THERMAL_GUARD** | Защита от перегрева — staged docker throttle/pause/stop при sustained высокой темпе. MODE=warn по умолчанию. См. [docs/THERMAL-GUARD.md](docs/THERMAL-GUARD.md) |
| 🔧 **PI_TWEAKS** | HW watchdog (BCM2712), EEPROM auto-update, WiFi powersave OFF, sysctl tunes. См. [docs/PI-TWEAKS.md](docs/PI-TWEAKS.md) |
| 🛡 **CONF_PERMS** | systemd path-unit смотрит за `/etc/travel-nas/` и восстанавливает owner/mode после правок через Filebrowser/веб |

> Docker-приложения (PHOTOVIEW … NAVIDROME) — **стеки** в `stacks/<name>/`, авто-обнаруживаются wizard'ом и деплоятся в `/opt/stacks/`. Добавить новое = папка + строка в `stacks/index.txt`, без нового модуля. См. [docs/DOCKER.md](docs/DOCKER.md).

## Hardware

- **Raspberry Pi 5** (8GB RAM рекомендуется) — самый быстрый, но греется и под нагрузкой ~12W
- **Raspberry Pi 4** (8GB RAM) — альтернатива, **~2× дольше работа от powerbank** (~7W под нагрузкой), обычно нет shutdown hang'а с USB-SSD. Слабее CPU (~50%), но для photo-backup IO-bound разница незаметна.
- Samsung T7 Shield SSD 4TB через USB 3.0 (или любой ext4-форматируемый внешний диск)
- microSD 64GB+ (для системы)
- Блок питания:
  - Pi 5: **27W USB-C PD** (Anker Nano 30W + 5A cable, ~€35)
  - Pi 4: **15W USB-C** хватит (любая нормальная)
- (Опционально) **MHS35 3.5" SPI display** — `goodtft ili9486`, rotation 90. Работает на обоих Pi 4/5.
- (Опционально) **Powerbank** с USB-C PD для поля (Anker 737 или подобные)

## Структура файлов на диске (`/mnt/storage`)

```
/mnt/storage/                  (owned by install user — можно создавать папки без sudo)
├── nas-backup/           Бэкапы с домашнего NAS
│   ├── Personal/  Docker/  Photos-Other/  ...
│   ├── _deleted/<DD-MM-YYYY>/
│   └── _logs/
├── usb-imports/          Бэкапы SD/USB (DD-MM-YYYY/HH-MM-SS_label_uuid/)
│   ├── .photoviewignore  Skip RAW для Photoview-сканера
│   └── *.incomplete/     Если backup был прерван (видно в Today summary)
├── pi-config-backups/    4 копии /etc и т.п. (автоматический Pi-backup)
├── media/                Пользовательское (Фильмы и т.п.)
│   └── YT-Archiver/      БД и downloads yt-archiver
├── _appdata/             БД Docker-приложений (reinstall-safe)
│   └── photoview/{db,cache}
├── sync/                 Для Syncthing (опционально)
└── _logs/                Логи всех скриптов
```

## Конфигурация

Секреты НЕ в git — лежат в `/etc/travel-nas/`:

| Файл | Назначение | Перм |
|---|---|---|
| `tg-notify.conf` | Telegram bot token + chat_id | 600 |
| `nas-backup.conf` | NAS host/user/pass + MODULES + `AUTO_BACKUP*` (расписание) | 600 |
| `photo-backup.conf` | Настройки автобэкапа SD | 644 |
| `storage-info.conf` | UUID storage-диска (сгенерён при mount) | 644 |
| `services.conf` | URL-ы для Services page в dashboard | 644 |
| `filebrowser.conf` | Логин/пароль Filebrowser (`FB_USER`/`FB_PASS`) | 600 |
| `yt-archiver.conf` | URL дашборда + `YT_CPU_LIMIT` (лимит CPU контейнера) | 644 |

В git коммитятся только `*.example` в `conf-examples/` (без секретов).

**Применение правок:** после ребута применяются все конфиги. Большинство — и без
ребута: `services.conf`/URL читаются live дашбордом; `AUTO_BACKUP*` и `YT_CPU_LIMIT`
применяются **сразу при сохранении** (systemd path-units); per-run скрипты
(nas/photo-backup, power-mode) берут конфиг свежим при следующем запуске;
`tg-notify.conf` — после рестарта tg-listener. Владелец конфигов = юзер из Pi Imager
(uid 1000), не хардкод.

## Dashboard (MHS35 display)

Pygame-кiosk в X11. Никаких внешних терминалов — фокус не уходит, тач всегда работает. Pages:

- **Status** (главная) — карточки: Network/IP/SSID (или AP с инструкцией), Storage (с `NOT MOUNTED` детектом + % справа от бара), System (CPU/RAM bars), **Last NAS backup** (агрегат: local/source/%), Last photo backup. Если бэкап в процессе — зелёная карточка с прогрессом заменяет last-карточки. Сверху в плашке: `up Xh Ym` слева, `power: [A·]<mode> <freq>GHz <W>W` справа (`A·` префикс = система сама выбирает режим).
- **Menu** — одна страница, 3 секции:
  - **NAS**: Run/Stop backup (одна контекстная кнопка) | NAS status
  - **INFO**: Today | Logs | Services / Configs | Docker
  - **SYSTEM**: AP info | Force AP, Reboot | Shutdown, Normal | Saver | Auto (power modes)
- **NAS status** — по каждому модулю: цвет-точка (ok/warn/fail/partial/absent), `local / source` размер, % при mismatch + `not fully copied` подсказка. Сверху строка `auto-backup: daily HH:MM` (расписание). Низ: `Back | Auto | Refresh` — **Auto** вкл/выкл авто-бэкап, **Refresh** опционально запрашивает source size через `rsync --dry-run --stats` (медленно).
- **Today** — превью daily-summary: uptime, CPU°C, IP, диск %, throttling, photos/NAS today, errors, microSD wear, power mode.
- **Services** — список из `/etc/travel-nas/services.conf` с подстановкой `{host}`, `{ip}`, `{user}`.
- **Logs** — встроенный viewer (photo-backup, nas-backup, watchdog, system-monitor, display errors).
- **Docker** — все compose-проекты с inline кнопками Stop/Start/Restart.
- **YT Archive** — статистика yt-archiver: каналы / видео / диск + очередь (downloading/pending/errors) + текущие загрузки с прогресс-барами. URL настраивается в `/etc/travel-nas/yt-archiver.conf`.
- **AP info / Force AP** — SSID `comitup-NNN` + URL `http://10.41.0.1` (comitup-web на :80 — captive-portal детект бьёт туда). Force AP сбрасывает текущий WiFi и стартует hotspot.
- **Reboot / Shutdown** — с подтверждением.

Auto-sleep через 5 минут неактивности (xset dpms + sysfs backlight для дисплеев которые умеют). На MHS35 lampbacklight прибита к 5V, экран чернеет но лампа горит — hardware-limit, не наш баг.

### Stop NAS backup

`nas-backup.sh` сам себя переоборачивает в transient systemd-unit (`nas-backup-runtime`) с собственным cgroup'ом — переживает рестарт дашборда или SSH-сессии. Кнопка **Stop backup** на NAS-странице делает `systemctl stop nas-backup-runtime` — SIGTERM всему cgroup'у. Bash trap в `nas-backup.sh` удаляет stale progress JSON при любом exit'е.

## Telegram бот

Если установлен **TG_LISTENER**, бот понимает:

| Команда | Действие |
|---|---|
| `/status` `/today` | Snapshot: uptime, T7, CPU, photos today, throttle, power mode |
| `/screenshot` `/screen` | **PNG-снимок текущего экрана дашборда** (через файловый IPC) |
| `/nas` | Статус NAS-бэкапов (модули, размеры, last-run) |
| `/docker` | Compose-проекты + inline кнопки Stop/Start/Restart |
| `/services` | URLs всех установленных сервисов |
| `/configs` | `/etc/travel-nas/` + где что лежит |
| `/backup` `/backup dry` `/backup diff` | NAS backup / dry-run / diff |
| `/update` | Pull свежих скриптов из GitHub + рестарт сервисов |
| `/logs [N]` | Хвосты всех логов (default 30 строк) |
| `/power` | Справка + текущее состояние pref/applied |
| `/power normal` `/power saver` | Зафиксировать ручной режим |
| `/power auto` | Дать системе самой выбирать (`A·` префикс на дашборде) |
| `/reboot` `/shutdown` | С подтверждением `/yes` в течение 30 секунд |
| `/help` | Список всех команд |

Авторизация: только chat_id из `TG_CHAT_ID`. Остальные сообщения игнорируются.

## Power mode

Защита от просадок 5V и перегрева. Не выключает сервисы — только опускает планку CPU чтобы пиковый ток был ниже.

| Режим | Тип | Что делает |
|---|---|---|
| `normal` | ручной | `ondemand` governor — CPU до max 2.4 GHz по нагрузке. Не меняется сам. |
| `saver`  | ручной | `powersave` governor — CPU зажат на min ~1.5 GHz. Не меняется сам. |
| `auto`   | система сама | По throttled-биту и CPU temp выбирает saver/normal. На дашборде с префиксом `A·` |

Auto-логика (при `pref=auto`):
- `vcgencmd get_throttled & 0x7` ≠ 0 → saver
- CPU temp ≥ 75°C → saver
- CPU temp < 65°C **и** throttle clear → normal (гистерезис 10°)

Триггеры тика:
- **`power-mode-tick.timer`** — раз в **60 секунд** (ловит короткие пики температуры)
- NetworkManager dispatcher на connect/disconnect
- `system-monitor.timer` каждые 5 мин (бэкап-механизм)

Файлы состояния:
- `/var/lib/travel-nas/power-mode-pref` — выбор юзера (`normal`/`saver`/`auto`)
- `/var/lib/travel-nas/power-mode.txt` — реально применённый governor

Управление: `power-mode.sh normal|saver|auto|auto-tick|status`. На дашборде Menu → SYSTEM → Normal/Saver/Auto. Через TG: `/power <режим>`.

## photo-backup надёжность

- Каждый бэкап стартует с suffix `.incomplete`, переименовывается без него после успешного rsync. Прерванные/сбойные остаются `.incomplete` — видно в Today page и в Telegram daily summary.
- Стейл `.incomplete` старше 24 часов автоматически удаляются на следующем запуске photo-backup.
- LED статус: солидный = idle, heartbeat = busy, фастблинк = error.

## Доступ

(`<host>` ниже = hostname который ты задал в Pi Imager, например `pi` или `pi-tn1`.)

- **Samba**: `smb://<host>.local/travel-nas` (Cmd+K в Finder)
- **SSH**: `ssh <user>@<host>.local`
- **AP mode** (полевой): подключиться к WiFi `comitup-NNN` (без пароля) → `http://10.41.0.1` для настройки нового WiFi
- **Веб-сервисы** — `http://<host>.local:<порт>`:

| Сервис | Порт | |
|---|---|---|
| comitup captive-portal | **80** | поле: «войти в сеть» бьёт сюда |
| Dockge | 5001 | менеджер docker-стеков |
| Photoview | 8000 | фото-галерея (в UI пути `/storage/*`, см. ниже) |
| YT-Archiver | 8081 | YouTube-архив |
| Filebrowser | 8082 | файлы + редактор конфигов |
| Dozzle | 8083 | live-логи контейнеров |
| Scrutiny | 8084 | SMART-здоровье T7 |
| Syncthing | 8384 | синхронизация папок |
| Navidrome | 4533 | стриминг музыки |

> ⚠️ **Photoview** UI принимает только пути ВНУТРИ контейнера. Мы монтируем `/mnt/storage` как `/storage:ro`. То есть в Photoview указывай `/storage/usb-imports`, а **не** `/mnt/storage/usb-imports`. Иначе получишь "Server error: internal system error at initialSetupWizard".

## Обновление скриптов после установки

После того как Pi уже настроена (`travel-nas-setup` отработал), обновлять можно тремя способами.

### A. Через wizard (рекомендуется)

```bash
travel-nas-setup
```

Открывается то же whiptail-меню. Оставь галки только на компонентах которые хочешь обновить (например только `DISPLAY` чтобы обновить dashboard). Конфиги (`/etc/travel-nas/*.conf`) сохраняются — модули проверяют наличие файла и не перезатирают.

### B. Один конкретный скрипт точечно

```bash
# Bash-скрипты
sudo curl -fsSL "https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/scripts/X.sh?$(date +%s)" -o /usr/local/bin/X.sh
sudo chmod +x /usr/local/bin/X.sh

# Python-скрипты
sudo curl -fsSL "https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/scripts/X.py?$(date +%s)" -o /usr/local/bin/X.py
sudo chmod +x /usr/local/bin/X.py
```

`?$(date +%s)` — cache-buster, чтобы GitHub CDN не отдал устаревшую версию.

После обновления dashboard'а — перезапусти его:
```bash
pkill -f travel-nas-display.py     # autostart его поднимет, либо вручную ↓
DISPLAY=:0 XAUTHORITY=/home/oleg/.Xauthority nohup /usr/bin/python3 /usr/local/bin/travel-nas-display.py >/tmp/dashboard.log 2>&1 &
```

После обновления tg-listener.py:
```bash
sudo systemctl restart tg-listener
```

После изменения compose-файлов (или через Dockge UI на `:5001`):
```bash
cd /opt/stacks/photoview && sudo docker compose up -d   # БД: /mnt/storage/_appdata/photoview/
cd /opt/stacks/ytarchiver && sudo docker compose up -d
```

### C. Через git clone (если планируешь разрабатывать)

```bash
git clone https://github.com/pelinoleg/travel-nas-setup ~/travel-nas-setup
cd ~/travel-nas-setup
git pull
bash setup.sh        # подхватит локальные lib/ и modules/
```

### Где что лежит на устройстве

| Путь | Что |
|---|---|
| `/usr/local/bin/` | Все скрипты (`*.sh`, `*.py`, `travel-nas-setup`) |
| `/etc/travel-nas/` | Конфиги (tg-notify, nas-backup, services, и т.п.) |
| `/etc/systemd/system/` | Юниты (`*.service`, `*.timer`) |
| `/etc/sudoers.d/travel-nas-dashboard` | NOPASSWD для dashboard buttons |
| `/var/lib/travel-nas/` | Runtime state (JSON-ы, offset, queue) |
| `/var/run/travel-nas/` | tmpfs runtime (backup-progress) |
| `/mnt/storage/_logs/` | Логи скриптов |
| `/mnt/storage/pi-config-backups/` | Еженедельные бэкапы конфигов |

## Восстановление при замене microSD

```bash
# 1. Установить чистую PiOS Desktop через Imager (SSH + WiFi настроены)
# 2. travel-nas-setup       # whiptail-меню → отметить всё → Enter
# 3. (после ребута) restore-pi-config из бэкапа на T7
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/restore-pi-config.sh -o restore.sh
bash restore.sh
sudo reboot
```

## Дата формата

Везде EU: `DD-MM-YYYY` (например `27-05-2026`).

## Ручные команды

```bash
# Бэкап с NAS
sudo nas-backup.sh                 # whiptail menu
sudo nas-backup.sh --run           # без вопросов
sudo nas-backup.sh --dry-run       # симуляция
sudo nas-backup.sh --diff          # diff

# Pi config backup
sudo pi-config-backup.sh

# Photo-backup вручную
sudo photo-backup.sh /dev/sdX1

# Watchdog
sudo systemctl status disk-watchdog.timer
sudo journalctl -u disk-watchdog.service -f

# Power mode
power-mode.sh status
sudo power-mode.sh saver           # принудительно зажать CPU

# Логи
tail -F /mnt/storage/_logs/*.log

# Telegram тест
/usr/local/bin/tg-notify.sh "Test" "Hello from Travel-NAS"
```

## Lessons learned

- **NVMe через PCIe HAT нестабилен** на Pi 5 (Kingston SNV2S падал) — стабильнее USB SSD. Pi 4 NVMe вообще нет (нет PCIe слота).
- **Bare USB SSD без DRAM не для NAS-нагрузки** — TLC SSD с DRAM (T7) лучше.
- **lbb (Little Backup Box) конфликтует с CasaOS/fstab** — заменён собственным photo-backup.
- **EXT4 надёжнее exFAT** на тяжёлой записи.
- **PiOS Imager preconfig** обязательно — иначе первый boot без сети и без SSH.
- **Pi 5 27W блок питания критичен** — с 15W блоками или хилым USB-PD идёт throttle. Pi 4 терпимее, 15W хватает.
- **Pi 5 shutdown с USB-SSD виснет** на "Reached target system power off" — известная hardware quirk (USB-bridge power-down). Pi 4 этой проблемы обычно не имеет.
- **Pi 4 vs Pi 5 для travel**: Pi 4 выигрывает по power (~2× дольше от powerbank), Pi 5 — по CPU. Для основного use-case (photo-backup + dashboard) Pi 4 достаточно.

## CHANGELOG

См. [CHANGELOG.md](CHANGELOG.md).
