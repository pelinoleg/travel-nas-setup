# Changelog

Significant changes to travel-nas-setup. Newest first.

## 2026-06-05 — opt-in: polkit без пароля (DESKTOP_AUTH)

- Новый **opt-in** компонент `DESKTOP_AUTH` (`26-desktop-auth.sh`): кладёт
  polkit-правило — члены группы `sudo` проходят все polkit-действия без запроса
  пароля (настройки/монтирование/сеть/обновления в десктопе больше не нагло
  спрашивают каждый раз). Терминальный sudo не трогается. По умолчанию ВЫКЛ в
  меню и НЕ входит в `--all` (это ослабление безопасности). Убрать = удалить
  `/etc/polkit-1/rules.d/49-travel-nas-nopasswd.rules`.

## 2026-06-05 — desktop: фавиконки сервисов + trusted-ярлыки (Trixie/labwc)

- Ярлыки docker-сервисов на DSI теперь с **фавиконками самих сервисов** (а не
  одинаковым глобусом). `resolve_icon` достаёт иконку как браузер: парсит
  `<link rel=icon>` на `localhost:PORT` → качает; fallback на dashboard-icons CDN
  по имени (для SPA вроде scrutiny, что не сервят favicon); иначе глобус. Файлы в
  `~/.local/share/icons/travel-nas/`, `Icon=` — абсолютным путём.
- Фикс «ярлыки показывали имя файла без иконки и просили подтверждение»: на
  Trixie/labwc PCManFM требует `gio metadata::trusted` (одного +x мало) +
  `quick_exec=1`. Icon по имени темы там не резолвится → только абсолютный путь.

## 2026-06-05 — desktop: на DSI ярлыки на docker-сервисы вместо дашборда

- `20-desktop.sh` теперь screen-aware. На **DSI** (где дашборда нет) больше не
  создаёт ярлыки Dashboard и Calibrate Touch (тач ёмкостный, калибровка не нужна).
  Вместо них — ярлыки на установленные docker-сервисы (`xdg-open http://localhost:PORT`
  в браузере; на 800×480 удобно открывать прямо там). Источник: `stacks/index.txt`
  + `meta.conf` (PORT/LABEL), фильтр по `DO_STACK_*` / наличию `/opt/stacks/<name>`;
  + Dockge (:5001). Ярлык Update остаётся на любом экране.
- На **MHS35** поведение прежнее (Dashboard + Calibrate + Update, icon size 36).
  Мелкие иконки/чёрный фон (desktop-items-0.conf) теперь только для MHS35.

## 2026-06-05 — ytarchiver: VPN exit-pool (folder-driven WireGuard)

- Поддержка нового VPN-механизма upstream: backend через docker.sock поднимает по
  gluetun-туннелю (`wgvpn-*`) на каждый `*.conf` в `/wireguard`, гоняет yt-dlp
  через здоровые, ротирует при блоке YouTube, дохлые конфиги карантинит. Opt-in
  через файлы: **пустая папка = прямые загрузки** (VPN выключен).
- compose backend: + env `WIREGUARD_CONFIGS_DIR=/wireguard`,
  `VPN_DOCKER_NETWORK=ytarchiver_ytarchiver_net`; + mount `/var/run/docker.sock`
  (спавн туннелей) + bind `wireguard/` → `/wireguard`. `stack_pre` создаёт папку.
- ⚠ docker.sock у backend = root-эквивалент на хосте (требование фичи). Туннели
  `wgvpn-*` — рантайм, не в compose/Dockge.

## 2026-06-05 — ytarchiver: POT-провайдер (обход YouTube bot-wall)

- Синхронизация стека с upstream `pelinoleg/ytarchiver`. Backend's yt-dlp теперь
  проходит «Sign in to confirm you're not a bot» без cookies через
  **bgutil-provider** (`brainicism/bgutil-ytdlp-pot-provider`) — новый сервис на
  `ytarchiver_net`, backend ходит к нему по `POT_PROVIDER_URL=http://bgutil-provider:4416`.
- **watchtower** (`nickfedor/watchtower`) — авто-обновляет ТОЛЬКО bgutil (label-scoped),
  наши backend/frontend не трогает.
- Backend: + env `POT_PROVIDER_URL`, `COOKIES_FILE`, `YOUTUBE_PLAYER_CLIENT`;
  `CORS_ORIGINS` `"[*]"` → `"*"`. Новый bind `cookies/` → `/cookies:ro` (опц. fallback
  `youtube.txt`); `stack_pre` создаёт папку.
