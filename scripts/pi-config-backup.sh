#!/bin/bash
# =============================================================================
# pi-config-backup.sh - Еженедельный бэкап конфигов Pi
# =============================================================================
# Запускается через root crontab воскресенье 03:00.
# Сохраняет 4 последних копии в /mnt/t7/pi-config-backups/<DD-MM-YYYY_HH-MM>/.
# Структура backup'а ЗЕРКАЛИРУЕТ исходные пути:
#   $BACKUP_DIR/etc/fstab           ← /etc/fstab
#   $BACKUP_DIR/usr/local/bin/foo   ← /usr/local/bin/foo
#   $BACKUP_DIR/home/oleg/Desktop   ← /home/oleg/Desktop
# Это упрощает restore: просто `cp -r $BACKUP/* /` (точечно через restore-скрипт).
# =============================================================================

set -u

BACKUP_ROOT="/mnt/t7/pi-config-backups"
TG_NOTIFY="/usr/local/bin/tg-notify.sh"

if ! mountpoint -q /mnt/t7; then
    BACKUP_ROOT="/home/$(logname 2>/dev/null || echo pi)/pi-config-backups"
fi

DATE=$(date '+%d-%m-%Y_%H-%M')
BACKUP_DIR="$BACKUP_ROOT/$DATE"
mkdir -p "$BACKUP_DIR"

# Helper: копируем src в $BACKUP_DIR/<src> (зеркало).
backup_path() {
    local src="$1"
    [[ -e "$src" ]] || return 0
    local dst="$BACKUP_DIR$src"
    sudo mkdir -p "$(dirname "$dst")"
    sudo cp -a "$src" "$dst" 2>/dev/null || true
}

# =============================================================================
# /etc — все наши конфиги и системные настройки
# =============================================================================
SYSTEM_ETC=(
    /etc/fstab
    /etc/hosts
    /etc/hostname
    /etc/motd
    /etc/samba                                              # smb.conf и т.п.
    /etc/network
    /etc/travel-nas                                          # все наши .conf
    /etc/sudoers.d/travel-nas-dashboard                      # dashboard buttons
    /etc/tmpfiles.d/travel-nas.conf                          # /var/run/travel-nas
    /etc/NetworkManager/dispatcher.d/99-travel-nas-power     # power-mode hook
    /etc/conf.d/devmon                                       # CasaOS devmon
    /etc/casaos
    /etc/udev/rules.d/99-photo-backup.rules
    /boot/firmware/cmdline.txt
    /boot/firmware/config.txt
)
for p in "${SYSTEM_ETC[@]}"; do backup_path "$p"; done

# =============================================================================
# /usr/local/bin — наши скрипты
# =============================================================================
TN_SCRIPTS=(
    tg-notify.sh
    photo-backup.sh
    nas-backup.sh
    pi-config-backup.sh
    disk-watchdog.sh
    system-monitor.sh
    daily-summary.sh
    set-led.sh
    power-mode.sh
    travel-nas-setup
    travel-nas-display.py
    nas-backup-status.py
    tg-listener.py
    backup-progress-writer.py
)
for s in "${TN_SCRIPTS[@]}"; do backup_path "/usr/local/bin/$s"; done

# =============================================================================
# /etc/systemd/system — наши units
# =============================================================================
TN_UNITS=(
    photo-backup@.service
    disk-watchdog.service        disk-watchdog.timer
    system-monitor.service       system-monitor.timer
    daily-summary.service        daily-summary.timer
    daily-summary-refresh.service daily-summary-refresh.timer
    nas-backup-status.service    nas-backup-status.timer
    tg-listener.service
    travel-nas-display.service           # legacy (мы перешли на autostart, но если жив — бэкапим)
)
for u in "${TN_UNITS[@]}"; do backup_path "/etc/systemd/system/$u"; done

# =============================================================================
# Docker apps — compose-файлы (БД оставляем — большие, восстановит rescan)
# =============================================================================
backup_path /opt/photoview/docker-compose.yml
# CasaOS apps (включая ytarchiver) — папка с compose и метаданными
backup_path /var/lib/casaos/apps
backup_path /var/lib/casaos/db

# =============================================================================
# User-space — autostart, lxsession, pcmanfm, Desktop
# =============================================================================
USER_LOGIN=$(logname 2>/dev/null || echo "$(whoami)")
USER_HOME="/home/$USER_LOGIN"
if [[ -d "$USER_HOME" ]]; then
    backup_path "$USER_HOME/.config/autostart/travel-nas-display.desktop"
    backup_path "$USER_HOME/.config/lxsession/LXDE-pi/autostart"
    backup_path "$USER_HOME/.config/pcmanfm/LXDE-pi/pcmanfm.conf"
    backup_path "$USER_HOME/.config/pcmanfm/default/pcmanfm.conf"
    backup_path "$USER_HOME/Desktop"
fi

# =============================================================================
# /var/lib/travel-nas — runtime state (queue важен; JSON-ы регенерируются)
# =============================================================================
backup_path /var/lib/travel-nas/summary-queue.txt

# =============================================================================
# Docker meta-info (для отладки)
# =============================================================================
if command -v docker &>/dev/null; then
    sudo docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' \
        > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
    sudo docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' \
        > "$BACKUP_DIR/docker-images.txt" 2>/dev/null || true
    sudo docker network ls > "$BACKUP_DIR/docker-networks.txt" 2>/dev/null || true
    sudo docker volume ls > "$BACKUP_DIR/docker-volumes.txt" 2>/dev/null || true
fi

# =============================================================================
# Список apt-пакетов + crontabs
# =============================================================================
dpkg --get-selections > "$BACKUP_DIR/installed-packages.txt"
sudo crontab -l > "$BACKUP_DIR/crontab-root.txt" 2>/dev/null || true
crontab     -l > "$BACKUP_DIR/crontab-user.txt" 2>/dev/null || true

# =============================================================================
# Метаданные backup'а
# =============================================================================
cat > "$BACKUP_DIR/backup-info.txt" << EOF
Backup created: $(date '+%d-%m-%Y %H:%M:%S')
Hostname:       $(hostname)
Kernel:         $(uname -r)
OS:             $(lsb_release -d 2>/dev/null | cut -f2 || echo "unknown")
Uptime:         $(uptime -p)
T7 mount:       $(mount | grep '/mnt/t7' || echo "not mounted")
T7 disk free:   $(df -h /mnt/t7 2>/dev/null | tail -1)
EOF

# =============================================================================
# Чистка старых бэкапов — оставляем 4 последних
# =============================================================================
cd "$BACKUP_ROOT" || exit 1
ls -1t | tail -n +5 | xargs -r rm -rf

# =============================================================================
# Telegram-уведомление
# =============================================================================
SIZE_HUMAN=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
if [[ -x "$TG_NOTIFY" ]]; then
    "$TG_NOTIFY" --append info "Pi config backed up" \
        "Size: $SIZE_HUMAN, Path: \`$DATE\`" 2>/dev/null || true
fi

echo "Backup completed: $BACKUP_DIR ($SIZE_HUMAN)"
