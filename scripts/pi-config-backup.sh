#!/bin/bash
# =============================================================================
# pi-config-backup.sh - Еженедельный бэкап конфигов Pi
# =============================================================================
# Запускается через cron (см. /etc/crontab).
# Сохраняет 4 последних копии, старые автоматически удаляются.
# =============================================================================

set -u

BACKUP_ROOT="/mnt/t7/pi-config-backups"
TG_NOTIFY="/usr/local/bin/tg-notify.sh"

# Если T7 не примонтирован — fallback в /home
if ! mountpoint -q /mnt/t7; then
    BACKUP_ROOT="/home/$(logname 2>/dev/null || echo pi)/pi-config-backups"
fi

DATE=$(date '+%d-%m-%Y_%H-%M')
BACKUP_DIR="$BACKUP_ROOT/$DATE"
mkdir -p "$BACKUP_DIR"

# === Системные файлы ===
cp -r /etc/fstab          "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/samba          "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/network        "$BACKUP_DIR/" 2>/dev/null || true
cp -r /etc/travel-nas     "$BACKUP_DIR/" 2>/dev/null || true
cp /boot/firmware/cmdline.txt "$BACKUP_DIR/" 2>/dev/null || true
cp /boot/firmware/config.txt  "$BACKUP_DIR/" 2>/dev/null || true

# === Travel-NAS скрипты ===
if [[ -d /usr/local/bin ]]; then
    mkdir -p "$BACKUP_DIR/scripts"
    cp /usr/local/bin/tg-notify.sh        "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/photo-backup.sh     "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/nas-backup.sh       "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/pi-config-backup.sh "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/disk-watchdog.sh    "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/system-monitor.sh   "$BACKUP_DIR/scripts/" 2>/dev/null || true
    cp /usr/local/bin/daily-summary.sh    "$BACKUP_DIR/scripts/" 2>/dev/null || true
fi

# === systemd units ===
mkdir -p "$BACKUP_DIR/systemd"
cp /etc/systemd/system/photo-backup@.service       "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/disk-watchdog.service       "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/disk-watchdog.timer         "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/system-monitor.service      "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/system-monitor.timer        "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/daily-summary.service       "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/daily-summary.timer         "$BACKUP_DIR/systemd/" 2>/dev/null || true
cp /etc/systemd/system/travel-nas-display.service  "$BACKUP_DIR/systemd/" 2>/dev/null || true

# === udev rules ===
mkdir -p "$BACKUP_DIR/udev"
cp /etc/udev/rules.d/99-photo-backup.rules "$BACKUP_DIR/udev/" 2>/dev/null || true

# === devmon config (если есть CasaOS) ===
if [[ -f /etc/conf.d/devmon ]]; then
    cp /etc/conf.d/devmon "$BACKUP_DIR/devmon.conf" 2>/dev/null || true
fi

# === CasaOS configs ===
if [[ -d /var/lib/casaos ]]; then
    mkdir -p "$BACKUP_DIR/casaos"
    cp -r /var/lib/casaos/apps "$BACKUP_DIR/casaos/" 2>/dev/null || true
    cp -r /var/lib/casaos/db   "$BACKUP_DIR/casaos/" 2>/dev/null || true
fi
if [[ -d /etc/casaos ]]; then
    cp -r /etc/casaos "$BACKUP_DIR/" 2>/dev/null || true
fi

# === Docker info ===
if command -v docker &>/dev/null; then
    docker ps -a --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}' > "$BACKUP_DIR/docker-containers.txt" 2>/dev/null || true
    docker images --format 'table {{.Repository}}\t{{.Tag}}\t{{.Size}}' > "$BACKUP_DIR/docker-images.txt" 2>/dev/null || true
    docker network ls > "$BACKUP_DIR/docker-networks.txt" 2>/dev/null || true
    docker volume ls > "$BACKUP_DIR/docker-volumes.txt" 2>/dev/null || true
fi

# === Список пакетов ===
dpkg --get-selections > "$BACKUP_DIR/installed-packages.txt"

# === Crontabs ===
sudo crontab -l > "$BACKUP_DIR/crontab-root.txt" 2>/dev/null || true
crontab -l > "$BACKUP_DIR/crontab-user.txt" 2>/dev/null || true

# === Метаданные ===
cat > "$BACKUP_DIR/backup-info.txt" << EOF
Backup created: $(date '+%d-%m-%Y %H:%M:%S')
Hostname:       $(hostname)
Kernel:         $(uname -r)
OS:             $(lsb_release -d 2>/dev/null | cut -f2 || echo "unknown")
Uptime:         $(uptime -p)
T7 mount:       $(mount | grep '/mnt/t7' || echo "not mounted")
T7 disk free:   $(df -h /mnt/t7 2>/dev/null | tail -1)
EOF

# === Чистка старых бэкапов — оставляем 4 последних ===
cd "$BACKUP_ROOT" || exit 1
ls -1t | tail -n +5 | xargs -r rm -rf

# === Telegram уведомление (в summary) ===
SIZE_HUMAN=$(du -sh "$BACKUP_DIR" 2>/dev/null | awk '{print $1}')
if [[ -x "$TG_NOTIFY" ]]; then
    "$TG_NOTIFY" --append info "Pi config backed up" "Size: $SIZE_HUMAN, Path: \`$DATE\`" 2>/dev/null || true
fi

echo "Backup completed: $BACKUP_DIR"
