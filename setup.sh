#!/bin/bash
# =============================================================================
# setup.sh - Travel-NAS Setup v2 (T7 edition)
# =============================================================================
# Цель: одной командой подготовить чистую Pi OS Desktop к работе как travel-NAS
# на базе Samsung T7 Shield (USB SSD) вместо NVMe.
#
# Использование:
#   bash setup.sh                # интерактивное меню
#   bash setup.sh --all          # установить всё без вопросов
#   bash setup.sh --help         # справка
#
# Поддерживает повторный запуск — пропустит уже установленное.
# =============================================================================

set -e

# ----- Цвета -----
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()   { echo -e "${GREEN}[OK]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*"; }
err()   { echo -e "${RED}[ERR]${NC} $*"; }
info()  { echo -e "${BLUE}[INFO]${NC} $*"; }

# ----- Базовые переменные -----
REPO_RAW="https://raw.githubusercontent.com/pelinoleg/travel-nas-setup/main"
T7_LABEL="t7"
T7_MOUNT="/mnt/t7"
CONFIG_DIR="/etc/travel-nas"
SCRIPT_DIR="/usr/local/bin"

# ----- Проверки -----
if [[ "$EUID" -eq 0 ]]; then
    err "Не запускай через sudo! Скрипт сам попросит sudo где нужно."
    exit 1
fi

if ! grep -q "Raspberry Pi 5" /proc/cpuinfo 2>/dev/null; then
    warn "Не похоже на Raspberry Pi 5. Продолжить? (y/N)"
    read -r ans
    [[ "$ans" != "y" && "$ans" != "Y" ]] && exit 0
fi

# ----- Установка whiptail -----
if ! command -v whiptail &>/dev/null; then
    info "Устанавливаю whiptail..."
    sudo apt-get update -qq
    sudo apt-get install -y whiptail
fi

# =============================================================================
# Скачивание скрипта из репо или копирование из локальной папки
# =============================================================================
fetch_script() {
    local name="$1"
    local target="$2"
    # Если запущен из директории с scripts/ — копируем оттуда
    if [[ -f "$(dirname "$0")/scripts/$name" ]]; then
        sudo cp "$(dirname "$0")/scripts/$name" "$target"
    else
        # Скачиваем с GitHub
        sudo curl -fsSL "$REPO_RAW/scripts/$name" -o "$target"
    fi
    sudo chmod +x "$target"
}

fetch_conf_example() {
    local name="$1"
    local target="$2"
    if [[ -f "$(dirname "$0")/conf-examples/$name" ]]; then
        sudo cp "$(dirname "$0")/conf-examples/$name" "$target"
    else
        sudo curl -fsSL "$REPO_RAW/conf-examples/$name" -o "$target"
    fi
}

# =============================================================================
# Меню выбора компонентов
# =============================================================================

if [[ "${1:-}" == "--all" ]]; then
    SELECTED="UPDATE UTILS HOSTNAME T7_MOUNT TG_NOTIFY SAMBA PI_BACKUP PHOTO_BACKUP NAS_BACKUP WATCHDOG SYS_MONITOR DAILY_SUM LOG2RAM ZRAM COMITUP CASAOS PHOTOVIEW DISPLAY DESKTOP"
elif [[ "${1:-}" == "--help" ]]; then
    cat << EOF
Travel-NAS Setup v2

Usage:
  bash setup.sh           Interactive menu
  bash setup.sh --all     Install everything

