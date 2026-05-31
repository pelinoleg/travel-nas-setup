#!/bin/bash
# =============================================================================
# nas-schedule.sh — управление авто-расписанием NAS-бэкапа (systemd timer)
# =============================================================================
# Единый источник правды: дёргается и wizard'ом (09-nas-backup), и дашбордом.
#
#   nas-schedule.sh status            → "off" | "daily HH:MM" | "weekly HH:MM"
#   nas-schedule.sh set daily 03:00   → включить ежедневно
#   nas-schedule.sh set weekly 04:30  → включить еженедельно (воскресенье)
#   nas-schedule.sh off               → выключить (выбор запоминается для toggle)
#   nas-schedule.sh toggle            → off↔on (on восстанавливает запомненное)
#
# status — read-only (без root). set/off/toggle меняют systemd → нужен root
# (скрипт сам перевызовётся через sudo, если запущен не от root).
# =============================================================================
set -u

TIMER_NAME="nas-backup-auto.timer"
SERVICE_PATH="/etc/systemd/system/nas-backup-auto.service"
TIMER_PATH="/etc/systemd/system/nas-backup-auto.timer"
PREF_FILE="/var/lib/travel-nas/nas-schedule.pref"   # запоминает выбор для toggle

is_on()      { systemctl is-enabled "$TIMER_NAME" >/dev/null 2>&1; }
valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }
need_root()  { [[ $EUID -eq 0 ]] || exec sudo "$0" "$@"; }

current() {   # echo "freq HH:MM" из активного таймера, или ничего
    [[ -f "$TIMER_PATH" ]] || return
    local cal time
    cal=$(grep -m1 '^OnCalendar=' "$TIMER_PATH" | cut -d= -f2-)
    time=$(echo "$cal" | grep -oE '[0-9]{2}:[0-9]{2}' | head -1)
    if echo "$cal" | grep -q '^Sun'; then echo "weekly ${time}"; else echo "daily ${time}"; fi
}

write_and_enable() {   # $1=freq  $2=HH:MM
    local freq="$1" time="$2" cal
    case "$freq" in
        daily)  cal="*-*-* ${time}:00" ;;
        weekly) cal="Sun *-*-* ${time}:00" ;;
        *) echo "bad freq: $freq" >&2; return 1 ;;
    esac
    cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=Automatic NAS backup (scheduled)
After=network-online.target mnt-storage.mount
Wants=network-online.target

[Service]
Type=oneshot
Environment=NAS_BACKUP_DETACHED=1
Nice=15
IOSchedulingClass=idle
# Тихо пропустить если NAS недоступен (в поездке) — без фейла/алёрта.
ExecStart=/bin/bash -c 'source /etc/travel-nas/nas-backup.conf 2>/dev/null; ping -c1 -W3 "$NAS_HOST" >/dev/null 2>&1 && exec /usr/local/bin/nas-backup.sh --run'
EOF
    cat > "$TIMER_PATH" <<EOF
[Unit]
Description=Scheduled NAS backup

[Timer]
OnCalendar=$cal
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
    mkdir -p "$(dirname "$PREF_FILE")"
    echo "$freq $time" > "$PREF_FILE"
    systemctl daemon-reload
    systemctl enable --now "$TIMER_NAME"
}

disable_all() {
    systemctl disable --now "$TIMER_NAME" 2>/dev/null
    rm -f "$TIMER_PATH" "$SERVICE_PATH"
    systemctl daemon-reload
}

case "${1:-status}" in
    status)
        if is_on; then current; else echo "off"; fi
        ;;
    set)
        need_root "$@"
        freq="${2:-daily}"; time="${3:-03:00}"
        valid_time "$time" || { echo "bad time (HH:MM): $time" >&2; exit 1; }
        write_and_enable "$freq" "$time" && echo "$freq $time"
        ;;
    off)
        need_root "$@"
        disable_all; echo "off"
        ;;
    toggle)
        need_root "$@"
        if is_on; then
            disable_all; echo "off"
        else
            pref=$(cat "$PREF_FILE" 2>/dev/null)
            freq=$(echo "$pref" | awk '{print $1}')
            time=$(echo "$pref" | awk '{print $2}')
            [[ "$freq" == daily || "$freq" == weekly ]] || freq="daily"
            valid_time "${time:-}" || time="03:00"
            write_and_enable "$freq" "$time" && echo "$freq $time"
        fi
        ;;
    *)
        echo "usage: nas-schedule.sh {status|set <daily|weekly> <HH:MM>|off|toggle}" >&2
        exit 1
        ;;
esac
