# Dashboard V2 — Web + Chromium Kiosk на DSI-экране

Документ-парковка идей под новый экран **Waveshare 4.3″ DSI 800×480 IPS capacitive** который поставится в Pi 4 (отдельный travel-NAS, второй девайс — не заменяет существующий с MHS35).

## Решение архитектуры

| Что | Решение |
|---|---|
| **UI движок** | Web app — FastAPI backend + HTMX/Alpine.js + Tailwind CSS + uPlot (charts). Один код для физического экрана и удалённого доступа через Tailscale. |
| **Kiosk** | `chromium-browser --kiosk --noerrdialogs --disable-infobars --autoplay-policy=no-user-gesture-required http://localhost:5000` (LXDE autostart) |
| **Старый pygame** | **Остаётся в репо**. НЕ в автозагрузке. Можно переключать через CLI/команду (см. ниже). Для аварийных случаев / SPI-сетапов без DSI. |
| **Live-обновления** | Server-Sent Events (SSE) — проще WebSocket, отлично работает с HTMX |
| **Backend код** | Переиспользовать функции из `travel-nas-display.py` (Cached pattern, status getters, action handlers) — обернуть их в FastAPI endpoints |
| **Стейт** | Тот же — `/var/lib/travel-nas/*.json`, `/var/run/travel-nas/*` |
| **Telegram** | Остаётся как был, только обновим вызовы action-функций (если выносим в общий `nas_core.py` модуль) |

## Переключение режимов

```bash
sudo dashboard-mode.sh web      # autostart Chromium kiosk, остановить pygame
sudo dashboard-mode.sh pygame   # autostart pygame, не запускать Chromium
sudo dashboard-mode.sh status   # что сейчас активно
```

Меняет `~/.config/autostart/*.desktop` файлы — отключает один, включает другой. **Никаких systemd unit'ов** трогать не нужно (текущий pygame autostart через LXDE как был).

## Миграция (порядок)

1. **Pi 4 + DSI приходит**. Ставим заново с нуля — будет «v2 reference setup».
2. На него ставим FastAPI + HTMX каркас, **только web mode**. pygame не ставится.
3. Параллельно работают: текущий Pi 5 на pygame, новый Pi 4 на web. Сравниваем.
4. **Если web лучше** (вероятно) — на Pi 5 тоже ставим, переключаем `dashboard-mode.sh web`. pygame остаётся в `/usr/local/bin/`, можно вернуться `dashboard-mode.sh pygame`.
5. Если web хуже — оставляем pygame на обоих, отказываемся от плана.

## Feature pool (в свободном порядке, выбираем когда дойдёт)

### Уже точно нужно (из текущего разговора)

- [ ] **Графики** — CPU temp 24ч, T7 used бар во времени, throughput backups, throttle events
- [ ] **File browser** `/mnt/t7/` с thumbnail'ами (libvips/sharp для preview), delete/move/rename
- [ ] **Backup folder picker** — tree-view выбор папок NAS-модулей, чекбоксы. Заменяет ручное редактирование `nas-backup.conf`.
- [ ] **Логи с фильтром/поиском** — все `/mnt/t7/_logs/*.log` в одном UI, regex search, follow tail, syntax highlight для ERROR/WARN
- [ ] **Тестовый ввод** — токены TG, NAS-password, services-conf редактор прямо в UI (сейчас pygame не умеет input)
- [ ] **Удалить файлы** — корзина с move-to-trash (как `_deleted/`)

### NAS-расширения

- [ ] **Storage analyzer** — du-style визуализация (sunburst/treemap) что съело T7. По папкам, по типу файла.
- [ ] **Duplicate finder** (jdupes wrap) — найти и почистить дубли в `usb-imports/`
- [ ] **Smart trash browser** — что в `_deleted/` от nas-backup, восстановить файл одной кнопкой
- [ ] **Backup timeline** — календарь когда что бэкапилось, размер дельта, длительность
- [ ] **«Что нового сегодня»** — список файлов добавленных за последние 24ч
- [ ] **Folder bookmarks** — quick-access к Music/Photos-Other/...

### Photography-specific (твой кейс)

- [ ] **Photo gallery встроенная** — без Photoview, нативно в UI, листание свайпом, EXIF панель
- [ ] **Photo cull mode** — left/right swipe для keep/reject, как Lightroom mobile. Бракованные → `_rejected/` папка.
- [ ] **EXIF batch editor** — массово поставить GPS / copyright по выборке
- [ ] **Auto-sort by EXIF date** — кнопка «организовать `usb-imports/` в `Photos/YYYY/MM-DD/`»
- [ ] **RAW thumbnail generator** — после import сгенерить превью (.thumb/) чтобы галерея летала
- [ ] **«Backup before flight» mode** — копирует выбранные папки на дополнительный USB / SD