Components:
  UPDATE         apt update + upgrade
  UTILS          htop, ncdu, tmux, git, smartmontools, exiftool, etc.
  HOSTNAME       Rename Pi to "travel-nas"
  T7_MOUNT       Mount T7 to /mnt/t7 (требует ext4 на диске!)
  TG_NOTIFY      Telegram notifications helper
  SAMBA          SMB share /mnt/t7
  PI_BACKUP      Weekly Pi config backup
  PHOTO_BACKUP   Auto SD/USB backup on insert
  NAS_BACKUP     Manual NAS → T7 backup tool
  WATCHDOG       Disk health monitor (5min)
  SYS_MONITOR    CPU/temp/throttling monitor (5min)
  DAILY_SUM      Daily summary in Telegram (21:00)
  LOG2RAM        Logs in RAM (microSD friendly)
  ZRAM           Compressed swap
  COMITUP        Field WiFi AP mode
  CASAOS         For Photoview/Syncthing/etc
  PHOTOVIEW      Photo gallery via Docker (после CASAOS)
  DISPLAY        MHS35 3.5" + Python dashboard
  DESKTOP        Desktop shortcuts (Pi Desktop)
EOF
    exit 0
else
    SELECTED=$(whiptail --title "Travel-NAS v2 Setup" \
        --checklist "Что устанавливать? (Space — выбор, Enter — OK)" 28 80 22 \
        "UPDATE"       "apt update + upgrade"                              ON \
        "UTILS"        "Утилиты (htop, ncdu, exiftool, smartctl...)"      ON \
        "HOSTNAME"     "Переименовать в travel-nas"                       ON \
        "T7_MOUNT"     "Примонтировать T7 в /mnt/t7"                      ON \
        "TG_NOTIFY"    "Telegram уведомления (helper)"                    ON \
        "SAMBA"        "Samba шара /mnt/t7"                               ON \
        "PI_BACKUP"    "Еженедельный бэкап конфигов"                      ON \
        "PHOTO_BACKUP" "Автобэкап SD/USB карт"                            ON \
        "NAS_BACKUP"   "Бэкап с домашнего NAS (вручную)"                  ON \
        "WATCHDOG"     "Мониторинг T7 (каждые 5 мин)"                     ON \
        "SYS_MONITOR"  "Мониторинг CPU/temp/throttling"                   ON \
        "DAILY_SUM"    "Вечерний отчёт в Telegram (21:00)"                ON \
        "LOG2RAM"      "Логи в RAM (microSD friendly)"                    ON \
        "ZRAM"         "Сжатый swap"                                       ON \
        "COMITUP"      "Полевой WiFi AP-режим"                            ON \
        "CASAOS"       "CasaOS (для Photoview/Syncthing)"                 OFF \
        "PHOTOVIEW"    "Photoview (нужен CASAOS)"                         OFF \
        "DISPLAY"      "MHS35 3.5\" + Python dashboard"                  OFF \
        "DESKTOP"      "Ярлыки на десктоп Pi"                             ON \
        3>&1 1>&2 2>&3) || exit 0
fi

# Преобразуем в DO_*
for opt in $SELECTED; do
    opt_clean=$(echo "$opt" | tr -d '"')
    declare "DO_$opt_clean=1"
done

# Создаём базовые папки
sudo mkdir -p "$CONFIG_DIR"
sudo chmod 755 "$CONFIG_DIR"

# =============================================================================
# 1. UPDATE
# =============================================================================
if [[ -n "${DO_UPDATE:-}" ]]; then
    info "=== Update ==="
    sudo apt-get update
    sudo apt-get upgrade -y
    log "System updated"
fi

# =============================================================================
# 2. UTILS
# =============================================================================
if [[ -n "${DO_UTILS:-}" ]]; then
    info "=== Utilities ==="
    sudo apt-get install -y \
        htop ncdu tmux git tree jq curl wget \
        smartmontools nvme-cli rsync sshpass \
        libimage-exiftool-perl \
        whiptail dialog \
        ifupdown net-tools wireless-tools \
        python3-pip python3-pygame python3-evdev \
        avahi-daemon
    log "Utilities installed"
fi

# =============================================================================
# 3. HOSTNAME → travel-nas
# =============================================================================
if [[ -n "${DO_HOSTNAME:-}" ]]; then
    info "=== Hostname ==="
    CURRENT_HOST=$(hostname)
    if [[ "$CURRENT_HOST" != "travel-nas" ]]; then
        sudo hostnamectl set-hostname travel-nas
        # Обновляем /etc/hosts
        sudo sed -i "s/127.0.1.1\s*$CURRENT_HOST/127.0.1.1\ttravel-nas/" /etc/hosts
        log "Hostname changed: $CURRENT_HOST → travel-nas"
        warn "После ребута имя будет travel-nas.local"
    else
        info "Hostname уже travel-nas"
    fi
