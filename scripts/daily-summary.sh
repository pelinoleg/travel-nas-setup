#!/bin/bash
# =============================================================================
# daily-summary.sh - Вечерний отчёт в Telegram (21:00)
# =============================================================================
# Собирает за день: статус системы, температуры, бэкапы, использование места.
# Также включает накопленные info-уведомления из summary-queue.
# =============================================================================

set -u

TG_NOTIFY="/usr/local/bin/tg-notify.sh"
T7_MOUNT="/mnt/t7"
SUMMARY_QUEUE="/var/lib/travel-nas/summary-queue.txt"
LOG="$T7_MOUNT/_logs/daily-summary.log"

mkdir -p "$(dirname "$LOG")" 2>/dev/null

log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*" >> "$LOG"
}

# === Сбор информации ===

# Uptime
UPTIME=$(uptime -p | sed 's/^up //')

# CPU temp (current + max за день из логов system-monitor если есть)
CPU_TEMP="?"
if command -v vcgencmd &>/dev/null; then
    CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
fi

# T7 disk
T7_INFO=""
T7_TEMP=""
if mountpoint -q "$T7_MOUNT"; then
    DISK_USED=$(df -h "$T7_MOUNT" --output=used 2>/dev/null | tail -1 | tr -d ' ')
    DISK_TOTAL=$(df -h "$T7_MOUNT" --output=size 2>/dev/null | tail -1 | tr -d ' ')
    DISK_PCT=$(df --output=pcent "$T7_MOUNT" 2>/dev/null | tail -1 | tr -d ' %')
    T7_INFO="${DISK_USED} / ${DISK_TOTAL} (${DISK_PCT}%)"

    # SMART temp
    if command -v smartctl &>/dev/null; then
        T7_DEV=$(findmnt -n -o SOURCE "$T7_MOUNT" 2>/dev/null | sed 's/[0-9]*$//')
        if [[ -n "$T7_DEV" ]]; then
            T7_TEMP=$(sudo smartctl -a -d sat "$T7_DEV" 2>/dev/null | grep -iE "Temperature_Celsius|Current Drive Temperature|Temperature:" | head -1 | grep -oE '[0-9]+' | head -1)
        fi
    fi
else
    T7_INFO="❌ NOT MOUNTED"
fi

# Бэкапы за день
TODAY=$(date '+%d-%m-%Y')

# Photo backups сегодня
PHOTO_COUNT=0
PHOTO_FILES=0
PHOTO_SIZE="0"
if [[ -d "$T7_MOUNT/usb-imports/$TODAY" ]]; then
    PHOTO_COUNT=$(find "$T7_MOUNT/usb-imports/$TODAY" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | wc -l)
    if [[ "$PHOTO_COUNT" -gt 0 ]]; then
        PHOTO_FILES=$(find "$T7_MOUNT/usb-imports/$TODAY" -type f 2>/dev/null | wc -l)
        PHOTO_SIZE=$(du -sh "$T7_MOUNT/usb-imports/$TODAY" 2>/dev/null | awk '{print $1}')
    fi
fi

# NAS backup был сегодня?
NAS_BACKUP_TODAY="no"
if [[ -d "$T7_MOUNT/nas-backup/_logs" ]]; then
    if find "$T7_MOUNT/nas-backup/_logs" -name "${TODAY}_*.log" -type f 2>/dev/null | grep -q .; then
        NAS_BACKUP_TODAY="yes"
    fi
fi

# Errors из логов за сегодня
ERRORS_TODAY=0
if [[ -d "$T7_MOUNT/_logs" ]]; then
    ERRORS_TODAY=$(find "$T7_MOUNT/_logs" -type f -name "*.log" -exec grep -l "ERROR\|CRITICAL\|FAILED" {} \; 2>/dev/null | wc -l)
fi

# IP адрес
IP_ADDR=$(hostname -I | awk '{print $1}')
SSID=""
if command -v iwgetid &>/dev/null; then
    SSID=$(iwgetid -r 2>/dev/null || echo "")
fi

# === Формируем сообщение ===

MSG="📊 *Daily Report — Travel-NAS*
$(date '+%d-%m-%Y %H:%M')

*System*
⏱  Uptime: \`${UPTIME}\`
🌡  CPU: \`${CPU_TEMP}°C\`
🌡  T7: \`${T7_TEMP:-?}°C\`
📡 IP: \`${IP_ADDR}\` ${SSID:+(${SSID})}

*Storage*
💾 T7: \`${T7_INFO}\`"

if [[ "$PHOTO_COUNT" -gt 0 ]]; then
    MSG+="

*Photo backups today*
📷 ${PHOTO_COUNT} cards
📁 ${PHOTO_FILES} files
💿 ${PHOTO_SIZE}"
fi

if [[ "$NAS_BACKUP_TODAY" == "yes" ]]; then
    MSG+="

*NAS backup*
🏠 ✅ Completed today"
fi

if [[ "$ERRORS_TODAY" -gt 0 ]]; then
    MSG+="

⚠️ *Issues:* $ERRORS_TODAY log(s) with errors
Check: \`/mnt/t7/_logs/\`"
fi

# Дописываем накопленные info-уведомления
if [[ -f "$SUMMARY_QUEUE" && -s "$SUMMARY_QUEUE" ]]; then
    MSG+="

*Today's events*"
    while IFS= read -r line; do
        MSG+="
${line}"
    done < "$SUMMARY_QUEUE"

    # Очищаем очередь после отправки
    > "$SUMMARY_QUEUE"
fi

# === Отправляем ===
if [[ -x "$TG_NOTIFY" ]]; then
    # Через временный файл — много текста и переносов
    "$TG_NOTIFY" -l info "$(date '+%d-%m')" "$MSG" 2>/dev/null || log_msg "Failed to send summary"
fi

log_msg "Daily summary sent"
exit 0
