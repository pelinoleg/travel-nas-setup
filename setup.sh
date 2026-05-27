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

set -u

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

# ----- Отчёт -----
# Каждый компонент пишется в один из этих массивов
INSTALLED=()
FAILED=()
SKIPPED=()

# Помечаем успешно установленный компонент + шлём info в Telegram-summary
mark_ok() {
    local name="$1"
    local detail="${2:-}"
    INSTALLED+=("$name")
    log "✓ $name${detail:+: $detail}"
    # В Telegram-summary (если уже есть tg-notify)
    if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
        /usr/local/bin/tg-notify.sh --append info "Installed" "$name${detail:+ — $detail}" 2>/dev/null || true
    fi
}

# Помечаем упавший компонент + кидаем алерт в Telegram
mark_fail() {
    local name="$1"
    local reason="${2:-unknown}"
    FAILED+=("$name: $reason")
    err "✗ $name FAILED: $reason"
    if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
        /usr/local/bin/tg-notify.sh -l warning "Install failed: $name" "$reason" 2>/dev/null || true
    fi
}

# Запускает команду, не прерывая скрипт при ошибке
try() {
    local desc="$1"
    shift
    if "$@"; then
        return 0
    else
        local code=$?
        warn "$desc — exit $code"
        return "$code"
    fi
}

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
    SELECTED="UPDATE UTILS HOSTNAME T7_MOUNT TG_NOTIFY SAMBA PI_BACKUP PHOTO_BACKUP NAS_BACKUP WATCHDOG SYS_MONITOR DAILY_SUM LOG2RAM ZRAM COMITUP CASAOS PHOTOVIEW YTARCHIVER DISPLAY DESKTOP"
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
  PHOTOVIEW      Photo gallery via Docker (после CASAOS, путь /t7/* в UI)
  YTARCHIVER     YouTube archiver via Docker (после CASAOS, UI на :8081)
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
        "CASAOS"       "CasaOS (для Photoview/Syncthing)"                 ON \
        "PHOTOVIEW"    "Photoview (нужен CASAOS, путь /t7/* в UI)"        ON \
        "YTARCHIVER"   "YT-Archiver (нужен CASAOS, UI на :8081)"          ON \
        "DISPLAY"      "MHS35 3.5\" + Python dashboard"                  ON \
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
    if (
        set -e
        sudo apt-get update
        sudo apt-get upgrade -y
    ); then
        mark_ok "UPDATE" "apt upgrade OK"
    else
        mark_fail "UPDATE" "apt update/upgrade failed"
    fi
fi

# =============================================================================
# 2. UTILS
# =============================================================================
if [[ -n "${DO_UTILS:-}" ]]; then
    info "=== Utilities ==="
    if sudo apt-get install -y \
        htop ncdu tmux git tree jq curl wget \
        smartmontools nvme-cli rsync sshpass \
        libimage-exiftool-perl \
        whiptail dialog \
        ifupdown net-tools wireless-tools \
        python3-pip python3-pygame python3-evdev \
        wmctrl \
        avahi-daemon; then
        mark_ok "UTILS"
    else
        mark_fail "UTILS" "apt install failed"
    fi
fi

# =============================================================================
# 3. HOSTNAME → travel-nas
# =============================================================================
if [[ -n "${DO_HOSTNAME:-}" ]]; then
    info "=== Hostname ==="
    if (
        set -e
        CURRENT_HOST=$(hostname)
        if [[ "$CURRENT_HOST" != "travel-nas" ]]; then
            sudo hostnamectl set-hostname travel-nas
            sudo sed -i "s/127.0.1.1\s*$CURRENT_HOST/127.0.1.1\ttravel-nas/" /etc/hosts
        fi
    ); then
        mark_ok "HOSTNAME" "travel-nas"
    else
        mark_fail "HOSTNAME" "hostnamectl failed"
    fi
fi

# =============================================================================
# 4. T7 MOUNT
# =============================================================================
if [[ -n "${DO_T7_MOUNT:-}" ]]; then
    info "=== T7 Mount ==="

    # 1. Сначала смотрим — уже есть диск с нашим label? (повторный запуск setup)
    T7_DEV=$(sudo blkid -L "$T7_LABEL" 2>/dev/null || echo "")

    # 2. Если нет — интерактивный wizard: показываем доступные диски,
    #    пользователь выбирает, мы форматируем в ext4 с нужным label.
    if [[ -z "$T7_DEV" ]]; then
        # Корневой диск (где OS) — НЕ предлагаем для форматирования
        SYS_SRC=$(findmnt -n -o SOURCE / 2>/dev/null)
        # Убираем номер партиции: /dev/mmcblk0p2 → /dev/mmcblk0; /dev/sda1 → /dev/sda
        SYS_DISK=$(echo "$SYS_SRC" | sed -E 's|p?[0-9]+$||')

        # Собираем кандидатов: только whole disks, не наша система, не loop/ram
        CANDIDATES=()
        while IFS=$'\t' read -r NAME SIZE MODEL TYPE; do
            [[ "$TYPE" != "disk" ]] && continue
            DEV="/dev/$NAME"
            [[ "$DEV" == "$SYS_DISK" ]] && continue
            # Слишком мелкие (boot media, USB-стики) пропускаем
            SIZE_BYTES=$(lsblk -bdn -o SIZE "$DEV" 2>/dev/null | head -1)
            (( ${SIZE_BYTES:-0} < 32000000000 )) && continue   # <32GB
            LABEL_INFO="${MODEL:-unknown}"
            CANDIDATES+=("$DEV" "$SIZE — $LABEL_INFO")
        done < <(lsblk -dn -o NAME,SIZE,MODEL,TYPE 2>/dev/null)

        if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
            mark_fail "T7_MOUNT" "не найдено подходящих дисков (нужен ≥32GB, не системный)"
            warn "Подключи внешний SSD/HDD и перезапусти setup.sh"
        else
            warn "ВНИМАНИЕ: выбранный диск БУДЕТ ОТФОРМАТИРОВАН в ext4!"
            warn "Все данные на нём ПРОПАДУТ. Скопируй их куда-нибудь ДО продолжения."
            echo ""
            SEL_DEV=$(whiptail --title "Disk for travel-NAS storage" \
                --menu "Выбери диск (БУДЕТ ОТФОРМАТИРОВАН в ext4!):" \
                20 76 10 "${CANDIDATES[@]}" 3>&1 1>&2 2>&3) || SEL_DEV=""

            if [[ -z "$SEL_DEV" ]]; then
                mark_fail "T7_MOUNT" "отмена пользователем"
            else
                SEL_INFO=$(lsblk -dn -o SIZE,MODEL,SERIAL "$SEL_DEV" 2>/dev/null | head -1)
                if whiptail --title "Confirm format" --yesno \
                    "Я СЕЙЧАС ОТФОРМАТИРУЮ:\n\n  $SEL_DEV\n  $SEL_INFO\n\nВСЕ ДАННЫЕ на нём БУДУТ УДАЛЕНЫ.\nВсе скопировал? Точно продолжить?" \
                    14 70; then
                    if (
                        set -e
                        info "Размонтирую любые существующие партиции на $SEL_DEV..."
                        for part in "${SEL_DEV}"?*; do
                            sudo umount "$part" 2>/dev/null || true
                        done
                        info "Стираю старые подписи (wipefs)..."
                        sudo wipefs -a "$SEL_DEV"
                        info "Создаю GPT + ext4 партицию..."
                        sudo parted -s "$SEL_DEV" mklabel gpt
                        sudo parted -s "$SEL_DEV" mkpart primary ext4 0% 100%
                        sudo partprobe "$SEL_DEV" 2>/dev/null || true
                        sleep 2
                        # NVMe / mmcblk используют ${dev}p1, SATA/USB — ${dev}1
                        if [[ "$SEL_DEV" =~ (nvme|mmcblk) ]]; then
                            PART="${SEL_DEV}p1"
                        else
                            PART="${SEL_DEV}1"
                        fi
                        info "Форматирую $PART в ext4 (label='$T7_LABEL', reserved=0%)..."
                        sudo mkfs.ext4 -F -L "$T7_LABEL" -m 0 "$PART"
                        T7_DEV="$PART"
                    ); then
                        T7_DEV=$(sudo blkid -L "$T7_LABEL" 2>/dev/null || echo "")
                    else
                        mark_fail "T7_MOUNT" "format failed"
                    fi
                else
                    mark_fail "T7_MOUNT" "отмена форматирования"
                fi
            fi
        fi
    fi

    if [[ -z "$T7_DEV" ]]; then
        : # mark_fail уже выставлен выше
    else
        if (
            set -e
            T7_UUID=$(sudo blkid -s UUID -o value "$T7_DEV")
            sudo mkdir -p "$T7_MOUNT"
            if ! grep -q "$T7_UUID" /etc/fstab; then
                echo "UUID=$T7_UUID $T7_MOUNT ext4 defaults,nofail,noatime 0 2" | sudo tee -a /etc/fstab > /dev/null
            fi
            if ! mountpoint -q "$T7_MOUNT"; then
                sudo mount "$T7_MOUNT"
            fi
            echo "T7_UUID=\"$T7_UUID\"" | sudo tee "$CONFIG_DIR/t7-info.conf" > /dev/null
            sudo chmod 644 "$CONFIG_DIR/t7-info.conf"
            sudo mkdir -p "$T7_MOUNT/nas-backup/"{_deleted,_logs}
            sudo mkdir -p "$T7_MOUNT/usb-imports" "$T7_MOUNT/pi-config-backups" "$T7_MOUNT/media" "$T7_MOUNT/sync" "$T7_MOUNT/_logs"
            # T7 — single-user device. Делаем oleg владельцем всего дерева чтобы
            # можно было создавать папки без sudo. lost+found оставляем root.
            sudo chown -R "$(whoami):$(whoami)" "$T7_MOUNT"/[!l]* 2>/dev/null || true
            sudo chown    "$(whoami):$(whoami)" "$T7_MOUNT" 2>/dev/null || true
        ); then
            mark_ok "T7_MOUNT" "$T7_DEV → $T7_MOUNT"
        else
            mark_fail "T7_MOUNT" "ошибка монтирования"
        fi
    fi
fi

# =============================================================================
# 5. TG_NOTIFY
# =============================================================================
if [[ -n "${DO_TG_NOTIFY:-}" ]]; then
    info "=== Telegram notifications ==="
    if (
        set -e
        fetch_script "tg-notify.sh" "$SCRIPT_DIR/tg-notify.sh"
        if [[ ! -f "$CONFIG_DIR/tg-notify.conf" ]]; then
            TG_TOKEN=$(whiptail --inputbox "Telegram bot token (от @BotFather):\nПусто = пропустить." 12 70 "" 3>&1 1>&2 2>&3) || TG_TOKEN=""
            TG_CHAT_ID=""
            if [[ -n "$TG_TOKEN" ]]; then
                TG_CHAT_ID=$(whiptail --inputbox "Telegram chat_id:" 10 70 "" 3>&1 1>&2 2>&3) || TG_CHAT_ID=""
            fi
            sudo tee "$CONFIG_DIR/tg-notify.conf" > /dev/null << EOF
TG_BOT_TOKEN="$TG_TOKEN"
TG_CHAT_ID="$TG_CHAT_ID"
HOSTNAME_LABEL="Travel-NAS"
EOF
            sudo chmod 600 "$CONFIG_DIR/tg-notify.conf"
            if [[ -n "$TG_TOKEN" && -n "$TG_CHAT_ID" ]]; then
                "$SCRIPT_DIR/tg-notify.sh" success "Travel-NAS setup" "Telegram настроен" || true
            fi
        fi
    ); then
        mark_ok "TG_NOTIFY"
    else
        mark_fail "TG_NOTIFY" "config wizard failed"
    fi
fi

# =============================================================================
# 6. SAMBA
# =============================================================================
if [[ -n "${DO_SAMBA:-}" ]]; then
    info "=== Samba ==="
    if (
        set -e
        if ! command -v smbd &>/dev/null; then
            sudo apt-get install -y samba samba-common-bin
        fi
        if mountpoint -q "$T7_MOUNT"; then
            SHARE_PATH="$T7_MOUNT"
        else
            SHARE_PATH="/home/$(whoami)/share"
            sudo mkdir -p "$SHARE_PATH"
            sudo chmod 777 "$SHARE_PATH"
        fi
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
        fi
        sudo systemctl restart smbd nmbd
        sudo systemctl enable smbd nmbd
    ); then
        mark_ok "SAMBA"
    else
        mark_fail "SAMBA" "install/config failed"
    fi
fi

# =============================================================================
# 7. PI_BACKUP
# =============================================================================
if [[ -n "${DO_PI_BACKUP:-}" ]]; then
    info "=== Pi config backup ==="
    if (
        set -e
        fetch_script "pi-config-backup.sh" "$SCRIPT_DIR/pi-config-backup.sh"
        CRON_LINE="0 3 * * 0 $SCRIPT_DIR/pi-config-backup.sh"
        if ! sudo crontab -l 2>/dev/null | grep -qF "$SCRIPT_DIR/pi-config-backup.sh"; then
            (sudo crontab -l 2>/dev/null; echo "$CRON_LINE") | sudo crontab -
        fi
    ); then
        mark_ok "PI_BACKUP" "cron: воскр 03:00"
    else
        mark_fail "PI_BACKUP" "cron failed"
    fi
fi

# =============================================================================
# 8. PHOTO_BACKUP
# =============================================================================
if [[ -n "${DO_PHOTO_BACKUP:-}" ]]; then
    info "=== Photo backup ==="
    if (
        set -e
        fetch_script "photo-backup.sh" "$SCRIPT_DIR/photo-backup.sh"
        T7_UUID=""
        if [[ -f "$CONFIG_DIR/t7-info.conf" ]]; then
            source "$CONFIG_DIR/t7-info.conf"
        fi
        if [[ ! -f "$CONFIG_DIR/photo-backup.conf" ]]; then
            sudo tee "$CONFIG_DIR/photo-backup.conf" > /dev/null << EOF
DEST="$T7_MOUNT/usb-imports"
AUTO_UMOUNT=true
T7_UUID="${T7_UUID:-}"
MIN_SIZE=1
WAIT_FOR_DEVMON=3
EOF
            sudo chmod 644 "$CONFIG_DIR/photo-backup.conf"
        fi
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
        sudo tee /etc/udev/rules.d/99-photo-backup.rules > /dev/null << 'EOF'
ACTION=="add", KERNEL=="sd[a-z][0-9]", SUBSYSTEM=="block", ENV{ID_BUS}=="usb", \
    TAG+="systemd", ENV{SYSTEMD_WANTS}+="photo-backup@%k.service"
EOF
        sudo systemctl daemon-reload
        sudo udevadm control --reload-rules
    ); then
        mark_ok "PHOTO_BACKUP"
    else
        mark_fail "PHOTO_BACKUP" "udev/systemd setup failed"
    fi
fi

# =============================================================================
# 9. NAS_BACKUP
# =============================================================================
if [[ -n "${DO_NAS_BACKUP:-}" ]]; then
    info "=== NAS backup ==="
    if (
        set -e
        if ! command -v sshpass &>/dev/null; then
            sudo apt-get install -y sshpass
        fi
        fetch_script "nas-backup.sh"        "$SCRIPT_DIR/nas-backup.sh"
        # Helper для JSON-статуса бэкапов (читает dashboard)
        fetch_script "nas-backup-status.py" "$SCRIPT_DIR/nas-backup-status.py"

        # /var/lib/travel-nas создаём заранее (туда пишутся status JSON'ы)
        sudo install -d -m 0755 /var/lib/travel-nas

        # Systemd timer — обновляет размеры папок раз в час фоном
        sudo tee /etc/systemd/system/nas-backup-status.service > /dev/null << 'EOF'
[Unit]
Description=Refresh NAS-backup folder sizes/status
After=network.target

[Service]
Type=oneshot
Nice=15
IOSchedulingClass=idle
ExecStart=/usr/bin/python3 /usr/local/bin/nas-backup-status.py
EOF
        sudo tee /etc/systemd/system/nas-backup-status.timer > /dev/null << 'EOF'
[Unit]
Description=Hourly NAS-backup status refresh

[Timer]
OnBootSec=2min
OnUnitActiveSec=1h
Unit=nas-backup-status.service

[Install]
WantedBy=timers.target
EOF
        sudo systemctl daemon-reload
        sudo systemctl enable --now nas-backup-status.timer

        if [[ ! -f "$CONFIG_DIR/nas-backup.conf" ]]; then
            NAS_HOST=$(whiptail --inputbox "NAS IP:" 10 60 "192.168.1.95" 3>&1 1>&2 2>&3) || NAS_HOST="192.168.1.95"
            NAS_USER=$(whiptail --inputbox "NAS user:" 10 60 "oleg" 3>&1 1>&2 2>&3) || NAS_USER="oleg"
            NAS_PASS=$(whiptail --passwordbox "NAS password:" 10 60 3>&1 1>&2 2>&3) || NAS_PASS=""
            sudo tee "$CONFIG_DIR/nas-backup.conf" > /dev/null << EOF
NAS_HOST="$NAS_HOST"
NAS_USER="$NAS_USER"
NAS_PASS="$NAS_PASS"
DEST="$T7_MOUNT/nas-backup"
MODULES=(
    "home|Personal"
    "docker|Docker"
    "Backup|Backup"
    "PMedia|PMedia"
    "Music|Music"
)
EXCLUDES=(
    "_gsdata_" ".DS_Store" "Thumbs.db" "@eaDir/" "#recycle/"
    ".Trash*" "*.tmp" ".cache/" "node_modules/" "__pycache__/"
    "vendor/" ".next/" ".nuxt/" "dist/" "build/" ".git/" ".svn/"
)
EOF
            sudo chmod 600 "$CONFIG_DIR/nas-backup.conf"
        fi
    ); then
        mark_ok "NAS_BACKUP"
    else
        mark_fail "NAS_BACKUP" "config failed"
    fi
fi

# =============================================================================
# 10. WATCHDOG
# =============================================================================
if [[ -n "${DO_WATCHDOG:-}" ]]; then
    info "=== Disk watchdog ==="
    if (
        set -e
        fetch_script "disk-watchdog.sh" "$SCRIPT_DIR/disk-watchdog.sh"
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
    ); then
        mark_ok "WATCHDOG" "каждые 5 мин"
    else
        mark_fail "WATCHDOG" "systemd setup failed"
    fi
fi

# =============================================================================
# 11. SYS_MONITOR
# =============================================================================
if [[ -n "${DO_SYS_MONITOR:-}" ]]; then
    info "=== System monitor ==="
    if (
        set -e
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
    ); then
        mark_ok "SYS_MONITOR"
    else
        mark_fail "SYS_MONITOR" "systemd setup failed"
    fi
fi

# =============================================================================
# 12. DAILY_SUM
# =============================================================================
if [[ -n "${DO_DAILY_SUM:-}" ]]; then
    info "=== Daily summary ==="
    if (
        set -e
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
        # Второй сервис/таймер: только JSON для dashboard, каждые 10 минут.
        # Без Telegram, без очистки event queue — лёгкий refresh для UI.
        sudo tee /etc/systemd/system/daily-summary-refresh.service > /dev/null << 'EOF'
[Unit]
Description=Refresh daily-summary JSON for dashboard
After=network.target

[Service]
Type=oneshot
Nice=15
ExecStart=/usr/local/bin/daily-summary.sh --json
EOF
        sudo tee /etc/systemd/system/daily-summary-refresh.timer > /dev/null << 'EOF'
[Unit]
Description=Daily-summary JSON refresh every 10 min

[Timer]
OnBootSec=1min
OnUnitActiveSec=10min
Unit=daily-summary-refresh.service

[Install]
WantedBy=timers.target
EOF
        sudo install -d -m 0755 /var/lib/travel-nas
        sudo systemctl daemon-reload
        sudo systemctl enable --now daily-summary.timer
        sudo systemctl enable --now daily-summary-refresh.timer
    ); then
        mark_ok "DAILY_SUM" "21:00 + UI refresh every 10min"
    else
        mark_fail "DAILY_SUM" "systemd setup failed"
    fi
fi

# =============================================================================
# 13. LOG2RAM
# =============================================================================
if [[ -n "${DO_LOG2RAM:-}" ]]; then
    info "=== Log2ram ==="
    if (
        set -e
        if ! dpkg -l | grep -q log2ram; then
            echo "deb http://packages.azlux.fr/debian/ bookworm main" | sudo tee /etc/apt/sources.list.d/azlux.list
            sudo wget -qO /etc/apt/trusted.gpg.d/azlux-archive-keyring.gpg https://azlux.fr/repo.gpg
            sudo apt-get update
            sudo apt-get install -y log2ram
        fi
    ); then
        mark_ok "LOG2RAM"
    else
        mark_fail "LOG2RAM" "install failed"
    fi
fi

# =============================================================================
# 14. ZRAM (не критично — PiOS уже использует встроенный zram)
# =============================================================================
if [[ -n "${DO_ZRAM:-}" ]]; then
    info "=== ZRAM ==="
    if ! dpkg -l | grep -q zram-tools; then
        sudo apt-get install -y zram-tools || warn "zram-tools install failed"
    fi
    sudo sed -i 's/^#\?ALGO=.*/ALGO=zstd/' /etc/default/zramswap 2>/dev/null || true
    sudo sed -i 's/^#\?PERCENT=.*/PERCENT=50/' /etc/default/zramswap 2>/dev/null || true

    if sudo systemctl restart zramswap 2>/dev/null; then
        mark_ok "ZRAM" "zstd, 50%"
    else
        warn "zramswap не запустился (PiOS уже использует встроенный zram — это норма)"
        mark_ok "ZRAM" "уже работает (встроенный)"
    fi

    if [[ -f /etc/sysctl.conf ]] && ! grep -q "vm.swappiness" /etc/sysctl.conf; then
        echo "vm.swappiness=10" | sudo tee -a /etc/sysctl.conf > /dev/null
        sudo sysctl -p > /dev/null 2>&1 || true
    fi
fi

# =============================================================================
# 15. COMITUP (через deb-пакет — рекомендованный авторами способ)
# =============================================================================
if [[ -n "${DO_COMITUP:-}" ]]; then
    info "=== Comitup (field WiFi) ==="
    if (
        set -e
        if ! dpkg -l | grep -q "^ii.*comitup "; then
            # Чистим старые подходы которые не работают на Trixie
            sudo rm -f /etc/apt/sources.list.d/comitup.list 2>/dev/null || true
            sudo rm -f /etc/apt/trusted.gpg.d/davesteele-comitup-archive-keyring.gpg 2>/dev/null || true

            TMPDEB=$(mktemp --suffix=.deb)
            wget -qO "$TMPDEB" "https://davesteele.github.io/comitup/deb/davesteele-comitup-apt-source_1.3_all.deb"
            sudo dpkg -i "$TMPDEB"
            rm -f "$TMPDEB"
            sudo apt-get update
            sudo apt-get install -y comitup
        fi
    ); then
        mark_ok "COMITUP"
    else
        mark_fail "COMITUP" "deb install failed"
    fi
fi

# =============================================================================
# 16. CASAOS
# =============================================================================
if [[ -n "${DO_CASAOS:-}" ]]; then
    info "=== CasaOS ==="
    if command -v casaos-cli &>/dev/null; then
        mark_ok "CASAOS" "уже установлен"
    else
        warn "Установка CasaOS, ~10 минут..."
        if (
            set -e
            if ! command -v curl &>/dev/null; then
                sudo apt-get install -y curl
            fi
            curl -fsSL https://get.casaos.io | sudo bash
        ); then
            mark_ok "CASAOS" "http://travel-nas.local"
        else
            mark_fail "CASAOS" "install script failed"
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
            fi
        done
        sudo systemctl restart devmon@devmon.service 2>/dev/null || true
    fi
fi

# =============================================================================
# 17. PHOTOVIEW
# =============================================================================
# В UI Photoview добавляй пути вида /t7/usb-imports или /t7/media — это пути
# ВНУТРИ контейнера, не на хосте. Photoview видит только что мы примонтировали.
# Mount только read-only — гарантия что галерея ничего не сотрёт.
if [[ -n "${DO_PHOTOVIEW:-}" ]]; then
    info "=== Photoview ==="
    if ! command -v docker &>/dev/null; then
        mark_fail "PHOTOVIEW" "Docker не установлен (сначала CASAOS)"
    elif (
        set -e
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
      # Весь T7 как read-only — в UI указывай /t7/usb-imports, /t7/media и т.п.
      - $T7_MOUNT:/t7:ro
EOF
        cd /opt/photoview
        sudo docker compose up -d
    ); then
        mark_ok "PHOTOVIEW" "http://travel-nas.local:8000 (UI path: /t7/usb-imports)"
    else
        mark_fail "PHOTOVIEW" "docker compose failed"
    fi
fi

# =============================================================================
# 18. YTARCHIVER — self-hosted YouTube archiver, появляется в CasaOS UI
# =============================================================================
# Compose-файл кладётся в /var/lib/casaos/apps/ytarchiver/ — CasaOS подхватывает
# его автоматически благодаря x-casaos метаданным (icon, port_map, title).
# Замечание: backend в исходном compose публикует порт 8000 (как Photoview).
# Это вызвало бы конфликт → выкинули из ports. Frontend (8081) ходит к backend
# через docker network ytarchiver_net и видит его по имени `backend`.
if [[ -n "${DO_YTARCHIVER:-}" ]]; then
    info "=== YT-Archiver ==="
    if ! command -v docker &>/dev/null; then
        mark_fail "YTARCHIVER" "Docker не установлен (сначала CASAOS)"
    elif (
        set -e
        # Папки данных на T7 — bind mount внутрь контейнера. Владелец oleg
        # чтобы yt-dlp процессы внутри могли писать.
        sudo install -d -o "$(whoami)" -g "$(whoami)" /mnt/t7/media/YT-Archiver/data
        sudo install -d -o "$(whoami)" -g "$(whoami)" /mnt/t7/media/YT-Archiver/video

        APP_DIR=/var/lib/casaos/apps/ytarchiver
        sudo mkdir -p "$APP_DIR"
        sudo tee "$APP_DIR/docker-compose.yml" >/dev/null << 'EOF'
name: ytarchiver
services:
  backend:
    image: ghcr.io/pelinoleg/ytarchiver-backend:latest
    container_name: ytarchiver-backend
    hostname: ytarchiver-backend
    restart: unless-stopped
    cpu_shares: 90
    deploy:
      resources:
        limits:
          memory: "8453619712"
    environment:
      BETWEEN_DOWNLOADS_MAX_SECONDS: "15"
      BETWEEN_DOWNLOADS_MIN_SECONDS: "5"
      CORS_ORIGINS: "[*]"
      DATA_DIR: /data
      DB_PATH: /data/ytarchiver.db
      DEFAULT_PLAYBACK_RATE: "1.0"
      DEFAULT_QUALITY: "1080"
      DEFAULT_RETENTION_DAYS: "0"
      DELETE_AFTER_WATCHED_PERCENT: "0"
      DOWNLOAD_DIR: /downloads
      INITIAL_BACKFILL_HARD_CAP: "500"
      LOG_LEVEL: INFO
      MAX_VIDEOS_PER_CHANNEL_SCAN: "50"
      MINI_PLAYER_ENABLED: "true"
      MUSIC_PLAYBACK_RATE: "1.0"
      MUSIC_QUEUE_PANEL_SIZE: "100"
      PREVIEW_CRF: "27"
      PREVIEW_SEGMENTS: "12"
      PREVIEW_WIDTH: "480"
      SPONSORBLOCK_API: https://sponsor.ajay.app
      SPONSORBLOCK_REFRESH_DAYS: "7"
      SYNC_INTERVAL_MINUTES: "240"
      SYNC_JITTER_MINUTES: "60"
    healthcheck:
      test: ["CMD", "curl", "-fsS", "http://localhost:8000/api/health"]
      interval: 30s
      timeout: 5s
      retries: 3
      start_period: 20s
    networks:
      - ytarchiver_net
    labels:
      icon: https://upload.wikimedia.org/wikipedia/commons/0/09/YouTube_full-color_icon_%282017%29.svg
    volumes:
      - type: bind
        source: /mnt/t7/media/YT-Archiver/data
        target: /data
      - type: bind
        source: /mnt/t7/media/YT-Archiver/video
        target: /downloads
  frontend:
    image: ghcr.io/pelinoleg/ytarchiver-frontend:latest
    container_name: ytarchiver-frontend
    hostname: ytarchiver-frontend
    restart: unless-stopped
    cpu_shares: 90
    deploy:
      resources:
        limits:
          memory: "8453619712"
    depends_on:
      backend:
        condition: service_started
        required: true
    networks:
      - ytarchiver_net
    ports:
      - target: 80
        published: "8081"
        protocol: tcp
    labels:
      icon: https://raw.githubusercontent.com/pelinoleg/ytarchiver/main/icon.png

networks:
  ytarchiver_net:
    name: ytarchiver_ytarchiver_net
    driver: bridge

x-casaos:
  architectures: [amd64, arm64]
  author: pelinoleg
  category: Media
  description:
    en_us: Self-hosted YouTube video archiver (yt-dlp + FastAPI + React)
  developer: pelinoleg
  icon: https://raw.githubusercontent.com/pelinoleg/ytarchiver/main/icon.png
  index: /
  main: frontend
  port_map: "8081"
  scheme: http
  store_app_id: ytarchiver
  tagline:
    en_us: YouTube Archiver
  title:
    en_us: YT Archiver
EOF
        cd "$APP_DIR"
        sudo docker compose pull
        sudo docker compose up -d
    ); then
        mark_ok "YTARCHIVER" "http://travel-nas.local:8081"
    else
        mark_fail "YTARCHIVER" "docker compose failed"
    fi
fi

# =============================================================================
# 19. DISPLAY (MHS35 + Python dashboard в X-kiosk режиме)
# =============================================================================
if [[ -n "${DO_DISPLAY:-}" ]]; then
    info "=== MHS35 + Display dashboard (X11 kiosk) ==="

    # Удаляем старый systemd-сервис если есть (мы переходим на autostart)
    if [[ -f /etc/systemd/system/travel-nas-display.service ]]; then
        sudo systemctl disable --now travel-nas-display.service 2>/dev/null || true
        sudo rm -f /etc/systemd/system/travel-nas-display.service
        sudo systemctl daemon-reload
    fi

    # Сам Python dashboard
    if (
        set -e
        fetch_script "travel-nas-display.py"        "$SCRIPT_DIR/travel-nas-display.py"
        # Helper для прогресса — парсит rsync, пишет JSON в /var/run/travel-nas/
        fetch_script "backup-progress-writer.py"    "$SCRIPT_DIR/backup-progress-writer.py"

        # services.conf — список URL для страницы Services в дашборде.
        # Не перезаписываем если уже есть. Делаем oleg-owned чтобы редактировать
        # без sudo (там нет секретов).
        sudo mkdir -p /etc/travel-nas
        if [[ ! -f /etc/travel-nas/services.conf ]]; then
            fetch_conf_example "services.conf.example" /etc/travel-nas/services.conf
        fi
        sudo chown "$(whoami):$(whoami)" /etc/travel-nas/services.conf
        sudo chmod 0644 /etc/travel-nas/services.conf

        DASHBOARD_USER="$(whoami)"

        # Runtime state directory: пишут и dashboard (oleg), и udev-скрипты (root).
        # /var/run = tmpfs, очищается при ребуте → ставим tmpfiles.d entry.
        sudo install -d -o "$DASHBOARD_USER" -g "$DASHBOARD_USER" -m 0775 /var/run/travel-nas
        sudo tee /etc/tmpfiles.d/travel-nas.conf >/dev/null << EOF
d /var/run/travel-nas 0775 $DASHBOARD_USER $DASHBOARD_USER -
EOF
        sudo systemd-tmpfiles --create /etc/tmpfiles.d/travel-nas.conf 2>/dev/null || true

        # Sudoers — даём кнопкам dashboard запускать команды без пароля.
        # Без NOPASSWD нажатия превратятся в "тихий no-op" из X-сессии.
        sudo tee /etc/sudoers.d/travel-nas-dashboard >/dev/null << EOF
# Generated by travel-nas-setup. Allows dashboard buttons to run privileged ops.
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/local/bin/nas-backup.sh
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/local/bin/nas-backup-status.py
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/local/bin/daily-summary.sh
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/bin/comitup-cli
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/bin/systemctl reboot, /usr/bin/systemctl poweroff
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/sbin/smartctl
$DASHBOARD_USER ALL=(root) NOPASSWD: /usr/bin/smbstatus
EOF
        sudo chmod 0440 /etc/sudoers.d/travel-nas-dashboard
        # Проверяем синтаксис чтобы не сломать sudo
        if ! sudo visudo -c -f /etc/sudoers.d/travel-nas-dashboard >/dev/null; then
            sudo rm -f /etc/sudoers.d/travel-nas-dashboard
            echo "ERR: sudoers file invalid, removed"
            exit 1
        fi

        # Autostart .desktop — запустится при логине пользователя в LXDE
        USER_HOME="/home/$DASHBOARD_USER"
        AUTOSTART_DIR="$USER_HOME/.config/autostart"
        mkdir -p "$AUTOSTART_DIR"

        cat > "$AUTOSTART_DIR/travel-nas-display.desktop" << EOF
[Desktop Entry]
Type=Application
Name=Travel-NAS Display
Comment=Dashboard for travel-NAS
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
X-GNOME-Autostart-enabled=true
StartupNotify=false
Terminal=false
Hidden=false
EOF

        # Отключаем экранную заставку и blanking (gating мы делаем сами через dpms).
        SS_DIR="$USER_HOME/.config/lxsession/LXDE-pi"
        mkdir -p "$SS_DIR"
        AUTOSTART_FILE="$SS_DIR/autostart"
        for cmd in \
            "@xset s off" \
            "@xset s noblank"; do
            if [[ ! -f "$AUTOSTART_FILE" ]] || ! grep -qF "$cmd" "$AUTOSTART_FILE"; then
                echo "$cmd" >> "$AUTOSTART_FILE"
            fi
        done
        # Старая строка `@xset -dpms` ломает auto-sleep dashboard — удаляем.
        if [[ -f "$AUTOSTART_FILE" ]]; then
            sed -i '/^@xset -dpms$/d' "$AUTOSTART_FILE"
        fi

        # Отключаем PCManFM popup при подключении USB/SD — он перехватывает
        # фокус с dashboard и юзеру приходится кликать "OK" перед каждым бэкапом.
        for PCMANFM_DIR in "$USER_HOME/.config/pcmanfm/LXDE-pi" "$USER_HOME/.config/pcmanfm/default"; do
            mkdir -p "$PCMANFM_DIR"
            PCMANFM_CONF="$PCMANFM_DIR/pcmanfm.conf"
            if [[ ! -f "$PCMANFM_CONF" ]]; then
                cat > "$PCMANFM_CONF" << 'EOF'
[volume]
mount_on_startup=0
mount_removable=0
autorun=0
EOF
            else
                # Идемпотентно: обновляем секцию [volume] или дописываем.
                if grep -q '^\[volume\]' "$PCMANFM_CONF"; then
                    sed -i '/^\[volume\]/,/^\[/{
                        s/^mount_on_startup=.*/mount_on_startup=0/
                        s/^mount_removable=.*/mount_removable=0/
                        s/^autorun=.*/autorun=0/
                    }' "$PCMANFM_CONF"
                else
                    printf '\n[volume]\nmount_on_startup=0\nmount_removable=0\nautorun=0\n' \
                        >> "$PCMANFM_CONF"
                fi
            fi
        done
    ); then
        mark_ok "DISPLAY_DASHBOARD" "autostart + sudoers готовы"
    else
        mark_fail "DISPLAY_DASHBOARD" "autostart setup failed"
    fi

    # Драйвер MHS35 — только если ещё не установлен
    if [[ ! -f /etc/X11/xorg.conf.d/40-libinput.conf.bak ]] && [[ ! -d /tmp/LCD-show ]]; then
        warn "Драйвер MHS35 РЕБУТИТ Pi!"
        echo "Запустить установку драйвера MHS35 сейчас? (y/N)"
        read -r ans
        if [[ "$ans" == "y" || "$ans" == "Y" ]]; then
            cd /tmp
            if sudo git clone https://github.com/goodtft/LCD-show.git 2>/dev/null; then
                cd /tmp/LCD-show
                sudo "./MHS35-show" "90"
                # сюда не дойдём — ребут
            else
                mark_fail "DISPLAY_DRIVER" "git clone failed"
            fi
        else
            info "Драйвер MHS35 пропущен (запусти потом: cd /tmp/LCD-show && sudo ./MHS35-show 90)"
        fi
    else
        info "Драйвер MHS35 уже установлен"
    fi