fi

# =============================================================================
# 4. T7 MOUNT (предполагаем что диск уже в ext4!)
# =============================================================================
if [[ -n "${DO_T7_MOUNT:-}" ]]; then
    info "=== T7 Mount ==="

    # Ищем диск по label "t7"
    T7_DEV=$(sudo blkid -L "$T7_LABEL" 2>/dev/null || echo "")

    if [[ -z "$T7_DEV" ]]; then
        warn "Диск с label '$T7_LABEL' не найден."
        warn "T7 должен быть отформатирован в ext4 с меткой 't7'."
        warn "Команды для форматирования (СОТРЁТ ВСЕ ДАННЫЕ):"
        warn "  sudo wipefs -a /dev/sdX"
        warn "  sudo parted /dev/sdX --script mklabel gpt"
        warn "  sudo parted /dev/sdX --script mkpart primary ext4 0% 100%"
        warn "  sudo mkfs.ext4 -L t7 -m 0 /dev/sdX1"
        warn ""
        warn "Где /dev/sdX — это твой T7 (проверь через lsblk)"
        warn "Пропускаю T7_MOUNT."
    else
        T7_UUID=$(sudo blkid -s UUID -o value "$T7_DEV")
        info "Найден T7: $T7_DEV (UUID: $T7_UUID)"

        # Создаём точку монтирования
        sudo mkdir -p "$T7_MOUNT"

        # Добавляем в fstab если ещё нет
        if ! grep -q "$T7_UUID" /etc/fstab; then
            echo "UUID=$T7_UUID $T7_MOUNT ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab > /dev/null
            log "T7 добавлен в /etc/fstab"
        fi

        # Монтируем если ещё нет
        if ! mountpoint -q "$T7_MOUNT"; then
            sudo mount "$T7_MOUNT" && log "T7 примонтирован в $T7_MOUNT" || err "Не удалось примонтировать"
        else
            info "T7 уже примонтирован"
        fi

        # Сохраняем UUID для других скриптов (нужно photo-backup чтобы исключать себя)
        echo "T7_UUID=\"$T7_UUID\"" | sudo tee "$CONFIG_DIR/t7-info.conf" > /dev/null
        sudo chmod 644 "$CONFIG_DIR/t7-info.conf"

        # Создаём структуру папок на T7
        sudo mkdir -p "$T7_MOUNT/nas-backup/"{_deleted,_logs}
        sudo mkdir -p "$T7_MOUNT/usb-imports"
        sudo mkdir -p "$T7_MOUNT/pi-config-backups"
        sudo mkdir -p "$T7_MOUNT/media"
        sudo mkdir -p "$T7_MOUNT/sync"
        sudo mkdir -p "$T7_MOUNT/_logs"
        sudo chmod 755 "$T7_MOUNT"

        log "Структура папок T7 создана"
    fi
fi

# =============================================================================
# 5. TG_NOTIFY — Telegram helper
# =============================================================================
if [[ -n "${DO_TG_NOTIFY:-}" ]]; then
    info "=== Telegram notifications ==="

    fetch_script "tg-notify.sh" "$SCRIPT_DIR/tg-notify.sh"

    # Создаём конфиг если нет
    if [[ ! -f "$CONFIG_DIR/tg-notify.conf" ]]; then
        echo ""
        info "Нужны Telegram bot token и chat_id."
        info "Если ещё не создал — следуй инструкции на экране, потом запусти setup снова."
        echo ""

        TG_TOKEN=$(whiptail --inputbox \
            "Telegram bot token (получи у @BotFather):\n\nПропусти если хочешь настроить потом — будет работать без уведомлений." \
            14 70 "" 3>&1 1>&2 2>&3) || TG_TOKEN=""

        TG_CHAT_ID=""
        if [[ -n "$TG_TOKEN" ]]; then
            TG_CHAT_ID=$(whiptail --inputbox \
                "Telegram chat_id (твой ID, открой https://api.telegram.org/botTOKEN/getUpdates):" \
                12 70 "" 3>&1 1>&2 2>&3) || TG_CHAT_ID=""
        fi

        # Пишем конфиг
        sudo tee "$CONFIG_DIR/tg-notify.conf" > /dev/null << EOF
