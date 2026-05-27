[[ -n "${DO_COMITUP:-}" ]] || return 0

info "=== Comitup (field WiFi) ==="
if (
    set -e
    # Если уже установлен — пропускаем тяжёлую часть
    if ! dpkg -l | grep -q "^ii.*comitup "; then
        # Чистим старые подходы которые не работают на Trixie
        sudo rm -f /etc/apt/sources.list.d/comitup.list 2>/dev/null || true
        sudo rm -f /etc/apt/trusted.gpg.d/davesteele-comitup-archive-keyring.gpg 2>/dev/null || true

        TMPDEB=$(mktemp --suffix=.deb)
        # Ретраи wget — публичный CDN может моргнуть
        for i in 1 2 3; do
            if wget -qO "$TMPDEB" "https://davesteele.github.io/comitup/deb/davesteele-comitup-apt-source_1.3_all.deb"; then
                break
            fi
            warn "wget attempt $i failed, retrying"
            sleep 5
        done
        [[ -s "$TMPDEB" ]] || { err "не удалось скачать davesteele apt source"; exit 1; }

        wait_for_apt
        sudo dpkg -i "$TMPDEB"
        rm -f "$TMPDEB"
        apt_get update
        apt_install comitup
    fi

    # Проверка постусловия: comitup-cli ДОЛЖЕН существовать на /usr/sbin/
    if ! [[ -x /usr/sbin/comitup-cli ]]; then
        err "comitup установлен но /usr/sbin/comitup-cli не найден — возможно деб битый"
        exit 1
    fi
); then
    mark_ok "COMITUP" "$(/usr/sbin/comitup-cli i 2>/dev/null | head -1 || echo 'installed')"
else
    mark_fail "COMITUP" "install failed"
fi
