#!/bin/bash
# =============================================================================
# daily-summary.sh - Вечерний отчёт в Telegram (21:00) + JSON для dashboard
# =============================================================================
# Default:   собирает метрики, ПИШЕТ JSON и шлёт Telegram (как было)
# --json:    только пишет JSON (для периодического refresh из таймера/UI)
#
# JSON:      /var/lib/travel-nas/daily-summary.json
# Telegram:  через /usr/local/bin/tg-notify.sh
# =============================================================================

set -u

TG_NOTIFY="/usr/local/bin/tg-notify.sh"
T7_MOUNT="/mnt/t7"
SUMMARY_QUEUE="/var/lib/travel-nas/summary-queue.txt"
LOG="$T7_MOUNT/_logs/daily-summary.log"
STATUS_FILE="/var/lib/travel-nas/daily-summary.json"

MODE="full"   # full | json
for arg in "$@"; do
    case "$arg" in
        --json|--json-only) MODE="json" ;;
        --help|-h)
            cat <<EOF
Usage: $0 [--json]
  (no args)  Collect data, write JSON, send Telegram (21:00 cron use)
  --json     Only write JSON (for periodic UI refresh)
EOF
            exit 0
            ;;
    esac
done

mkdir -p "$(dirname "$LOG")" 2>/dev/null
mkdir -p "$(dirname "$STATUS_FILE")"

log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*" >> "$LOG"
}

# =============================================================================
# Сбор данных
# =============================================================================
UPTIME=$(uptime -p | sed 's/^up //')

CPU_TEMP=""
if command -v vcgencmd &>/dev/null; then
    CPU_TEMP=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
fi

T7_USED=""; T7_TOTAL=""; T7_PCT=""; T7_AVAIL=""; T7_TEMP=""; T7_MOUNTED="no"
if mountpoint -q "$T7_MOUNT"; then
    T7_MOUNTED="yes"
    T7_USED=$(df -h "$T7_MOUNT" --output=used 2>/dev/null | tail -1 | tr -d ' ')
    T7_TOTAL=$(df -h "$T7_MOUNT" --output=size 2>/dev/null | tail -1 | tr -d ' ')
    T7_AVAIL=$(df -h "$T7_MOUNT" --output=avail 2>/dev/null | tail -1 | tr -d ' ')
    T7_PCT=$(df --output=pcent "$T7_MOUNT" 2>/dev/null | tail -1 | tr -d ' %')

    if command -v smartctl &>/dev/null; then
        T7_DEV=$(findmnt -n -o SOURCE "$T7_MOUNT" 2>/dev/null | sed 's/[0-9]*$//')
        if [[ -n "$T7_DEV" ]]; then
            T7_TEMP=$(sudo -n smartctl -a -d sat "$T7_DEV" 2>/dev/null \
                | grep -iE "Temperature_Celsius|Current Drive Temperature|Temperature:" \
                | head -1 | grep -oE '[0-9]+' | head -1)
        fi
    fi
fi