# Telegram bot configuration
# Изменить позже: sudo nano /etc/travel-nas/tg-notify.conf

TG_BOT_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
HOSTNAME_LABEL="Travel-NAS"
EOF
        sudo chmod 600 "$CONFIG_DIR/tg-notify.conf"
        log "Конфиг создан: $CONFIG_DIR/tg-notify.conf (chmod 600)"

        # Тестовое сообщение
        if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
            info "Отправляю тест..."
            if "$SCRIPT_DIR/tg-notify.sh" success "Travel-NAS setup" "Telegram настроен. Получаешь это значит работает."; then
                log "Тест отправлен — проверь Telegram"
            else
                warn "Тест не отправился — проверь токен и chat_id"
            fi
        fi
    else
        info "Конфиг уже существует"
    fi
fi

# =============================================================================
# 6. SAMBA
# =============================================================================
if [[ -n "${DO_SAMBA:-}" ]]; then
    info "=== Samba ==="

    if ! command -v smbd &>/dev/null; then
        sudo apt-get install -y samba samba-common-bin
    fi

    # Определяем путь шары
    if mountpoint -q "$T7_MOUNT"; then
        SHARE_PATH="$T7_MOUNT"
    else
        SHARE_PATH="/home/$(whoami)/share"
        sudo mkdir -p "$SHARE_PATH"
        sudo chmod 777 "$SHARE_PATH"
        warn "T7 не примонтирован — шара указывает на $SHARE_PATH"
        warn "После монтирования T7 поправь: sudo sed -i 's|path = $SHARE_PATH|path = $T7_MOUNT|' /etc/samba/smb.conf"
    fi

    # Добавляем шару если ещё нет
    if ! sudo grep -q "^\[travel-nas\]" /etc/samba/smb.conf 2>/dev/null; then
        sudo tee -a /etc/samba/smb.conf > /dev/null << EOF

[travel-nas]
   comment = Travel NAS storage
   path = $SHARE_PATH
   browseable = yes
   read only = no
   guest ok = yes
   guest only = yes
   create mask = 0666
   directory mask = 0777
   force user = nobody
   force group = nogroup
EOF
        log "Шара [travel-nas] добавлена → $SHARE_PATH"
    else
        info "Шара уже настроена"
    fi

    sudo systemctl restart smbd nmbd
    sudo systemctl enable smbd nmbd
    log "Samba запущена"
fi

# =============================================================================
# 7. PI_BACKUP
# =============================================================================
if [[ -n "${DO_PI_BACKUP:-}" ]]; then
    info "=== Pi config backup ==="

    fetch_script "pi-config-backup.sh" "$SCRIPT_DIR/pi-config-backup.sh"

    # Добавляем в cron root: каждое воскресенье в 03:00
    CRON_LINE="0 3 * * 0 $SCRIPT_DIR/pi-config-backup.sh"
    if ! sudo crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/pi-config-backup.sh"; then
        (sudo crontab -l 2>/dev/null; echo "$CRON_LINE") | sudo crontab -
        log "Cron добавлен: воскресенье 03:00"
    else
        info "Cron уже настроен"
    fi
fi

