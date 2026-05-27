#!/bin/bash
# =============================================================================
# set-led.sh — управляет встроенным power-LED Raspberry Pi
# =============================================================================
# Используется backup-скриптами как визуальный индикатор:
#   set-led.sh idle     — solid (default) — система готова
#   set-led.sh busy     — slow blink (heartbeat) — идёт backup
#   set-led.sh error    — fast blink — что-то пошло не так
#   set-led.sh off      — погасить
#
# Pi 5: LED называется /sys/class/leds/ACT и /sys/class/leds/PWR.
# ACT (зелёный) — controlled, PWR (красный) — индикатор питания.
# Управляем ACT, так как он не должен реагировать на ввод-вывод
# (его default-trigger = mmc0, что показывает обращения к microSD).
# =============================================================================

set -u

LED_DIR="/sys/class/leds/ACT"
[[ -d "$LED_DIR" ]] || LED_DIR="/sys/class/leds/led0"   # старые Pi
[[ -d "$LED_DIR" ]] || { echo "No controllable LED found" >&2; exit 0; }

TRIGGER="$LED_DIR/trigger"
BRIGHTNESS="$LED_DIR/brightness"

set_trigger() {
    # требует root
    echo "$1" | sudo tee "$TRIGGER" >/dev/null 2>&1 || true
}

set_brightness() {
    echo "$1" | sudo tee "$BRIGHTNESS" >/dev/null 2>&1 || true
}

case "${1:-idle}" in
    idle|default)
        # Вернуть к стандартному поведению (показывает SD I/O)
        set_trigger "mmc0"
        ;;
    busy)
        # Медленный heartbeat — заметно, не назойливо
        set_trigger "heartbeat"
        ;;
    error)
        # Быстрое мигание — таймер 100/100 мс
        set_trigger "timer"
        echo 100 | sudo tee "$LED_DIR/delay_on"  >/dev/null 2>&1 || true
        echo 100 | sudo tee "$LED_DIR/delay_off" >/dev/null 2>&1 || true
        ;;
    on)
        set_trigger "none"
        set_brightness 1
        ;;
    off)
        set_trigger "none"
        set_brightness 0
        ;;
    *)
        echo "Usage: $0 idle|busy|error|on|off" >&2
        exit 1
        ;;
esac