- Наши адаптации сохранены: `name`, `ytarchiver_net`, `cpu_shares`+`deploy.limits`
  из `.env`, bind в `/mnt/storage/media/YT-Archiver/`, порт **8081**, healthcheck.

## 2026-06-04 — Выбор экрана: + Waveshare 4.3″ DSI

- **Визард выбора экрана** (`19-display.sh`): MHS35 (SPI) / Waveshare 4.3″ DSI /
  skip. Тип определяется один раз (config.txt → `display.conf` → whiptail →
  default mhs35 в неинтерактиве). MHS35-путь и его дашборд/`screen-rotate.sh`
  не тронуты — старый экран работает как раньше (используется на другом Pi).
- **DSI = только screen-enablement, без дашборда** (дашборд под 800×480 — отдельный
  шаг). При выборе DSI модуль: дописывает оверлеи `vc4-kms-v3d` +
  `vc4-kms-dsi-7inch` в config.txt (идемпотентно), пишет `SCREEN_TYPE=dsi43` в
  `/etc/travel-nas/display.conf`, ставит udev-правило (group video 0664 на
  `/sys/class/backlight/*`) + добавляет uid-1000 в группу video. Тач ёмкостный,
  driver-free. Нужен reboot.
- **Новые CLI-хелперы** (DSI): `dsi-backlight.sh <0-255|N%|±N|on|off>` — яркость
  через sysfs без sudo; `dsi-rotate.sh {0|90|180|270}` — поворот дисплея
  (cmdline.txt `video=DSI-1:…rotate=N`) + тача (udev `LIBINPUT_CALIBRATION_MATRIX`).
  Управление из UI/Telegram — отдельным шагом.

## 2026-06-01 — Фиксы стеков + Vellum + автозапуск

### Фиксы
- **Автозапуск на ребуте**: docker.service drop-in `RequiresMountsFor=/mnt/storage`
  (стартует после монтирования диска) + `travel-nas-stacks.service` (oneshot
  `up -d` всех стеков). Лечит «все докеры в stop после reboot» (гонка docker vs mount).
- **MHS35-драйвер: повторный setup больше не спрашивает** — детект по
  `dtoverlay=mhs35` в config.txt (персистентно) вместо `/tmp/LCD-show` (чистится
  ребутом) + tty-guard (не висит на `read` в неинтерактиве).
- **TinyFileManager убран** — образ `tinyfilemanager:master` только amd64, на
  arm64 (Pi) нет манифеста.
- **ytarchiver порт кликабельный в Dockge**: `ports` переведён с длинного синтаксиса
  (`target/published`) на короткий `"8081:80"` — Dockge парсит только его.
- **Filebrowser пароль**: образ LSIO/s6 генерит случайный пароль в БД (bbolt,
  залочена сервером — `users add` извне не работал, 403). Теперь `stack_post` ловит
  его из логов → `filebrowser.conf` (`FB_GENERATED_PASS`); дашборд (Services)
  показывает `admin / <пароль>`.

### NAS-backup
- **Фикс: auto-backup в дашборде всегда показывал "off"** — `nas-backup.conf`
  создавался `root:root 600`, а `nas-schedule.sh status` бежит от юзера дашборда
  (не root) → `Permission denied` → всегда "off". Модуль теперь chown'ит conf на
  uid-1000. (На существующем устройстве: `sudo chown <user> nas-backup.conf`.)
- **Понятные алерты вместо "Failed 5/5"** — `check_connectivity` классифицирует
  причину: нет пинга / rsync-демон не отвечает / **auth failed (неверный пароль)**
  — и шлёт точный Telegram-алерт. Листинг `::` не требует пароля, поэтому
  авторизацию проверяем отдельно на первом модуле. Новый флаг `nas-backup.sh --test`.

### Прочее
- **Дефолт экрана MHS35: 270** (было 90) — портрет 320×480 «вверх ногами» под
  физический монтаж. Сменить — дашборд rotate/flip или `screen-rotate.sh`.
- **setup: длительность установки** в финальном отчёте + Telegram («Время: Xм Yс»).
- **Дашборд будит экран** на старт бэкапа (USB), `/screenshot`, перегрев (≥80°C)
  и важный TG-алерт (tg-notify warning/error/critical пишет `wake-req`).
- **power-mode.conf удалён** — `power-mode.sh` его не читал (режим авто-детектится
  по `vcgencmd get_throttled`). Чистка ссылок в config-редакторах/perms/README.
- **filebrowser.conf → fix-conf-perms 600** (секрет, раньше не было в списке).

### Filebrowser
- Пароль стал детерминированным: образ s6 генерил случайный в залоченной bbolt
  (`users add` извне → 403). Решение — **pre-seed БД** одноразовыми `docker run`
  (`config init` + `users add|update` из `filebrowser.conf`) ДО старта сервера.