# =============================================================================
# 8. PHOTO_BACKUP
# =============================================================================
if [[ -n "${DO_PHOTO_BACKUP:-}" ]]; then
    info "=== Photo backup ==="

    fetch_script "photo-backup.sh" "$SCRIPT_DIR/photo-backup.sh"

    # Читаем T7 UUID
    T7_UUID=""
    if [[ -f "$CONFIG_DIR/t7-info.conf" ]]; then
        # shellcheck source=/dev/null
        source "$CONFIG_DIR/t7-info.conf"
    fi

    # Создаём конфиг если нет
    if [[ ! -f "$CONFIG_DIR/photo-backup.conf" ]]; then
        sudo tee "$CONFIG_DIR/photo-backup.conf" > /dev/null << EOF
# Photo backup configuration
# Изменить: sudo nano /etc/travel-nas/photo-backup.conf

# Целевая папка
DEST="$T7_MOUNT/usb-imports"

# Авторазмонтирование после бэкапа
AUTO_UMOUNT=true

# UUID нашего T7 — чтобы НЕ бэкапить сам себя
T7_UUID="${T7_UUID:-}"

# Минимальный размер файла для копирования (байт)
MIN_SIZE=1

# Сколько секунд ждать пока devmon (CasaOS) смонтирует
WAIT_FOR_DEVMON=3
EOF
        sudo chmod 644 "$CONFIG_DIR/photo-backup.conf"
        log "Конфиг создан"
    fi

    # systemd unit
    sudo tee /etc/systemd/system/photo-backup@.service > /dev/null << 'EOF'
[Unit]
Description=Photo Backup for %i
After=local-fs.target network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/photo-backup.sh /dev/%i
User=root
TimeoutStartSec=7200
EOF

    # udev rule
    sudo tee /etc/udev/rules.d/99-photo-backup.rules > /dev/null << 'EOF'
# Photo Backup: запускаем при подключении USB-карт ридера
ACTION=="add", KERNEL=="sd[a-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}+="photo-backup@%k.service"
EOF

    sudo systemctl daemon-reload
    sudo udevadm control --reload-rules
    log "Photo-backup готов"
    info "Тест: sudo /usr/local/bin/photo-backup.sh /dev/sdX1"
fi

# =============================================================================
# 9. NAS_BACKUP
# =============================================================================
if [[ -n "${DO_NAS_BACKUP:-}" ]]; then
    info "=== NAS backup ==="

    # Зависимость
    if ! command -v sshpass &>/dev/null; then
        sudo apt-get install -y sshpass
    fi

    fetch_script "nas-backup.sh" "$SCRIPT_DIR/nas-backup.sh"

    # Создаём конфиг с whiptail wizard
    if [[ ! -f "$CONFIG_DIR/nas-backup.conf" ]]; then
        info "Настройка NAS-backup..."

        NAS_HOST=$(whiptail --inputbox "NAS IP-адрес:" 10 60 "192.168.1.95" 3>&1 1>&2 2>&3) || exit 0
        NAS_USER=$(whiptail --inputbox "NAS rsync username:" 10 60 "oleg" 3>&1 1>&2 2>&3) || exit 0
        NAS_PASS=$(whiptail --passwordbox "NAS rsync password:" 10 60 3>&1 1>&2 2>&3) || exit 0

        sudo tee "$CONFIG_DIR/nas-backup.conf" > /dev/null << EOF
# NAS backup configuration
# Адаптируй модули под свой NAS!
# Формат: "rsync_module|local_folder"

NAS_HOST="$NAS_HOST"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"

# Где сохранять
DEST="$T7_MOUNT/nas-backup"

# Список модулей (адаптируй под свой NAS)
MODULES=(
    "home|Personal"
    "docker|Docker"
    "Backup|Backup"
    "PMedia|PMedia"
    "Music|Music"
)

# Исключения rsync
EXCLUDES=(
    "_gsdata_"
    ".DS_Store"
    "Thumbs.db"
    "@eaDir/"
    "#recycle/"
    ".Trash*"
    "*.tmp"
    ".cache/"
    "node_modules/"
    "__pycache__/"
    "vendor/"
    ".next/"
    ".nuxt/"
    "dist/"
    "build/"
    ".git/"
    ".svn/"
)
EOF
        sudo chmod 600 "$CONFIG_DIR/nas-backup.conf"
        log "Конфиг создан: $CONFIG_DIR/nas-backup.conf"
        info "Отредактируй MODULES под свой NAS: sudo nano $CONFIG_DIR/nas-backup.conf"
    fi
