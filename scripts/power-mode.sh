#!/bin/bash
# =============================================================================
# power-mode.sh — переключает CPU governor под условия питания
# =============================================================================
# Принцип: ВСЁ должно работать. Когда от powerbank'а просядет питание —
# вместо вырубания сервисов просто опускаем планку CPU так, чтобы Pi
# не дёргала пиковые токи. Всё остаётся доступно, просто медленнее.
#
# Два режима:
#   normal — ondemand governor (CPU поднимается до max когда нужно).
#            Используется когда питания достаточно (нормальный БП / powerbank
#            хорошо держит 5V).
#   saver  — powersave governor (CPU зажат на min частоте).
#            Используется когда vcgencmd сообщил под-вольтаж — пик потребления
#            ниже, шанс что Pi устоит больше. Никакие сервисы НЕ выключаются.
#
# Команды:
#   power-mode.sh              — auto: smart выбор по throttled-биту
#   power-mode.sh auto         — то же что без аргументов
#   power-mode.sh normal       — принудительно normal
#   power-mode.sh saver        — принудительно saver
#   power-mode.sh status       — показать текущий
#
# Триггеры авто-переключения:
#   • NetworkManager dispatcher при connect/disconnect (network up = новый
#     БП был воткнут?)
#   • system-monitor когда детектит throttling прямо сейчас
#
# Конфиг: /etc/travel-nas/power-mode.conf (HOME_SSIDS — legacy, не используется)
# =============================================================================

set -u

STATE="/var/lib/travel-nas/power-mode.txt"
LOG="/mnt/t7/_logs/power-mode.log"

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null

log_msg() {
    echo "[$(date '+%d-%m-%Y %H:%M:%S')] $*" >> "$LOG"
}

throttled_now() {
    command -v vcgencmd &>/dev/null || return 1
    local v
    v=$(vcgencmd get_throttled 2>/dev/null | sed 's/throttled=//')
    [[ -z "$v" ]] && return 1
    # Бит 0x1 = под-вольтаж СЕЙЧАС. Бит 0x4 = throttling СЕЙЧАС. 0x2 = freq cap.
    (( $((v)) & 0x7 )) && return 0
    return 1
}

cpu_temp_c() {
    command -v vcgencmd &>/dev/null || { echo 0; return; }
    vcgencmd measure_temp 2>/dev/null | grep -oE '[0-9]+\.[0-9]+' | cut -d. -f1
}

# Гистерезисные пороги (CPU °C). 10° gap чтобы не дёргаться туда-сюда.
TEMP_HOT=75      # ≥75 → переходим в saver
TEMP_COOL=65     # <65 → возвращаемся в normal

detect_mode() {
    # Под-вольтаж сейчас — однозначно saver
    if throttled_now; then
        echo "saver"
        return
    fi

    local t prev
    t=$(cpu_temp_c)
    prev=""
    [[ -f "$STATE" ]] && prev=$(cat "$STATE")

    # Гистерезис по температуре. Помогает CPU остыть когда жарко (saver
    # ограничивает max-частоту → меньше тепла → возврат через TEMP_COOL).
    if [[ "$prev" == "saver" ]]; then
        # Остаёмся в saver пока не остыли ниже TEMP_COOL
        if (( t < TEMP_COOL )); then
            echo "normal"
        else
            echo "saver"
        fi
    else
        # В normal: переключаемся если жарко
        if (( t >= TEMP_HOT )); then
            echo "saver"
        else
            echo "normal"
        fi
    fi
}

apply_governor() {
    local gov="$1"
    local count=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if echo "$gov" | sudo tee "$f" >/dev/null 2>&1; then
            count=$((count + 1))
        fi
    done
    echo "  governor=$gov applied to $count CPUs"
}

apply_mode() {
    local mode="$1"
    case "$mode" in
        normal)
            echo "→ NORMAL mode (ondemand governor)"
            apply_governor ondemand
            ;;
        saver)
            echo "→ SAVER mode (powersave governor — CPU зажат на min частоте)"
            echo "  Все сервисы работают, просто медленнее."
            apply_governor powersave
            ;;
        *)
            echo "Unknown mode: $mode" >&2
            return 1
            ;;
    esac
    echo "$mode" | sudo tee "$STATE" >/dev/null
    log_msg "mode applied: $mode"
}

# legacy: home/field/emergency → mapping на новые
map_legacy() {
    case "$1" in
        home|field) echo "normal" ;;
        emergency)  echo "saver" ;;
        *)          echo "$1" ;;
    esac
}

action="${1:-auto}"
action=$(map_legacy "$action")

case "$action" in
    normal|saver)
        apply_mode "$action"
        ;;
    status)
        if [[ -f "$STATE" ]]; then cat "$STATE"; else echo "unknown"; fi
        ;;
    auto|"")
        m=$(detect_mode)
        prev=""
        [[ -f "$STATE" ]] && prev=$(cat "$STATE")
        if [[ "$m" != "$prev" ]]; then
            apply_mode "$m"
        fi
        echo "$m"
        ;;
    *)
        echo "Usage: $0 [auto|normal|saver|status]" >&2
        exit 1
        ;;
esac
