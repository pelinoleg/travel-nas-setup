[[ -n "${DO_HOSTNAME:-}" ]] || return 0

# Желаемое имя устройства. Меняется только здесь — везде остальное должно
# подцепиться через mDNS (avahi-daemon) автоматически.
DESIRED_HOST="travel-nas"

info "=== Hostname ==="
if (
    set -e

    # Читаем текущее имя из ТРЁХ источников. Они МОГУТ разойтись:
    #   `hostname`            — kernel runtime (uname --nodename)
    #   /etc/hostname          — что грузится при boot
    #   `hostnamectl --static` — static-name systemd-hostnamed
    CMD_HOST=$(hostname 2>/dev/null  || echo "")
    ETC_HOST=$(cat /etc/hostname 2>/dev/null | tr -d '\n' || echo "")
    HCTL_HOST=$(hostnamectl --static 2>/dev/null || echo "")

    if [[ "$CMD_HOST"  == "$DESIRED_HOST" \
       && "$ETC_HOST"  == "$DESIRED_HOST" \
       && "$HCTL_HOST" == "$DESIRED_HOST" ]]; then
        info "Hostname уже = $DESIRED_HOST (всё консистентно)"
    else
        warn "Hostname разъехался — выравниваю:"
        warn "  hostname:           $CMD_HOST"
        warn "  /etc/hostname:      $ETC_HOST"
        warn "  hostnamectl static: $HCTL_HOST"
        warn "  желаемое:           $DESIRED_HOST"

        # 1. systemd-путь (обновит /etc/hostname + transient hostname)
        sudo hostnamectl set-hostname "$DESIRED_HOST" || true

        # 2. Подстраховка — прямая запись в /etc/hostname (на случай если
        #    hostnamectl чем-то недоволен)
        echo "$DESIRED_HOST" | sudo tee /etc/hostname >/dev/null

        # 3. Сразу применяем в текущий kernel (чтобы новые процессы видели
        #    новое имя без ребута; уже запущенные шеллы свой PS1 не обновят
        #    до релогина — это норма).
        sudo hostname "$DESIRED_HOST" 2>/dev/null || true
    fi

    # /etc/hosts — единственная строка 127.0.1.1 должна указывать на DESIRED_HOST.
    if grep -qE "^[[:space:]]*127\.0\.1\.1" /etc/hosts; then
        sudo sed -i -E \
            "s|^[[:space:]]*127\.0\.1\.1[[:space:]]+\S+.*|127.0.1.1\t$DESIRED_HOST|" \
            /etc/hosts
    else
        echo -e "127.0.1.1\t$DESIRED_HOST" | sudo tee -a /etc/hosts >/dev/null
    fi
); then
    mark_ok "HOSTNAME" "$DESIRED_HOST"
    # Подсказка пользователю: текущая SSH-сессия будет показывать старое имя
    # в PS1 до релогина — это не баг, просто кешированный prompt.
    if [[ "$(hostname)" != "$DESIRED_HOST" ]]; then
        warn "Текущий shell прочитал hostname ДО изменения. Перелогинься (или sudo reboot)."
    fi
else
    mark_fail "HOSTNAME" "hostnamectl failed"
fi