fi

# =============================================================================
# 10. WATCHDOG
# =============================================================================
if [[ -n "${DO_WATCHDOG:-}" ]]; then
    info "=== Disk watchdog ==="

    fetch_script "disk-watchdog.sh" "$SCRIPT_DIR/disk-watchdog.sh"

    # systemd service + timer
    sudo tee /etc/systemd/system/disk-watchdog.service > /dev/null << 'EOF'
[Unit]
Description=Travel-NAS disk watchdog

[Service]
Type=oneshot
ExecStart=/usr/local/bin/disk-watchdog.sh
EOF

    sudo tee /etc/systemd/system/disk-watchdog.timer > /dev/null << 'EOF'
[Unit]
Description=Run disk-watchdog every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
Unit=disk-watchdog.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now disk-watchdog.timer
    log "Watchdog запущен (каждые 5 мин)"
fi

# =============================================================================
# 11. SYS_MONITOR
# =============================================================================
if [[ -n "${DO_SYS_MONITOR:-}" ]]; then
    info "=== System monitor ==="

    fetch_script "system-monitor.sh" "$SCRIPT_DIR/system-monitor.sh"

    sudo tee /etc/systemd/system/system-monitor.service > /dev/null << 'EOF'
[Unit]
Description=Travel-NAS system monitor

[Service]
Type=oneshot
ExecStart=/usr/local/bin/system-monitor.sh
EOF

    sudo tee /etc/systemd/system/system-monitor.timer > /dev/null << 'EOF'
[Unit]
Description=Run system-monitor every 5 minutes

[Timer]
OnBootSec=3min
OnUnitActiveSec=5min
Unit=system-monitor.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now system-monitor.timer
    log "System monitor запущен"
fi

# =============================================================================
# 12. DAILY_SUM
# =============================================================================
if [[ -n "${DO_DAILY_SUM:-}" ]]; then
    info "=== Daily summary ==="

    fetch_script "daily-summary.sh" "$SCRIPT_DIR/daily-summary.sh"

    sudo tee /etc/systemd/system/daily-summary.service > /dev/null << 'EOF'
[Unit]
Description=Travel-NAS daily summary

[Service]
Type=oneshot
ExecStart=/usr/local/bin/daily-summary.sh
EOF

    sudo tee /etc/systemd/system/daily-summary.timer > /dev/null << 'EOF'
[Unit]
Description=Daily summary at 21:00

[Timer]
OnCalendar=*-*-* 21:00:00
Persistent=true
Unit=daily-summary.service

[Install]
WantedBy=timers.target
EOF

    sudo systemctl daemon-reload
    sudo systemctl enable --now daily-summary.timer
    log "Daily summary запланирован на 21:00"
fi

# =============================================================================
# 13. LOG2RAM
# =============================================================================
if [[ -n "${DO_LOG2RAM:-}" ]]; then
    info "=== Log2ram ==="

    if ! dpkg -l | grep -q log2ram; then
        echo "deb http://packages.azlux.fr/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/azlux.list
        sudo wget -qO /etc/apt/trusted.gpg.d/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
        sudo apt-get update
        sudo apt-get install -y log2ram
        log "Log2ram установлен"
    else
        info "Log2ram уже установлен"
    fi
fi

# =============================================================================
# 14. ZRAM
# =============================================================================
if [[ -n "${DO_ZRAM:-}" ]]; then
    info "=== ZRAM ==="

    if ! dpkg -l | grep -q zram-tools; then
        sudo apt-get install -y zram-tools
    fi
    sudo sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap
    sudo sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap
    sudo systemctl restart zramswap

    # Swappiness
    if ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf > /dev/null
        sudo sysctl -p
    fi
    log "ZRAM настроен (zstd, 50%, swappiness=10)"