- Кратко был Quantum (`gtstef/filebrowser`) — откатили, UI не понравился. Вернули
  классический Filebrowser (образ `:v2` без s6), user 1000, root `/srv`.
- Меню setup: размеры whiptail по `tput cols/lines` — длинные `STACK_*` теги
  больше не вылезают за рамку.

### Новое
- **Syncthing Vellum**: тема (light+dark) ставится в `<config>/gui/` из репо
  pelinoleg/syncthing-vellum; дефолт `vellum-light` (правка `config.xml`).

## 2026-06-01 — Стеки Dozzle, Scrutiny, Navidrome

- **Dozzle** (:8083) — live-логи всех контейнеров, stateless.
- **Scrutiny** (:8084) — SMART-здоровье диска (omnibus). `setup.sh` резолвит блок-
  устройство T7 в `.env`, пробрасывает + `cap SYS_RAWIO/SYS_ADMIN` для smartctl.
- **Navidrome** (:4533) — стриминг музыки, библиотека `/mnt/storage/media/Music`.

## 2026-06-01 — CasaOS → Docker + Dockge; comitup на :80; Syncthing + Filebrowser

### Почему
CasaOS держал порт 80 (comitup captive-portal не работал в поле — отдавал «invalid
request»), ставил devmon (асинхронный авто-маунт ломал формат диска), тяжёлый.

### Сделано
- **Удалён CasaOS.** Docker ставится напрямую (apt-репо) — модуль `16-casaos.sh` →
  `16-docker.sh`. cgroup-memory фикс и NM no-docker.conf сохранены.
- **Dockge** (новый `16b-dockge.sh`, :5001) — web-менеджер compose-стеков в `/opt/stacks`.
- **Стеки — папка `stacks/` в репо** (вместо per-app модулей). Каждый стек —
  `stacks/<name>/{compose.yaml, meta.conf, setup.sh}`, перечислен в `stacks/index.txt`.
  Generic-модуль `17-stacks.sh` авто-деплоит выбранные в `/opt/stacks/<name>/`, wizard
  сам предлагает их (тег `STACK_<NAME>` из `meta.conf`). **Добавить приложение = папка
  в `stacks/` + строка в index.txt, новый модуль НЕ нужен.** Удалены per-app модули
  `17-photoview` / `18-ytarchiver` / `18b-syncthing` / `18c-filebrowser`.
- **Стеки** (все с `name:`): photoview (`/opt/photoview`→, :8000), ytarchiver
  (`/var/lib/casaos/apps`→, убран x-casaos, :8081), Syncthing (:8384,
  `/mnt/storage/sync`), Filebrowser (:8082, файл-менеджер + редактор `/etc/travel-nas`),
  Dozzle (:8083, live-логи контейнеров, stateless). Креды Filebrowser в
  `/etc/travel-nas/filebrowser.conf` (НЕ в git). Существующие контейнеры
  адаптируются по имени проекта.
- **comitup web_port 8090 → 80** — captive-portal детект бьёт в :80 (порт теперь свободен).
- devmon-ripples: формат диска глушит `udisks2` (а не devmon); pi-config-backup/
  restore — `/opt/stacks` вместо `/var/lib/casaos`; thermal-guard EXCLUDE `^casaos`→`^dockge`.
- setup.sh: компоненты `CASAOS` → `DOCKER DOCKGE` + `SYNCTHING FILEBROWSER`.
- Новый `docs/DOCKER.md`.

> Миграция: на боксе с CasaOS — `casaos-uninstall` (оставить Docker) → перезапуск
> setup. `16-docker.sh` детектит остатки CasaOS и предупреждает.

## 2026-05-31 — fix: Pi 5 usb_max_current РАНО (диск отваливался до монтирования)

### Storage / Pi 5
- **usb_max_current_enable=1 теперь ставится В НАЧАЛЕ `04-storage-mount`, безусловно
  для Pi 5** (было — только в mount-блоке, т.е. ПОСЛЕ детекта диска). Chicken-and-egg:
  без флага Pi 5 жмёт USB-ток до 600mA, SSD под нагрузкой браунит → `device offline`
  → диск исчезает из lsblk → wizard говорит «дисков не найдено» вместо «форматировать?».
  Теперь флаг ставится первым, с явным warn «сделай REBOOT». На свежей Pi 5 установке:
  setup → reboot → второй прогон видит стабильный диск.
- «Дисков не найдено» сообщение подсказывает про USB-power/reboot если флаг только добавлен.

## 2026-05-31 — универсальный storage-диск (без привязки к `t7`) + chrony

