#!/bin/bash
# =============================================================================
# power-mode.sh — переключает CPU governor + heavy Docker apps под условия питания
# =============================================================================
# Режимы:
#   home       — на домашнем Wi-Fi: ondemand, все Docker apps запущены
#   field      — в поездке от хорошего питания: ondemand, как обычно
#   emergency  — детектнули under-voltage прямо сейчас: powersave +
#                остановить тяжёлые Docker apps (yt-archiver, photoview)
#
# Запуск:
#   power-mode.sh              — авто-детект и применить
#   power-mode.sh home|field|emergency  — принудительно
#   power-mode.sh status       — показать текущий режим
#
# Авто-детект:
#  - Если vcgencmd get_throttled & 0x7 (under-voltage сейчас) → emergency
#  - Иначе если SSID в HOME_SSIDS → home
#  - Иначе → field
#
# Триггеры:
#  - NetworkManager dispatcher при connect/disconnect
#  - system-monitor.sh при детекте throttling
#  - manually via dashboard / shell
# =============================================================================

set -u

CONFIG="/etc/travel-nas/power-mode.conf"
STATE="/var/lib/travel-nas/power-mode.txt"
LOG="/mnt/t7/_logs/power-mode.log"

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null

log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*" >> "$LOG"
}

# Дефолты на случай если config не существует
HOME_SSIDS=()
HEAVY_DOCKER_APPS=("ytarchiver" "photoview")

if [[ -f "$CONFIG" ]]; then
    # shellcheck source=/dev/null
    source "$CONFIG"
fi

current_ssid() {
    iw dev wlan0 link 2>/dev/null \
        | awk -F: '/^\s*SSID:/ {sub(/^ /,"",$2); print $2; exit}'
}

throttled_now() {
    command -v vcgencmd &>/dev/null || return 1
    local v
    v=$(vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//')
    [[ -z "$v" ]] && return 1
    (( $((v)) & 0x7 )) && return 0
    return 1
}

detect_mode() {
    if throttled_now; then
        echo "emergency"; return
    fi
    local ssid; ssid=$(current_ssid)
    if [[ -n "$ssid" && ${#HOME_SSIDS[@]} -gt 0 ]]; then
        for h in "${HOME_SSIDS[@]}"; do
            if [[ "$ssid" == "$h" ]]; then
                echo "home"; return
            fi
        done
    fi
    echo "field"
}

apply_governor() {
    local gov="$1"
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo "$gov" | sudo tee "$f" >/dev/null 2>&1 || true
    done
}

heavy_apps_start() {
    for app in "${HEAVY_DOCKER_APPS[@]}"; do
        local compose=""
        if   [[ -f "/var/lib/casaos/apps/$app/docker-compose.yml" ]]; then
            compose="/var/lib/casaos/apps/$app/docker-compose.yml"
        elif [[ -f "/opt/$app/docker-compose.yml" ]]; then
            compose="/opt/$app/docker-compose.yml"
        fi
        [[ -z "$compose" ]] && continue
        sudo docker compose -f "$compose" up -d 2>/dev/null \
            && log_msg "started: $app"
    done
}

heavy_apps_stop() {
    for app in "${HEAVY_DOCKER_APPS[@]}"; do
        local compose=""
        if   [[ -f "/var/lib/casaos/apps/$app/docker-compose.yml" ]]; then
            compose="/var/lib/casaos/apps/$app/docker-compose.yml"
        elif [[ -f "/opt/$app/docker-compose.yml" ]]; then
            compose="/opt/$app/docker-compose.yml"
        fi
        [[ -z "$compose" ]] && continue
        sudo docker compose -f "$compose" stop 2>/dev/null \
            && log_msg "stopped: $app"
    done
}

apply_mode() {
    local mode="$1"
    case "$mode" in
        home)
            apply_governor ondemand
            heavy_apps_start
            ;;
        field)
            apply_governor ondemand
            # field не стартует и не стопит Docker — оставляет как было
            ;;
        emergency)
            apply_governor powersave
            heavy_apps_stop
            ;;
        *)
            echo "Unknown mode: $mode" >&2
            return 1
            ;;
    esac
    echo "$mode" | sudo tee "$STATE" >/dev/null
    log_msg "mode applied: $mode"
}

action="${1:-auto}"
case "$action" in
    home|field|emergency)
        apply_mode "$action"
        ;;
    status)
        if [[ -f "$STATE" ]]; then
            cat "$STATE"
        else
            echo "unknown"
        fi
        ;;
    auto|"")
        m=$(detect_mode)
        # Не перезаписываем если режим тот же — экономит docker calls
        prev=""
        [[ -f "$STATE" ]] && prev=$(cat "$STATE")
        if [[ "$m" != "$prev" ]]; then
            apply_mode "$m"
        fi
        echo "$m"
        ;;
    *)
        echo "Usage: $0 [auto|home|field|emergency|status]" >&2
        exit 1
        ;;
esac
