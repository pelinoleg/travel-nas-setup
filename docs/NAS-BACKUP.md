# NAS Backup (`nas-backup.sh`)

Скрипт **incremental backup** с домашнего NAS (UGREEN / Synology) на travel-NAS T7 SSD через **rsync daemon**.

Адаптирован для travel-NAS Pi из домашнего Mac-варианта. Главные отличия от Mac-версии:
- Self-reexec через `systemd-run` → переживает рестарт dashboard'а / SSH сессии
- Прогресс пишется в `/var/run/travel-nas/backup-progress.json` → dashboard видит live
- Telegram уведомления о старте / финале / ошибках
- Stop button на дашборде (systemctl stop nas-backup-runtime)

---

## Что делает

Копирует данные с **home NAS** (`192.168.1.95` по дефолту) на **T7 SSD** travel-NAS'а через rsync daemon, поддерживая **мирроринг**:

- Новые файлы на NAS → копируются на T7
- Изменённые файлы → перезаписываются
- Удалённые с NAS → удаляются и с T7 (но не теряются — см. ниже)
- Файлы которые есть на T7 но нет на NAS → перемещаются в `_deleted/<DATE>/`

То есть это **синхронизация с soft-delete**: если случайно удалил с NAS файл — он жив в `_deleted/`.

---

## Архитектура: пути и rsync modules

### Почему через SFTP/SSH видишь `/volume1/...` а в скрипте `home`, `Backup`, `PMedia`

NAS (UGREEN/Synology) предоставляет **два разных интерфейса** к одним и тем же данным:

| Интерфейс | Как видишь файлы | Чем подключаешься |
|---|---|---|
| **SFTP/SSH** | `/volume1/Personal/` (file system path) | Filezilla / `ssh user@nas` / Finder |
| **SMB/CIFS** | `Personal` (share name) | macOS Finder Cmd+K |
| **rsync daemon** | `home`, `docker`, `PMedia` (module names) | `nas-backup.sh` |

**rsync daemon** на NAS работает на порту 873 и читает конфиг `/etc/rsyncd.conf` (или эквивалент в UGREEN UI). Там для каждой шары прописан **rsync module** — короткое имя, которое мапится на physical path:

```ini
# Пример /etc/rsyncd.conf на NAS
[home]
    path = /volume1/Personal
    comment = User home
    read only = yes
    auth users = oleg
    secrets file = /etc/rsyncd.secrets

[docker]
    path = /volume2/Docker
    read only = yes
    ...
```

Когда наш скрипт делает `rsync user@nas::home/`, NAS rsync daemon **видит, что `home` мапится на `/volume1/Personal`**, и кидает оттуда файлы.

**Поэтому** в конфиге `nas-backup.conf` модули записаны как `home|Personal`, не `Personal|Personal`:
- `home` — это **rsync module** на NAS (как настроено в `rsyncd.conf` на NAS)
- `Personal` — это **target папка** на T7 (`/mnt/t7/nas-backup/Personal/`)

Если на NAS rsync-модуль называется иначе — нужно менять левую часть `MODULES=` в конфиге.

### Где посмотреть какие модули доступны

С Pi:

```bash
nas-backup.sh
# → выбрать "6. Test connectivity"
# покажет:
#   home    User home directory
#   docker  Docker volumes
#   PMedia  Personal media
#   ...
```

Или вручную:
```bash
sshpass -p PASSWORD rsync user@192.168.1.95::
```

Левая колонка — то что пишешь в `MODULES=` слева от `|`.

### Можно ли писать subpath / абсолютный путь?

| Формат в `MODULES=` | Работает | Пример |
|---|---|---|
| `module` | ✅ | `home\|Personal` |
| `module/subpath` | ✅ если subpath существует | `HDD6TB/Photos\|MyPhotos` |
| `module/.dotfile` | ✅ | `home/.config\|MyConfig` |
| `module/deeper/path` | ✅ | `HDD6TB/Media/Movies\|Movies` |
| `/volume1/...` | ❌ ERROR: must start with module name | rsync daemon не принимает абс. пути |
| `volume1/...` | ❌ Unknown module 'volume1' | volume1 не модуль |
| `module/../other` | ❌ rsync chroot блок | нельзя выйти за модуль |

