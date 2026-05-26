# Travel-NAS на Raspberry Pi 5

Универсальный скрипт настройки **Raspberry Pi 5 + Little Backup Box + CasaOS** как мобильного NAS для бэкапа SD-карт с фотоаппарата и хранения данных в поле.

## TL;DR

**Одной командой:**
```bash
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/setup-lbb.sh -o setup-lbb.sh && bash setup-lbb.sh
```

**Или через git (если планируешь дорабатывать):**
```bash
git clone https://github.com/pelinoleg/travel-nas-setup.git
cd travel-nas-setup
bash setup-lbb.sh
```

Откроется интерактивное меню — отметишь галочками что нужно, нажмёшь OK, через 30 минут готовый травел-NAS.

**Без меню (поставить всё):**
```bash
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/setup-lbb.sh -o setup-lbb.sh && bash setup-lbb.sh --all
```

## Что внутри

`setup-lbb.sh` ставит и настраивает:

| Компонент | Описание |
|---|---|
| 🔧 **PCIe + NVMe** | Параметры стабильности для NVMe (без них NVMe падает с "controller is down") |
| 👤 **Юзер pi** | lbb требует именно `pi`, скрипт создаст с паролем `hammett` |
| 📦 **Утилиты** | htop, ncdu, tmux, git, nvme-cli, smartmontools, rsync, tree, jq |
| 💾 **NVMe auto-mount** | Через `/etc/fstab` в `/mnt/nvme_target` — не конфликтует с lbb (он работает с `/media/`) |
| 📷 **Little Backup Box** | Веб-интерфейс для бэкапа SD-карт фотоаппарата |
| 🏠 **CasaOS** (опц.) | Home-NAS dashboard на порту 80 (http://lbb.local) |
| 🗂 **Samba** | Открытая SMB-шара для Mac/iPhone в домашней сети |
| 💿 **Log2ram** | Логи в RAM → microSD живёт дольше |
| ⚡ **ZRAM tuning** | Оптимизация под бэкап-задачи (zstd, swappiness=10) |
| 💼 **Auto-backup** | Еженедельный бэкап конфига Pi на NVMe |
| 🖥 **LCD 3.5"** (опц.) | Драйвер для MHS35-экрана (CUQI/goodtft) |

## Применимость

Скрипт заточен под конкретную сборку, но легко адаптируется:

**Тестировано:**
- Raspberry Pi 5 8GB
- 52Pi N04 M.2 NVMe HAT (top-mount)
- Pi OS Desktop (Bookworm/Trixie)
- Kingston / Samsung 2TB NVMe

**Должно работать:**
- Pi 4 (без PCIe-настроек, остальное OK)
- Pi 5 с другими NVMe-платами (Pimoroni, Pineberry)
- Pi OS Lite (просто пропускаешь LCD-блок)

## Использование

### Интерактивный режим
```bash
bash setup-lbb.sh
```
Откроет TUI-меню с галочками.

### Поставить всё подряд
```bash
bash setup-lbb.sh --all
```

### Повторный запуск
Можно запускать сколько угодно раз — уже установленное пропустится.
Удобно для добавления новых компонентов через несколько недель.

## После установки

### Доступ к веб-морде:
- **CasaOS**: http://lbb.local (основной дашборд)
- **Little Backup Box**: http://lbb.local:8080 (специальный инструмент для бэкапа)
- **Samba шара**: `smb://lbb.local/travel-nas` (с Mac: Cmd+K в Finder)

### Первичная настройка lbb через веб:
1. Зайти на http://lbb.local:8080
2. Settings → Backup → выбрать source/target
3. Tools → проверить что NVMe видно как Int. storage

### CasaOS первый запуск:
1. http://lbb.local:100 → создать аккаунт
2. App Store → можно поставить Immich, Paperless, etc.
3. Все контейнеры хранят данные в `/mnt/nvme_target/casaos-data/`

## Полевой режим (comitup)

При установке lbb включается **comitup** — Pi автоматически:
- Если знакомый Wi-Fi есть → подключается к нему
- Если нет → поднимает свою Wi-Fi точку `little-backup-box-XXXX`

С iPhone подключаешься к этой точке → открываешь `http://10.41.0.1` → видишь lbb.

## Архитектурные решения

**Почему юзер `pi`?** lbb-разработчики настаивают на этом имени и есть [issue](https://github.com/outdoorbits/little-backup-box/issues) когда другие имена ломают часть функций. Параллельно скрипт сохраняет любого существующего юзера (типа `oleg`) для SSH.

**Почему NVMe монтируется в `/mnt/` а не в `/media/`?** lbb использует `/media/` как свою рабочую директорию и может перетирать чужие папки. `/mnt/` — стандартное место для постоянных монтирований по Linux-конвенции (`/media/` для съёмных), и lbb туда не лезет.

**Почему NVMe монтируется через fstab, а не через CasaOS или lbb?** Системное монтирование надёжнее: работает всегда, даже если CasaOS/lbb сломаются. Скрипт также добавляет NVMe в `--ignore-device` для CasaOS devmon, чтобы тот не перехватывал диск в свой `/mnt/tech_NVME_target`.

**Почему PCIe Gen 1, а не Gen 3?** На плате 52Pi N04 + Pi 5 + большинство NVMe — Gen 3 нестабилен (controller crashes). Gen 1 даёт честные ~250 MB/s, что для бэкапа фоток с UHS-II SD карт более чем достаточно.

**Почему CasaOS на порту 80?** Это его дефолтный порт, всё работает из коробки. lbb по дефолту слушает 8080 и 443 (HTTPS), поэтому порт 80 свободен. Архитектурно: CasaOS — основной дашборд (открывается без указания порта), lbb — специальный инструмент (на 8080).

## Бэкап-стратегия

Скрипт ставит **автобэкап конфига Pi**:
- Раз в неделю (воскресенье 03:00) сохраняет важные файлы (`/etc/fstab`, `samba`, `cmdline.txt`, `config.txt`, lbb-config, список пакетов, docker-контейнеры, crontabs)
- Хранит последние 4 копии (~месяц)
- Лежит на NVMe (`/mnt/nvme_target/pi-config-backups/`)

Если microSD умрёт — берёшь свежий microSD, ставишь Pi OS, клонируешь репо, запускаешь скрипт, восстанавливаешь конфиг из бэкапа. Полное восстановление за ~1 час.

Запустить вручную:
```bash
sudo /usr/local/bin/backup-pi-config.sh
```

## Восстановление из бэкапа

Если microSD умер или ставишь travel-NAS на новый Pi:

1. Поставь чистую Pi OS Desktop, зайди по SSH
2. Запусти `setup-lbb.sh` — поднимется база системы
3. Подключи NVMe со старыми бэкапами (он смонтируется в `/mnt/nvme_target`)
4. Запусти восстановление:

```bash
curl -fsSL https://raw.githubusercontent.com/pelinleg/travel-nas-setup/main/restore-pi-config.sh -o restore-pi-config.sh
bash restore-pi-config.sh
```

Откроется интерактивное меню — выберешь бэкап (последний или любой из 4 имеющихся), отметишь галочками что восстанавливать (fstab, samba, lbb config, CasaOS apps, и т.д.), и скрипт всё сделает.

**Что восстанавливается:**
- `/etc/fstab`, `/etc/samba/`, `/etc/network/`
- `/boot/firmware/cmdline.txt` (NVMe-фиксы)
- `/boot/firmware/config.txt` (PCIe Gen 1)
- `/var/www/little-backup-box/config.cfg` (профили lbb)
- `/var/lib/casaos/apps/` (compose-файлы установленных приложений)
- `/var/lib/casaos/db/` (метаданные CasaOS)
- `/etc/casaos/` (глобальные настройки CasaOS)
- `/etc/conf.d/devmon` (защита от перехвата дисков)
- Crontab root
- Опционально: переустановка всех apt-пакетов из списка

**Что НЕ восстанавливается** (это отдельные сущности):
- Данные приложений (фото Immich, документы Paperless и т.д.) — они в `/DATA/` или на NVMe в подпапках, бэкап-стратегия отдельная (restic, rclone)
- Docker-образы — скачаются заново при `docker compose up`
- Бэкапы фоток lbb — лежат на NVMe, никуда не девались

Все перезаписанные файлы сохраняются с суффиксом `.before-restore-<timestamp>` — если что-то сломалось, можно откатиться.

## Troubleshooting

### NVMe падает с "controller is down"
Скрипт уже добавил параметры в `/boot/firmware/cmdline.txt`. Если после ребута всё равно падает — попробуй понизить PCIe ещё:
```bash
sudo nano /boot/firmware/config.txt
# уже должно быть dtparam=pciex1_gen=1
```
Если и это не помогает — проверь питание (нужен минимум 27W PD).

### LCD-экран чёрный после установки lbb
Запусти скрипт ещё раз только с галочкой LCD. Или вручную:
```bash
sudo nano /boot/firmware/config.txt
# закомментируй: include lbb-display.txt
```

### lbb не пускает в веб
Дефолтный basic auth: username **`lbb`**, пароль тот что задал при установке.

### Samba шара не видна с Mac
Проверь что Pi и Mac в одной сети:
```bash
ping lbb.local
# Если не пингуется — используй IP вместо .local
```

## Контрибьют

Нашёл баг? Хочешь добавить новый компонент?
- Открой issue с описанием
- Или сразу PR с изменениями в `setup-lbb.sh`

## Лицензия

MIT — используй как хочешь.

## Авторам

Скрипт собран в процессе совместной отладки [Little Backup Box](https://github.com/outdoorbits/little-backup-box) на Pi 5 — много граблей по дороге.