#!/bin/bash
# =============================================================================
# system-monitor.sh - Мониторинг Pi (CPU temp, throttling, RAM)
# =============================================================================
# Запускается через systemd timer раз в 5 минут.
# Алертит только при проблемах.
# =============================================================================

set -u

TG_NOTIFY="/usr/local/bin/tg-notify.sh"
LOG="/mnt/t7/_logs/system-monitor.log"
STATE_DIR="/var/lib/travel-nas"
STATE_FILE="$STATE_DIR/system-monitor-state.txt"

CPU_TEMP_WARN=70      # °C
CPU_TEMP_CRITICAL=80  # °C
RAM_WARN=85           # % used
SD_WEAR_WARN=70       # %  — eMMC/microSD life_time used

mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null
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

can_alert() {
    local key="$1"
    local last
    last=$(grep "^${key}:" "$STATE_FILE" 2>/dev/null | tail -1 | cut -d: -f2)
    if [[ -z "$last" ]]; then
        return 0
    fi
    local now=$(date +%s)
    local diff=$((now - last))
    [[ "$diff" -gt 3600 ]] && return 0
    return 1
}

set_state() {
    local key="$1"
    grep -v "^${key}:" "$STATE_FILE" > "${STATE_FILE}.tmp"
    echo "${key}:$(date +%s)" >> "${STATE_FILE}.tmp"
    mv "${STATE_FILE}.tmp" "$STATE_FILE"
}

# === CPU temp ===
check_cpu_temp() {
    if ! command -v vcgencmd &>/dev/null; then
        return 0
    fi
    local temp
    temp=$(vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1)
    if [[ -z "$temp" ]]; then
        return 0
    fi

    if [[ "$temp" -ge "$CPU_TEMP_CRITICAL" ]]; then
        if can_alert "cpu_temp_critical"; then
            tg_notify critical "Pi CPU CRITICAL temp" "Current: ${temp}°C
Throttling will kick in.
Check ventilation."
            set_state "cpu_temp_critical"
        fi
    elif [[ "$temp" -ge "$CPU_TEMP_WARN" ]]; then
        if can_alert "cpu_temp_warn"; then
            tg_notify warning "Pi CPU temp high" "Current: ${temp}°C
Above ${CPU_TEMP_WARN}°C threshold."
            set_state "cpu_temp_warn"
        fi
    fi
}

# === Throttling ===
check_throttling() {
    if ! command -v vcgencmd &>/dev/null; then
        return 0
    fi
    local throttled
    throttled=$(vcgencmd get_throttled 2>/dev/null | grep -oE '0x[0-9a-fA-F]+')

    if [[ -z "$throttled" || "$throttled" == "0x0" ]]; then
        return 0
    fi

    # Декодируем биты
    local val=$((throttled))
    local issues=()

    [[ $((val & 0x1)) -ne 0 ]]     && issues+=("Under-voltage now")
    [[ $((val & 0x2)) -ne 0 ]]     && issues+=("ARM freq capped now")
    [[ $((val & 0x4)) -ne 0 ]]     && issues+=("CPU throttled now")
    [[ $((val & 0x8)) -ne 0 ]]     && issues+=("Soft temp limit now")
    [[ $((val & 0x10000)) -ne 0 ]] && issues+=("Under-voltage occurred")
    [[ $((val & 0x40000)) -ne 0 ]] && issues+=("Throttling occurred")

    # Алертим только если что-то "now" (текущая проблема)
    if [[ $((val & 0xF)) -ne 0 ]]; then
        if can_alert "throttling"; then
            tg_notify warning "Pi power/throttle issue" "$(printf '%s\n' "${issues[@]}")
Check power supply (5V/5A required)."
            set_state "throttling"
        fi
        # Триггерим переключение в emergency mode (если установлен power-mode)
        if [[ -x /usr/local/bin/power-mode.sh ]]; then
            /usr/local/bin/power-mode.sh auto >/dev/null 2>&1 &
        fi
    fi
}

# === RAM ===
check_ram() {
    local mem_total mem_avail mem_used_pct
    mem_total=$(free -m | awk 'NR==2 {print $2}')
    mem_avail=$(free -m | awk 'NR==2 {print $7}')
    mem_used_pct=$(( (mem_total - mem_avail) * 100 / mem_total ))

    if [[ "$mem_used_pct" -ge "$RAM_WARN" ]]; then
        if can_alert "ram_high"; then
            tg_notify warning "Pi RAM high" "Used: ${mem_used_pct}%
Available: ${mem_avail} MB / ${mem_total} MB"
            set_state "ram_high"
        fi
    fi
}

# === microSD wear ===
# Карта сообщает износ в /sys/block/mmcblk0/device/life_time как два hex-значения:
# первое для области A (user), второе для B (system). Каждое значение
# (1..0x0A) соответствует диапазону 10% (1=0-10%, 2=10-20%, ... 0x0A=90-100%).
# 0x0B = превышено максимальное количество циклов.
check_sd_wear() {
    local lt_path="/sys/block/mmcblk0/device/life_time"
    [[ -r "$lt_path" ]] || return 0
    local raw
    raw=$(cat "$lt_path" 2>/dev/null)
    # Берём максимум из двух значений
    local v1 v2 max_v
    v1=$(echo "$raw" | awk '{print $1}')
    v2=$(echo "$raw" | awk '{print $2}')
    [[ -z "$v1" || -z "$v2" ]] && return 0
    v1=$((v1)); v2=$((v2))
    max_v=$(( v1 > v2 ? v1 : v2 ))
    # life_time = N * 10% used (наихудшая оценка)
    local pct=$(( max_v * 10 ))
    if [[ "$pct" -ge "$SD_WEAR_WARN" ]]; then
        if can_alert "sd_wear"; then
            tg_notify warning "microSD wear ${pct}%" "Card lifetime usage estimate.
Backup /etc, rotate to a fresh card soon.
Raw: $raw"
            set_state "sd_wear"
        fi
    fi
}

check_cpu_temp
check_throttling
check_ram
check_sd_wear

# Дёргаем power-mode каждый запуск (5 мин) — учитывает и throttle, и
# температурный гистерезис. Если режим не меняется — это no-op.
if [[ -x /usr/local/bin/power-mode.sh ]]; then
    /usr/local/bin/power-mode.sh auto >/dev/null 2>&1 &
fi

exit 0