**Безопасность**: rsync daemon работает в chroot per-module. Невозможно случайно забэкапить `/etc` или вылезти за пределы модуля. При неверном пути `nas-backup.sh --diff` сразу выдаст ошибку — не нужно ждать backup чтобы понять что путь кривой.

**Trailing slash не важен**: `home/` и `home` идентичны.

**Excludes относительны к subpath**: если бэкапишь `HDD6TB/Photos`, `--exclude=".cache/"` фильтрует `HDD6TB/Photos/*/.cache/`, не `HDD6TB/.cache/`.

---

## Использование

### Из CLI (на Pi через SSH)

```bash
sudo nas-backup.sh              # whiptail menu (интерактивно)
sudo nas-backup.sh --run        # запустить backup сразу
sudo nas-backup.sh --dry-run    # симуляция (не копирует, только показывает что бы скопировал)
sudo nas-backup.sh --diff       # показать что отличается NAS vs T7 (без копирования)
sudo nas-backup.sh --config     # редактировать конфиг
```

### Из дашборда

**Menu → NAS → Run backup** — запускает `--run` mode.

Когда backup активен:
- Карточка на главной показывает progress в real-time
- Кнопка **Run** превращается в **Stop**
- Tap на progress card → детали (%, files done, speed, ETA)

### Из Telegram

```
/backup       # запустить backup
/backup dry   # dry-run
/backup diff  # показать diff
```

---

## Конфиг: `/etc/travel-nas/nas-backup.conf`

```bash
NAS_HOST="192.168.1.95"          # IP или hostname домашнего NAS
NAS_USER="oleg"                  # user для rsync daemon
NAS_PASS="..."                   # password из rsyncd.secrets на NAS

DEST="/mnt/t7/nas-backup"        # куда копировать на T7

# MODULES — какие шары забирать.
# Формат: "rsync_module|local_folder"
#   rsync_module = имя в `rsync user@nas::` (см. Test connectivity)
#   local_folder = название папки на T7 под /mnt/t7/nas-backup/
MODULES=(
    "home|Personal"              # NAS::home → /mnt/t7/nas-backup/Personal/
    "docker|Docker"              # NAS::docker → /mnt/t7/nas-backup/Docker/
    "Backup|Backup"
    "PMedia|PMedia"
    "Music|Music"
)

# EXCLUDES — что НЕ копировать (передаётся как --exclude в rsync)
EXCLUDES=(
    "_gsdata_" ".DS_Store" "Thumbs.db" "@eaDir/"
    "#recycle/" ".Trash*" "*.tmp" ".cache/"
    "node_modules/" "__pycache__/" "vendor/"
    ".next/" ".nuxt/" "dist/" "build/" ".git/" ".svn/"
)
```

`NAS_PASS` хранится в **plain text** в этом файле (chmod 600 root). Это компромисс ради автоматизации — secret не уходит в логи / процесс-листинг (передаётся через `sshpass -p`).

---

## Где что лежит после backup'а

```
/mnt/t7/nas-backup/
├── Personal/                    # mirror NAS::home
├── Docker/                      # mirror NAS::docker
├── Backup/                      # mirror NAS::Backup
├── PMedia/                      # mirror NAS::PMedia
├── Music/                       # mirror NAS::Music
├── _deleted/                    # soft-delete архив
│   └── 28-05-2026/              # за каждый день backup'а
│       ├── Personal/            # файлы которые были удалены с NAS
│       │   └── path/to/file.jpg
│       └── ...
└── _logs/                       # rsync output полным дампом
    ├── 28-05-2026_15-30_Personal.log
    └── ...
```

`_deleted/` растёт если файлы на NAS удаляют. Время от времени можно почистить старые даты:
```bash
sudo rm -rf /mnt/t7/nas-backup/_deleted/01-04-2026
```

---

## Self-reexec через systemd-run (важно)

При запуске с `--run/--dry-run/--diff` под root скрипт **сам себя переоборачивает** в transient systemd unit `nas-backup-runtime`:

```bash
# Что реально происходит когда dashboard зовёт скрипт:
exec systemd-run --unit=nas-backup-runtime --collect --quiet ... nas-backup.sh --run
```

Зачем: dashboard может рестартиться (или sysprq dropped его cgroup) — без этой защиты rsync прибился бы вместе с dashboard'ом. Теперь rsync в **своём cgroup'е**, переживает что угодно.

