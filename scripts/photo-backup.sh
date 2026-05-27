#!/bin/bash
# =============================================================================
# photo-backup.sh - Автобэкап USB/SD-карт при подключении
# =============================================================================
# Запускается через udev → systemd photo-backup@<device>.service
#
# Логика:
#  1. Получает /dev/sdX1 от systemd
#  2. Проверяет что это НЕ наш T7 (по UUID)
#  3. Использует flock — параллельные запуски пропускаются
#  4. Ждёт пока CasaOS devmon примонтирует, или монтирует сам read-only
#  5. rsync со всеми файлами (что воткнули — то и копируем)
#  6. Имя: /mnt/t7/usb-imports/DD-MM-YYYY/HH-MM_<label>_<uuid>/
#  7. Auto-umount после завершения
#  8. Telegram уведомления через tg-notify
#
# Конфиг: /etc/travel-nas/photo-backup.conf
# Логи: /mnt/t7/_logs/photo-backup.log
# =============================================================================

set -u

CONFIG="/etc/travel-nas/photo-backup.conf"
TG_NOTIFY="/usr/local/bin/tg-notify.sh"
LOG_DIR="/mnt/t7/_logs"
LOG="$LOG_DIR/photo-backup.log"
LOCK_DIR="/var/run/travel-nas"

DEVICE="${1:-}"

# Загружаем конфиг
if [[ ! -f "$CONFIG" ]]; then
    echo "photo-backup: config not found at $CONFIG" >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$CONFIG"

# Дефолты если не заданы в конфиге
DEST="${DEST:-/mnt/t7/usb-imports}"
AUTO_UMOUNT="${AUTO_UMOUNT:-true}"
T7_UUID="${T7_UUID:-}"
MIN_SIZE="${MIN_SIZE:-1}"
WAIT_FOR_DEVMON="${WAIT_FOR_DEVMON:-3}"

# Папки
mkdir -p "$LOG_DIR" "$LOCK_DIR"

# Перенаправление вывода в лог
exec >> "$LOG" 2>&1

# Helper для логирования
log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*"
}

# Helper для Telegram
tg_notify() {
    local level="$1"
    local title="$2"
    local msg="$3"
    if [[ -x "$TG_NOTIFY" ]]; then
        "$TG_NOTIFY" -l "$level" "$title" "$msg" 2>/dev/null || true
    fi
}

log_msg "=== Backup triggered for $DEVICE ==="

# Базовые проверки
if [[ -z "$DEVICE" || ! -b "$DEVICE" ]]; then
    log_msg "ERROR: $DEVICE is not a block device"
    exit 1
fi

# КРИТИЧНО: игнорируем системные устройства
if [[ "$DEVICE" =~ nvme || "$DEVICE" =~ mmcblk ]]; then
    log_msg "Skipping system device: $DEVICE"
    exit 0
fi

# КРИТИЧНО: проверяем что это НЕ наш T7
DEVICE_UUID=$(lsblk -no UUID "$DEVICE" 2>/dev/null | head -1)
if [[ -n "$T7_UUID" && "$DEVICE_UUID" == "$T7_UUID" ]]; then
    log_msg "Skipping T7 (target disk): $DEVICE"
    exit 0
fi

# Игнорируем также если parent device = наш T7 (sda1 от sda с UUID T7)
PARENT=$(lsblk -no PKNAME "$DEVICE" 2>/dev/null | head -1)
if [[ -n "$PARENT" ]]; then
    for part in /dev/${PARENT}*; do
        PART_UUID=$(lsblk -no UUID "$part" 2>/dev/null | head -1)
        if [[ "$PART_UUID" == "$T7_UUID" ]]; then
            log_msg "Skipping partition of T7: $DEVICE (parent has T7 UUID)"
            exit 0
        fi
    done
fi

# Flock — параллельные запуски на разные устройства не блокируются,
# но один и тот же DEVICE дважды — блокируется
LOCK_FILE="$LOCK_DIR/photo-backup-$(basename "$DEVICE").lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log_msg "Another instance is running for $DEVICE, exit"
    exit 0
fi

# Ждём пока devmon смонтирует
sleep "$WAIT_FOR_DEVMON"

# Где смонтирован диск?
MOUNT_SRC=$(findmnt -n -o TARGET "$DEVICE" 2>/dev/null | head -1)
TEMP_MOUNT=""

if [[ -z "$MOUNT_SRC" ]]; then
    # devmon не смонтировал — монтируем сами read-only
    TEMP_MOUNT=$(mktemp -d /tmp/photo-backup-XXXXXX)
    if mount -o ro "$DEVICE" "$TEMP_MOUNT" 2>/dev/null; then
        MOUNT_SRC="$TEMP_MOUNT"
        log_msg "Mounted $DEVICE at $TEMP_MOUNT (read-only)"
    else
        log_msg "ERROR: cannot mount $DEVICE"
        rmdir "$TEMP_MOUNT" 2>/dev/null
        tg_notify error "Backup failed" "Cannot mount \`$DEVICE\`"
        exit 1
    fi
fi

log_msg "Source mounted at: $MOUNT_SRC"

# Метка и UUID
LABEL=$(lsblk -no LABEL "$DEVICE" 2>/dev/null | head -1 | tr ' /' '_-' | tr -cd '[:alnum:]_-')
UUID_SHORT=$(echo "$DEVICE_UUID" | cut -c1-8)
[[ -z "$LABEL" ]] && LABEL="USB"
[[ -z "$UUID_SHORT" ]] && UUID_SHORT="nouuid"

