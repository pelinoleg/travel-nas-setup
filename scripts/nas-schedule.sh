#!/bin/bash
# =============================================================================
# nas-schedule.sh — авто-расписание NAS-бэкапа
# =============================================================================
# ИСТОЧНИК ПРАВДЫ — /etc/travel-nas/nas-backup.conf (как все настройки проекта):
#   AUTO_BACKUP="on|off"
#   AUTO_BACKUP_FREQ="daily|weekly"     # weekly = воскресенье
#   AUTO_BACKUP_TIME="HH:MM"            # 24ч
#
# Меняешь конфиг руками → path-unit `nas-schedule-apply` сам применяет (как
# другие настройки). Этот скрипт только синхронизирует systemd-timer с конфигом.
#
#   status            → "off" | "daily HH:MM" | "weekly HH:MM"   (читает конфиг)
#   apply             → привести systemd-timer в соответствие с конфигом   (root)
#   set <freq> <time> → записать в конфиг + apply                          (root)
#   off               → AUTO_BACKUP=off + apply                            (root)
#   toggle            → флип on/off + apply                                (root)
#
# status — read-only (без root). Остальное меняет systemd/конфиг → нужен root
# (скрипт сам перевызовётся через sudo, если запущен не от root).
# =============================================================================
set -u

CONF="/etc/travel-nas/nas-backup.conf"
TIMER_NAME="nas-backup-auto.timer"
SERVICE_PATH="/etc/systemd/system/nas-backup-auto.service"
TIMER_PATH="/etc/systemd/system/nas-backup-auto.timer"

need_root()  { [[ $EUID -eq 0 ]] || exec sudo "$0" "$@"; }
valid_time() { [[ "$1" =~ ^([01][0-9]|2[0-3]):[0-5][0-9]$ ]]; }

# Читаем наши ключи из конфига. Source в субшелле — массивы/секреты не утекают.
read_conf() {
    AUTO_BACKUP="off"; AUTO_BACKUP_FREQ="daily"; AUTO_BACKUP_TIME="03:00"
    [[ -f "$CONF" ]] || return
    eval "$(
        # shellcheck disable=SC1090
        source "$CONF" 2>/dev/null
        printf 'AUTO_BACKUP=%q\n'      "${AUTO_BACKUP:-off}"
        printf 'AUTO_BACKUP_FREQ=%q\n' "${AUTO_BACKUP_FREQ:-daily}"
        printf 'AUTO_BACKUP_TIME=%q\n' "${AUTO_BACKUP_TIME:-03:00}"
    )"
}

# Записать/обновить ключ в конфиге (создаёт блок если ключей ещё нет).
set_key() {
    local k="$1" v="$2"
    [[ -f "$CONF" ]] || return 1
    if grep -qE "^[[:space:]]*${k}=" "$CONF"; then
        sed -i "s#^[[:space:]]*${k}=.*#${k}=\"${v}\"#" "$CONF"
    else
        printf '%s="%s"\n' "$k" "$v" >> "$CONF"
    fi
}

write_units() {   # $1 = OnCalendar
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
OnCalendar=$1
Persistent=true
RandomizedDelaySec=5min

[Install]
WantedBy=timers.target
EOF
    systemctl daemon-reload
    systemctl enable --now "$TIMER_NAME"
}

disable_all() {
    systemctl disable --now "$TIMER_NAME" 2>/dev/null
    rm -f "$TIMER_PATH" "$SERVICE_PATH"
    systemctl daemon-reload
}

do_apply() {
    read_conf
    if [[ "$AUTO_BACKUP" != "on" ]]; then
        disable_all
        return
    fi
    valid_time "$AUTO_BACKUP_TIME" || AUTO_BACKUP_TIME="03:00"
    local cal
    case "$AUTO_BACKUP_FREQ" in
        weekly) cal="Sun *-*-* ${AUTO_BACKUP_TIME}:00" ;;
        *)      cal="*-*-* ${AUTO_BACKUP_TIME}:00" ;;
    esac
    write_units "$cal"
}

case "${1:-status}" in
    status)
        read_conf
        if [[ "$AUTO_BACKUP" == "on" ]]; then
            echo "${AUTO_BACKUP_FREQ} ${AUTO_BACKUP_TIME}"
        else
            echo "off"
        fi
        ;;
    apply)
        need_root "$@"
        do_apply
        ;;
    set)
        need_root "$@"
        freq="${2:-daily}"; time="${3:-03:00}"
        valid_time "$time" || { echo "bad time (HH:MM): $time" >&2; exit 1; }
        [[ "$freq" == daily || "$freq" == weekly ]] || { echo "bad freq: $freq" >&2; exit 1; }
        set_key AUTO_BACKUP on
        set_key AUTO_BACKUP_FREQ "$freq"
        set_key AUTO_BACKUP_TIME "$time"
        do_apply
        echo "$freq $time"
        ;;
    off)
        need_root "$@"
        set_key AUTO_BACKUP off
        do_apply
        echo "off"
        ;;
    toggle)
        need_root "$@"
        read_conf
        if [[ "$AUTO_BACKUP" == "on" ]]; then
            set_key AUTO_BACKUP off
        else
            set_key AUTO_BACKUP on
        fi
        do_apply
        read_conf
        [[ "$AUTO_BACKUP" == "on" ]] && echo "${AUTO_BACKUP_FREQ} ${AUTO_BACKUP_TIME}" || echo "off"
        ;;
    *)
        echo "usage: nas-schedule.sh {status|apply|set <daily|weekly> <HH:MM>|off|toggle}" >&2
        exit 1
        ;;
esac