### Storage
- **Диск больше не завязан на имя `t7`.** «Свой» диск опознаётся по файлу-маркеру
  `.travel-nas-storage` в корне ФС — с ЛЮБЫМ label, переживает переустановку OS.
  Порядок детекта: UUID из conf → скан маркера → legacy-label `t7` → wizard.
- **Путь `/mnt/t7` → `/mnt/storage`** во всех скриптах, конфигах, сервисах,
  systemd-юнитах и Docker bind-mount'ах. Старые установки мигрируют автоматически
  при первом прогоне `04-storage-mount` (убирает legacy fstab-запись `/mnt/t7`,
  перемонтирует в `/mnt/storage`).
- Переименовано: модуль `04-t7-mount.sh` → `04-storage-mount.sh`, conf
  `t7-info.conf` → `storage-info.conf`, JSON-ключ статуса `t7` → `storage`,
  переменные `T7_*` → `STORAGE_*`, контейнерный путь Photoview `/t7` → `/storage`.
- **Wizard переработан:** показывает все подключённые диски (размер · ФС · метка ·
  модель), даёт выбрать. Уже ext4 и здоров (`e2fsck -fn`) → «Использовать как
  есть» (данные целы). Чужой/пустой диск → формат в ext4 с запросом имени диска.

### Utils
- **chrony** добавлен в UTILS — точное время/NTP (для travel-устройства с
  возможным RTC-дрейфом).

### NAS / Photo
- **NAS авто-бэкап (опц.)** — в wizard'е NAS_BACKUP спрашивается расписание:
  off / daily / weekly **+ кастомное время (HH:MM)** → systemd timer
  `nas-backup-auto`. Когда NAS недоступен (в поездке) — тихо пропускается
  (ping-guard в ExecStart), без фейла юнита и без Telegram-алёрта. `Persistent=true`
  — пропущенный из-за выключенного Pi бэкап догоняется при следующем включении.
- **Расписание живёт в `nas-backup.conf`** (`AUTO_BACKUP` / `AUTO_BACKUP_FREQ` /
  `AUTO_BACKUP_TIME`, с кастомным временем HH:MM) — как все настройки проекта.
  Правка руками применяется автоматически через path-unit `nas-schedule-apply`.
  `nas-schedule.sh` (status/apply/set/off/toggle) синхронит systemd-timer с конфигом.
- **Дашборд → NAS status**: строка `auto-backup: daily HH:MM` + кнопка **Auto on/off**
  (`sudo nas-schedule.sh toggle` правит конфиг). Низ страницы `Back | Auto | Refresh`.
  Новый sudoers-вызов → нужен двойной прогон update.
- **Фикс**: миграция `/mnt/t7`→`/mnt/storage` теперь чинит и пути в
  `/etc/travel-nas/*.conf` (DEST). Раньше старый DEST в конфиге ломал
  nas-backup/photo-backup (писали/сканировали мёртвый путь) — статус показывал `?`.
- **photo-backup guard** — отказ + Telegram-алёрт если storage-диск не
  примонтирован (раньше тихо лил импорт на microSD; был инцидент 6.6 ГБ).

### YT-Archiver
- **CPU-лимит контейнера** (ffmpeg-превью забирал ~3.4 ядра из 4 и клал
  отзывчивость). Жёсткий `deploy.resources.limits.cpus`, выносится в
  `yt-archiver.conf` → `YT_CPU_LIMIT` (дефолт `2.0`, с комментами и примерами
  1.0/2.0/3.0/4.0). Применить на лету: `docker update --cpus=2.0 ytarchiver-backend`.

### Универсальность (reflash-proof)
- Имя пользователя больше не захардкожено `oleg` — резолвится из uid 1000
  (юзер из Pi Imager): `getent passwd 1000` / `pwd.getpwuid(1000)`. Затронуты
  chown в photo/nas-backup, fix-conf-perms, SSH-подсказки (+ `{user}` подстановка).
- **security**: пароль убран из закоммиченных файлов (репо публичный); требуется
  ротация пароля владельцем (остался в git-истории).

> ⚠️ Миграция живого устройства: после `travel-nas-update` (fast) скрипты будут
> ждать `/mnt/storage`, а диск ещё в `/mnt/t7`. Нужен полный `travel-nas-setup`
> (выбрать минимум STORAGE_MOUNT + SAMBA + PHOTOVIEW + VERIFY) и **reboot** —
> модуль мигрирует fstab и перемонтирует, остальные модули перегенерят конфиги
> с новым путём. CasaOS-апы с ручным bind-mount на `/mnt/t7` поправить вручную.

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
