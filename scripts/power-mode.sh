#!/bin/bash
# =============================================================================
# power-mode.sh — переключает CPU governor под условия питания / температуры
# =============================================================================
# Три режима:
#   normal — CPU ondemand (до max 2.4 GHz). Никогда не меняется сам.
#   saver  — CPU powersave (зажат на min). Никогда не меняется сам.
#   auto   — система сама решает по throttled+temp. `A·` префикс в UI.
#
# Файлы состояния:
#   /var/lib/travel-nas/power-mode-pref — выбор юзера (normal/saver/auto)
#   /var/lib/travel-nas/power-mode.txt  — реально применённый governor
#
# Команды:
#   power-mode.sh              — `auto` action: pref → apply
#   power-mode.sh auto-tick    — то же (для systemd timer / dispatcher)
#   power-mode.sh normal       — set pref=normal + apply
#   power-mode.sh saver        — set pref=saver  + apply
#   power-mode.sh auto         — set pref=auto   + apply (по температуре)
#   power-mode.sh status       — текущий pref + applied
#
# Триггеры авто-переключения (при pref=auto):
#   • CPU temp ≥ 75°C → saver
#   • throttled-бит    → saver
#   • temp < 65°C AND throttle clear → normal (гистерезис 10°)
# =============================================================================

set -u

PREF_FILE="/var/lib/travel-nas/power-mode-pref"
STATE="/var/lib/travel-nas/power-mode.txt"
# Лог намеренно в /var/lib (на microSD), не /mnt/t7. Power-mode событие
# может СОВПАДАТЬ с момент когда T7 моргнул (USB power dip) — попытка
# писать в /mnt/t7/_logs/ даёт I/O error и теряет важную диагностику.
LOG="/var/lib/travel-nas/power-mode.log"

mkdir -p "$(dirname "$STATE")" "$(dirname "$LOG")" 2>/dev/null

log_msg() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$LOG" 2>/dev/null
}

read_pref() {
    if [[ -f "$PREF_FILE" ]]; then
        cat "$PREF_FILE"
    else
        echo "auto"
    fi
}

write_pref() {
    echo "$1" | sudo tee "$PREF_FILE" >/dev/null
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

detect_mode_from_env() {
    # Возвращает строку "<mode>|<reason>"
    if throttled_now; then
        echo "saver|throttled-bit-set"
        return
    fi

    local t prev
    t=$(cpu_temp_c)
    prev=""
    [[ -f "$STATE" ]] && prev=$(cat "$STATE")

    # Гистерезис: пока в saver — остаёмся пока не остынем < TEMP_COOL.
    # Пока в normal — переходим в saver только при t >= TEMP_HOT.
    if [[ "$prev" == "saver" ]]; then
        if (( t < TEMP_COOL )); then
            echo "normal|cooled-to-${t}C-below-${TEMP_COOL}"
        else
            echo "saver|still-hot-${t}C-above-${TEMP_COOL}"
        fi
    else
        if (( t >= TEMP_HOT )); then
            echo "saver|temp-${t}C-above-${TEMP_HOT}"
        else
            echo "normal|temp-${t}C-below-${TEMP_HOT}"
        fi
    fi
}

apply_governor() {
    local gov="$1"
    local count=0 failed=0
    for f in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        if echo "$gov" | sudo tee "$f" >/dev/null 2>&1; then
            count=$((count + 1))
        else
            failed=$((failed + 1))
        fi
    done
    if (( failed > 0 )); then
        log_msg "WARN: governor=$gov applied to $count CPUs, $failed failed"
    fi
    echo "  governor=$gov applied to $count CPUs"
}

# target_governor_for "saver" → "powersave"; "normal" → "ondemand"
target_governor_for() {
    case "$1" in
        normal) echo "ondemand" ;;
        saver)  echo "powersave" ;;
        *)      return 1 ;;
    esac
}

# current_governor — что РЕАЛЬНО стоит в kernel (а не наш state-file).
current_governor() {
    cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null
}

