# Travel-NAS Setup v2 (T7 edition)

Infrastructure-as-Code для travel-NAS на Raspberry Pi 5 с Samsung T7 Shield SSD.

## Установка одной командой

```bash
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/setup.sh -o setup.sh && bash setup.sh
```

Откроется интерактивное меню — выбери компоненты галочками.

## Что устанавливается

| Компонент | Назначение |
|---|---|
| 📡 **Comitup** | Полевой WiFi AP-режим (если нет WiFi) |
| 💾 **T7 auto-mount** | Samsung T7 Shield в `/mnt/t7` через fstab |
| 📁 **Samba** | SMB-шара `smb://travel-nas.local/travel-nas` (открытая) |
| 📷 **Photo backup** | udev + rsync + Telegram — автокопирование SD/USB |
| 🏠 **NAS backup** | Manual бэкап с UGREEN NAS через rsync daemon |
| 💼 **Pi config backup** | Еженедельный бэкап конфигов на T7 |
| 🐕 **Disk watchdog** | Мониторинг T7 (SMART, temp, mount, space) |
| 💻 **System monitor** | CPU/temp/throttling Pi |
| 📊 **Daily summary** | Вечерний отчёт в Telegram (21:00) |
| 📱 **TG-notify** | Единый helper для всех Telegram уведомлений |
| 💾 **Log2ram** | Логи в RAM → microSD живёт дольше |
| 🗜️ **ZRAM** | Сжатый swap с zstd |
| 🏠 **CasaOS** | Опционально для Photoview/Syncthing |
| 🖼️ **Photoview** | Опциональная web-галерея фотографий |
| 🖥️ **MHS35 display** | 3.5" сенсорный экран + Python dashboard |

## Структура файлов на T7

```
/mnt/t7/
├── nas-backup/           # с UGREEN NAS (АВТОЧИСТКА когда <10% места)
│   ├── Personal/
│   ├── Docker/
│   ├── Photos-Other/
│   ├── Music/
│   ├── _deleted/<DD-MM-YYYY>/
│   └── _logs/
│
├── usb-imports/          # бэкапы USB/SD (НЕ ЧИСТИТЬ автоматически)
│   ├── <DD-MM-YYYY>/
│   │   ├── HH-MM_<label>_<uuid>/
│   │   └── ...
│   └── ...
│
├── pi-config-backups/    # 4 копии конфигов Pi
├── media/                # твои медиа (вручную)
├── sync/                 # для Syncthing
└── _logs/                # логи скриптов
```

## Архитектура конфигов

**Секреты НЕ хранятся в git!** Они в `/etc/travel-nas/`:

```
/etc/travel-nas/
├── tg-notify.conf        # Telegram bot token + chat_id (chmod 600)
├── nas-backup.conf       # NAS IP/user/pass + список модулей (chmod 600)
├── photo-backup.conf     # настройки автобэкапа SD
└── t7-info.conf          # UUID нашего T7
```

В git коммитятся только примеры в `conf-examples/`.

## Telegram уведомления

Три уровня важности:

- 🟢 **Info** — копится в очередь, отправляется в daily summary
- 🟡 **Normal** — сразу (старт/конец бэкапа, прогресс)
- 🔴 **Critical** — сразу + повтор через час если проблема не исчезла

Конфиг: `/etc/travel-nas/tg-notify.conf`

## Доступ

- **Samba**: `smb://travel-nas.local/travel-nas` (Cmd+K в Finder)
- **CasaOS**: `http://travel-nas.local` (если установлен)
- **Photoview**: `http://travel-nas.local:8000` (если установлен)
- **SSH**: `ssh oleg@travel-nas.local`

## Восстановление из бэкапа

При замене microSD или переустановке:

```bash
# 1. Установить чистую Pi OS Desktop
# 2. Запустить setup.sh (поднимет базу)
bash setup.sh --all
sudo reboot

# 3. Восстановить конфиги из бэкапа на T7
curl -fsSL https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main/restore-pi-config.sh -o restore.sh
bash restore.sh
sudo reboot
```

## Дата формата

Везде используется EU-формат: `DD-MM-YYYY`. Например `27-05-2026`.

## Поддержка повторного запуска

`setup.sh` можно запускать сколько угодно раз — он:
- Пропускает уже установленные пакеты
- Не перезаписывает существующие конфиги
- Обновляет только сами скрипты в `/usr/local/bin/`

## Ручные команды

```bash
# Запустить бэкап Pi config сейчас
sudo /usr/local/bin/pi-config-backup.sh

# Бэкап с NAS (интерактивно)
sudo nas-backup.sh

# Бэкап с NAS (без вопросов)
sudo nas-backup.sh --run

# Симуляция NAS-бэкапа
sudo nas-backup.sh --dry-run

# Diff с NAS (что изменится)
sudo nas-backup.sh --diff

# Тест photo-backup вручную
sudo photo-backup.sh /dev/sdX1

# Проверить watchdog
sudo systemctl status disk-watchdog.timer
sudo journalctl -u disk-watchdog.service -f

# Тест Telegram
/usr/local/bin/tg-notify.sh "Test" "Hello from Travel-NAS"

# Логи
tail -F /mnt/t7/_logs/*.log
```

## Hardware

- Raspberry Pi 5 (8GB RAM)
- Samsung T7 Shield SSD 4TB (USB 3.2 Gen 2, IP65)
- microSD 64GB+ (для системы)
- Pi 5 27W блок питания (комплектный)
- (Опционально) MHS35 3.5" touch display
- (Опционально) Powerbank с 5V/5A USB-C (Anker 737, Prime 27650)

## Lessons learned

- **NVMe через N04 PCIe HAT нестабилен** — стабильнее USB SSD
- **Kingston SNV2S без DRAM не для NAS-нагрузки** — TLC SSD с DRAM лучше
- **lbb (Little Backup Box) конфликтует с CasaOS/fstab** — заменён собственным photo-backup
- **EXT4 надёжнее exFAT** на тяжёлой записи

См. историю проекта в коммитах для деталей.
