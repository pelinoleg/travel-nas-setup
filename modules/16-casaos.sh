[[ -n "${DO_CASAOS:-}" ]] || return 0

info "=== CasaOS ==="
if command -v casaos-cli &>/dev/null; then
    mark_ok "CASAOS" "уже установлен"
else
    warn "Установка CasaOS, ~10 минут..."
    if (
        set -e
        if ! command -v curl &>/dev/null; then
            apt_install curl
        fi
        # CasaOS installer внутри тащит smartmontools и другие зависимости.
        # Если UTILS до этого упал (mirror 404), apt оказывается в broken-state
        # → installer падает "Unmet dependencies". Чиним заранее.
        wait_for_apt
        sudo DEBIAN_FRONTEND=noninteractive apt-get update -qq || true
        sudo DEBIAN_FRONTEND=noninteractive apt-get --fix-broken install -y 2>/dev/null || true
        # Преставим smartmontools и docker dependencies сами — installer тогда
        # просто проверит "уже установлено" и пойдёт дальше.
        apt_install smartmontools ca-certificates curl gnupg lsb-release || true

        wait_for_apt
        curl -fsSL https://get.casaos.io | sudo bash
    ); then
        mark_ok "CASAOS" "http://pi.local"
    else
        mark_fail "CASAOS" "install script failed"
    fi
fi

# NetworkManager: игнорим docker bridge/veth/br-* интерфейсы. Без этого
# каждый docker start/stop генерит NM state-change → desktop notification
# с именем вида "You are now connected to vetha45aeae" → выглядит как
# непонятные символы (по факту это имя docker veth-интерфейса).
if [[ -d /etc/NetworkManager/conf.d ]]; then
    sudo tee /etc/NetworkManager/conf.d/no-docker.conf >/dev/null << 'EOF'
# Travel-NAS: NM ignore docker bridges/veths. Без этого popup при
# docker start/stop с именем veth-интерфейса (выглядит как мусор).
[keyfile]
unmanaged-devices=interface-name:veth*;interface-name:docker*;interface-name:br-*
EOF
    sudo systemctl reload NetworkManager 2>/dev/null || true
fi

# Защита fstab-устройств от перехвата devmon (CasaOS поставил devmon)
if [[ -f /etc/conf.d/devmon ]] && command -v findmnt &>/dev/null; then
    FSTAB_DEVS=$(awk '/^UUID=/ {print $2}' /etc/fstab | while read mp; do
        findmnt -n -o SOURCE "$mp" 2>/dev/null || true
    done | grep -E '^/dev/' | sort -u)

    for dev in $FSTAB_DEVS; do
        if ! grep -q "ignore-device $dev" /etc/conf.d/devmon; then
            sudo sed -i "s|ARGS=\"\(.*\)\"|ARGS=\"\1 --ignore-device $dev\"|" /etc/conf.d/devmon
        fi
    done
    sudo systemctl restart devmon@devmon.service 2>/dev/null || true
fi
