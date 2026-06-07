#!/bin/bash
# =============================================================================
# dsi-backlight.sh — яркость Waveshare 4.3″ DSI через sysfs (только этот экран).
# На MHS35 backlight прибит к 5V и не управляется — там этот скрипт не нужен.
#
# Доступ без sudo даёт udev-правило 99-backlight-permissions.rules (group video
# 0664), которое ставит модуль 19-display при выборе DSI. Если прав нет —
# фолбэк на sudo tee.
#
# Использование:
#   dsi-backlight.sh             показать текущую яркость / max / % / power
#   dsi-backlight.sh 128         установить (0..max_brightness, обычно 0-255)
#   dsi-backlight.sh 50%         установить в процентах от max
#   dsi-backlight.sh +20 | -20   шаг вверх/вниз
#   dsi-backlight.sh off | on    выключить/включить подсветку (bl_power)
# =============================================================================
set -e

BL=$(ls -d /sys/class/backlight/*/ 2>/dev/null | head -1 || true)
[[ -n "$BL" ]] || { echo "backlight не найден в /sys/class/backlight — DSI не подключён или выбран не тот экран" >&2; exit 1; }
BL="${BL%/}"
BR="$BL/brightness"
PWR="$BL/bl_power"
MAX=$(cat "$BL/max_brightness" 2>/dev/null || echo 255)

write() {  # write <file> <value> — прямо если writable, иначе через sudo
    local f="$1" v="$2"
    if [[ -w "$f" ]]; then printf '%s' "$v" > "$f"; else printf '%s' "$v" | sudo tee "$f" >/dev/null; fi
}
clamp() { local v="$1"; (( v < 0 )) && v=0; (( v > MAX )) && v=$MAX; echo "$v"; }

cur=$(cat "$BR" 2>/dev/null || echo "?")
arg="${1:-}"

case "$arg" in
    "")
        pct=$(( cur * 100 / MAX ))
        pwr=$(cat "$PWR" 2>/dev/null || echo "?")   # 0=on, 4=off (FB_BLANK)
        echo "backlight: $BL"
        echo "brightness: $cur / $MAX (${pct}%)   bl_power=$pwr (0=on,4=off)"
        ;;
    on)   write "$PWR" 0; [[ "$(cat "$BR" 2>/dev/null)" == "0" ]] && write "$BR" "$MAX"; echo "backlight ON" ;;
    off)  write "$BR" 0; write "$PWR" 4; echo "backlight OFF" ;;   # brightness=0 — bl_power=4 на DSI лишь притухает
    +*)   write "$BR" "$(clamp $(( cur + ${arg#+} )))"; write "$PWR" 0; echo "brightness → $(cat "$BR")/$MAX" ;;
    -*)   write "$BR" "$(clamp $(( cur - ${arg#-} )))"; write "$PWR" 0; echo "brightness → $(cat "$BR")/$MAX" ;;
    *%)   write "$BR" "$(clamp $(( ${arg%\%} * MAX / 100 )))"; write "$PWR" 0; echo "brightness → $(cat "$BR")/$MAX" ;;
    *[!0-9]*) echo "Usage: $0 [ <0-$MAX> | <N%> | +N | -N | on | off ]" >&2; exit 2 ;;
    *)    write "$BR" "$(clamp "$arg")"; write "$PWR" 0; echo "brightness → $(cat "$BR")/$MAX" ;;
esac
