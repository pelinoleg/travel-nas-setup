#!/bin/bash
# =============================================================================
# disk-watchdog.sh - Мониторинг T7 (раз в 5 минут через systemd timer)
# =============================================================================
# Проверяет:
#  - Примонтирован ли T7 (если нет — попытка mount + alert)
#  - Read-only режим из-за ошибок ext4
#  - Температуру (SMART)
#  - SMART warnings (Critical, Media errors)
#  - Свободное место (>90% — warning, >95% — critical + auto-cleanup nas-backup)
#
# State в /var/lib/travel-nas/disk-watchdog-state.txt чтобы не спамить
# одинаковыми алертами каждые 5 минут.
# =============================================================================

set -u

TG_NOTIFY="/usr/local/bin/tg-notify.sh"
T7_MOUNT="/mnt/t7"
LOG="$T7_MOUNT/_logs/disk-watchdog.log"
STATE_DIR="/var/lib/travel-nas"
STATE_FILE="$STATE_DIR/disk-watchdog-state.txt"
NAS_BACKUP_DIR="$T7_MOUNT/nas-backup"

# Thresholds
TEMP_WARN=60         # °C — предупреждение
TEMP_CRITICAL=70     # °C — критично, остановить запись
SPACE_WARN=90        # % использовано
SPACE_CRITICAL=95    # % — авточистка nas-backup

mkdir -p "$STATE_DIR" "$(dirname "$LOG")"
touch "$STATE_FILE"

log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*" >> "$LOG"
}

tg_notify() {
    local level="$1"
    local title="$2"
    local msg="$3"
    if [[ -x "$TG_NOTIFY" ]]; then
        "$TG_NOTIFY" -l "$level" "$title" "$msg" 2>/dev/null || true
    fi
}