# Throttling status — Pi 5 power monitor (хватает ли питания)
THROTTLE_VAL=""
THROTTLE_NOW="no"
THROTTLE_PAST="no"
if command -v vcgencmd &>/dev/null; then
    THROTTLE_VAL=$(vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//')
    if [[ -n "$THROTTLE_VAL" ]]; then
        v=$((THROTTLE_VAL))
        (( v & 0x7      )) && THROTTLE_NOW="yes"
        (( v & 0x70000  )) && THROTTLE_PAST="yes"
    fi
fi

# Бэкапы за день
TODAY=$(date '+%d-%m-%Y')

PHOTO_COUNT=0
PHOTO_FILES=0
PHOTO_SIZE="0"
if [[ -d "$T7_MOUNT/usb-imports/$TODAY" ]]; then
    PHOTO_COUNT=$(find "$T7_MOUNT/usb-imports/$TODAY" -maxdepth 1 -mindepth 1 -type d \
        ! -name '*.incomplete' 2>/dev/null | wc -l)
    if [[ "$PHOTO_COUNT" -gt 0 ]]; then
        PHOTO_FILES=$(find "$T7_MOUNT/usb-imports/$TODAY" -type f \
            ! -path '*.incomplete/*' 2>/dev/null | wc -l)
        PHOTO_SIZE=$(du -sh "$T7_MOUNT/usb-imports/$TODAY" 2>/dev/null | awk '{print $1}')
    fi
fi

# Incomplete folders across all dates — оборвавшиеся бэкапы
INCOMPLETE_COUNT=0
if [[ -d "$T7_MOUNT/usb-imports" ]]; then
    INCOMPLETE_COUNT=$(find "$T7_MOUNT/usb-imports" -maxdepth 2 -mindepth 2 -type d \
        -name '*.incomplete' 2>/dev/null | wc -l)
fi

# microSD wear estimate (см. system-monitor.sh для деталей)
SD_WEAR_PCT=""
if [[ -r /sys/block/mmcblk0/device/life_time ]]; then
    SD_WEAR_PCT=$(awk '{a=strtonum($1); b=strtonum($2); m=(a>b?a:b); print m*10}' \
        /sys/block/mmcblk0/device/life_time 2>/dev/null)
fi

NAS_BACKUP_TODAY="no"
if [[ -d "$T7_MOUNT/nas-backup/_logs" ]]; then
    if find "$T7_MOUNT/nas-backup/_logs" -name "${TODAY}_*.log" -type f 2>/dev/null | grep -q .; then
        NAS_BACKUP_TODAY="yes"
    fi
fi

ERRORS_TODAY=0
if [[ -d "$T7_MOUNT/_logs" ]]; then
    ERRORS_TODAY=$(find "$T7_MOUNT/_logs" -type f -name "*.log" -mtime -1 \
        -exec grep -l "ERROR\|CRITICAL\|FAILED" {} \; 2>/dev/null | wc -l)
fi

IP_ADDR=$(hostname -I | awk '{print $1}')
SSID=""
if command -v iw &>/dev/null; then
    SSID=$(iw dev wlan0 link 2>/dev/null | awk -F: '/^\s*SSID:/ {sub(/^ /,"",$2); print $2; exit}')
fi

# События дня (из summary-queue) — массив для JSON, очередь НЕ очищаем в json-mode
EVENTS_JSON="[]"
if [[ -f "$SUMMARY_QUEUE" && -s "$SUMMARY_QUEUE" ]]; then
    EVENTS_JSON=$(python3 -c '
import json, sys
lines = [l.rstrip("\n") for l in sys.stdin if l.strip()]
print(json.dumps(lines))
' < "$SUMMARY_QUEUE")
fi

# =============================================================================
# Пишем JSON атомарно
# =============================================================================
TMP_JSON="${STATUS_FILE}.tmp"
# os.environ читает только exported переменные
export TODAY UPTIME CPU_TEMP IP_ADDR SSID
export T7_MOUNTED T7_USED T7_AVAIL T7_TOTAL T7_PCT T7_TEMP
export THROTTLE_VAL THROTTLE_NOW THROTTLE_PAST
export PHOTO_COUNT PHOTO_FILES PHOTO_SIZE
export NAS_BACKUP_TODAY ERRORS_TODAY EVENTS_JSON INCOMPLETE_COUNT SD_WEAR_PCT
python3 - <<PYEOF > "$TMP_JSON"
import json, os, time
data = {
    "updated": int(time.time()),
    "date":    os.environ.get("TODAY", ""),
    "uptime":  os.environ.get("UPTIME", ""),
    "cpu_temp": int(os.environ["CPU_TEMP"]) if os.environ.get("CPU_TEMP") else None,
    "ip":      os.environ.get("IP_ADDR") or None,
    "ssid":    os.environ.get("SSID") or None,
    "t7": {
        "mounted":  os.environ.get("T7_MOUNTED") == "yes",
        "used":     os.environ.get("T7_USED") or None,
        "avail":    os.environ.get("T7_AVAIL") or None,
        "total":    os.environ.get("T7_TOTAL") or None,
        "pct":      int(os.environ["T7_PCT"]) if os.environ.get("T7_PCT") else None,
        "temp":     int(os.environ["T7_TEMP"]) if os.environ.get("T7_TEMP") else None,
    },
    "throttle": {
        "raw":  os.environ.get("THROTTLE_VAL") or None,
        "now":  os.environ.get("THROTTLE_NOW") == "yes",
        "past": os.environ.get("THROTTLE_PAST") == "yes",
    },
    "photo_today": {
        "cards": int(os.environ.get("PHOTO_COUNT") or 0),
        "files": int(os.environ.get("PHOTO_FILES") or 0),
        "size":  os.environ.get("PHOTO_SIZE") or "0",
    },
    "nas_today":    os.environ.get("NAS_BACKUP_TODAY") == "yes",
    "errors_today": int(os.environ.get("ERRORS_TODAY") or 0),
    "incomplete":   int(os.environ.get("INCOMPLETE_COUNT") or 0),
    "sd_wear_pct":  int(os.environ["SD_WEAR_PCT"]) if os.environ.get("SD_WEAR_PCT") else None,
    "events":       json.loads(os.environ.get("EVENTS_JSON") or "[]"),
}
print(json.dumps(data, indent=2))
PYEOF

mv "$TMP_JSON" "$STATUS_FILE"
chmod 0644 "$STATUS_FILE" 2>/dev/null || true

# =============================================================================
# Только JSON режим — выходим, не трогаем Telegram, не очищаем очередь
# =============================================================================
if [[ "$MODE" == "json" ]]; then
    log_msg "JSON refreshed: $STATUS_FILE"
    exit 0
fi

# =============================================================================
# Формируем Telegram-сообщение
# =============================================================================
THROTTLE_LINE=""
if [[ "$THROTTLE_NOW" == "yes" ]]; then
    THROTTLE_LINE="
⚡ *Under-voltage NOW* — \`${THROTTLE_VAL}\`"
elif [[ "$THROTTLE_PAST" == "yes" ]]; then
    THROTTLE_LINE="
⚡ Power dipped earlier today"
fi

MSG="📊 *Daily Report — Travel-NAS*
$(date '+%d-%m-%Y %H:%M')

*System*
⏱  Uptime: \`${UPTIME}\`
🌡  CPU: \`${CPU_TEMP}°C\`
📡 IP: \`${IP_ADDR}\` ${SSID:+(${SSID})}${THROTTLE_LINE}"

# T7 temp на USB-bridge почти всегда unavailable → не показываем "?°C"
if [[ -n "$T7_TEMP" ]]; then
    MSG+="
🌡  T7: \`${T7_TEMP}°C\`"
fi

MSG+="

*Storage*
💾 T7: \`${T7_USED} / ${T7_TOTAL} (${T7_PCT}%)\`"

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

if [[ "$INCOMPLETE_COUNT" -gt 0 ]]; then
    MSG+="

🔶 *Incomplete backups:* $INCOMPLETE_COUNT
Folders with .incomplete suffix exist — backup was interrupted.
Check: \`/mnt/t7/usb-imports/\`"
fi

if [[ -f "$SUMMARY_QUEUE" && -s "$SUMMARY_QUEUE" ]]; then
    # Группируем повторяющиеся "Installed: X" события в одну строку.
    # Если их много (>3) — даём свёрнутый summary вместо 15 одинаковых строк.
    INSTALLED_LIST=$(grep -E "Installed: " "$SUMMARY_QUEUE" 2>/dev/null \
        | sed -E 's/.*Installed: ([A-Z_]+).*/\1/' | sort -u | tr '\n' ',' \
        | sed 's/,$//; s/,/, /g')
    INSTALLED_COUNT=$(echo "$INSTALLED_LIST" | tr ',' '\n' | grep -c .)

    # Остальные события — то что НЕ "Installed:"
    OTHER_EVENTS=$(grep -vE "Installed: " "$SUMMARY_QUEUE" 2>/dev/null || true)

    if [[ "$INSTALLED_COUNT" -gt 0 ]] || [[ -n "$OTHER_EVENTS" ]]; then
        MSG+="

*Today's events*"
    fi
    if [[ "$INSTALLED_COUNT" -gt 3 ]]; then
        MSG+="
🛠 Setup: $INSTALLED_COUNT components installed
\`$INSTALLED_LIST\`"
    elif [[ "$INSTALLED_COUNT" -gt 0 ]]; then
        # Мало — выводим каждое отдельно
        while IFS= read -r line; do
            [[ -n "$line" ]] && MSG+="
${line}"
        done < <(grep -E "Installed: " "$SUMMARY_QUEUE")
    fi
    # Прочие события (бэкапы, ошибки, throttle и т.п.) — всегда показываем
    while IFS= read -r line; do
        [[ -n "$line" ]] && MSG+="
${line}"
    done <<< "$OTHER_EVENTS"

    > "$SUMMARY_QUEUE"
fi

if [[ -x "$TG_NOTIFY" ]]; then
    "$TG_NOTIFY" -l info "$(date '+%d-%m')" "$MSG" 2>/dev/null \
        || log_msg "Failed to send summary"
fi

log_msg "Daily summary sent + JSON written"
exit 0