### Travel-specific

- [ ] **Battery widget** — если поставишь INA219/UPS HAT, текущее напряжение/ток/процент
- [ ] **Power consumption graph** — ваты во времени, видно сколько кушает на powerbank'е
- [ ] **WiFi сканер + connect** — заменяет comitup web-portal, видно networks с уровнем сигнала, тапнул → SSID + password
- [ ] **QR-коды для share** — кнопка «Сгенерировать QR для Samba URL» / Photoview / SSH — на телефоне сканируешь и open. Удобно когда показываешь кому-то фото.
- [ ] **Speed test** — `iperf3` к домашнему NAS или speedtest-cli, видно реальную скорость WiFi в текущей точке
- [ ] **Tailscale device list** — кто online, latency, кнопка ping
- [ ] **Captive portal helper** — детектит «WiFi есть но нет интернета», открывает portal-URL в этом же Chromium
- [ ] **Map с текущим местоположением** — если поставишь GPS dongle (или просто IP geo)
- [ ] **«Trip log»** — когда устройство было on, где (по GPS / WiFi BSSID), время непрерывной работы

### Media / fun

- [ ] **Music player** — листание `/mnt/t7/Music/`, cover art, queue, play (mpd/mpv бэкендом). Bluetooth наушники → travel-плеер.
- [ ] **Photo slideshow** — авто-показ последнего USB-import'а после копирования (отдельная full-screen mode)
- [ ] **DLNA-каст** — на ТВ в отеле «Сast to TV»
- [ ] **Internet radio** — стримы в дороге

### Maintenance / diagnostics

- [ ] **«Diagnostics report» one-tap** — журнал + dmesg + status JSONы + verify результат в zip → положить на T7 + послать в TG. Полезно когда что-то идёт не так в дороге.
- [ ] **Failed units panel** — список `systemctl --failed` с restart-кнопкой
- [ ] **SMART history** — графики атрибутов SSD во времени (Power_On_Hours, Wear_Level)
- [ ] **«Force scrub now»** — кнопка запуска `nas-verify` с прогресс-баром
- [ ] **Container restart history** — graph «когда что упало»

### Security / privacy

- [ ] **Lockscreen с PIN** — для travel, чтоб кто попало не тыкнул экран
- [ ] **LUKS toggle** — кнопка «зашифровать T7» (с подтверждениями)
- [ ] **Failed SSH** — список откуда пытались зайти
- [ ] **Audit trail** — кто/когда что менял (если работают несколько пользователей)

### Smart home integration

- [ ] **MQTT publish** — статус travel-NAS в Home Assistant
- [ ] **Webhook on backup** — POST к URL когда NAS backup завершился
- [ ] **Home Assistant tile** — карточка для HA dashboard

## Открытые вопросы (решим когда экран приедет)

- **Frontend complexity:** HTMX + Alpine хватит, или сразу Svelte/Vue? HTMX даст ~80% возможностей при 20% сложности. Думаю стартуем с HTMX, переедем на framework если упрёмся.
- **Сборка:** HTMX без сборки. Если выбираем framework — нужно решать с Vite/esbuild на Pi (медленнее).
- **Auth:** Локально без auth (kiosk), удалённо через Tailscale ACL. Или нужен лог-ин для web-доступа с phone'а?
- **Lcheck:** chromium крашится при OOM? Pi 4 8GB вытянет, но стоит ли watchdog'нуть с auto-restart.
- **Multi-user:** мама хочет смотреть фото — нужен read-only режим? Photoview это уже даёт. Можно redirect.
- **Offline:** что показывает страница если бэкенд лёг? «Service unavailable» или cached snapshot?

## Что НЕ делать (anti-features)

- Не пытаться писать responsive «на телефоне». 4.3″ 800×480 это сам по себе уже не телефонный размер. Делать чисто под этот экран. Если хочется на mac — тот же URL через Tailscale, просто отобразится больше пустого места по краям. Норм.
- Не строить «универсальный конструктор виджетов» — это путь к paralysis. Жёсткий layout = быстрая разработка.
- Не тащить React/Next.js — overkill, сборка длинная, deploy сложный.

## Сохранение pygame как альтернативы

```bash
sudo dashboard-mode.sh pygame
# 1. Killает chromium kiosk (если идёт)
# 2. Меняет ~/.config/autostart/ — отключает chromium-kiosk.desktop,
#    включает travel-nas-display.desktop
# 3. Запускает pygame через systemd-run --uid=oleg (как сейчас travel-nas-update делает)
```

И обратно `sudo dashboard-mode.sh web`. Этот скрипт сделаем сразу в первом же сетапе v2.