# Установить state (не повторять одинаковый алерт чаще раз в час)
set_state() {
    local key="$1"
    local value="$2"
    local now=$(date +%s)
    grep -v "^${key}:" "$STATE_FILE" > "${STATE_FILE}.tmp"
    echo "${key}:${now}:${value}" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

get_state() {
    local key="$1"
    grep "^${key}:" "$STATE_FILE" 2>/dev/null | tail -1 || echo ""
}

# Можно ли сейчас слать алерт для этого ключа? (не чаще раз в час)
can_alert() {
    local key="$1"
    local last
    last=$(get_state "$key" | cut -d: -f2)
    if [[ -z "$last" ]]; then
        return 0
    fi
    local now=$(date +%s)
    local diff=$((now - last))
    if [[ "$diff" -gt 3600 ]]; then
        return 0
    fi
    return 1
}

# === Проверка 1: T7 примонтирован? ===
check_mount() {
    if mountpoint -q "$T7_MOUNT"; then
        # Был ли он отмонтирован раньше?
        local last_state
        last_state=$(get_state "mount" | cut -d: -f3)
        if [[ "$last_state" == "down" ]]; then
            tg_notify success "T7 reconnected" "Disk mounted again at \`$T7_MOUNT\`"
            log_msg "T7 reconnected"
        fi
        set_state "mount" "up"
        return 0
    else
        # Не примонтирован — пробуем смонтировать
        log_msg "T7 not mounted, attempting mount -a"
        if mount -a 2>/dev/null && mountpoint -q "$T7_MOUNT"; then
            log_msg "Successfully mounted via mount -a"
            set_state "mount" "up"
            return 0
        fi
        # Не получилось
        log_msg "ERROR: T7 not mounted and cannot be mounted"
        if can_alert "mount"; then
            tg_notify critical "T7 disconnected!" "Disk not mounted at \`$T7_MOUNT\`
Try: \`sudo mount -a\`
Check: \`lsblk -f\`"
        fi
        set_state "mount" "down"
        return 1
    fi
}

# === Проверка 2: Read-only режим? ===
check_readonly() {
    if mount | grep "$T7_MOUNT" | grep -qE 'emergency_ro|\bro\b'; then
        log_msg "ERROR: T7 in read-only mode!"
        if can_alert "readonly"; then
            tg_notify critical "T7 is READ-ONLY!" "Filesystem errors detected.
Mount info: $(mount | grep "$T7_MOUNT")
Check: \`sudo dmesg | grep -i ext4\`
Likely need fsck."
        fi
        return 1
    fi
    return 0
}

# === Проверка 3: SMART здоровье ===
check_smart() {
    local device
    device=$(findmnt -n -o SOURCE "$T7_MOUNT" 2>/dev/null | sed 's/[0-9]*$//')
    if [[ -z "$device" ]]; then
        return 0
    fi

    if ! command -v smartctl &>/dev/null; then
        return 0
    fi

    # USB SSD через USB-bridge — нужна опция -d sat
    local smart_out
    smart_out=$(sudo smartctl -a -d sat "$device" 2>/dev/null || sudo smartctl -a "$device" 2>/dev/null || echo "")

    if [[ -z "$smart_out" ]]; then
        return 0
    fi

    # Температура
    local temp
    temp=$(echo "$smart_out" | grep -iE "Temperature_Celsius|Current Drive Temperature|Temperature:" | head -1 | grep -oE '[0-9]+' | head -1)
    if [[ -n "$temp" ]]; then
        if [[ "$temp" -ge "$TEMP_CRITICAL" ]]; then
            if can_alert "temp_critical"; then
                tg_notify critical "T7 CRITICAL temperature" "Current: ${temp}°C (>${TEMP_CRITICAL}°C)
Stop heavy writes immediately."
            fi
        elif [[ "$temp" -ge "$TEMP_WARN" ]]; then
            if can_alert "temp_warn"; then
                tg_notify warning "T7 temperature high" "Current: ${temp}°C (>${TEMP_WARN}°C)"
            fi
        fi
    fi

    # Проверка SMART health
    if echo "$smart_out" | grep -qiE "FAILED|FAILING_NOW"; then
        if can_alert "smart_failed"; then
            tg_notify critical "T7 SMART FAILED" "Disk reports failure!
Backup important data NOW.
Run: \`sudo smartctl -a $device\`"
        fi
    fi
}

# === Проверка 4: Свободное место ===
check_space() {
    local usage
    usage=$(df --output=pcent "$T7_MOUNT" 2>/dev/null | tail -1 | tr -d ' %')
    if [[ -z "$usage" ]]; then
        return 0
    fi

    local avail
    avail=$(df -h --output=avail "$T7_MOUNT" 2>/dev/null | tail -1 | tr -d ' ')

    if [[ "$usage" -ge "$SPACE_CRITICAL" ]]; then
        log_msg "CRITICAL: T7 ${usage}% used, ${avail} available"
        if can_alert "space_critical"; then
            tg_notify critical "T7 almost full" "Used: ${usage}%
Available: ${avail}

Auto-cleanup nas-backup will start..."
        fi
        # Запускаем автоочистку только nas-backup (НЕ photos!)
        cleanup_nas_backup
    elif [[ "$usage" -ge "$SPACE_WARN" ]]; then
        log_msg "WARN: T7 ${usage}% used, ${avail} available"
        if can_alert "space_warn"; then
            tg_notify warning "T7 getting full" "Used: ${usage}%
Available: ${avail}

Cleanup will trigger at ${SPACE_CRITICAL}%"
        fi
    fi
}

# === Автоочистка старых nas-backup _deleted ===
cleanup_nas_backup() {
    if [[ ! -d "$NAS_BACKUP_DIR/_deleted" ]]; then
        return 0
    fi

    log_msg "Auto-cleanup: removing _deleted folders older than 30 days"
    local freed_before
    freed_before=$(df --output=avail "$T7_MOUNT" | tail -1)

    find "$NAS_BACKUP_DIR/_deleted" -maxdepth 1 -type d -mtime +30 -exec rm -rf {} \; 2>/dev/null

    local freed_after
    freed_after=$(df --output=avail "$T7_MOUNT" | tail -1)
    local freed_kb=$((freed_after - freed_before))
    local freed_mb=$((freed_kb / 1024))

    if [[ "$freed_mb" -gt 0 ]]; then
        tg_notify info "Auto-cleanup done" "Removed _deleted folders older than 30 days.
Freed: ${freed_mb} MB"
        log_msg "Auto-cleanup freed ${freed_mb} MB"
    fi
}

# === Главный цикл ===
check_mount       || exit 0  # Если не смонтирован — дальше нет смысла
check_readonly    || true
check_smart       || true
check_space       || true

exit 0