fi

# =============================================================================
# 19. DESKTOP shortcuts
# =============================================================================
if [[ -n "${DO_DESKTOP:-}" ]]; then
    info "=== Desktop shortcuts ==="
    if (
        set -e
        USER_HOME="/home/$(whoami)"
        DESKTOP_DIR="$USER_HOME/Desktop"
        if [[ -d "$DESKTOP_DIR" ]]; then
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
            # Запуск/возврат dashboard'а после "Exit to desktop"
            cat > "$DESKTOP_DIR/Travel-NAS-Dashboard.desktop" << EOF
[Desktop Entry]
Version=1.0
Type=Application
Name=Travel-NAS Dashboard
Comment=Re-open the kiosk dashboard
Exec=/usr/bin/python3 /usr/local/bin/travel-nas-display.py
Icon=display
Terminal=false
Categories=System;
EOF
            chmod +x "$DESKTOP_DIR"/*.desktop
        else
            echo "Desktop folder not found"
            exit 1
        fi
    ); then
        mark_ok "DESKTOP" "ярлыки на десктопе"
    else
        mark_fail "DESKTOP" "Desktop folder не найден (не Desktop PiOS?)"
    fi
fi

# =============================================================================
# Финальный отчёт
# =============================================================================
echo ""
echo "================================================================"
echo "                    Установка завершена"
echo "================================================================"
echo ""

if [[ ${#INSTALLED[@]} -gt 0 ]]; then
    log "Установлено успешно (${#INSTALLED[@]}):"
    for item in "${INSTALLED[@]}"; do
        echo "   ✓ $item"
    done
fi

if [[ ${#FAILED[@]} -gt 0 ]]; then
    echo ""
    err "Не удалось установить (${#FAILED[@]}):"
    for item in "${FAILED[@]}"; do
        echo "   ✗ $item"
    done
fi

echo ""
IP=$(hostname -I | awk '{print $1}')
echo "IP:       $IP"
echo "Hostname: $(hostname).local"

# Отправляем итоговый отчёт в Telegram
if [[ -x /usr/local/bin/tg-notify.sh ]] && [[ -f /etc/travel-nas/tg-notify.conf ]]; then
    REPORT="Setup finished.

✅ Installed (${#INSTALLED[@]}):
$(printf '• %s\n' "${INSTALLED[@]}")"

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        REPORT+="

❌ Failed (${#FAILED[@]}):
$(printf '• %s\n' "${FAILED[@]}")"
    fi

    REPORT+="

IP: $IP
Hostname: $(hostname).local"

    if [[ ${#FAILED[@]} -gt 0 ]]; then
        /usr/local/bin/tg-notify.sh -l warning "Setup finished with errors" "$REPORT" 2>/dev/null || true
    else
        /usr/local/bin/tg-notify.sh -l success "Setup complete" "$REPORT" 2>/dev/null || true
    fi
fi

echo ""
warn "Рекомендуется ребут для применения hostname и других изменений:"
warn "  sudo reboot"
echo ""