fi

# =============================================================================
# 15. COMITUP
# =============================================================================
if [[ -n "${DO_COMITUP:-}" ]]; then
    info "=== Comitup (field WiFi) ==="

    if ! dpkg -l | grep -q comitup; then
        echo "deb http://davesteele.github.io/comitup/repo comitup main" | sudo tee /etc/apt/sources.list.d/comitup.list
        sudo wget -qO /etc/apt/trusted.gpg.d/davesteele-comitup-archive-keyring.gpg https://davesteele.github.io/comitup/deb/davesteele-comitup-apt-source.gpg
        sudo apt-get update
        sudo apt-get install -y comitup
        log "Comitup установлен"
    else
        info "Comitup уже установлен"
    fi
fi

# =============================================================================
# 16. CASAOS
# =============================================================================
if [[ -n "${DO_CASAOS:-}" ]]; then
    info "=== CasaOS ==="

    if command -v casaos-cli &>/dev/null; then
        info "CasaOS уже установлен"
    else
        warn "Установка CasaOS, ~10 минут..."
        if ! command -v curl &>/dev/null; then
            sudo apt-get install -y curl
        fi
        curl -fsSL https://get.casaos.io | sudo bash || warn "Установка не прошла"

        if command -v casaos-cli &>/dev/null; then
            log "CasaOS установлен → http://travel-nas.local"
        fi
    fi

    # Защита fstab-устройств от перехвата devmon
    if [[ -f /etc/conf.d/devmon ]] && command -v findmnt &>/dev/null; then
        FSTAB_DEVS=$(awk '/^UUID=/ {print $2}' /etc/fstab | while read mp; do
            findmnt -n -o SOURCE "$mp" 2>/dev/null || true
        done | grep -E '^/dev/' | sort -u)

        for dev in $FSTAB_DEVS; do
            if ! grep -q "ignore-device $dev" /etc/conf.d/devmon; then
                sudo sed -i "s|ARGS=\"\(.*\)\"|ARGS=\"\1 --ignore-device $dev\"|" /etc/conf.d/devmon
                log "devmon ignore: $dev"
            fi
        done
        sudo systemctl restart devmon@devmon.service 2>/dev/null || true
    fi
fi

# =============================================================================
# 17. PHOTOVIEW (после CasaOS)
# =============================================================================
if [[ -n "${DO_PHOTOVIEW:-}" ]]; then
    info "=== Photoview ==="

    if ! command -v docker &>/dev/null; then
        warn "Docker не установлен. Сначала установи CasaOS или Docker."
    else
        # Создаём compose-файл
        sudo mkdir -p /opt/photoview
        sudo tee /opt/photoview/docker-compose.yml > /dev/null << EOF
version: "3"
services:
  db:
    image: mariadb:10.11
    restart: unless-stopped
    environment:
      - MYSQL_DATABASE=photoview
      - MYSQL_USER=photoview
      - MYSQL_PASSWORD=photoview
      - MYSQL_RANDOM_ROOT_PASSWORD=1
    volumes:
      - /opt/photoview/db:/var/lib/mysql

  photoview:
    image: viktorstrate/photoview:latest
    restart: unless-stopped
    ports:
      - "8000:80"
    depends_on:
      - db
    environment:
      - PHOTOVIEW_DATABASE_DRIVER=mysql
      - PHOTOVIEW_MYSQL_URL=photoview:photoview@tcp(db)/photoview
      - PHOTOVIEW_LISTEN_IP=0.0.0.0
      - PHOTOVIEW_LISTEN_PORT=80
      - PHOTOVIEW_MEDIA_CACHE=/app/cache
    volumes:
      - /opt/photoview/cache:/app/cache
      - $T7_MOUNT/usb-imports:/photos:ro
EOF
        cd /opt/photoview
        sudo docker compose up -d || warn "Не удалось запустить Photoview"
        log "Photoview → http://travel-nas.local:8000"
    fi