Минусы:
- Нельзя запустить два backup'а параллельно (один и тот же unit name)
- Логи идут в `journalctl -u nas-backup-runtime` (плюс в log-файл)

Stop:
```bash
sudo systemctl stop nas-backup-runtime
```

Или через дашборд **Menu → NAS → Stop backup** (то же самое).

---

## Progress / dashboard integration

Скрипт пишет JSON в `/var/run/travel-nas/backup-progress.json`:

```json
{
  "source": "nas",
  "device": "192.168.1.95",
  "label": "Personal",
  "target": "/mnt/t7/nas-backup/Personal",
  "percent": 47,
  "files_done": 12345,
  "size_done": "234.5G",
  "speed": "28.4M/s",
  "eta": "12m 15s",
  "updated": 1779953265
}
```

Dashboard обновляет каждый ~2 секунды. ETA / speed сглажены через median окна 15 значений (rsync скачет сильно, без сглаживания было бы 8h → 20m → 16h оборванно).

Bash-trap удаляет JSON при любом exit'е (SIGTERM от Stop, нормальный exit, crash). Без него дашборд показал бы stale progress.

---

## Логи

Каждый модуль = отдельный лог:
```
/mnt/t7/nas-backup/_logs/28-05-2026_15-30_Personal.log
/mnt/t7/nas-backup/_logs/28-05-2026_15-45_Docker.log
...
```

Внутри полный rsync output: каждый файл который копировался / удалялся + статистика в конце:

```
sent 12.30M bytes  received 1.46G bytes  3.21M bytes/sec
total size is 1.68T  speedup is 1152.13
Number of files: 286,604
Number of created files: 12,345
Number of deleted files: 14
Total file size: 1.68T bytes
Total transferred file size: 1.46G bytes
```

Из последней строки наш `nas-backup-status.py` парсит **source size** для NAS status page на дашборде.

---

## Уведомления Telegram

- **Старт**: `🟢 NAS-backup started · Source: 192.168.1.95 · Modules: 5`
- **Успех**: `✅ NAS-backup complete · Modules: 5/5 · Total size: 2.1T · Duration: 1h 23m 45s`
- **Ошибки**: `⚠️ NAS-backup with errors · OK: 4 · Failed: 1 · Check: /mnt/t7/nas-backup/_logs/`
- **Cannot reach NAS**: `❌ NAS-backup failed · Cannot reach NAS at 192.168.1.95`

---

## Diff mode (`--diff`)

Показывает что *будет* скопировано / удалено если запустишь backup, без реальной копии:

```
📂 Personal ← NAS::home
─────────────────────────────────────────
  ➕ New: 234
  📝 Changed: 12
  🗑  Will delete: 0

📂 Docker ← NAS::docker
─────────────────────────────────────────
  ✅ In sync
...
```

Быстрее чем `--dry-run` (использует `--size-only` instead of checksum).

---

## Troubleshooting

### "NAS unreachable"
- Pi не в той же сети что NAS (например на comitup AP-mode)
- NAS выключен
- Проверь: `ping 192.168.1.95`

### "Cannot connect to NAS rsync daemon (wrong password?)"
- Пароль в `nas-backup.conf` неверный
- Rsync daemon на NAS не запущен или порт 873 закрыт
- Проверь руками: `sshpass -p PASSWORD rsync user@192.168.1.95::`

### Status "partial" на дашборде
Backup был прерван (Stop button или crash) — нет `--stats` блока в логе. Запусти Run заново, доделает с того где остановился (rsync incremental — копирует только diff).

### Status "ok" но видишь что копировалось не всё
Возможно RAW-файлы или большие архивы исключены через `EXCLUDES`. Глянь конфиг.

### Source size = `?` на NAS status page
Ни одного завершённого backup'а ещё не было (нет stats блока в логах). Запусти Refresh — дашборд сделает быстрый `rsync --dry-run --stats` и подтянет реальный размер с NAS.

### rsync error 23 / 24 (partial transfer)
- 23 = partial transfer due to vanished source files — мирно (что-то удалили в момент копии)
- 24 = vanished source files — тоже warning
- Оба считаются как **OK** в нашем скрипте (`exit_code == 24 → log warning`).