# Структура: usb-imports/DD-MM-YYYY/HH-MM_<label>_<uuid>/
DATE_DIR=$(date '+%d-%m-%Y')
TIME_PREFIX=$(date '+%H-%M')
BACKUP_NAME="${TIME_PREFIX}_${LABEL}_${UUID_SHORT}"
TARGET_DIR="${DEST}/${DATE_DIR}/${BACKUP_NAME}"
mkdir -p "$TARGET_DIR"

log_msg "Target: $TARGET_DIR"

# Размер источника и количество файлов
SIZE_HUMAN=$(du -sh "$MOUNT_SRC" 2>/dev/null | awk '{print $1}')
FILE_COUNT_SRC=$(find "$MOUNT_SRC" -type f 2>/dev/null | wc -l)

# Проверка — есть ли вообще что копировать
if [[ "$FILE_COUNT_SRC" -eq 0 ]]; then
    log_msg "No files to backup on $DEVICE"
    rmdir "$TARGET_DIR" 2>/dev/null
    # Уборка если сами монтировали
    if [[ -n "$TEMP_MOUNT" && -d "$TEMP_MOUNT" ]]; then
        umount "$TEMP_MOUNT" 2>/dev/null || true
        rmdir "$TEMP_MOUNT" 2>/dev/null || true
    fi
    exit 0
fi

# Уведомление: старт
tg_notify normal "📷 Backup started" "Device: \`$DEVICE\` ($LABEL)
Files: $FILE_COUNT_SRC
Size: $SIZE_HUMAN
Target: \`$DATE_DIR/$BACKUP_NAME\`"

START_TIME=$(date +%s)

# rsync — копируем ВСЁ
rsync -avh \
    --info=PROGRESS2 \
    --stats \
    --no-owner --no-group --no-perms \
    --min-size="${MIN_SIZE}" \
    --exclude='*$recycle.bin/*' \
    --exclude='*trash*' \
    --exclude='.Spotlight-V100' \
    --exclude='.fseventsd' \
    --exclude='.Trashes' \
    --exclude='System Volume Information' \
    --exclude='._*' \
    "$MOUNT_SRC/" "$TARGET_DIR/" 2>&1

RSYNC_EXIT=$?
END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
DURATION_MIN=$((DURATION / 60))
DURATION_SEC=$((DURATION % 60))

# Подсчитываем результат
FILE_COUNT_DST=$(find "$TARGET_DIR" -type f 2>/dev/null | wc -l)
SIZE_DST=$(du -sh "$TARGET_DIR" 2>/dev/null | awk '{print $1}')

# Обработка кодов выхода rsync:
# 0  — успех
# 23 — partial (часть файлов не передалась — это нормально если карта битая)
# 24 — vanished files — тоже не fatal
case "$RSYNC_EXIT" in
    0)
        log_msg "Backup OK: $FILE_COUNT_DST/$FILE_COUNT_SRC files, $SIZE_DST in ${DURATION_MIN}m${DURATION_SEC}s"
        tg_notify success "Backup complete" "Files: $FILE_COUNT_DST/$FILE_COUNT_SRC
Size: $SIZE_DST
Duration: ${DURATION_MIN}m ${DURATION_SEC}s
Path: \`$DATE_DIR/$BACKUP_NAME\`

You can safely remove the card."
        ;;
    23|24)
        # Partial — посчитаем сколько НЕ скопировалось
        MISSED=$((FILE_COUNT_SRC - FILE_COUNT_DST))
        SUCCESS_PCT=$((FILE_COUNT_DST * 100 / FILE_COUNT_SRC))
        log_msg "Backup PARTIAL: $FILE_COUNT_DST/$FILE_COUNT_SRC files ($SUCCESS_PCT%), missed $MISSED"
        if [[ "$SUCCESS_PCT" -ge 90 ]]; then
            # 90%+ — считаем за успех с предупреждением
            tg_notify warning "Backup complete with warnings" "Files: $FILE_COUNT_DST/$FILE_COUNT_SRC (${SUCCESS_PCT}%)
Missed: $MISSED files (read errors on card?)
Size: $SIZE_DST
Duration: ${DURATION_MIN}m ${DURATION_SEC}s
Path: \`$DATE_DIR/$BACKUP_NAME\`"
        else
            tg_notify error "Backup failed" "Only $FILE_COUNT_DST/$FILE_COUNT_SRC files copied (${SUCCESS_PCT}%)
Card may be damaged. Check log:
/mnt/t7/_logs/photo-backup.log"
        fi
        ;;
    *)
        log_msg "Backup FAILED with rsync exit $RSYNC_EXIT"
        tg_notify error "Backup failed" "Device: \`$DEVICE\`
Rsync exit: $RSYNC_EXIT
Files: $FILE_COUNT_DST/$FILE_COUNT_SRC

Check log: \`/mnt/t7/_logs/photo-backup.log\`"
        ;;
esac

# Auto-umount
if [[ "${AUTO_UMOUNT}" == "true" ]]; then
    log_msg "Syncing and unmounting..."
    sync
    sleep 2
    sync
    if umount "$MOUNT_SRC" 2>/dev/null; then
        log_msg "Unmounted $MOUNT_SRC successfully"
        tg_notify info "Card unmounted" "Safe to remove \`$DEVICE\` ($LABEL)"
    else
        log_msg "Failed to umount $MOUNT_SRC (may be busy)"
        tg_notify warning "Cannot unmount card" "Device: \`$DEVICE\`
Wait a moment and remove manually."
    fi
fi

# Уборка временного mount
if [[ -n "$TEMP_MOUNT" && -d "$TEMP_MOUNT" ]]; then
    umount "$TEMP_MOUNT" 2>/dev/null || true
    rmdir "$TEMP_MOUNT" 2>/dev/null || true
fi

log_msg "=== Done ==="
exit "$RSYNC_EXIT"
