#!/bin/bash
# =============================================================================
# cpu-boost.sh — временно снять docker CPU-лимиты со ВСЕХ контейнеров под
# известную нагрузку (поставил вентилятор → жми boost). Авто-возврат через
# BOOST_MINUTES (из /etc/travel-nas/cpu-boost.conf). Thermal-guard НЕ трогаем —
# защита от перегрева остаётся (если раскалится даже с вентилятором — притормозит).
#
#   on      — снять лимиты (--cpus=0), запомнить текущие, завести авто-возврат
#   off     — вернуть запомненные лимиты, отменить таймер
#   status  — "off" | "on <минут_осталось>"
#
# state хранит конец-epoch + список "name:nanocpus" снятых лимитов.
# =============================================================================
set -u

CONF="/etc/travel-nas/cpu-boost.conf"
STATE="/var/lib/travel-nas/cpu-boost.state"
REVERT_UNIT="cpu-boost-revert"

BOOST_MINUTES=10
[[ -f "$CONF" ]] && source "$CONF" 2>/dev/null
[[ "${BOOST_MINUTES:-}" =~ ^[0-9]+$ ]] && (( BOOST_MINUTES >= 1 )) || BOOST_MINUTES=10

need_root() { [[ ${EUID:-$(id -u)} -eq 0 ]] || exec sudo "$0" "$@"; }

cmd_on() {
    need_root "$@"
    # --cpus=0 на некоторых docker НЕ снимает лимит (0 = "не задано"). Ставим
    # все ядра машины — практически без лимита, но надёжно применяется.
    local full; full=$(nproc 2>/dev/null); [[ "$full" =~ ^[0-9]+$ ]] || full=4
    local saved="" name cpus
    while read -r name; do
        [[ -n "$name" ]] || continue
        cpus=$(docker inspect "$name" --format '{{.HostConfig.NanoCpus}}' 2>/dev/null)
        [[ "$cpus" =~ ^[0-9]+$ ]] && (( cpus > 0 )) || continue   # только лимитированные
        saved+="$name:$cpus "
        docker update --cpus="$full" "$name" >/dev/null 2>&1
    done < <(docker ps --format '{{.Names}}')

    mkdir -p "$(dirname "$STATE")"
    printf '%s\n%s\n' "$(( $(date +%s) + BOOST_MINUTES * 60 ))" "$saved" > "$STATE"
    chmod 644 "$STATE" 2>/dev/null || true

    # Авто-возврат как transient-таймер. Сброс старого если жал повторно.
    systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
    systemd-run --on-active="${BOOST_MINUTES}min" --unit="$REVERT_UNIT" \
        /usr/local/bin/cpu-boost.sh off >/dev/null 2>&1 || true
    echo "BOOST ON: лимиты сняты на ${BOOST_MINUTES} мин (${saved:-нет лимитированных}). Thermal-guard активен."
}

cmd_off() {
    need_root "$@"
    systemctl stop "$REVERT_UNIT.timer" 2>/dev/null || true
    if [[ -f "$STATE" ]]; then
        local saved kv name cpus
        saved=$(sed -n '2p' "$STATE")
        for kv in $saved; do
            name="${kv%%:*}"; cpus="${kv##*:}"
            [[ -n "$name" && "$cpus" =~ ^[0-9]+$ ]] || continue
            docker update --cpus="$(awk "BEGIN{printf \"%.3f\", $cpus/1000000000}")" "$name" >/dev/null 2>&1
        done
        rm -f "$STATE"
    fi
    echo "BOOST OFF: лимиты восстановлены."
}

cmd_status() {
    if [[ -f "$STATE" ]]; then
        local end now; end=$(sed -n '1p' "$STATE" 2>/dev/null); now=$(date +%s)
        [[ "$end" =~ ^[0-9]+$ ]] || { echo "off"; return; }
        if (( end > now )); then echo "on $(( (end - now + 59) / 60 ))"; else echo "off"; fi
    else
        echo "off"
    fi
}

case "${1:-status}" in
    on|start) cmd_on "$@" ;;
    off|stop) cmd_off "$@" ;;
    status)   cmd_status ;;
    *) echo "Usage: $0 {on|off|status}" >&2; exit 1 ;;
esac
