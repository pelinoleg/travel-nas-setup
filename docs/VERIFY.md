# Backup verify scrub

`nas-verify.py` — ежемесячный систэмди-таймер, который ловит две вещи:

1. **Bit-rot** — когда SSD молча портит уже записанные байты (один из ~10⁻¹⁴ для NAND, на 4 TB заметно).
2. **Bad sectors / I/O errors** — пока диск ещё пишет, но какие-то сектора уже не читаются.

## Как работает

1. Обходит `/mnt/t7/usb-imports` и `/mnt/t7/nas-backup` (можно переопределить через `--target`).
2. Для каждого файла:
   - Читает все байты → ловит I/O ошибки на уровне ядра (попадают в `dmesg`)
   - Считает `sha256` → попадает в манифест `_logs/verify-manifests/YYYYMMDD-HHMMSS.tsv`
3. Манифест формат TSV: `<sha256>\t<mtime>\t<size>\t<path>`
4. Сравнивает с прошлым манифестом:
   - **`added`** — файлы которых не было — норма (например, новый бэкап)
   - **`deleted`** — файлы которые удалили — норма (например, `_deleted/` rotation)
   - **`changed_normal`** — hash другой, но `mtime` или `size` тоже изменился — норма (rsync обновил)
   - **`bitrot`** — hash другой, при этом `mtime` И `size` совпали → **тихая коррупция**
5. Параллельно считает `I/O error`, `Buffer I/O error`, `EXT4-fs error`, `Medium Error`, `blk_update_request` в `dmesg`.
6. Пишет JSON-итог в `/var/lib/travel-nas/verify-status.json` (читается дашбордом и `/verify`-командой).
7. Если что-то найдено — алёрт в Telegram через `tg-notify.sh -l warning`.

## Сколько занимает

- `sha256sum` на Pi 5 + T7 USB-3.0: **~250-300 MB/s** read + hash
- На ~600GB → **30-45 минут**
- На полные 4 TB → **3-4 часа**
- Запланировано на 1 число месяца ~03:00. `Persistent=true` — если был выключен, догонит при загрузке.
- `Nice=15` + `IOSchedulingClass=idle` — не мешает фоновому Photoview/Samba.

## Команды

```bash
# CLI
sudo systemctl start nas-verify.service          # запустить scrub сейчас (фон)
journalctl -u nas-verify.service -f              # следить за прогрессом
nas-verify.py --status                           # JSON последнего запуска
sudo nas-verify.py --target usb-imports          # только photo-имматериал

# Список манифестов (последние 6 хранятся)
ls -lt /mnt/t7/_logs/verify-manifests/
```

```
# Telegram
/verify           — последний статус + что нашёл
/verify run       — запустить scrub в фоне
```

## Что показывает дашборд

На странице **Storage** в нижней секции (если verify хоть раз запускался):

```
Last verify                                ✓ ok
2d ago                       1234 files · 0 bit-rot
```

При проблемах `✓ ok` → `✗ alert` красным, число bit-rot подсветится.

## Trade-offs

- **Не btrfs / zfs**: T7 на ext4. Btrfs/ZFS дали бы scrub нативно, но требуют переформатирования и берут больше CPU при записи.
- **sha256 не b3sum**: B3 в 5-10× быстрее, но пакета нет в дефолтной PiOS. Раз в месяц 30 минут — не повод тащить отдельный пакет.
- **Манифест на T7, не на microSD**: иначе расход microSD wear. Но если T7 умирает целиком — последний манифест умирает с ним. Это приемлемо: bit-rot ловится в течение месяца, до катастрофы.
- **Только sha256, не verify-against-source**: не сверяемся с домашним NAS (rsync `--checksum --dry-run`) — это потребовало бы прохода NAS целиком, что 6+ часов. Манифест на самом T7 ловит проблемы T7, не источника.

## Удалить

```bash
sudo systemctl disable --now nas-verify.timer
sudo rm /etc/systemd/system/nas-verify.{service,timer}
sudo systemctl daemon-reload
# Манифесты и логи можно оставить — занимают мало.
```