fi

# =============================================================================
# 18. DISPLAY (MHS35 + Python dashboard)
# =============================================================================
if [[ -n "${DO_DISPLAY:-}" ]]; then
    info "=== MHS35 + Display ==="

    # Драйвер MHS35
    if [[ ! -d /tmp/LCD-show ]]; then
        cd /tmp
        sudo git clone https://github.com/goodtft/LCD-show.git
    fi

    warn "ВНИМАНИЕ: установка драйвера MHS35 ребутает Pi!"
    warn "Перед ребутом сохранится скрипт dashboard."
    echo "Продолжить? (y/N)"
    read -r ans

    # Сначала ставим Python dashboard и systemd-сервис
    fetch_script "travel-nas-display.py" "$SCRIPT_DIR/travel-nas-display.py"

    sudo tee /etc/systemd/system/travel-nas-display.service > /dev/null << 'EOF'
[Unit]
Description=Travel-NAS Display Dashboard
After=multi-user.target graphical.target

[Service]
Type=simple
ExecStart=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Restart=on-failure
RestartSec=10
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOF
    sudo systemctl daemon-reload
    sudo systemctl enable travel-nas-display.service
    log "Display dashboard service создан (запустится после ребута)"

    if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
        cd /tmp/LCD-show
        sudo "./MHS35-show" "90"
        # Сюда не дойдём — ребут
    else
        info "Запустишь драйвер вручную:"
        info "  cd /tmp/LCD-show && sudo ./MHS35-show 90"
    fi
fi

# =============================================================================
# 19. DESKTOP shortcuts
# =============================================================================
if [[ -n "${DO_DESKTOP:-}" ]]; then
    info "=== Desktop shortcuts ==="

    USER_HOME="/home/$(whoami)"
    DESKTOP_DIR="$USER_HOME/Desktop"

    if [[ -d "$DESKTOP_DIR" ]]; then
        # NAS-backup ярлык
        cat > "$DESKTOP_DIR/NAS-Backup.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=NAS Backup
Comment=Backup files from home UGREEN NAS to T7
Exec=lxterminal -e "sudo /usr/local/bin/nas-backup.sh"
Icon=drive-harddisk
Terminal=false
Categories=System;
EOF

        # Logs view
        cat > "$DESKTOP_DIR/View-Logs.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Travel-NAS Logs
Comment=View all logs
Exec=lxterminal -e "tail -F /mnt/t7/_logs/*.log"
Icon=utilities-log-viewer
Terminal=false
Categories=System;
EOF

        chmod +x "$DESKTOP_DIR"/*.desktop
        log "Ярлыки созданы в $DESKTOP_DIR"
    else
        warn "$DESKTOP_DIR не найден (не Desktop версия PiOS?)"
    fi
fi

# =============================================================================
# Финал
# =============================================================================
echo ""
echo "================================================================"
log "Установка завершена!"
echo "================================================================"
echo ""

IP=$(hostname -I | awk '{print $1}')
echo "IP: $IP"
echo "Hostname: $(hostname).local"
echo ""

[[ -n "${DO_SAMBA:-}" ]] && info "Samba: smb://travel-nas.local/travel-nas"
[[ -n "${DO_CASAOS:-}" ]] && info "CasaOS: http://travel-nas.local"
[[ -n "${DO_PHOTOVIEW:-}" ]] && info "Photoview: http://travel-nas.local:8000"
[[ -n "${DO_PHOTO_BACKUP:-}" ]] && info "Photo backup: вставь USB-картридер → автобэкап"
[[ -n "${DO_NAS_BACKUP:-}" ]] && info "NAS backup: sudo nas-backup.sh"

echo ""
warn "После ребута имя будет travel-nas.local"
warn "Чтобы применить hostname, требуется ребут:"
warn "  sudo reboot"
echo ""
echo "Повторный запуск: bash setup.sh"
echo "Установить всё:   bash setup.sh --all"