apply_mode() {
    local mode="$1"
    local reason="${2:-manual}"
    local target_gov
    target_gov=$(target_governor_for "$mode") || {
        echo "Unknown mode: $mode" >&2
        return 1
    }
    case "$mode" in
        normal) echo "→ NORMAL mode (ondemand governor) — $reason" ;;
        saver)  echo "→ SAVER mode (powersave governor) — $reason"
                echo "  Все сервисы работают, просто медленнее." ;;
    esac
    apply_governor "$target_gov"

    # Verify: kernel actually accepted our request. Если нет —
    # state файл НЕ пишем (иначе соврём что saver когда реально ondemand).
    local now_gov
    now_gov=$(current_governor)
    if [[ "$now_gov" != "$target_gov" ]]; then
        log_msg "ERR: apply_mode '$mode' failed — kernel says gov='$now_gov' (хотели '$target_gov')"
        return 1
    fi
    echo "$mode" | sudo tee "$STATE" >/dev/null
    log_msg "applied: mode=$mode reason=$reason gov=$target_gov"
}

# legacy aliases для совместимости со старыми скриптами/командами
map_legacy() {
    case "$1" in
        home|field) echo "normal" ;;
        emergency)  echo "saver" ;;
        *)          echo "$1" ;;
    esac
}

do_auto_tick() {
    # auto-tick вызывается по таймеру/dispatcher'у. НЕ меняет pref.
    # Читает текущий pref → проверяет РЕАЛЬНЫЙ governor → действует.
    local pref
    pref=$(read_pref)
    local prev=""
    [[ -f "$STATE" ]] && prev=$(cat "$STATE")

    case "$pref" in
        normal|saver)
            # КРИТИЧНО: проверяем что kernel реально на нужном governor'е.
            # Не доверяем state-file — после reboot/внешнего сервиса governor
            # может быть ondemand хотя state="saver" с прошлой сессии. Раньше
            # tick говорил "no-op (already saver)" и оставался ondemand —
            # дашборд показывал 'saver' при 2.4GHz. Гарантируем enforcement.
            local target_gov now_gov
            target_gov=$(target_governor_for "$pref")
            now_gov=$(current_governor)
            if [[ "$now_gov" != "$target_gov" ]]; then
                apply_mode "$pref" "tick:enforce was=$now_gov want=$target_gov"
            else
                log_msg "tick: pref=$pref gov=$now_gov ✓"
            fi
            ;;
        auto|"")
            local detected reason
            IFS='|' read -r detected reason <<< "$(detect_mode_from_env)"
            log_msg "tick: pref=auto detected=$detected prev=$prev reason=$reason"
            if [[ "$detected" != "$prev" ]]; then
                apply_mode "$detected" "auto:$reason"
            fi
            echo "$detected"
            ;;
        *)
            log_msg "ERR: unknown pref '$pref', resetting to auto"
            write_pref "auto"
            do_auto_tick
            ;;
    esac
}

print_status() {
    local pref applied
    pref=$(read_pref)
    applied=""
    [[ -f "$STATE" ]] && applied=$(cat "$STATE")
    echo "pref=$pref applied=${applied:-unknown}"
    if [[ "$pref" == "auto" ]]; then
        local detected reason
        IFS='|' read -r detected reason <<< "$(detect_mode_from_env)"
        echo "auto would pick: $detected ($reason)"
    fi
    echo "throttled-raw: $(vcgencmd get_throttled 2>/dev/null || echo n/a)"
    echo "cpu-temp:      $(cpu_temp_c)°C"
}

action="${1:-auto-tick}"
action=$(map_legacy "$action")

case "$action" in
    normal|saver)
        write_pref "$action"
        apply_mode "$action" "manual"
        ;;
    auto)
        # Юзер выбрал auto — записываем pref и сразу применяем по env
        write_pref "auto"
        do_auto_tick
        ;;
    auto-tick|"")
        do_auto_tick
        ;;
    status)
        print_status
        ;;
    *)
        echo "Usage: $0 [normal|saver|auto|auto-tick|status]" >&2
        exit 1
        ;;
esac
